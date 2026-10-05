import Foundation
import Yams

extension IOSInstanceStore {
    private func mutationSource(_ id: String, installPath: String?) throws -> IOSInstallationLocation {
        let source = try location(id, installPath: installPath)
        let records = try registry()
        let legacy = documents.appendingPathComponent(id == "default" ? "SillyTavern" : "instances/\(id)")
        guard records[id] != nil || source.directory.path == legacy.path else {
            throw IOSFileError.invalid("An existing managed instance is required; unrelated contents were preserved")
        }
        for name in ["server.js", "package.json"] {
            guard !(try source.files.guardValue(source.directory.appendingPathComponent(name))).isDirectory else {
                throw IOSFileError.invalid("The source is not an installed instance")
            }
        }
        if source.files.exists(source.directory.appendingPathComponent(ownershipName)) {
            let receipt = try source.files.json(source.directory.appendingPathComponent(ownershipName))
            let sourceIdentity = try source.files.guardValue(source.directory).identity
            guard receipt["owner"] as? String == "sillyclient", receipt["instanceId"] as? String == id,
                  receipt["path"] as? String == source.directory.path,
                  receipt["rootIdentity"] as? String == source.rootIdentity,
                  receipt["directoryIdentity"] as? String == sourceIdentity else {
                throw IOSFileError.invalid("The instance ownership receipt does not match its registered location")
            }
        }
        return source
    }

    private static func directoryName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.utf8.count <= 200, !name.hasPrefix("."), !name.hasSuffix("."),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\<>:\"|?*").union(.controlCharacters)) == nil,
              !name.unicodeScalars.contains(where: { $0.value == 0x2028 || $0.value == 0x2029 }) else {
            throw IOSFileError.invalid("The instance name must be a non-empty portable folder name")
        }
        return name
    }

    func rename(instanceId: String, newName: String, installPath: String? = nil) throws -> [String: Any] {
        let id = try Self.identity(instanceId)
        let name = try Self.directoryName(newName)
        try recoverRelocation(id)
        try NodeRunner.shared.beginMaintenance(instance: id)
        defer { NodeRunner.shared.endMaintenance(instance: id) }
        let source = try mutationSource(id, installPath: installPath)
        let target = source.directory.deletingLastPathComponent().appendingPathComponent(name)
        let result = try relocateStopped(id, source: source, target: target, name: name)
        return ["success": true, "oldId": id, "newId": id,
                "oldPath": result["oldPath"]!, "newPath": result["newPath"]!]
    }

    func relocate(instanceId: String, targetPath: String?, installPath: String? = nil) throws -> [String: Any] {
        let id = try Self.identity(instanceId)
        try recoverRelocation(id)
        try NodeRunner.shared.beginMaintenance(instance: id)
        defer { NodeRunner.shared.endMaintenance(instance: id) }
        let source = try mutationSource(id, installPath: installPath)
        var target = documents.appendingPathComponent("instances/\(id)")
        if let raw = targetPath {
            target = try IOSInstallationLocations.path(raw)
            let selected = try locations.acquire(target)
            defer { withExtendedLifetime(selected) {} }
            if selected.files.exists(target), target.path != source.directory.path {
                guard try selected.files.guardValue(target).isDirectory else {
                    throw IOSFileError.invalid("The selected destination is not a directory")
                }
                if !selected.files.exists(target.appendingPathComponent("package.json")) {
                    target.appendPathComponent(id)
                }
            }
        }
        return try relocateStopped(id, source: source, target: target, name: nil)
    }

    private func relocatedConfiguration(_ original: Data?, source: URL, target: URL) throws -> Data? {
        guard let original = original else { return nil }
        guard let text = String(data: original, encoding: .utf8),
              var value = try Yams.load(yaml: text) as? [String: Any] else {
            throw IOSFileError.invalid("The instance has invalid YAML configuration; no files were moved")
        }
        guard let raw = value["dataRoot"] else { return original }
        guard let path = raw as? String, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IOSFileError.invalid("The instance dataRoot is invalid")
        }
        let dataRoot = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : source.appendingPathComponent(path)).standardizedFileURL
        guard IOSInstallationLocations.contains(source, dataRoot) else {
            throw IOSFileError.invalid("Moving an instance with an external dataRoot is unsupported; its source was preserved")
        }
        guard path.hasPrefix("/") else { return original }
        value["dataRoot"] = target.path + String(dataRoot.path.dropFirst(source.path.count))
        return Data(try Yams.dump(object: value).utf8)
    }

    private func relocateStopped(_ id: String, source: IOSInstallationLocation, target: URL,
                                 name: String?) throws -> [String: Any] {
        let destination = try locations.acquire(target)
        defer { withExtendedLifetime((source, destination)) {} }
        var records = try registry()
        guard records[id] != nil || records.count < 256 else { throw IOSFileError.invalid("Instance registry is full") }
        try validateLocation(id, location: destination, records: records)
        let original = source.directory
        let identity = try source.files.guardValue(original).identity
        if original.path == target.path {
            var record = try registrationRecord(id, location: source, previous: records[id] ?? [:])
            if let name = name { record["name"] = name }
            records[id] = record
            try NodeRunner.shared.stoppedMutation(instance: id) { try files.writeJSON(records, to: registryURL) }
            return ["success": true, "instanceId": id, "oldPath": original.path, "newPath": target.path, "unchanged": true]
        }
        guard !IOSInstallationLocations.contains(original, target), !IOSInstallationLocations.contains(target, original) else {
            throw IOSFileError.invalid("The source and destination cannot contain one another")
        }
        try IOSInstanceMaintenance.requireNoPendingRecovery(original, files: source.files)
        if destination.files.exists(target) {
            guard original.deletingLastPathComponent().path == target.deletingLastPathComponent().path,
                  try destination.files.guardValue(target).identity == identity else {
                throw IOSFileError.invalid("The destination already exists; no contents were replaced")
            }
        }
        let metadataNames = ["config.yaml", ownershipName]
        var originals: [String: Data] = [:]
        for item in metadataNames {
            let path = original.appendingPathComponent(item)
            if source.files.exists(path) { originals[item] = try source.files.data(path) }
        }
        let configuration = try relocatedConfiguration(originals["config.yaml"], source: original, target: target)
        try destination.files.createDirectory(target.deletingLastPathComponent())
        let staging = target.deletingLastPathComponent().appendingPathComponent(".sillyclient-relocate-\(UUID().uuidString)")
        let sameVolume = try source.files.guardValue(original).device == destination.files.guardValue(target.deletingLastPathComponent()).device
        let journal = try IOSRelocationJournal(store: self, id: id, source: source, destination: destination,
            staging: staging, sameVolume: sameVolume, originals: originals)
        var stagedIdentity: String?
        do {
            if sameVolume {
                try source.files.move(original, to: staging, destination: destination.files)
                stagedIdentity = identity
            } else {
                // Cross-volume migration is verified copying, never copy-then-delete.
                try source.files.copyTree(original, to: staging, destination: destination.files,
                    budget: IOSInspectionBudget(maxEntries: 131072, maxBytes: 8 * 1024 * 1024 * 1024),
                    rootCreated: { stagedIdentity = $0.identity; try journal.staged($0.identity) })
            }
            if let configuration = configuration, configuration != originals["config.yaml"] {
                try journal.willWrite(configuration, name: "config.yaml")
                try destination.files.write(configuration, to: staging.appendingPathComponent("config.yaml"))
            }
            let receipt = try JSONSerialization.data(withJSONObject: ownershipRecord(id, location: destination, at: staging),
                                                     options: [.sortedKeys, .prettyPrinted])
            try journal.willWrite(receipt, name: ownershipName)
            try destination.files.write(receipt, to: staging.appendingPathComponent(ownershipName))
            try NodeRunner.shared.stoppedMutation(instance: id) {
                guard try destination.files.guardValue(staging).identity == stagedIdentity else {
                    throw IOSFileError.invalid("The staged instance directory changed")
                }
                try destination.files.move(staging, to: target)
                var record = try registrationRecord(id, location: destination, previous: records[id] ?? [:])
                if let name = name { record["name"] = name }
                records[id] = record
                try files.writeJSON(records, to: registryURL)
            }
        } catch {
            do { try journal.recover() }
            catch { throw IOSFileError.invalid("Relocation recovery is pending: \(error.localizedDescription)") }
            throw error
        }
        // The registry commit is authoritative; a leftover journal is cleared on next access.
        try? journal.complete()
        var result: [String: Any] = ["success": true, "instanceId": id, "oldPath": original.path,
                                     "newPath": target.path, "unchanged": false]
        if !sameVolume { result["retainedSourcePath"] = original.path }
        return result
    }

    func legacyInstances() throws -> [[String: Any]] {
        guard try recoverPendingRelocations().isEmpty else {
            throw IOSFileError.invalid("An interrupted relocation still needs recovery; scan instances for its details")
        }
        let legacy = documents.appendingPathComponent("SillyTavern")
        guard files.exists(legacy) else { return [] }
        let records = try registry()
        let registered = try records.first { try recordPath($0.value).path == legacy.path }
        guard registered != nil || records["default"] == nil else { return [] }
        let id = registered?.key ?? "default"
        let source = try mutationSource(id, installPath: legacy.path)
        defer { withExtendedLifetime(source) {} }
        let package = try source.files.json(legacy.appendingPathComponent("package.json"))
        return [["instanceId": id, "name": registered?.value["name"] as? String ?? id,
                 "currentPath": legacy.path, "targetPath": documents.appendingPathComponent("instances/\(id)").path,
                 "version": package["version"] as? String ?? "local"]]
    }

    func migrateLegacyInstances(instanceIds: [String]?) throws -> [String: Any] {
        let candidates = try legacyInstances()
        let eligible = Set(candidates.compactMap { $0["instanceId"] as? String })
        let requested = try (instanceIds ?? Array(eligible).sorted()).map { try Self.identity($0) }
        guard requested.count <= 256, Set(requested).count == requested.count else {
            throw IOSFileError.invalid("The legacy migration selection is invalid or duplicated")
        }
        var results: [[String: Any]] = []
        for id in requested {
            do {
                guard eligible.contains(id) else { throw IOSFileError.invalid("The selected instance is not a legacy migration candidate") }
                results.append(try relocate(instanceId: id, targetPath: nil))
            } catch {
                results.append(["success": false, "instanceId": id,
                    "oldPath": candidates.first { $0["instanceId"] as? String == id }?["currentPath"] as? String ?? "",
                    "newPath": "", "error": error.localizedDescription])
            }
        }
        return ["success": results.allSatisfy { $0["success"] as? Bool == true }, "results": results]
    }
}
