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
                        maximumBytes: UInt64 = 512 * 1024 * 1024, maximumEntries: Int = 30000,
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
            guard names.insert(nameKey).inserted else { throw IOSFileError.invalid("Archive contains duplicate paths") }
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

}
