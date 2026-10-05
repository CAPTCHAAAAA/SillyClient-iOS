import Foundation
import CryptoKit

final class IOSInstanceMaintenance {
    static let shared = IOSInstanceMaintenance(store: .shared)
    private struct Candidate {
        let id: String
        let token: String
        let relative: String
        let kind: String
        let action: String
        let description: String
        let snapshot: IOSFileSnapshot
        let references: [String]
        var publicValue: [String: Any] {
            ["id": id, "token": token, "kind": kind, "action": action, "relativePath": relative,
             "description": description, "sizeBytes": snapshot.bytes,
             "confidence": kind == "download_cache" ? "owned" : "suspected",
             "defaultSelected": kind == "download_cache"]
        }
    }
    private struct Plan {
        let instance: String
        let root: URL
        let rootIdentity: String
        let configDigest: String
        let configGuard: IOSFileGuard?
        let expires: TimeInterval
        let candidates: [Candidate]
    }
    private struct RestorePlan {
        let instance: String
        let recovery: String
        let recordDigest: String
        let recordGuard: IOSFileGuard
        let payloadDigest: String
        let expires: TimeInterval
    }
    private let store: IOSInstanceStore
    private let now: () -> TimeInterval
    private var scans: [String: Plan] = [:]
    private var restores: [String: RestorePlan] = [:]
    private let ttl: TimeInterval = 300
    private let base = ".sillyclient-maintenance"

    static func requireNoPendingRecovery(_ root: URL, files: IOSManagedFiles) throws {
        let parent = root.appendingPathComponent(".sillyclient-maintenance/recovery")
        guard files.exists(parent) else { return }
        for child in try files.children(parent, limit: 4096) {
            guard try files.guardValue(child).isDirectory,
                  files.exists(child.appendingPathComponent("payload")) else { continue }
            let phase = (try? files.json(child.appendingPathComponent("record.json")))?["phase"] as? String
            guard phase == "restored" else {
                throw IOSFileError.invalid("Restore pending maintenance backups before renaming or relocating this instance")
            }
        }
    }

    init(store: IOSInstanceStore, now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.store = store
        self.now = now
    }
    private func hash(_ bytes: Data) -> String { IOSManagedFiles.hex(SHA256.hash(data: bytes)) }
    private func expire() {
        scans = scans.filter { $0.value.expires > now() }
        restores = restores.filter { $0.value.expires > now() }
    }
    private func validSegment(_ value: String) -> Bool {
        value != "." && value != ".." && value.range(of: "^[A-Za-z0-9_.-]{1,160}\\z", options: .regularExpression) != nil
    }
    private func config(_ root: URL, files: IOSManagedFiles) throws -> (String, IOSFileGuard?) {
        let path = root.appendingPathComponent("config.yaml")
        if !files.exists(path) { return ("missing", nil) }
        let data = try files.data(path)
        return (hash(data), try files.guardValue(path))
    }
    private func validate(_ plan: Plan, files: IOSManagedFiles, hashConfig: Bool) throws {
        guard try store.directory(plan.instance, maintenance: true).path == plan.root.path,
              try files.guardValue(plan.root).identity == plan.rootIdentity else {
            throw IOSFileError.invalid("Instance directory identity changed")
        }
        let path = plan.root.appendingPathComponent("config.yaml")
        if let expected = plan.configGuard {
            guard try files.guardValue(path) == expected else { throw IOSFileError.invalid("Instance configuration changed") }
        } else if files.exists(path) { throw IOSFileError.invalid("Instance configuration changed") }
        if hashConfig, try config(plan.root, files: files).0 != plan.configDigest { throw IOSFileError.invalid("Instance configuration contents changed") }
    }
    private func validateReferences(_ candidate: Candidate, root: URL, files: IOSManagedFiles) throws {
        guard candidate.kind == "stale_extension_reference" else { return }
        let local = root.appendingPathComponent(candidate.relative).deletingLastPathComponent().appendingPathComponent("extensions")
        let global = root.appendingPathComponent("public/scripts/extensions/third-party")
        for reference in candidate.references {
            let name = String(reference.dropFirst("third-party/".count))
            guard !files.exists(local.appendingPathComponent(name)),
                  !files.exists(global.appendingPathComponent(name)) else {
                throw IOSFileError.invalid("A referenced extension was reinstalled; its disabled setting was preserved")
            }
        }
    }
    private func users(_ root: URL, files: IOSManagedFiles) throws -> [URL] {
        let data = root.appendingPathComponent("data")
        if !files.exists(data) { return [] }
        return try files.children(data, limit: 256).filter {
            validSegment($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix("_")
                && (try? files.guardValue($0).isDirectory) == true
        }
    }

    func scan(_ instance: String) throws -> [String: Any] {
        expire()
        let id = try IOSInstanceStore.identity(instance)
        let location = try store.location(id)
        defer { withExtendedLifetime(location) {} }
        let root = location.directory
        try NodeRunner.shared.beginMaintenance(instance: id)
        defer { NodeRunner.shared.endMaintenance(instance: id) }
        scans = scans.filter { $0.value.instance != id }
        guard scans.count < 16 else { throw IOSFileError.invalid("Maintenance scan capacity reached; existing scans remain valid") }
        let files = location.files
        let configuration = try config(root, files: files)
        let identity = try files.guardValue(root).identity
        let budget = IOSInspectionBudget()
        var candidates: [Candidate] = []
        var warnings: [String] = []
        func add(_ file: URL, kind: String, description: String, references: [String] = []) throws {
            guard candidates.count < 128 else { throw IOSFileError.invalid("Candidate limit reached; remaining files were preserved") }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            _ = try IOSSafeArchive.relativePath(relative)
            let snapshot = try files.snapshot(file, budget: budget)
            candidates.append(Candidate(id: UUID().uuidString, token: UUID().uuidString, relative: relative,
                kind: kind, action: kind == "broken_extension" ? "quarantine" : kind == "download_cache"
                    ? "delete_cache" : "remove_disabled_reference",
                description: description, snapshot: snapshot, references: references))
        }
        for user in try users(root, files: files) {
            let extensions = user.appendingPathComponent("extensions")
            if files.exists(extensions) {
                for entry in try files.children(extensions, limit: 512) {
                    do {
                        guard try files.guardValue(entry).isDirectory, validSegment(entry.lastPathComponent) else { continue }
                        let manifestPath = entry.appendingPathComponent("manifest.json")
                        var reason: String?
                        if !files.exists(manifestPath) { reason = "Missing extension manifest" }
                        else {
                            do {
                                let manifest = try files.json(manifestPath, budget: budget)
                                for key in ["js", "css"] {
                                    guard let value = manifest[key], !(value is NSNull) else { continue }
                                    guard let text = value as? String else { reason = "Invalid entry declaration"; break }
                                    if text.isEmpty { continue }
                                    let relative = try IOSSafeArchive.relativePath(text.hasPrefix("./") ? String(text.dropFirst(2)) : text)
                                    let asset = entry.appendingPathComponent(relative)
                                    if try !files.exists(asset) || files.guardValue(asset).isDirectory {
                                        reason = "Missing extension entry file"; break
                                    }
                                }
                            } catch { reason = "Extension manifest or entry could not be verified" }
                        }
                        if let reason = reason { try add(entry, kind: "broken_extension", description: "\(entry.lastPathComponent): \(reason)") }
                    } catch { warnings.append("\(entry.lastPathComponent) was preserved: \(error.localizedDescription)") }
                }
            }
            let settings = user.appendingPathComponent("settings.json")
            if files.exists(settings) {
                do {
                    let value = try files.json(settings, budget: budget)
                    if let disabled = (value["extension_settings"] as? [String: Any])?["disabledExtensions"] as? [String] {
                        guard disabled.count <= 256 else { throw IOSFileError.invalid("Disabled extension reference limit reached") }
                        let references = Set(disabled).filter { reference in
                            guard reference.hasPrefix("third-party/") else { return false }
                            let name = String(reference.dropFirst("third-party/".count))
                            return validSegment(name) && !files.exists(extensions.appendingPathComponent(name))
                                && !files.exists(root.appendingPathComponent("public/scripts/extensions/third-party/\(name)"))
                        }.sorted()
                        if !references.isEmpty { try add(settings, kind: "stale_extension_reference",
                            description: "Disabled references without matching extension directories", references: references) }
                    }
                } catch { warnings.append("Settings were preserved: \(error.localizedDescription)") }
            }
        }
        let cacheRoot = root.appendingPathComponent("\(base)/download-cache")
        if files.exists(cacheRoot) {
            for entry in try files.children(cacheRoot, limit: 512) {
                do {
                    guard UUID(uuidString: entry.lastPathComponent) != nil, try files.guardValue(entry).isDirectory else { continue }
                    guard try files.children(entry, limit: 3).map({ $0.lastPathComponent }).sorted() == ["download.zip", "owner.json"] else { continue }
                    let ownerURL = entry.appendingPathComponent("owner.json")
                    let payloadURL = entry.appendingPathComponent("download.zip")
                    let owner = try files.json(ownerURL, budget: budget)
                    let payload = try files.data(payloadURL, maximum: 32 * 1024 * 1024, budget: budget)
                    let cutoff = now() - 24 * 3600
                    guard owner["revision"] as? Int == 1, owner["owner"] as? String == "sillyclient",
                          owner["instanceId"] as? String == id, owner["payload"] as? String == "download.zip",
                          owner["sha256"] as? String == hash(payload), owner["sizeBytes"] as? Int == payload.count else { continue }
                    guard try [entry, ownerURL, payloadURL].allSatisfy({
                        let value = try files.guardValue($0)
                        return Double(value.modifiedSeconds) + Double(value.modifiedNanos) / 1e9 <= cutoff
                    }) else { continue }
                    try add(entry, kind: "download_cache", description: "Verified expired launcher download cache")
                } catch { warnings.append("Download cache was preserved: \(error.localizedDescription)") }
            }
        }
        let scanId = UUID().uuidString
        let plan = Plan(instance: id, root: root, rootIdentity: identity, configDigest: configuration.0,
            configGuard: configuration.1, expires: now() + ttl, candidates: candidates)
        try validate(plan, files: files, hashConfig: true)
        scans[scanId] = plan
        return ["instanceId": id, "scanId": scanId, "expiresAt": plan.expires * 1000,
            "items": candidates.map { $0.publicValue }, "warnings": warnings]
    }

    func apply(instance: String, scanId: String, selections: [[String: Any]]) throws -> [String: Any] {
        expire()
        guard let plan = scans.removeValue(forKey: scanId), plan.instance == instance, plan.expires > now(),
              selections.count <= 128 else { throw IOSFileError.invalid("Maintenance scan expired or was already used") }
        var selected: [Candidate] = []
        var used = Set<String>()
        for selection in selections {
            guard let id = selection["id"] as? String, used.insert(id).inserted,
                  let candidate = plan.candidates.first(where: { $0.id == id }),
                  selection["token"] as? String == candidate.token else {
                throw IOSFileError.invalid("Maintenance selection or token is invalid")
            }
            selected.append(candidate)
        }
        try NodeRunner.shared.beginMaintenance(instance: instance)
        defer { NodeRunner.shared.endMaintenance(instance: instance) }
        let location = try store.location(instance)
        defer { withExtendedLifetime(location) {} }
        let files = location.files
        try validate(plan, files: files, hashConfig: true)
        let budget = IOSInspectionBudget()
        var results: [[String: Any]] = []
        var recoveryIds: [String] = []
        var activeRecoveryRecords: [String: IOSFileGuard] = [:]
        var total: Int64 = 0
        for candidate in selected {
            var result: [String: Any] = ["id": candidate.id, "success": false, "action": candidate.action,
                "freedBytes": 0, "quarantinedBytes": 0]
            var createdRecovery: (String, URL)?
            do {
                try validate(plan, files: files, hashConfig: true)
                let source = plan.root.appendingPathComponent(candidate.relative)
                guard try files.snapshot(source, budget: budget) == candidate.snapshot else {
                    throw IOSFileError.invalid("The selected content changed after scanning")
                }
                try validateReferences(candidate, root: plan.root, files: files)
                let recovery = UUID().uuidString
                let folder = plan.root.appendingPathComponent("\(base)/recovery/\(recovery)")
                try requireRecoveryCapacity(plan.root, files: files, activeRecords: &activeRecoveryRecords)
                try files.createDirectory(folder)
                let payload = folder.appendingPathComponent("payload")
                createdRecovery = (recovery, payload)
                let recordURL = folder.appendingPathComponent("record.json")
                var record: [String: Any] = ["revision": 1, "owner": "sillyclient", "instanceId": instance,
                    "recoveryId": recovery, "rootIdentity": plan.rootIdentity, "configDigest": plan.configDigest,
                    "relativePath": candidate.relative, "kind": candidate.kind, "action": candidate.action,
                    "description": candidate.description, "createdAt": now() * 1000,
                    "sizeBytes": candidate.snapshot.bytes, "originalDigest": candidate.snapshot.contentDigest,
                    "payloadDigest": candidate.snapshot.contentDigest, "phase": "prepared"]
                if candidate.kind == "stale_extension_reference" {
                    let original = try files.data(source, budget: budget)
                    var settings = try files.json(source, budget: budget)
                    guard var extensionSettings = settings["extension_settings"] as? [String: Any],
                          let disabled = extensionSettings["disabledExtensions"] as? [String] else {
                        throw IOSFileError.invalid("Disabled references changed")
                    }
                    extensionSettings["disabledExtensions"] = disabled.filter { !candidate.references.contains($0) }
                    settings["extension_settings"] = extensionSettings
                    let applied = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                    guard applied.count <= 1024 * 1024 else { throw IOSFileError.invalid("Applied settings exceed the metadata limit") }
                    record["payloadDigest"] = hash(original)
                    record["appliedDigest"] = hash(applied)
                    try files.write(original, to: payload, replace: false)
                    try files.writeJSON(record, to: recordURL, replace: false)
                    try NodeRunner.shared.stoppedMutation(instance: instance) {
                        try validate(plan, files: files, hashConfig: false)
                        try files.validate(candidate.snapshot, at: source)
                        try validateReferences(candidate, root: plan.root, files: files)
                        try files.write(applied, to: source)
                    }
                    record["phase"] = "quarantined"
                    try files.writeJSON(record, to: recordURL)
                    result["success"] = true
                } else {
                    try files.writeJSON(record, to: recordURL, replace: false)
                    try NodeRunner.shared.stoppedMutation(instance: instance) {
                        try validate(plan, files: files, hashConfig: false)
                        try files.validate(candidate.snapshot, at: source)
                        try files.move(source, to: payload)
                    }
                    let actual = try files.snapshot(payload, budget: budget)
                    guard actual.guardValue.identity == candidate.snapshot.guardValue.identity else {
                        throw IOSFileError.invalid("Quarantined payload identity changed")
                    }
                    record["payloadDigest"] = actual.contentDigest
                    record["sizeBytes"] = actual.bytes
                    record["phase"] = "quarantined"
                    try files.writeJSON(record, to: recordURL)
                    result["quarantinedBytes"] = actual.bytes
                    total += actual.bytes
                    result["success"] = actual.contentDigest == candidate.snapshot.contentDigest
                    if actual.contentDigest != candidate.snapshot.contentDigest {
                        result["error"] = "Content changed during quarantine; the verified actual payload was retained for recovery"
                    }
                }
            } catch { result["error"] = error.localizedDescription }
            if let (recovery, payload) = createdRecovery, files.exists(payload) {
                result["recoveryId"] = recovery
                result["preservedForRecovery"] = true
                recoveryIds.append(recovery)
            }
            results.append(result)
        }
        return ["success": results.allSatisfy { $0["success"] as? Bool == true }, "results": results,
            "freedBytes": 0, "quarantinedBytes": total, "recoveryIds": recoveryIds]
    }

    private func requireRecoveryCapacity(_ root: URL, files: IOSManagedFiles, activeRecords: inout [String: IOSFileGuard]) throws {
        let parent = root.appendingPathComponent("\(base)/recovery")
        guard files.exists(parent) else { activeRecords.removeAll(); return }
        let listing = try files.boundedChildren(parent, limit: 4096)
        guard !listing.truncated else { throw IOSFileError.invalid("Recovery inspection limit reached; existing records were preserved") }
        var observed: [String: IOSFileGuard] = [:]
        let active = try listing.items.filter { child in
            guard try files.guardValue(child).isDirectory else { return false }
            guard files.exists(child.appendingPathComponent("payload")) else { return false }
            let record = child.appendingPathComponent("record.json")
            guard let current = try? files.guardValue(record) else { return true }
            // A guard cannot prove unchanged contents, so only cache the conservative active conclusion.
            if activeRecords[record.path] == current {
                observed[record.path] = current
                return true
            }
            let phase = (try? files.json(record))?["phase"] as? String
            guard phase != "restored" else { return false }
            if (try? files.guardValue(record)) == current { observed[record.path] = current }
            return true
        }
        activeRecords = observed
        guard active.count < 256 else { throw IOSFileError.invalid("Recovery capacity reached; restore or retain existing backups before applying more changes") }
    }

    private func recoveryRecord(_ root: URL, files: IOSManagedFiles, instance: String, recovery: String) throws -> (URL, [String: Any], String, IOSFileGuard) {
        guard UUID(uuidString: recovery) != nil else { throw IOSFileError.invalid("Invalid recovery identity") }
        let folder = root.appendingPathComponent("\(base)/recovery/\(recovery)")
        let recordURL = folder.appendingPathComponent("record.json")
        let before = try files.guardValue(recordURL)
        let bytes = try files.data(recordURL, maximum: 65536)
        guard try files.guardValue(recordURL) == before else { throw IOSFileError.invalid("Recovery metadata changed while being read") }
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["revision"] as? Int == 1, value["owner"] as? String == "sillyclient",
              value["instanceId"] as? String == instance, value["recoveryId"] as? String == recovery,
              let relative = value["relativePath"] as? String, let kind = value["kind"] as? String,
              let action = value["action"] as? String,
              ["prepared", "quarantined", "restored"].contains(value["phase"] as? String ?? ""),
              try IOSSafeArchive.relativePath(relative) == relative else {
            throw IOSFileError.invalid("Recovery record cannot be verified")
        }
        let parts = relative.split(separator: "/").map(String.init)
        let valid: Bool
        switch (kind, action) {
        case ("broken_extension", "quarantine"):
            valid = parts.count == 4 && parts[0] == "data" && validSegment(parts[1])
                && parts[2] == "extensions" && validSegment(parts[3])
        case ("stale_extension_reference", "remove_disabled_reference"):
            valid = parts.count == 3 && parts[0] == "data" && validSegment(parts[1]) && parts[2] == "settings.json"
        case ("download_cache", "delete_cache"):
            valid = parts.count == 3 && parts[0] == base && parts[1] == "download-cache" && UUID(uuidString: parts[2]) != nil
        default: valid = false
        }
        guard valid else { throw IOSFileError.invalid("Recovery path does not match its allowed action") }
        return (folder, value, hash(bytes), before)
    }

    private func restoreValidation(_ root: URL, files: IOSManagedFiles, record: [String: Any], folder: URL,
                                   budget: IOSInspectionBudget) throws -> String {
        guard record["rootIdentity"] as? String == (try files.guardValue(root).identity),
              record["configDigest"] as? String == (try config(root, files: files).0),
              let expected = record["payloadDigest"] as? String, let relative = record["relativePath"] as? String else {
            throw IOSFileError.invalid("Recovery no longer belongs to this instance configuration")
        }
        let payload = folder.appendingPathComponent("payload")
        let target = root.appendingPathComponent(relative)
        if record["kind"] as? String == "stale_extension_reference" {
            guard let applied = record["appliedDigest"] as? String,
                  hash(try files.data(target, budget: budget)) == applied,
                  hash(try files.data(payload, budget: budget)) == expected else {
                throw IOSFileError.invalid("Settings changed since maintenance; nothing was overwritten")
            }
        } else {
            guard !files.exists(target) else { throw IOSFileError.invalid("A same-name replacement exists; nothing was overwritten") }
            guard try files.snapshot(payload, budget: budget).contentDigest == expected else {
                throw IOSFileError.invalid("Recovery payload contents changed")
            }
        }
        _ = try files.checked(target.deletingLastPathComponent())
        return expected
    }

    func list(_ instance: String) throws -> [String: Any] {
        expire()
        let location = try store.location(instance)
        defer { withExtendedLifetime(location) {} }
        let root = location.directory
        let files = location.files
        try NodeRunner.shared.beginMaintenance(instance: instance)
        defer { NodeRunner.shared.endMaintenance(instance: instance) }
        restores = restores.filter { $0.value.instance != instance }
        let parent = root.appendingPathComponent("\(base)/recovery")
        guard files.exists(parent) else { return ["items": [], "warnings": []] }
        var items: [[String: Any]] = []
        var warnings: [String] = []
        let budget = IOSInspectionBudget()
        let listing = try files.boundedChildren(parent, limit: 4096)
        if listing.truncated { warnings.append("Recovery inspection limit reached; additional records were preserved") }
        for child in listing.items {
            do {
                let recovery = child.lastPathComponent
                let (folder, record, digest, recordGuard) = try recoveryRecord(root, files: files, instance: instance, recovery: recovery)
                if record["phase"] as? String == "restored" { continue }
                if !files.exists(folder.appendingPathComponent("payload")) { continue }
                var value: [String: Any] = ["recoveryId": recovery, "createdAt": record["createdAt"] ?? 0,
                    "description": record["description"] ?? "Maintenance recovery", "relativePath": record["relativePath"] ?? "",
                    "kind": record["kind"] ?? "", "action": record["action"] ?? "",
                    "sizeBytes": record["sizeBytes"] ?? 0, "canRestore": false, "token": ""]
                do {
                    guard restores.count < 256 else {
                        throw IOSFileError.invalid("Recovery token capacity reached; existing tokens remain valid")
                    }
                    let payloadDigest = try restoreValidation(root, files: files, record: record, folder: folder, budget: budget)
                    let token = UUID().uuidString
                    restores[token] = RestorePlan(instance: instance, recovery: recovery,
                        recordDigest: digest, recordGuard: recordGuard, payloadDigest: payloadDigest, expires: now() + ttl)
                    value["canRestore"] = true
                    value["token"] = token
                } catch { value["conflict"] = error.localizedDescription }
                items.append(value)
                if items.count == 256 { warnings.append("Recovery listing limit reached; remaining records were preserved"); break }
            } catch {
                if warnings.count < 64 { warnings.append("Recovery record was preserved: \(error.localizedDescription)") }
            }
        }
        return ["items": items, "warnings": warnings]
    }

    func restore(instance: String, recovery: String, token: String) throws -> [String: Any] {
        expire()
        guard let plan = restores.removeValue(forKey: token), plan.instance == instance, plan.recovery == recovery,
              plan.expires > now() else { throw IOSFileError.invalid("Recovery token expired or was already used") }
        let location = try store.location(instance)
        defer { withExtendedLifetime(location) {} }
        let root = location.directory
        let files = location.files
        try NodeRunner.shared.beginMaintenance(instance: instance)
        defer { NodeRunner.shared.endMaintenance(instance: instance) }
        let (folder, record, digest, recordGuard) = try recoveryRecord(root, files: files, instance: instance, recovery: recovery)
        guard record["phase"] as? String != "restored", digest == plan.recordDigest, recordGuard == plan.recordGuard,
              try restoreValidation(root, files: files, record: record, folder: folder,
            budget: IOSInspectionBudget()) == plan.payloadDigest else { throw IOSFileError.invalid("Recovery record changed") }
        let payload = folder.appendingPathComponent("payload")
        let target = root.appendingPathComponent(record["relativePath"] as! String)
        let configBefore = try config(root, files: files)
        guard configBefore.0 == record["configDigest"] as? String else {
            throw IOSFileError.invalid("Instance configuration changed before restore")
        }
        let payloadSnapshot = try files.snapshot(payload)
        let settings = record["kind"] as? String == "stale_extension_reference"
        let targetSnapshot = settings ? try files.snapshot(target) : nil
        let bytes = settings ? try files.data(payload) : nil
        if let bytes = bytes {
            guard hash(bytes) == record["payloadDigest"] as? String,
                  hash(try files.data(target)) == record["appliedDigest"] as? String else {
                throw IOSFileError.invalid("Settings or recovery data changed before restore")
            }
        } else {
            guard payloadSnapshot.contentDigest == record["payloadDigest"] as? String else {
                throw IOSFileError.invalid("Recovery payload changed before restore")
            }
        }
        try NodeRunner.shared.stoppedMutation(instance: instance) {
            guard try files.guardValue(root).identity == record["rootIdentity"] as? String else {
                throw IOSFileError.invalid("Instance or payload identity changed before restore")
            }
            try files.validate(payloadSnapshot, at: payload)
            let configURL = root.appendingPathComponent("config.yaml")
            if let expected = configBefore.1 {
                guard try files.guardValue(configURL) == expected else { throw IOSFileError.invalid("Instance configuration changed before restore") }
            } else if files.exists(configURL) { throw IOSFileError.invalid("Instance configuration changed before restore") }
            let currentRecord = try files.guardValue(folder.appendingPathComponent("record.json"))
            guard currentRecord == recordGuard else { throw IOSFileError.invalid("Recovery metadata changed") }
            if let bytes = bytes, let expected = targetSnapshot {
                try files.validate(expected, at: target)
                try files.write(bytes, to: target)
            } else {
                guard !files.exists(target) else { throw IOSFileError.invalid("Restore destination is occupied") }
                try files.move(payload, to: target)
            }
        }
        var result: [String: Any] = ["success": true, "recoveryId": recovery, "relativePath": record["relativePath"] ?? ""]
        do {
            var completed = record
            completed["phase"] = "restored"
            completed["restoredAt"] = now() * 1000
            try files.writeJSON(completed, to: folder.appendingPathComponent("record.json"))
            let history = root.appendingPathComponent("\(base)/history")
            try files.createDirectory(history)
            try files.move(folder, to: history.appendingPathComponent(recovery))
        } catch { result["warning"] = "Contents were restored, but recovery history could not be archived: \(error.localizedDescription)" }
        return result
    }
}
