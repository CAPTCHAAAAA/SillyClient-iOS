import Foundation
import ZIPFoundation
import Darwin

enum IOSSafeArchive {
    static func relativePath(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains(":"),
              raw.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw IOSFileError.invalid("Unsafe archive path")
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), parts.count <= 64 else {
            throw IOSFileError.invalid("Unsafe archive path component")
        }
        return parts.joined(separator: "/")
    }

    static func extract(_ source: URL, to target: URL, stripSingleRoot: Bool = false,
                        maximumBytes: UInt64 = 4 * 1024 * 1024 * 1024, maximumEntries: Int = 100000,
                        include: (String) -> Bool = { _ in true }, cancelled: () throws -> Void = {}) throws {
        let files = IOSManagedFiles(root: target)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw IOSFileError.invalid("Archive staging directory is missing")
        }
        let archive = try Archive(url: source, accessMode: .read)
        var total: UInt64 = 0
        var count = 0
        var names = Set<String>()
        var rootName: String?
        for entry in archive {
            try cancelled()
            count += 1
            guard count <= maximumEntries, entry.type != .symlink,
                  entry.uncompressedSize <= maximumBytes - total else {
                throw IOSFileError.invalid("Archive exceeds its extraction limits or contains links")
            }
            total += entry.uncompressedSize
            let trimmed = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            var relative = try relativePath(trimmed)
            if stripSingleRoot {
                let segments = relative.split(separator: "/")
                let currentRoot = String(segments[0])
                if let previous = rootName, previous != currentRoot {
                    throw IOSFileError.invalid("Archive does not have a unique root")
                }
                rootName = currentRoot
                if segments.count == 1 {
                    guard entry.type == .directory else { throw IOSFileError.invalid("Archive root is not a directory") }
                    continue
                }
                relative = segments.dropFirst().joined(separator: "/")
            }
            let nameKey = relative.precomposedStringWithCanonicalMapping.lowercased()
            if entry.type == .directory {
                if !names.insert(nameKey).inserted {
                    continue
                }
            } else {
                guard names.insert(nameKey).inserted else { throw IOSFileError.invalid("Archive contains duplicate paths") }
            }
            if !include(relative) { continue }
            let destination = target.appendingPathComponent(relative)
            _ = try files.checked(destination, allowMissing: true)
            if entry.type == .directory {
                try files.createDirectory(destination)
                continue
            }
            try files.createDirectory(destination.deletingLastPathComponent())
            guard !files.exists(destination) else { throw IOSFileError.invalid("Archive destination already exists") }
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let created = try files.guardValue(destination)
            defer { try? handle.close() }
            var written: UInt64 = 0
            let checksum = try archive.extract(entry, bufferSize: 32768, skipCRC32: false) { chunk in
                try cancelled()
                guard UInt64(chunk.count) <= entry.uncompressedSize - written else {
                    throw IOSFileError.invalid("Archive entry is larger than its declared size")
                }
                written += UInt64(chunk.count)
                try handle.write(contentsOf: chunk)
            }
            guard written == entry.uncompressedSize, checksum == entry.checksum,
                  try files.guardValue(destination).identity == created.identity else {
                throw IOSFileError.invalid("Archive checksum or size verification failed")
            }
        }
        guard count > 0 else { throw IOSFileError.invalid("Archive is empty") }
    }

    struct ImportSummary {
        let importEntries: Int
        let importBytes: Int64
        let skippedEntries: Int
        let skippedBytes: Int64
        let hasSecrets: Bool
        let hasConfig: Bool
        let wrapperPrefix: String
        var importable: Bool { importEntries > 0 }

        var dictionary: [String: Any] {
            [
                "importEntries": importEntries,
                "importBytes": importBytes,
                "skippedEntries": skippedEntries,
                "skippedBytes": skippedBytes,
                "hasSecrets": hasSecrets,
                "hasConfig": hasConfig,
                "importable": importable
            ]
        }
    }

    struct PlannedEntry {
        let entry: Entry
        let targetRelativePath: String
    }

    private static let extensionsRoot = "public/scripts/extensions/third-party"
    private static let webpackCache = "data/_webpack"
    private static let optionalFiles = Set(["secrets.json", "config.yaml", "config.yml"])

    private static func isUserData(_ path: String) -> Bool {
        if path == "data" || path.hasPrefix("data/") {
            return path != webpackCache && !path.hasPrefix("\(webpackCache)/")
        }
        if path == "plugins" || path.hasPrefix("plugins/") { return true }
        if path == extensionsRoot || path.hasPrefix("\(extensionsRoot)/") { return true }
        if ["public", "public/scripts", "public/scripts/extensions"].contains(path) { return true }
        return false
    }

    private static func isHostMetadata(_ path: String) -> Bool {
        return path == ".sc-identity"
            || path == ".sillyclient-dependencies-pending"
            || path.hasPrefix(".sillyclient-")
            || path.hasPrefix(".sc-import-tmp-")
    }

    private static func detectWrapperPrefix(_ entries: [(path: String, isDirectory: Bool)]) -> String {
        guard let first = entries.first?.path else { return "" }
        let root = String(first.split(separator: "/").first ?? "")
        if ["data", "public", "src", "node_modules", "plugins", "default-user"].contains(root) {
            return ""
        }
        let prefix = "\(root)/"
        if entries.contains(where: { $0.path != root && !$0.path.hasPrefix(prefix) }) {
            return ""
        }
        if entries.contains(where: { $0.path == root && !$0.isDirectory }) {
            return ""
        }
        let hasInstanceRoot = entries.contains { item in
            let relative = String(item.path.dropFirst(prefix.count))
            return ["server.js", "package.json", "config.yaml"].contains(relative)
                || relative.hasPrefix("data/")
                || (relative == "data" && item.isDirectory)
        }
        return hasInstanceRoot ? prefix : ""
    }

    private static func planArchive(_ archiveURL: URL, includeOptional: Bool) throws -> (summary: ImportSummary, included: [PlannedEntry]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: archiveURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw IOSFileError.invalid("Archive file does not exist or is a directory")
        }
        let attributes = try fm.attributesOfItem(atPath: archiveURL.path)
        let fileSize = (attributes[.size] as? Int64) ?? 0
        guard fileSize >= 22 && fileSize <= 2 * 1024 * 1024 * 1024 else {
            throw IOSFileError.invalid("Archive size is invalid or exceeds 2GB limit")
        }
        let archive = try Archive(url: archiveURL, accessMode: .read)
        var entriesList: [(entry: Entry, path: String, isDirectory: Bool)] = []
        var seenPaths = Set<String>()
        var declaredBytes: UInt64 = 0

        for entry in archive {
            guard entriesList.count < 131072 else {
                throw IOSFileError.invalid("Archive exceeds entry count limit")
            }
            let trimmed = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let validPath = try relativePath(trimmed)
            let lower = validPath.lowercased()
            if entry.type != .directory {
                guard seenPaths.insert(lower).inserted else {
                    throw IOSFileError.invalid("Archive contains duplicate paths: \(validPath)")
                }
            } else {
                seenPaths.insert(lower)
            }
            guard entry.uncompressedSize <= 512 * 1024 * 1024 else {
                throw IOSFileError.invalid("Single archive entry exceeds 512MB limit")
            }
            declaredBytes += entry.uncompressedSize
            guard declaredBytes <= 4 * 1024 * 1024 * 1024 else {
                throw IOSFileError.invalid("Archive uncompressed size exceeds 4GB limit")
            }
            entriesList.append((entry: entry, path: validPath, isDirectory: entry.type == .directory))
        }

        let prefix = detectWrapperPrefix(entriesList.map { ($0.path, $0.isDirectory) })
        var importEntries = 0
        var importBytes: Int64 = 0
        var skippedEntries = 0
        var skippedBytes: Int64 = 0
        var hasSecrets = false
        var hasConfig = false
        var included: [PlannedEntry] = []

        for item in entriesList {
            if item.isDirectory && !prefix.isEmpty && item.path == String(prefix.dropLast()) {
                continue
            }
            let relative = prefix.isEmpty ? item.path : (item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path)
            if relative.isEmpty || isHostMetadata(relative) { continue }

            let isOptional = optionalFiles.contains(relative)
            if isOptional {
                if relative == "secrets.json" { hasSecrets = true }
                else { hasConfig = true }

                if includeOptional {
                    included.append(PlannedEntry(entry: item.entry, targetRelativePath: relative))
                    importEntries += 1
                    importBytes += Int64(item.entry.uncompressedSize)
                } else {
                    skippedEntries += 1
                    skippedBytes += Int64(item.entry.uncompressedSize)
                }
                continue
            }

            if isUserData(relative) {
                included.append(PlannedEntry(entry: item.entry, targetRelativePath: relative))
                importEntries += 1
                importBytes += Int64(item.entry.uncompressedSize)
            } else {
                skippedEntries += 1
                skippedBytes += Int64(item.entry.uncompressedSize)
            }
        }

        let summary = ImportSummary(
            importEntries: importEntries,
            importBytes: importBytes,
            skippedEntries: skippedEntries,
            skippedBytes: skippedBytes,
            hasSecrets: hasSecrets,
            hasConfig: hasConfig,
            wrapperPrefix: prefix
        )
        return (summary, included)
    }

    static func inspectArchive(_ archiveURL: URL) throws -> ImportSummary {
        let (summary, _) = try planArchive(archiveURL, includeOptional: false)
        return summary
    }

    static func importArchiveData(_ archiveURL: URL, targetDir: URL, includeOptional: Bool) throws -> (imported: Int, bytes: Int64, skipped: Int) {
        let fm = FileManager.default
        let serverJS = targetDir.appendingPathComponent("server.js")
        guard fm.fileExists(atPath: serverJS.path) else {
            throw IOSFileError.invalid("Instance directory does not exist or server.js is missing")
        }
        let (summary, included) = try planArchive(archiveURL, includeOptional: includeOptional)
        guard summary.importable else {
            throw IOSFileError.invalid("No importable user data found in archive")
        }
        let archive = try Archive(url: archiveURL, accessMode: .read)
        var imported = 0
        var bytes: Int64 = 0

        for item in included {
            let targetFile = targetDir.appendingPathComponent(item.targetRelativePath).resolvingSymlinksInPath()
            guard targetFile.path.hasPrefix(targetDir.path) else {
                throw IOSFileError.invalid("Import path escapes instance directory: \(item.targetRelativePath)")
            }

            if item.entry.type == .directory {
                try fm.createDirectory(at: targetFile, withIntermediateDirectories: true)
                continue
            }

            let parentDir = targetFile.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let tempFile = parentDir.appendingPathComponent(".sc-import-tmp-\(UUID().uuidString)")
            let descriptor = open(tempFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var written: UInt64 = 0
            do {
                let checksum = try archive.extract(item.entry, bufferSize: 32768, skipCRC32: false) { chunk in
                    guard UInt64(chunk.count) <= item.entry.uncompressedSize - written else {
                        throw IOSFileError.invalid("Archive entry exceeds declared size")
                    }
                    written += UInt64(chunk.count)
                    try handle.write(contentsOf: chunk)
                }
                try? handle.close()
                guard written == item.entry.uncompressedSize, checksum == item.entry.checksum else {
                    throw IOSFileError.invalid("CRC or size verification failed for entry: \(item.targetRelativePath)")
                }

                if fm.fileExists(atPath: targetFile.path) {
                    try fm.removeItem(at: targetFile)
                }
                try fm.moveItem(at: tempFile, to: targetFile)
                imported += 1
                bytes += Int64(written)
            } catch {
                try? handle.close()
                if fm.fileExists(atPath: tempFile.path) {
                    try? fm.removeItem(at: tempFile)
                }
                throw error
            }
        }

        return (imported, bytes, summary.skippedEntries)
    }

    static func exportInstanceDirectory(_ sourceDir: URL, destinationURL: URL) throws -> Int64 {
        let fm = FileManager.default
        let serverJS = sourceDir.appendingPathComponent("server.js")
        guard fm.fileExists(atPath: serverJS.path) else {
            throw IOSFileError.invalid("Instance directory does not exist or server.js is missing")
        }
        let parentDir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        let archive = try Archive(url: destinationURL, accessMode: .create)

        let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [])
        let basePath = sourceDir.standardizedFileURL.path

        while let fileURL = enumerator?.nextObject() as? URL {
            let name = fileURL.lastPathComponent
            if [".git", "node_modules", ".cache"].contains(name)
                || name.hasPrefix(".sillyclient-")
                || name.hasPrefix(".sc-import-tmp-") {
                enumerator?.skipDescendants()
                continue
            }
            let standardFileURL = fileURL.standardizedFileURL
            guard standardFileURL.path.hasPrefix(basePath) else { continue }
            var relative = String(standardFileURL.path.dropFirst(basePath.count))
            if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
            if relative.isEmpty { continue }

            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if resourceValues.isDirectory == true {
                // uncompressedSize 必须显式 Int64：ZIPFoundation 0.9.19 同时存在 Int64 与已弃用 UInt32 重载，字面量 0 会触发歧义编译错误。
                try archive.addEntry(with: "\(relative)/", type: .directory, uncompressedSize: Int64(0), compressionMethod: .none, provider: { (_: UInt64, _: Int) in Data() })
            } else if resourceValues.isRegularFile == true {
                let data = try Data(contentsOf: fileURL)
                try archive.addEntry(with: relative, type: .file, uncompressedSize: Int64(data.count),
                                     compressionMethod: .deflate, provider: { offset, size in
                    data.subdata(in: Int(offset)..<min(data.count, Int(offset) + size))
                })
            }
        }

        let attr = try fm.attributesOfItem(atPath: destinationURL.path)
        return (attr[.size] as? Int64) ?? 0
    }
}
