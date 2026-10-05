import Foundation

final class IOSRelocationJournal {
    private let store: IOSInstanceStore
    private let id: String
    private let url: URL
    private var value: [String: Any]

    static func url(_ store: IOSInstanceStore, _ id: String) -> URL {
        store.documents.appendingPathComponent(".sillyclient-relocations/\(id).json")
    }

    private static func pathRecord(_ store: IOSInstanceStore, _ path: URL) -> [String: Any] {
        if IOSInstallationLocations.contains(store.documents, path) {
            return ["documentsRelativePath": String(path.path.dropFirst(store.documents.path.count + 1))]
        }
        return ["path": path.path]
    }

    init(store: IOSInstanceStore, id: String, source: IOSInstallationLocation,
         destination: IOSInstallationLocation, staging: URL, sameVolume: Bool,
         originals: [String: Data]) throws {
        self.store = store
        self.id = id
        url = Self.url(store, id)
        guard originals.values.reduce(0, { $0 + $1.count }) <= 256 * 1024 else {
            throw IOSFileError.invalid("Instance metadata exceeds the relocation recovery limit")
        }
        value = ["revision": 1, "instanceId": id,
            "source": Self.pathRecord(store, source.directory), "target": Self.pathRecord(store, destination.directory),
            "stagingName": staging.lastPathComponent, "sameVolume": sameVolume,
            "sourceIdentity": try source.files.guardValue(source.directory).identity,
            "sourceRootIdentity": source.rootIdentity, "targetRootIdentity": destination.rootIdentity,
            "originals": originals.mapValues { $0.base64EncodedString() }, "changed": [String: String]()]
        if let grant = source.grantId { value["sourceGrant"] = grant }
        if let grant = destination.grantId { value["targetGrant"] = grant }
        if sameVolume { value["stagedIdentity"] = value["sourceIdentity"] }
        try store.files.createDirectory(url.deletingLastPathComponent())
        try store.files.writeJSON(value, to: url, replace: false)
    }

    init(store: IOSInstanceStore, id: String) throws {
        self.store = store
        self.id = id
        url = Self.url(store, id)
        value = try store.files.json(url)
        guard value["revision"] as? Int == 1, value["instanceId"] as? String == id else {
            throw IOSFileError.invalid("Relocation recovery identity is invalid; all contents were preserved")
        }
    }

    func staged(_ identity: String) throws {
        value["stagedIdentity"] = identity
        try store.files.writeJSON(value, to: url)
    }

    func willWrite(_ bytes: Data, name: String) throws {
        guard ["config.yaml", store.ownershipName].contains(name), bytes.count <= 256 * 1024 else {
            throw IOSFileError.invalid("Relocation metadata is not supported")
        }
        var changed = value["changed"] as? [String: String] ?? [:]
        changed[name] = bytes.base64EncodedString()
        let originals = value["originals"] as? [String: String] ?? [:]
        guard originals.values.reduce(0, { $0 + $1.utf8.count }) + changed.values.reduce(0, { $0 + $1.utf8.count }) < 900 * 1024 else {
            throw IOSFileError.invalid("Relocation recovery metadata exceeds its storage limit")
        }
        value["changed"] = changed
        try store.files.writeJSON(value, to: url)
    }

    func complete() throws { try FileManager.default.removeItem(at: store.files.checked(url)) }

    private func retainCopy(_ reason: String) throws {
        let parent = store.documents.appendingPathComponent(".sillyclient-relocations-retained")
        try store.files.createDirectory(parent)
        guard try store.files.children(parent, limit: 256).count < 256 else {
            throw IOSFileError.invalid("Retained relocation records require review before further recovery")
        }
        value["recoveryNote"] = reason
        try store.files.writeJSON(value, to: url)
        try store.files.move(url, to: parent.appendingPathComponent("\(id)-\(UUID().uuidString).json"))
    }

    // Called under the runtime mutation lock, including after a process restart.
    func recover() throws {
        guard let sourceRecord = value["source"] as? [String: Any],
              let targetRecord = value["target"] as? [String: Any],
              let stagingName = value["stagingName"] as? String,
              stagingName.hasPrefix(".sillyclient-relocate-"),
              UUID(uuidString: String(stagingName.dropFirst(".sillyclient-relocate-".count))) != nil,
              let sameVolume = value["sameVolume"] as? Bool,
              let sourceIdentity = value["sourceIdentity"] as? String,
              let originals = value["originals"] as? [String: String],
              let changed = value["changed"] as? [String: String],
              Set(originals.keys).union(changed.keys).isSubset(of: ["config.yaml", store.ownershipName]) else {
            throw IOSFileError.invalid("Relocation recovery metadata is invalid; all contents were preserved")
        }
        let original = try store.recordPath(sourceRecord)
        let target = try store.recordPath(targetRecord)
        let stagedIdentity = value["stagedIdentity"] as? String
        let registered = try store.registry()[id]
        func acquireSource() throws -> IOSInstallationLocation {
            if let record = registered {
                guard try store.recordPath(record).path == original.path,
                      record["directoryIdentity"] as? String == sourceIdentity,
                      record["isTakeover"] as? Bool != true, record["removalPending"] as? Bool != true else {
                    throw IOSFileError.invalid("Instance registration changed during relocation; all contents were preserved")
                }
            }
            let source = try store.locations.acquire(original, grantId: value["sourceGrant"] as? String)
            guard source.rootIdentity == value["sourceRootIdentity"] as? String,
                  original.path != source.root.path,
                  !IOSInstallationLocations.contains(original, target), !IOSInstallationLocations.contains(target, original) else {
                throw IOSFileError.invalid("Relocation authorization changed; all contents were preserved")
            }
            return source
        }
        let destination: IOSInstallationLocation
        do { destination = try store.locations.acquire(target, grantId: value["targetGrant"] as? String) }
        catch {
            guard !sameVolume else { throw error }
            let source = try acquireSource()
            defer { withExtendedLifetime(source) {} }
            guard (try? source.files.guardValue(original).identity) == sourceIdentity else { throw error }
            // A retained copy cannot make the untouched, still-registered source unusable.
            try retainCopy("Destination authorization is unavailable; the source was retained and no destination contents were removed")
            return
        }
        defer { withExtendedLifetime(destination) {} }
        guard destination.rootIdentity == value["targetRootIdentity"] as? String,
              target.path != destination.root.path else {
            throw IOSFileError.invalid("Relocation authorization changed; all contents were preserved")
        }
        let staging = target.deletingLastPathComponent().appendingPathComponent(stagingName)
        if let record = registered, try store.recordPath(record).path == target.path,
           let stagedIdentity = stagedIdentity,
           record["directoryIdentity"] as? String == stagedIdentity,
           record["rootIdentity"] as? String == destination.rootIdentity,
           (try? destination.files.guardValue(target).identity) == stagedIdentity {
            try complete()
            return
        }
        let source = try acquireSource()
        defer { withExtendedLifetime(source) {} }
        if sameVolume {
            guard stagedIdentity == sourceIdentity else { throw IOSFileError.invalid("Relocation directory identity is invalid") }
            var current: URL
            if (try? destination.files.guardValue(staging).identity) == sourceIdentity { current = staging }
            else if (try? destination.files.guardValue(target).identity) == sourceIdentity { current = target }
            else if (try? source.files.guardValue(original).identity) == sourceIdentity {
                try complete()
                return
            } else { throw IOSFileError.invalid("Relocation data cannot be identified; the recovery record was retained") }
            if source.files.exists(original) {
                guard original.deletingLastPathComponent().path == current.deletingLastPathComponent().path,
                      (try? source.files.guardValue(original).identity) == sourceIdentity,
                      !destination.files.exists(staging) else {
                    throw IOSFileError.invalid("The original path is occupied; relocation data was preserved at \(current.path)")
                }
                try destination.files.move(current, to: staging)
                current = staging
            }
            for (name, encoded) in changed {
                guard let expected = Data(base64Encoded: encoded) else { throw IOSFileError.invalid("Invalid relocation metadata encoding") }
                let before = try originals[name].map { raw -> Data in
                    guard let data = Data(base64Encoded: raw) else { throw IOSFileError.invalid("Invalid original metadata encoding") }
                    return data
                }
                let path = current.appendingPathComponent(name)
                let actual = destination.files.exists(path) ? try destination.files.data(path) : nil
                guard actual == expected || actual == before else {
                    throw IOSFileError.invalid("Relocation metadata was edited; its recovery record and contents were preserved")
                }
                if let before = before { try destination.files.write(before, to: path) }
                else if destination.files.exists(path) { try FileManager.default.removeItem(at: destination.files.checked(path)) }
            }
            try destination.files.move(current, to: original, destination: source.files)
        } else {
            guard (try? source.files.guardValue(original).identity) == sourceIdentity else {
                throw IOSFileError.invalid("The retained source changed; no copied contents were removed")
            }
            // A crash between mkdir and its identity receipt must not disable the intact source.
            // Without that receipt, keep any staging contents instead of inferring ownership.
            guard stagedIdentity != nil else {
                try retainCopy("Staging identity was not recorded; the source was retained and no unverified contents were removed")
                return
            }
            for candidate in [staging, target] where destination.files.exists(candidate) {
                guard let stagedIdentity = stagedIdentity,
                      (try? destination.files.guardValue(candidate).identity) == stagedIdentity else {
                    throw IOSFileError.invalid("An unverified copy was preserved at \(candidate.path); original data remains at \(original.path)")
                }
                try FileManager.default.removeItem(at: destination.files.checked(candidate))
            }
        }
        try complete()
    }
}

extension IOSInstanceStore {
    func recoverPendingRelocations() throws -> [String: String] {
        let parent = documents.appendingPathComponent(".sillyclient-relocations")
        guard files.exists(parent) else { return [:] }
        var failures: [String: String] = [:]
        for entry in try files.children(parent, limit: 256) {
            guard entry.pathExtension == "json", let id = try? Self.identity(entry.deletingPathExtension().lastPathComponent) else { continue }
            do { try recoverRelocation(id) }
            catch { failures[id] = error.localizedDescription }
        }
        return failures
    }

    func recoverRelocation(_ id: String, operation: String? = nil) throws {
        _ = try Self.identity(id)
        guard files.exists(IOSRelocationJournal.url(self, id)) else { return }
        if let operation = operation { try NodeRunner.shared.beginProvisionRecovery(instance: id, operation: operation) }
        else { try NodeRunner.shared.beginMaintenance(instance: id) }
        defer { NodeRunner.shared.endMaintenance(instance: id) }
        try IOSRelocationJournal(store: self, id: id).recover()
    }
}
