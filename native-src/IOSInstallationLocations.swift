import Foundation

typealias IOSCoordinatedRead = (URL, (URL) throws -> Void) throws -> Void

final class IOSInstallationLocation {
    let root: URL
    let directory: URL
    let files: IOSManagedFiles
    let grantId: String?
    let rootIdentity: String
    private let release: () -> Void

    init(root: URL, directory: URL, grantId: String?, identity: String, release: @escaping () -> Void = {}) {
        self.root = root
        self.directory = directory
        self.grantId = grantId
        rootIdentity = identity
        files = IOSManagedFiles(root: root, expectedRootIdentity: identity)
        self.release = release
    }
    deinit { release() }
}

final class IOSInstallationLocations {
    private let documents: URL
    private let files: IOSManagedFiles
    private let makeBookmark: (URL) throws -> Data
    private let resolveBookmark: (Data) throws -> (URL, Bool)
    private let startScope: (URL) -> Bool
    private let stopScope: (URL) -> Void
    private let coordinateRead: IOSCoordinatedRead
    private let externalCapability: (URL) throws -> Void
    private var registryURL: URL { documents.appendingPathComponent(".sillyclient-installation-roots.json") }

    init(documents: URL,
         makeBookmark: @escaping (URL) throws -> Data = {
             return try $0.bookmarkData(options: .minimalBookmark,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
         },
         resolveBookmark: @escaping (Data) throws -> (URL, Bool) = {
             var stale = false
             let url = try URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &stale)
             return (url, stale)
         },
         startScope: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopScope: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         coordinateRead: @escaping IOSCoordinatedRead = { url, accessor in
             let coordinator = NSFileCoordinator(filePresenter: nil)
             var coordinationError: NSError?
             var accessorError: Error?
             coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                 do { try accessor(coordinatedURL) }
                 catch { accessorError = error }
             }
             if let coordinationError { throw coordinationError }
             if let accessorError { throw accessorError }
         },
         externalCapability: @escaping (URL) throws -> Void = IOSInstallationLocations.requireLocalRuntime) {
        self.documents = documents
        files = IOSManagedFiles(root: documents)
        self.makeBookmark = makeBookmark
        self.resolveBookmark = resolveBookmark
        self.startScope = startScope
        self.stopScope = stopScope
        self.coordinateRead = coordinateRead
        self.externalCapability = externalCapability
    }

    static func path(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'",
           value.last == first { value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }),
              !value.contains("\\") else { throw IOSFileError.invalid("An absolute local installation path is required") }
        let url: URL
        if value.hasPrefix("/") { url = URL(fileURLWithPath: value) }
        else {
            guard let parsed = URL(string: value), parsed.isFileURL, parsed.host == nil || parsed.host == "",
                  parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil else {
                throw IOSFileError.invalid("Only absolute local paths and credential-free file URLs are supported")
            }
            url = parsed
        }
        guard url.path.hasPrefix("/"), !url.path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw IOSFileError.invalid("Installation paths cannot be relative or contain parent traversal")
        }
        return url.standardizedFileURL
    }

    static func contains(_ root: URL, _ path: URL) -> Bool {
        path.path == root.path || path.path.hasPrefix(root.path + "/")
    }

    private func records() throws -> [String: [String: Any]] {
        guard files.exists(registryURL) else { return [:] }
        let value = try files.json(registryURL)
        guard value["revision"] as? Int == 1, let roots = value["roots"] as? [String: [String: Any]], roots.count <= 32 else {
            throw IOSFileError.invalid("Installation root authorization metadata is invalid")
        }
        return roots
    }

    private static func requireLocalRuntime(_ root: URL) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
        guard values.isDirectory == true, values.isUbiquitousItem != true else {
            throw IOSFileError.invalid("Cloud-only installation roots cannot host the embedded runtime; select a local directory")
        }
        let managed = IOSManagedFiles(root: root)
        let probe = root.appendingPathComponent(".sillyclient-capability-\(UUID().uuidString)")
        // Probe only launcher-created files. No provider file is replaced or removed.
        try managed.createExclusiveDirectory(probe)
        defer { try? FileManager.default.removeItem(at: managed.checked(probe)) }
        let first = probe.appendingPathComponent("first")
        let second = probe.appendingPathComponent("second")
        let bytes = Data("sillyclient-local-runtime".utf8)
        try managed.write(bytes, to: first, replace: false)
        try managed.move(first, to: second)
        guard try managed.data(second) == bytes else { throw IOSFileError.invalid("The selected provider cannot retain local runtime files") }
    }

    @discardableResult
    func select(_ selected: URL) throws -> URL {
        var stage = "validate-selection"
        var scoped = false
        do {
            guard selected.isFileURL else { throw IOSFileError.invalid("The selected installation root is not a local directory URL") }
            stage = "start-security-scope"
            scoped = startScope(selected)
            NSLog("[IOSInstallationLocations] stage=%@ scope=%@", stage, String(scoped))
            defer { if scoped { stopScope(selected) } }
            var root: URL?
            var rootIdentity: String?
            stage = "coordinate-selected-directory"
            try coordinateRead(selected) { coordinatedURL in
                stage = "inspect-coordinated-directory"
                let candidate = coordinatedURL.resolvingSymlinksInPath().standardizedFileURL
                guard candidate.path != "/", candidate.path == self.documents.path || !Self.contains(candidate, self.documents) else {
                    throw IOSFileError.invalid("A filesystem root or sandbox ancestor cannot be an installation root")
                }
                let identity = try IOSManagedFiles(root: candidate).guardValue(candidate)
                guard identity.isDirectory else { throw IOSFileError.invalid("Select an installation directory") }
                root = candidate
                rootIdentity = identity.identity
            }
            guard let root, let rootIdentity else { throw IOSFileError.invalid("The file provider did not provide an authorized directory URL") }
            let internalRoot = Self.contains(documents, root)
            guard internalRoot || scoped else { throw IOSFileError.invalid("The selected installation root has no security-scoped authorization") }
            // Keep selection lightweight; validate provider write capabilities only when creating an instance.
            stage = "read-authorization-registry"
            var roots = try records()
            let key = roots.first(where: { $0.value["path"] as? String == root.path })?.key ?? UUID().uuidString
            guard roots[key] != nil || roots.count < 32 else { throw IOSFileError.invalid("Installation root authorization capacity reached") }
            var record: [String: Any] = ["path": root.path, "rootIdentity": rootIdentity]
            if internalRoot {
                record["kind"] = "documents"
                record["relativePath"] = root.path == documents.path ? "" : String(root.path.dropFirst(documents.path.count + 1))
            } else {
                stage = "create-security-scoped-bookmark"
                let bookmark = try makeBookmark(selected)
                guard !bookmark.isEmpty, bookmark.count <= 16384 else { throw IOSFileError.invalid("Installation root bookmark is invalid or oversized") }
                record["kind"] = "bookmark"
                record["bookmark"] = bookmark.base64EncodedString()
            }
            roots[key] = record
            stage = "write-authorization-registry"
            try files.writeJSON(["revision": 1, "roots": roots], to: registryURL)
            NSLog("[IOSInstallationLocations] stage=complete scope=%@", String(scoped))
            return root
        } catch {
            let nsError = error as NSError
            NSLog("[IOSInstallationLocations] stage=%@ scope=%@ domain=%@ code=%ld", stage, String(scoped), nsError.domain, nsError.code)
            throw IOSFileError.invalid("Installation folder selection failed at \(stage) [\(nsError.domain):\(nsError.code)]: \(error.localizedDescription)")
        }
    }

    func validateExternalCapability(for location: IOSInstallationLocation) throws {
        guard !Self.contains(documents, location.root) else { return }
        try externalCapability(location.root)
    }

    func acquire(_ target: URL, grantId: String? = nil) throws -> IOSInstallationLocation {
        if Self.contains(documents, target) {
            let identity = try files.guardValue(documents).identity
            _ = try files.checked(target, allowMissing: true)
            return IOSInstallationLocation(root: documents, directory: target, grantId: nil, identity: identity)
        }
        let roots = try records()
        let matches = roots.filter { entry in
            guard entry.value["kind"] as? String == "bookmark",
                  let path = entry.value["path"] as? String else { return false }
            return (grantId == nil || entry.key == grantId) && Self.contains(URL(fileURLWithPath: path), target)
        }.sorted { ($0.value["path"] as? String ?? "").count > ($1.value["path"] as? String ?? "").count }
        guard let match = matches.first, let encoded = match.value["bookmark"] as? String,
              encoded.utf8.count <= 21848, let bookmark = Data(base64Encoded: encoded),
              let expectedPath = match.value["path"] as? String, let identity = match.value["rootIdentity"] as? String else {
            throw IOSFileError.invalid("Select this installation root again to grant persistent access; no default directory was used")
        }
        let scopedURL: URL
        let stale: Bool
        do { (scopedURL, stale) = try resolveBookmark(bookmark) }
        catch {
            let nsError = error as NSError
            NSLog("[IOSInstallationLocations] stage=resolve-security-scoped-bookmark domain=%@ code=%ld", nsError.domain, nsError.code)
            throw IOSFileError.invalid("Installation folder authorization could not be restored [\(nsError.domain):\(nsError.code)]: \(error.localizedDescription)")
        }
        guard !stale, scopedURL.isFileURL else { throw IOSFileError.invalid("Installation root bookmark is stale; select the same directory again") }
        let scopeStarted = startScope(scopedURL)
        NSLog("[IOSInstallationLocations] stage=restore-security-scope scope=%@", String(scopeStarted))
        guard scopeStarted else { throw IOSFileError.invalid("Installation root authorization was lost; select the same directory again") }
        var retained = false
        defer { if !retained { stopScope(scopedURL) } }
        let root = scopedURL.resolvingSymlinksInPath().standardizedFileURL
        guard root.path == expectedPath else { throw IOSFileError.invalid("Installation root bookmark moved to another location; no runtime was substituted") }
        let managed = IOSManagedFiles(root: root, expectedRootIdentity: identity)
        guard try managed.guardValue(root).isDirectory else { throw IOSFileError.invalid("Installation root is unavailable") }
        _ = try managed.checked(target, allowMissing: true)
        let values = try root.resourceValues(forKeys: [.isUbiquitousItemKey])
        guard values.isUbiquitousItem != true else { throw IOSFileError.invalid("The selected installation root is not locally available") }
        retained = true
        return IOSInstallationLocation(root: root, directory: target, grantId: match.key, identity: identity) {
            self.stopScope(scopedURL)
        }
    }
}
