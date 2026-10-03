import Foundation
import CryptoKit
import Darwin

enum IOSFileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct IOSFileGuard: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let birthSeconds: Int64
    let birthNanos: Int64
    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var identity: String { "\(device):\(inode):\(birthSeconds):\(birthNanos)" }
    var fingerprint: String {
        "\(identity):\(mode):\(size):\(modifiedSeconds):\(modifiedNanos)"
    }
}

struct IOSFileSnapshot: Equatable {
    let digest: String
    let contentDigest: String
    let bytes: Int64
    let guardValue: IOSFileGuard
    let observations: [IOSFileObservation]
}

struct IOSFileObservation: Equatable {
    let relative: String
    let value: IOSFileGuard
}

final class IOSInspectionBudget {
    private(set) var entries = 0
    private(set) var bytes: Int64 = 0
    let maxEntries: Int
    let maxBytes: Int64
    init(maxEntries: Int = 16384, maxBytes: Int64 = 256 * 1024 * 1024) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }
    func spend(entries count: Int = 0, bytes byteCount: Int64 = 0) throws {
        guard count >= 0, byteCount >= 0, count <= maxEntries - entries, byteCount <= maxBytes - bytes else {
            throw IOSFileError.invalid("Inspection limit reached; uninspected files were preserved")
        }
        entries += count
        bytes += byteCount
    }
}

final class IOSManagedFiles {
    let root: URL
    private let fm = FileManager.default
    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func checked(_ url: URL, allowMissing: Bool = false) throws -> URL {
        let candidate = url.standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw IOSFileError.invalid("Path is outside its managed root")
        }
        let relative = candidate.path == root.path ? "" : String(candidate.path.dropFirst(root.path.count + 1))
        var current = root
        _ = try rawGuard(root)
        for part in relative.split(separator: "/") {
            current.appendPathComponent(String(part))
            if !exists(current) {
                guard allowMissing else { throw IOSFileError.invalid("Managed path is missing") }
                continue
            }
            _ = try rawGuard(current)
        }
        return candidate
    }

    func exists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
    }

    private func fromStat(_ value: stat) throws -> IOSFileGuard {
        let type = value.st_mode & mode_t(S_IFMT)
        guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else {
            throw IOSFileError.invalid("Links and non-regular files were preserved")
        }
        return IOSFileGuard(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino),
            mode: UInt16(value.st_mode), size: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanos: Int64(value.st_mtimespec.tv_nsec),
            birthSeconds: Int64(value.st_birthtimespec.tv_sec), birthNanos: Int64(value.st_birthtimespec.tv_nsec))
    }

    private func rawGuard(_ url: URL) throws -> IOSFileGuard {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try fromStat(value)
    }

    func guardValue(_ url: URL) throws -> IOSFileGuard { try rawGuard(checked(url)) }

    func boundedChildren(_ directory: URL, limit: Int) throws -> (items: [URL], truncated: Bool) {
        guard limit >= 0 else { throw IOSFileError.invalid("Invalid directory entry limit") }
        let safe = try checked(directory)
        let before = try rawGuard(safe)
        guard before.isDirectory, let handle = opendir(safe.path) else {
            throw IOSFileError.invalid("Cannot enumerate the managed directory")
        }
        defer { closedir(handle) }
        var result: [URL] = []
        var truncated = false
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if result.count == limit { truncated = true; break }
            result.append(safe.appendingPathComponent(name))
        }
        guard try rawGuard(safe) == before else { throw IOSFileError.invalid("Directory changed during enumeration") }
        return (result.sorted { $0.lastPathComponent < $1.lastPathComponent }, truncated)
    }

    func children(_ directory: URL, limit: Int = 8192) throws -> [URL] {
        let result = try boundedChildren(directory, limit: limit)
        guard !result.truncated else { throw IOSFileError.invalid("Directory entry limit reached") }
        return result.items
    }

    func data(_ file: URL, maximum: Int = 1024 * 1024, budget: IOSInspectionBudget? = nil) throws -> Data {
        let safe = try checked(file)
        let before = try rawGuard(safe)
        guard !before.isDirectory, before.size >= 0, before.size <= maximum else {
            throw IOSFileError.invalid("Metadata is not a bounded regular file")
        }
        let descriptor = open(safe.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, try fromStat(opened) == before else {
            throw IOSFileError.invalid("File changed before it could be read")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 32768)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, count <= maximum - result.count else {
                throw IOSFileError.invalid("Metadata exceeds its inspection limit")
            }
            try budget?.spend(bytes: Int64(count))
            result.append(contentsOf: buffer.prefix(count))
        }
        guard try rawGuard(safe) == before else { throw IOSFileError.invalid("File changed while being read") }
        return result
    }

    func json(_ file: URL, budget: IOSInspectionBudget? = nil) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data(file, budget: budget)) as? [String: Any] else {
            throw IOSFileError.invalid("JSON metadata must be an object")
        }
        return value
    }

    func snapshot(_ file: URL, budget: IOSInspectionBudget = IOSInspectionBudget(),
                  maximumBytes: Int64 = 128 * 1024 * 1024, cancelled: () throws -> Void = {}) throws -> IOSFileSnapshot {
        let original = try checked(file)
        let rootGuard = try rawGuard(original)
        var digest = SHA256()
        var content = SHA256()
        var entries = 0
        var total: Int64 = 0
        var observations: [IOSFileObservation] = []
        func visit(_ current: URL, depth: Int) throws {
            try cancelled()
            entries += 1
            guard entries <= 8192, depth <= 64 else { throw IOSFileError.invalid("Inspection tree limit reached") }
            try budget.spend(entries: 1)
            _ = try checked(current)
            let before = try rawGuard(current)
            let relative = current == original ? "." : String(current.path.dropFirst(original.path.count + 1))
            observations.append(IOSFileObservation(relative: relative, value: before))
            digest.update(data: Data("\(relative)\0\(before.fingerprint)\0".utf8))
            content.update(data: Data("\(relative)\0\(before.isDirectory)\0".utf8))
            if before.isDirectory {
                for child in try children(current, limit: 8192 - entries) { try visit(child, depth: depth + 1) }
            } else {
                guard before.size >= 0, before.size <= maximumBytes - total else {
                    throw IOSFileError.invalid("Inspection byte limit reached")
                }
                let descriptor = open(current.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, try fromStat(opened) == before else {
                    throw IOSFileError.invalid("Inspection file changed before opening")
                }
                var buffer = [UInt8](repeating: 0, count: 32768)
                while true {
                    try cancelled()
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0, Int64(count) <= maximumBytes - total else {
                        throw IOSFileError.invalid("Inspection byte limit reached")
                    }
                    try budget.spend(bytes: Int64(count))
                    total += Int64(count)
                    let chunk = Data(buffer.prefix(count))
                    digest.update(data: chunk)
                    content.update(data: chunk)
                }
            }
            guard try rawGuard(current) == before else { throw IOSFileError.invalid("Inspection content changed") }
        }
        try visit(original, depth: 0)
        guard try rawGuard(original) == rootGuard else { throw IOSFileError.invalid("Inspection root changed") }
        return IOSFileSnapshot(digest: Self.hex(digest.finalize()), contentDigest: Self.hex(content.finalize()),
            bytes: total, guardValue: rootGuard, observations: observations)
    }

    func validate(_ snapshot: IOSFileSnapshot, at file: URL) throws {
        let original = try checked(file)
        for observation in snapshot.observations {
            let item = observation.relative == "." ? original : original.appendingPathComponent(observation.relative)
            guard try rawGuard(checked(item)) == observation.value else {
                throw IOSFileError.invalid("Inspected content changed before the operation committed")
            }
        }
    }

    func copyTree(_ source: URL, to target: URL, destination: IOSManagedFiles,
                  budget: IOSInspectionBudget = IOSInspectionBudget(maxEntries: 32768, maxBytes: 2 * 1024 * 1024 * 1024),
                  include: (String) -> Bool = { _ in true }, cancelled: () throws -> Void = {}) throws {
        let original = try checked(source)
        guard !destination.exists(target) else { throw IOSFileError.invalid("Copy destination already exists") }
        var inspected: [(URL, IOSFileGuard)] = []
        let verificationBudget = IOSInspectionBudget(maxEntries: budget.maxEntries, maxBytes: budget.maxBytes)
        func visit(_ current: URL, _ output: URL, depth: Int) throws {
            try cancelled()
            guard depth <= 64 else { throw IOSFileError.invalid("Migration nesting limit reached") }
            try budget.spend(entries: 1)
            let before = try rawGuard(checked(current))
            inspected.append((current, before))
            if before.isDirectory {
                try destination.createDirectory(output)
                for child in try children(current, limit: budget.maxEntries - budget.entries) {
                    let relative = String(child.path.dropFirst(original.path.count + 1))
                    if include(relative) {
                        try visit(child, output.appendingPathComponent(child.lastPathComponent), depth: depth + 1)
                    }
                }
            } else {
                guard before.size >= 0, before.size <= budget.maxBytes - budget.bytes else {
                    throw IOSFileError.invalid("Migration byte limit reached")
                }
                try destination.createDirectory(output.deletingLastPathComponent())
                let input = open(current.path, O_RDONLY | O_NOFOLLOW)
                guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { close(input) }
                var opened = stat()
                guard fstat(input, &opened) == 0, try fromStat(opened) == before else {
                    throw IOSFileError.invalid("Migration source changed before opening")
                }
                let safeOutput = try destination.checked(output, allowMissing: true)
                let descriptor = open(safeOutput.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { close(descriptor) }
                let created = try destination.guardValue(safeOutput)
                var expected = SHA256()
                expected.update(data: Data(".\0false\0".utf8))
                var copied: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 32768)
                while true {
                    try cancelled()
                    let count = Darwin.read(input, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0, Int64(count) <= before.size - copied else {
                        throw IOSFileError.invalid("Migration source grew or could not be read")
                    }
                    try budget.spend(bytes: Int64(count))
                    copied += Int64(count)
                    let chunk = Data(buffer.prefix(count))
                    expected.update(data: chunk)
                    try chunk.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < count {
                            let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                            if written < 0 && errno == EINTR { continue }
                            guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                            offset += written
                        }
                    }
                }
                guard copied == before.size, fstat(input, &opened) == 0, try fromStat(opened) == before,
                      fsync(descriptor) == 0 else { throw IOSFileError.invalid("Migration source changed or its copy was incomplete") }
                let actual = try destination.snapshot(safeOutput, budget: verificationBudget,
                                                      maximumBytes: budget.maxBytes, cancelled: cancelled)
                guard actual.guardValue.identity == created.identity,
                      actual.contentDigest == Self.hex(expected.finalize()) else {
                    throw IOSFileError.invalid("Copied user data did not verify")
                }
            }
            guard try rawGuard(checked(current)) == before else { throw IOSFileError.invalid("Migration source changed") }
        }
        try visit(original, target, depth: 0)
        for (path, expected) in inspected {
            try cancelled()
            guard try rawGuard(checked(path)) == expected else { throw IOSFileError.invalid("Migration source changed after copying") }
        }
    }

    static func hex<T: Sequence>(_ values: T) -> String where T.Element == UInt8 {
        values.map { String(format: "%02x", $0) }.joined()
    }

    func createDirectory(_ directory: URL) throws {
        let target = try checked(directory, allowMissing: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        _ = try checked(target)
    }

    func move(_ source: URL, to target: URL, replace: Bool = false) throws {
        let safeSource = try checked(source)
        let safeTarget = try checked(target, allowMissing: !replace)
        guard try guardValue(safeTarget.deletingLastPathComponent()).isDirectory else {
            throw IOSFileError.invalid("Move destination parent is unavailable")
        }
        let flags = replace ? UInt32(0) : UInt32(RENAME_EXCL)
        guard renamex_np(safeSource.path, safeTarget.path, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func write(_ data: Data, to target: URL, replace: Bool = true) throws {
        let safeTarget = try checked(target, allowMissing: true)
        let temporary = safeTarget.deletingLastPathComponent().appendingPathComponent(".sillyclient-write-\(UUID().uuidString).tmp")
        _ = try checked(temporary, allowMissing: true)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var closed = false
        defer {
            if !closed { close(descriptor) }
            if exists(temporary) { try? fm.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        closed = true
        if replace && exists(safeTarget) { try move(temporary, to: safeTarget, replace: true) }
        else { try move(temporary, to: safeTarget) }
    }

    func writeJSON(_ value: [String: Any], to target: URL, replace: Bool = true) throws {
        try write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]), to: target, replace: replace)
    }

    func relative(_ file: URL) throws -> String {
        let safe = try checked(file, allowMissing: true)
        guard safe != root else { throw IOSFileError.invalid("The managed root is not an item path") }
        return String(safe.path.dropFirst(root.path.count + 1))
    }
}
