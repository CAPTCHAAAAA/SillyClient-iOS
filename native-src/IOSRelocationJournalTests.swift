#if DEBUG
import Foundation

enum IOSRelocationJournalTests {
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw IOSFileError.invalid(message) }
    }

    private static func fixture(_ root: URL) throws -> (IOSInstanceStore, IOSInstallationLocation, IOSInstallationLocation, URL, Data) {
        let files = IOSManagedFiles(root: root)
        let store = IOSInstanceStore(root: root)
        let source = root.appendingPathComponent("instances/stable-id")
        let target = root.appendingPathComponent("instances/renamed")
        try files.createDirectory(source.appendingPathComponent("data"))
        try files.write(Data("fixture".utf8), to: source.appendingPathComponent("server.js"))
        try files.writeJSON(["version": "1.0.0"], to: source.appendingPathComponent("package.json"))
        let config = Data("dataRoot: \(source.path)/data\n".utf8)
        try files.write(config, to: source.appendingPathComponent("config.yaml"))
        try files.write(Data("retained".utf8), to: source.appendingPathComponent("data/chat.txt"))
        let origin = try store.locations.acquire(source)
        try files.writeJSON(["stable-id": store.registrationRecord("stable-id", location: origin)], to: store.registryURL)
        return (store, origin, try store.locations.acquire(target),
            target.deletingLastPathComponent().appendingPathComponent(".sillyclient-relocate-\(UUID().uuidString)"), config)
    }

    private static func authorizationRecovery(_ parent: URL, files: IOSManagedFiles) throws {
        for phase in ["committed-with-revoked-source", "copy-with-revoked-target"] {
            let documents = parent.appendingPathComponent("\(phase)/documents")
            let external = parent.appendingPathComponent("\(phase)/external")
            try files.createDirectory(documents)
            try files.createDirectory(external)
            var permitted = true
            var acquisitions = 0
            let locations = IOSInstallationLocations(documents: documents,
                makeBookmark: { Data($0.path.utf8) },
                resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
                startScope: { _ in acquisitions += 1; return permitted }, stopScope: { _ in }, externalCapability: { _ in })
            let (_, internalSource, internalTarget, _, original) = try fixture(documents)
            let store = IOSInstanceStore(root: documents, locations: locations)
            try locations.select(external)
            let externalLocation = try locations.acquire(external.appendingPathComponent("external-instance"))
            if phase == "committed-with-revoked-source" {
                try internalSource.files.move(internalSource.directory, to: externalLocation.directory, destination: externalLocation.files)
                try store.files.writeJSON(["stable-id": store.registrationRecord("stable-id", location: externalLocation)], to: store.registryURL)
                let staging = internalTarget.directory.deletingLastPathComponent().appendingPathComponent(".sillyclient-relocate-\(UUID().uuidString)")
                let journal = try IOSRelocationJournal(store: store, id: "stable-id", source: externalLocation,
                    destination: internalTarget, staging: staging, sameVolume: false, originals: ["config.yaml": original])
                try journal.staged(externalLocation.files.guardValue(externalLocation.directory).identity)
                try externalLocation.files.move(externalLocation.directory, to: internalTarget.directory, destination: store.files)
                try store.files.writeJSON(["stable-id": store.registrationRecord("stable-id", location: internalTarget)], to: store.registryURL)
                permitted = false
                let before = acquisitions
                let resolved = try IOSInstanceStore(root: documents, locations: locations).directory("stable-id")
                try require(resolved.path == internalTarget.directory.path && acquisitions == before,
                            "Committed internal instance still required obsolete external authorization")
            } else {
                let staging = external.appendingPathComponent(".sillyclient-relocate-\(UUID().uuidString)")
                let journal = try IOSRelocationJournal(store: store, id: "stable-id", source: internalSource,
                    destination: externalLocation, staging: staging, sameVolume: false, originals: ["config.yaml": original])
                try externalLocation.files.createExclusiveDirectory(staging)
                try externalLocation.files.write(Data("retained partial copy".utf8), to: staging.appendingPathComponent("retained.txt"))
                try journal.staged(externalLocation.files.guardValue(staging).identity)
                permitted = false
                let recreated = IOSInstanceStore(root: documents, locations: locations)
                try require(recreated.directory("stable-id").path == internalSource.directory.path,
                            "Lost destination authorization blocked the untouched source")
                try require(files.data(staging.appendingPathComponent("retained.txt")) == Data("retained partial copy".utf8),
                            "Recovery removed data at an unauthorized destination")
                try require(store.files.children(documents.appendingPathComponent(".sillyclient-relocations-retained"), limit: 256).count == 1,
                            "Unavailable destination lost its retained cleanup record")
            }
            try require(!store.files.exists(IOSRelocationJournal.url(store, "stable-id")), "Successful authorization recovery retained an active journal")
        }
    }

    private static func cancellationRecovery(_ root: URL, files: IOSManagedFiles) throws {
        try files.createDirectory(root)
        let (store, source, target, staging, original) = try fixture(root)
        _ = try IOSRelocationJournal(store: store, id: "stable-id", source: source,
            destination: target, staging: staging, sameVolume: true, originals: ["config.yaml": original])
        try store.files.move(source.directory, to: staging)
        let runner = NodeRunner.shared
        let operation = UUID().uuidString
        try runner.reserve(instance: "stable-id", operation: operation)
        defer { runner.stop(instance: "stable-id", operation: operation) }
        var wrongOperationRejected = false
        do { try runner.beginProvisionRecovery(instance: "stable-id", operation: "obsolete") }
        catch { wrongOperationRejected = true }
        try require(wrongOperationRejected, "Provision recovery accepted an unrelated operation")
        try runner.beginProvisionRecovery(instance: "stable-id", operation: operation)
        do {
            defer { runner.endMaintenance(instance: "stable-id") }
            let stopped = DispatchSemaphore(value: 0)
            runner.stop(instance: "stable-id", operation: operation) { _ in stopped.signal() }
            try require(stopped.wait(timeout: .now() + 5) == .success, "Cancelling recovery blocked runtime state IO")
            try require(runner.status["instanceId"] == nil, "Recovery cancellation retained an active runtime")
            var rejected = false
            do { try runner.reserve(instance: "other", operation: "other-operation") } catch { rejected = true }
            try require(rejected, "Another startup bypassed the recovery maintenance lease")
        }
        var cancelled = false
        do { try store.recoverRelocation("stable-id", operation: operation) } catch { cancelled = true }
        try require(cancelled && store.files.exists(staging), "A cancelled queued startup resumed relocation work")
        try require(store.directory("stable-id").path == source.directory.path, "Stopped instance could not recover on retry")
    }

    static func run(_ parent: URL, files: IOSManagedFiles) throws {
        for phase in ["prepared", "staged", "metadata", "published", "committed"] {
            let root = parent.appendingPathComponent(phase)
            try files.createDirectory(root)
            let (store, source, destination, staging, original) = try fixture(root)
            let managed = store.files
            let journal = try IOSRelocationJournal(store: store, id: "stable-id", source: source,
                destination: destination, staging: staging, sameVolume: true, originals: ["config.yaml": original])
            let changed = Data("dataRoot: \(destination.directory.path)/data\n".utf8)
            if phase != "prepared" { try managed.move(source.directory, to: staging) }
            if ["metadata", "published", "committed"].contains(phase) {
                try journal.willWrite(changed, name: "config.yaml")
                try managed.write(changed, to: staging.appendingPathComponent("config.yaml"))
            }
            if ["published", "committed"].contains(phase) { try managed.move(staging, to: destination.directory) }
            if phase == "committed" {
                try managed.writeJSON(["stable-id": store.registrationRecord("stable-id", location: destination)], to: store.registryURL)
            }
            let recreated = IOSInstanceStore(root: root)
            let resolved = try recreated.directory("stable-id")
            let expected = phase == "committed" ? destination.directory : source.directory
            try require(resolved.path == expected.path, "Recovery selected the wrong instance path at \(phase)")
            try require(managed.data(resolved.appendingPathComponent("config.yaml")) == (phase == "committed" ? changed : original),
                        "Recovery lost configuration at \(phase)")
            try require(managed.data(resolved.appendingPathComponent("data/chat.txt")) == Data("retained".utf8), "Recovery changed user data")
            try require(!managed.exists(IOSRelocationJournal.url(recreated, "stable-id")), "Completed recovery retained its journal")
        }
        let root = parent.appendingPathComponent("conflict")
        try files.createDirectory(root)
        let (store, source, destination, staging, original) = try fixture(root)
        _ = try IOSRelocationJournal(store: store, id: "stable-id", source: source,
            destination: destination, staging: staging, sameVolume: true, originals: ["config.yaml": original])
        try store.files.move(source.directory, to: staging)
        try store.files.createDirectory(source.directory)
        try store.files.write(Data("replacement".utf8), to: source.directory.appendingPathComponent("keep.txt"))
        var rejected = false
        do { _ = try IOSInstanceStore(root: root).directory("stable-id") } catch { rejected = true }
        try require(rejected && store.files.exists(staging), "Conflicting source was overwritten or staged data lost")
        try require(store.files.data(source.directory.appendingPathComponent("keep.txt")) == Data("replacement".utf8),
                    "Recovery modified a replacement directory")
        let legacyRoot = parent.appendingPathComponent("unregistered-legacy")
        try files.createDirectory(legacyRoot)
        let (legacy, old, next, pending, config) = try fixture(legacyRoot)
        try legacy.files.writeJSON([:], to: legacy.registryURL)
        _ = try IOSRelocationJournal(store: legacy, id: "stable-id", source: old, destination: next,
            staging: pending, sameVolume: true, originals: ["config.yaml": config])
        try legacy.files.move(old.directory, to: pending)
        let restored = try IOSInstanceStore(root: legacyRoot).records()
        try require(restored.count == 1 && restored[0]["instanceId"] as? String == "stable-id",
                    "Scanning lost an unregistered legacy instance moved to hidden staging")
        try require(legacy.files.exists(old.directory) && !legacy.files.exists(pending), "Legacy scan did not recover its original path")

        let copyRoot = parent.appendingPathComponent("copy-before-identity")
        try files.createDirectory(copyRoot)
        let (copyStore, intact, copyTarget, unknown, copyConfig) = try fixture(copyRoot)
        _ = try IOSRelocationJournal(store: copyStore, id: "stable-id", source: intact, destination: copyTarget,
            staging: unknown, sameVolume: false, originals: ["config.yaml": copyConfig])
        try copyStore.files.createExclusiveDirectory(unknown)
        try copyStore.files.write(Data("unverified".utf8), to: unknown.appendingPathComponent("keep.txt"))
        try require(copyStore.directory("stable-id").path == intact.directory.path, "Unrecorded staging identity blocked the intact source")
        try require(copyStore.files.data(unknown.appendingPathComponent("keep.txt")) == Data("unverified".utf8),
                    "Recovery removed an unverified staging directory")
        try require(copyStore.files.children(copyRoot.appendingPathComponent(".sillyclient-relocations-retained"), limit: 256).count == 1,
                    "Unverified staging lost its retained cleanup record")
        try authorizationRecovery(parent, files: files)
        try cancellationRecovery(parent.appendingPathComponent("cancelled-recovery"), files: files)
    }
}
#endif
