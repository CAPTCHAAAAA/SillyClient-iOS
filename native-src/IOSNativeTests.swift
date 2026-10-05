#if DEBUG
import Foundation
import Darwin
import ZIPFoundation
import WebKit

private final class IOSFixtureChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

enum IOSNativeTests {
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw IOSFileError.invalid(message) }
    }
    private static func rejects(_ message: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try require(rejected, message)
    }

    private static func relocationFixture(_ root: URL, files: IOSManagedFiles,
                                           id: String = "stable-id", relative: String? = nil) throws -> (IOSInstanceStore, URL) {
        let store = IOSInstanceStore(root: root)
        let path = root.appendingPathComponent(relative ?? "instances/\(id)")
        try files.createDirectory(path.appendingPathComponent("data/default-user"))
        try files.write(Data("fixture".utf8), to: path.appendingPathComponent("server.js"))
        try files.writeJSON(["name": "SillyTavern", "version": "1.0.0"], to: path.appendingPathComponent("package.json"))
        try files.write(Data("dataRoot: \(path.path)/data\nport: 8123\ncustom: retained\n".utf8),
                        to: path.appendingPathComponent("config.yaml"))
        try files.write(Data("retained chat".utf8), to: path.appendingPathComponent("data/default-user/chat.txt"))
        let location = try store.locations.acquire(path)
        try files.writeJSON([id: store.registrationRecord(id, location: location)], to: store.registryURL)
        return (store, path)
    }

    static func run(progress: (([String: Any]) -> Void)? = nil) -> [String: Any] {
        let parent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath().appendingPathComponent("ios-test-fixtures-\(UUID().uuidString)")
        var results: [[String: Any]] = []
        func test(_ name: String, _ body: (URL, IOSManagedFiles) throws -> Void) {
            let root = parent.appendingPathComponent(UUID().uuidString)
            let started = Date()
            progress?(["currentGroup": name, "completedGroups": results.count, "results": results, "state": "running"])
            autoreleasepool {
                var result: [String: Any] = ["name": name, "passed": true]
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try body(root, IOSManagedFiles(root: root))
                } catch {
                    result["passed"] = false
                    result["error"] = error.localizedDescription
                }
                result["elapsedMs"] = max(0, Int(Date().timeIntervalSince(started) * 1000))
                results.append(result)
            }
            progress?(["currentGroup": name, "completedGroups": results.count, "results": results, "state": "completed"])
        }
        defer { try? FileManager.default.removeItem(at: parent) }
        test("Instance access locks match Windows vectors and preserve protection on invalid data or failed writes") { _, _ in
            try IOSInstanceAccessLockTests.run()
        }
        test("Instance access lock Keychain storage survives recreation and deletion") { _, _ in
            try IOSInstanceAccessLockTests.runKeychain()
        }
        test("Instance deletion retains retryable ownership until physical removal and registry commit complete") { root, files in
            try IOSInstanceDeletionTests.run(root, files: files)
        }
        test("Instance rename preserves identity and data while updating the physical directory and scan") { root, files in
            let (store, source) = try relocationFixture(root, files: files)
            let identity = try files.guardValue(source).identity
            let result = try store.rename(instanceId: "stable-id", newName: "Renamed Instance", installPath: source.path)
            let renamed = root.appendingPathComponent("instances/Renamed Instance")
            try require(result["oldId"] as? String == "stable-id" && result["newId"] as? String == "stable-id", "Rename changed identity")
            try require(!files.exists(source) && files.guardValue(renamed).identity == identity, "Physical directory was not renamed")
            try require(files.data(renamed.appendingPathComponent("data/default-user/chat.txt")) == Data("retained chat".utf8), "User data changed")
            try require(store.migrationDataDirectory(renamed, files: files).path == renamed.appendingPathComponent("data").path,
                        "Rename left an absolute dataRoot at its previous path")
            try require(store.info("stable-id")["name"] as? String == "Renamed Instance", "Display name was not persisted")
            try require(store.records().count == 1, "Renamed directory was rediscovered as a second identity")
            let lower = try store.rename(instanceId: "stable-id", newName: "renamed instance")
            try require(lower["newPath"] as? String == root.appendingPathComponent("instances/renamed instance").path,
                        "Case-only rename did not update the real path")
            for name in ["", "..", "../outside", "nested/name", ".sillyclient-owned", "invalid\nname"] {
                try rejects("Unsafe instance name was accepted") { _ = try store.rename(instanceId: "stable-id", newName: name) }
            }
        }
        test("Instance relocation honors selected roots and defaults while rejecting overlap and unknown sources") { root, files in
            let (store, source) = try relocationFixture(root, files: files)
            let selected = root.appendingPathComponent("selected")
            try files.createDirectory(selected)
            try store.locations.select(selected)
            let result = try store.relocate(instanceId: "stable-id", targetPath: selected.path, installPath: source.path)
            let target = selected.appendingPathComponent("stable-id")
            try require(result["newPath"] as? String == target.path && !files.exists(source), "Selected root was ignored")
            let recreated = IOSInstanceStore(root: root)
            try require(recreated.directory("stable-id").path == target.path, "Recreated store lost the destination")
            try require(recreated.registry()["stable-id"]?["documentsRelativePath"] as? String == "selected/stable-id",
                        "Relocation dropped the sandbox-relative registration")
            try rejects("A nested destination was accepted") {
                _ = try store.relocate(instanceId: "stable-id", targetPath: target.appendingPathComponent("nested").path)
            }
            try rejects("An unregistered identity could rename another directory") {
                _ = try store.rename(instanceId: "unknown", newName: "stolen", installPath: target.path)
            }
            try rejects("Unsupported external path silently fell back") {
                _ = try store.relocate(instanceId: "stable-id", targetPath: root.deletingLastPathComponent().appendingPathComponent("unapproved/target").path)
            }
            let movedBack = try store.relocate(instanceId: "stable-id", targetPath: nil)
            try require(movedBack["newPath"] as? String == source.path && files.exists(source), "Default relocation was a false no-op")
        }
        test("Instance location mutations reject active runtime reservations without changing disk") { root, files in
            let (store, source) = try relocationFixture(root, files: files)
            let before = try files.data(store.registryURL)
            let operation = UUID().uuidString
            try NodeRunner.shared.reserve(instance: "busy-fixture", operation: operation)
            defer {
                let stopped = DispatchSemaphore(value: 0)
                NodeRunner.shared.stop(instance: "busy-fixture", operation: operation) { _ in stopped.signal() }
                _ = stopped.wait(timeout: .now() + 5)
            }
            try rejects("Rename moved a runtime with an active reservation") { _ = try store.rename(instanceId: "stable-id", newName: "blocked") }
            try rejects("Relocation moved a runtime with an active reservation") {
                _ = try store.relocate(instanceId: "stable-id", targetPath: root.appendingPathComponent("blocked").path)
            }
            try require(files.exists(source) && files.data(store.registryURL) == before, "Rejected operation changed instance state")
        }
        test("Registry commit failure restores the original directory configuration and ownership") { root, files in
            let (store, source) = try relocationFixture(root, files: files)
            let before = try files.data(store.registryURL)
            let configuration = try files.data(source.appendingPathComponent("config.yaml"))
            try require(chmod(root.path, mode_t(0o500)) == 0, "Could not prepare the registry failure fixture")
            defer { _ = chmod(root.path, mode_t(0o700)) }
            try rejects("Unwritable registry reported a successful rename") {
                _ = try store.rename(instanceId: "stable-id", newName: "uncommitted")
            }
            try require(files.exists(source) && !files.exists(root.appendingPathComponent("instances/uncommitted")), "Failed commit did not restore the original path")
            try require(files.data(source.appendingPathComponent("config.yaml")) == configuration, "Rollback changed the original YAML")
            try require(!files.exists(source.appendingPathComponent(store.ownershipName)), "Rollback left a new ownership receipt")
            try require(files.data(store.registryURL) == before, "Failed commit changed the registry")
        }
        test("Legacy migration enumerates real instances and reports partial failure without losing committed results") { root, files in
            let (store, source) = try relocationFixture(root, files: files, id: "default", relative: "SillyTavern")
            let candidates = try store.legacyInstances()
            try require(candidates.count == 1 && candidates[0]["currentPath"] as? String == source.path, "Legacy detection returned a stub")
            let result = try store.migrateLegacyInstances(instanceIds: ["default", "missing"])
            let results = result["results"] as? [[String: Any]] ?? []
            try require(result["success"] as? Bool == false && results.count == 2, "Partial failure was reported as total success")
            try require(results[0]["success"] as? Bool == true && results[1]["success"] as? Bool == false, "Committed item or failure details were lost")
            try require(store.directory("default").path == root.appendingPathComponent("instances/default").path,
                        "Legacy migration did not change the registered physical path")
            try require(store.legacyInstances().isEmpty, "Migrated instance was offered again")
            try rejects("Duplicated migration selection was accepted") { _ = try store.migrateLegacyInstances(instanceIds: ["default", "default"]) }
        }
        test("Relocation across approved authorities keeps leases and refreshes the destination registration") { root, files in
            let documents = root.appendingPathComponent("documents")
            let external = root.appendingPathComponent("external")
            try files.createDirectory(documents)
            try files.createDirectory(external)
            var scopes = 0
            let locations = IOSInstallationLocations(documents: documents,
                makeBookmark: { Data($0.path.utf8) },
                resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
                startScope: { _ in scopes += 1; return true }, stopScope: { _ in scopes -= 1 }, externalCapability: { _ in })
            let (initial, original) = try relocationFixture(documents, files: IOSManagedFiles(root: documents))
            _ = initial
            let store = IOSInstanceStore(root: documents, locations: locations)
            try locations.select(external)
            let moved = try store.relocate(instanceId: "stable-id", targetPath: external.path)
            try require(moved["newPath"] as? String == external.appendingPathComponent("stable-id").path, "Approved external root was ignored")
            try require(scopes == 0 && store.registry()["stable-id"]?["grantId"] as? String != nil, "External lease or grant was lost")
            let restored = try store.relocate(instanceId: "stable-id", targetPath: nil)
            try require(restored["newPath"] as? String == original.path && scopes == 0, "Return to Documents leaked a lease")
            try require(store.registry()["stable-id"]?["grantId"] == nil, "Internal registration retained an obsolete external grant")
        }
        test("Installation paths require absolute local paths and preserve quoted file URL semantics") { root, _ in
            let selected = root.appendingPathComponent("selected root")
            try require(IOSInstallationLocations.path("  \"\(selected.path)\"  ").path == selected.path, "Quoted path changed")
            try require(IOSInstallationLocations.path(selected.absoluteString).path == selected.path, "File URL changed")
            for raw in ["", "folder", "https://example.test/folder", "file://other-host/folder",
                        root.path + "/../outside", root.path + "/unsafe\nsuffix", "D:\\Tavern", "/unsafe\u{2028}name"] {
                try rejects("Unsafe installation path was accepted") { _ = try IOSInstallationLocations.path(raw) }
            }
        }
        test("Relocation journal recovers interrupted moves and refuses occupied source directories") { root, files in
            try IOSRelocationJournalTests.run(root, files: files)
        }
        test("Relocation preserves pending maintenance backups instead of invalidating restore metadata") { root, files in
            let (store, source) = try relocationFixture(root, files: files)
            let recovery = source.appendingPathComponent(".sillyclient-maintenance/recovery/\(UUID().uuidString)")
            try files.createDirectory(recovery)
            try files.write(Data("backup".utf8), to: recovery.appendingPathComponent("payload"))
            try files.writeJSON(["phase": "quarantined"], to: recovery.appendingPathComponent("record.json"))
            let before = try files.data(source.appendingPathComponent("config.yaml"))
            try rejects("Rename invalidated a pending maintenance backup") {
                _ = try store.rename(instanceId: "stable-id", newName: "blocked")
            }
            try require(files.data(source.appendingPathComponent("config.yaml")) == before,
                        "Rejected rename changed backup configuration")
            try require(files.data(recovery.appendingPathComponent("payload")) == Data("backup".utf8), "Recovery payload was lost")
        }
        test("Documents root and exact installation modes persist and reject conflicting instance paths") { root, files in
            let store = IOSInstanceStore(root: root)
            let selected = root.appendingPathComponent("selected-root")
            try files.createDirectory(selected)
            try require(store.locations.select(selected).path == selected.path, "Selected sandbox root changed")
            let target = selected.appendingPathComponent("custom-instance")
            let location = try store.location("custom-instance", installPath: selected.path, installPathMode: "root", requireExisting: false)
            try require(location.directory.path == target.path, "Root mode did not append the instance identity")
            try require(store.location("custom-instance", installPath: target.path, requireExisting: false).directory.path == target.path,
                        "Exact mode appended the instance twice")
            try files.createDirectory(target)
            try files.writeJSON(["custom-instance": ["path": target.path, "documentsRelativePath": "selected-root/custom-instance",
                "directoryIdentity": try files.guardValue(target).identity]], to: root.appendingPathComponent("instances-registry.json"))
            let recreated = IOSInstanceStore(root: root)
            try require(recreated.directory("custom-instance").path == target.path, "New store forgot its registered custom path")
            try require(recreated.location("custom-instance", installPath: target.path + "/").directory.path == target.path,
                        "A trailing directory separator conflicted with the registered path")
            try require(recreated.location("custom-instance", installPath: selected.path + "/", installPathMode: "root").directory.path == target.path,
                        "Root mode changed after its previously missing destination was created")
            try require(recreated.info("custom-instance")["installPath"] as? String == target.path, "Info reported a default path")
            try rejects("Registered instance was silently relocated") {
                _ = try recreated.location("custom-instance", installPath: root.appendingPathComponent("elsewhere").path)
            }
            try rejects("Nested instance path was accepted") {
                _ = try recreated.location("nested", installPath: target.appendingPathComponent("nested").path, requireExisting: false)
            }
            try rejects("Ancestor instance path was accepted") {
                _ = try recreated.location("ancestor", installPath: selected.path, requireExisting: false)
            }
            try rejects("Documents root became an uninstallable instance") {
                _ = try recreated.location("root-instance", installPath: root.path, requireExisting: false)
            }
            try rejects("Root mode accepted no selected path") { _ = try recreated.location("missing", installPathMode: "root", requireExisting: false) }
            let unrelated = root.appendingPathComponent("unregistered-user-directory")
            try files.createDirectory(unrelated)
            try files.write(Data("must survive".utf8), to: unrelated.appendingPathComponent("retained"))
            try rejects("Unregistered directory could be uninstalled") { _ = try recreated.uninstall("unregistered", installPath: unrelated.path) }
            try require(files.data(unrelated.appendingPathComponent("retained")) == Data("must survive".utf8), "Uninstall deleted unrelated data")
            let replacement = selected.appendingPathComponent("replacement")
            try files.move(target, to: replacement)
            try files.createDirectory(target)
            try rejects("Replaced registered directory was accepted") { _ = try recreated.directory("custom-instance") }
            let unavailable = try recreated.records().first { $0["instanceId"] as? String == "custom-instance" }
            try require(unavailable?["status"] as? String == "unavailable", "Unavailable registration disappeared from scan")
        }
        test("Persistent external root bookmarks retain bounded leases and fail closed after lost authorization") { root, files in
            let documents = root.appendingPathComponent("documents")
            let selected = root.appendingPathComponent("external-root")
            try files.createDirectory(documents)
            try files.createDirectory(selected)
            var scopes = 0
            var stale = false
            var permitted = true
            var moved = false
            func authorizations() -> IOSInstallationLocations {
                IOSInstallationLocations(documents: documents, makeBookmark: { Data($0.path.utf8) },
                    resolveBookmark: { (moved ? root : URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), stale) },
                    startScope: { _ in if permitted { scopes += 1 }; return permitted },
                    stopScope: { _ in scopes -= 1 }, externalCapability: { _ in })
            }
            let original = authorizations()
            try require(original.select(selected).path == selected.path && scopes == 0, "Picker authorization leaked its scope")
            var lease: IOSInstallationLocation? = try authorizations().acquire(selected.appendingPathComponent("instance"))
            try require(scopes == 1 && lease?.root.path == selected.path, "Recreated authority did not resolve the saved bookmark")
            try rejects("External lease authorized a sibling path") { _ = try lease!.files.checked(documents, allowMissing: true) }
            lease = nil
            try require(scopes == 0, "Stopped lease did not release security scope")
            stale = true
            try rejects("Stale bookmark used another runtime") { _ = try authorizations().acquire(selected.appendingPathComponent("instance")) }
            stale = false
            permitted = false
            try rejects("Lost authorization fell back internally") { _ = try authorizations().acquire(selected.appendingPathComponent("instance")) }
            permitted = true
            moved = true
            try rejects("Moved bookmark substituted another directory") { _ = try authorizations().acquire(selected.appendingPathComponent("instance")) }
            moved = false
            let old = root.appendingPathComponent("original-root")
            try files.move(selected, to: old)
            try files.createDirectory(selected)
            try rejects("Same-path replacement root was trusted") { _ = try authorizations().acquire(selected.appendingPathComponent("instance")) }
            try require(scopes == 0, "Rejected bookmark leaked security scope")
            let denied = IOSInstallationLocations(documents: documents, makeBookmark: { _ in Data([1]) },
                startScope: { _ in true }, stopScope: { _ in },
                externalCapability: { _ in throw IOSFileError.invalid("Unsupported provider fixture") })
            try rejects("Unsupported provider was persisted") { _ = try denied.select(selected) }
        }
        test("Custom installation commits at the selected root and can recover registration without replacing data") { root, files in
            let store = IOSInstanceStore(root: root)
            let selected = root.appendingPathComponent("selected-root")
            try files.createDirectory(selected)
            try store.locations.select(selected)
            let id = "actual-custom-runtime"
            let target = selected.appendingPathComponent(id)
            func prepare(_ mode: String, path: String, persistedSelections: Bool = false) throws {
                let operation = UUID().uuidString
                try NodeRunner.shared.reserve(instance: id, operation: operation)
                defer {
                    let stopped = DispatchSemaphore(value: 0)
                    NodeRunner.shared.stop(instance: id, operation: operation) { _ in stopped.signal() }
                    _ = stopped.wait(timeout: .now() + 5)
                }
                let actual = try store.prepare(instance: id, operation: operation, version: "stable", localZip: nil,
                    installPath: path, installPathMode: mode, port: 8123, config: nil,
                    preinstall: persistedSelections ? ["revision": 1, "extensionIds": ["already-created"]] : nil,
                    companion: persistedSelections ? ["bundleId": "sc-bordeaux", "revision": 1] : nil)
                try require(actual.path == target.path, "Preparation used the default directory")
            }
            try prepare("root", path: selected.path)
            let marker = target.appendingPathComponent("data/retained-user-data")
            try files.write(Data("preserved".utf8), to: marker)
            let server = try files.snapshot(target.appendingPathComponent("server.js"))
            try files.writeJSON([:], to: root.appendingPathComponent("instances-registry.json"))
            try prepare("exact", path: target.path, persistedSelections: true)
            try require(files.snapshot(target.appendingPathComponent("server.js")) == server, "Recovery replaced the pinned runtime")
            try require(files.data(marker) == Data("preserved".utf8), "Registration recovery replaced user data")
            let recreated = IOSInstanceStore(root: root)
            try require(recreated.info(id)["installPath"] as? String == target.path, "Recreated store lost custom registration")
            try require(!files.exists(root.appendingPathComponent("instances/\(id)")), "A fallback runtime was also created")
            let sibling = selected.appendingPathComponent("unrelated")
            try files.write(Data("untouched".utf8), to: sibling)
            try require(recreated.uninstall(id, installPath: target.path)["success"] as? Bool == true, "Custom uninstall failed")
            try require(!files.exists(target) && files.exists(selected) && files.data(sibling) == Data("untouched".utf8),
                        "Uninstall removed the selected root or unrelated data")
        }
        test("Custom copy migration and maintenance share the registered directory and preserve their source") { root, files in
            let store = IOSInstanceStore(root: root)
            let selected = root.appendingPathComponent("migration-root")
            let source = root.appendingPathComponent("source-user")
            try files.createDirectory(selected)
            try files.createDirectory(source.appendingPathComponent("chats"))
            try files.createDirectory(source.appendingPathComponent("extensions/broken-custom"))
            try files.write(Data("chat-preserved".utf8), to: source.appendingPathComponent("chats/chat.jsonl"))
            try files.writeJSON(["unrelated": true], to: source.appendingPathComponent("settings.json"))
            try files.write(Data("extension-preserved".utf8), to: source.appendingPathComponent("extensions/broken-custom/index.js"))
            let before = try files.snapshot(source)
            let id = "custom-copy-runtime"
            let operation = UUID().uuidString
            try NodeRunner.shared.reserve(instance: id, operation: operation)
            let target: URL
            do {
                target = try store.migrate(instance: id, operation: operation, sourcePath: source.path,
                    targetPath: selected.path, installPathMode: "root", mode: "copy", includeSecrets: false, preinstall: nil)
            } catch {
                let stopped = DispatchSemaphore(value: 0)
                NodeRunner.shared.stop(instance: id, operation: operation) { _ in stopped.signal() }
                _ = stopped.wait(timeout: .now() + 5)
                throw error
            }
            let stopped = DispatchSemaphore(value: 0)
            NodeRunner.shared.stop(instance: id, operation: operation) { _ in stopped.signal() }
            try require(stopped.wait(timeout: .now() + 5) == .success, "Migration reservation did not stop")
            try require(target.path == selected.appendingPathComponent(id).path, "Copy used an internal fallback")
            let maintenance = IOSInstanceMaintenance(store: IOSInstanceStore(root: root))
            let scan = try maintenance.scan(id)
            let candidate = (scan["items"] as! [[String: Any]]).first!
            let applied = try maintenance.apply(instance: id, scanId: scan["scanId"] as! String,
                selections: [["id": candidate["id"]!, "token": candidate["token"]!]])
            try require(applied["success"] as? Bool == true, "Custom extension was not quarantined")
            let recovery = (try maintenance.list(id)["items"] as! [[String: Any]]).first!
            try require(maintenance.restore(instance: id, recovery: recovery["recoveryId"] as! String,
                token: recovery["token"] as! String)["success"] as? Bool == true, "Custom recovery failed")
            try require(files.snapshot(source) == before, "Copy or maintenance changed its source")
            try require(files.data(target.appendingPathComponent("data/default-user/chats/chat.jsonl")) == Data("chat-preserved".utf8),
                        "Custom copy orphaned user data")
            _ = try store.uninstall(id, installPath: target.path)
            try require(files.snapshot(source) == before && files.exists(selected), "Custom uninstall changed source or selected root")
        }
        test("Credential-free URL validation and origin boundaries") { _, _ in
            for raw in ["javascript:alert(1)", "file:///tmp/test", "https://user:pass@example.com", "//example.com", "https:///"] {
                do {
                    _ = try IOSNavigationPolicy.validatedURL(raw)
                    throw IOSFileError.invalid("Unsafe URL was accepted")
                } catch let error as IOSFileError {
                    guard error.localizedDescription != "Unsafe URL was accepted" else { throw error }
                }
            }
            let first = try IOSNavigationPolicy.validatedURL("https://example.com/a")
            let second = try IOSNavigationPolicy.validatedURL("https://example.com:443/b")
            try require(IOSNavigationPolicy.sameOrigin(first, second), "Default HTTPS port did not match")
            try require(!IOSNavigationPolicy.sameOrigin(first, URL(string: "http://example.com")!), "Scheme change matched")
            try require(!IOSNavigationPolicy.sameOrigin(first, URL(string: "https://example.com:444")!), "Port change matched")
        }
        test("Bounded runtime log frames preserve captured identities and reject malformed output") { _, _ in
            func frame(instance: String = "fixture-instance", operation: String = "fixture-operation",
                       stream: String = "stdout", bytes: Data, extra: Bool = false) throws -> Data {
                var value = ["instanceId": instance, "operationId": operation, "stream": stream,
                             "lineBase64": bytes.base64EncodedString()]
                if extra { value["unexpected"] = "field" }
                var result = Data(IOSRuntimeLogFrame.prefix.utf8)
                result.append(try JSONSerialization.data(withJSONObject: value))
                return result
            }
            let line = "\u{4E2D}\u{6587} [SILLYCLIENT_LOG_V1] nested text"
            for stream in ["stdout", "stderr"] {
                guard let value = IOSRuntimeLogFrame.decode(try frame(stream: stream, bytes: Data(line.utf8))) else {
                    throw IOSFileError.invalid("Valid runtime log frame was rejected")
                }
                try require(value.instanceId == "fixture-instance" && value.operationId == "fixture-operation",
                            "Captured log identity was changed")
                try require(value.stream == stream && value.line == line, "UTF-8 log payload or stream changed")
            }
            try require(IOSRuntimeLogFrame.decode(try frame(bytes: Data(repeating: 97, count: 16384))) != nil,
                        "Maximum bounded log payload was rejected")
            let malformed = try [
                frame(instance: "unsafe\n", bytes: Data("line".utf8)),
                frame(operation: "unsafe\r", bytes: Data("line".utf8)),
                frame(instance: "../outside", bytes: Data("line".utf8)),
                frame(operation: String(repeating: "a", count: 129), bytes: Data("line".utf8)),
                frame(stream: "other", bytes: Data("line".utf8)),
                frame(bytes: Data()),
                frame(bytes: Data("two\nlines".utf8)),
                frame(bytes: Data([0xc3, 0x28])),
                frame(bytes: Data(repeating: 97, count: 16385)),
                frame(bytes: Data("line".utf8), extra: true),
                Data("unframed host output".utf8),
                Data((IOSRuntimeLogFrame.prefix + "{}").utf8),
                Data(repeating: 97, count: 24577),
            ]
            for bytes in malformed {
                try require(IOSRuntimeLogFrame.decode(bytes) == nil, "Malformed runtime log frame was accepted")
            }
            for identity in ["trailing\n", "trailing\r", "../outside", "", String(repeating: "a", count: 129)] {
                try rejects("Unsafe native instance identity was accepted") { _ = try IOSInstanceStore.identity(identity) }
            }
        }
        test("Captured native diagnostics remain storage-only while valid Worker frames publish once") { _, _ in
            var routed: [(line: String, instance: String, operation: String, publishes: Bool)] = []
            func route(_ bytes: Data) {
                NodeRunner.routeCapturedOutput(bytes) { line, instance, operation, publishes in
                    routed.append((line, instance, operation, publishes))
                }
            }
            let diagnostic = "TO JS {\"message\":\"captured native listener delivery\"}"
            route(Data(diagnostic.utf8))
            var frame = Data(IOSRuntimeLogFrame.prefix.utf8)
            frame.append(try JSONSerialization.data(withJSONObject: [
                "instanceId": "captured-instance", "operationId": "captured-operation", "stream": "stdout",
                "lineBase64": Data("original worker message".utf8).base64EncodedString(),
            ]))
            route(frame)
            route(Data((IOSRuntimeLogFrame.prefix + "{}").utf8))
            route(Data(repeating: 97, count: 65537))
            try require(routed.count == 4, "Captured output was lost or duplicated")
            try require(routed[0].line == diagnostic && routed[0].instance == "runtime"
                        && routed[0].operation.isEmpty && !routed[0].publishes,
                        "Native delivery output could feed another frontend log event")
            try require(routed[1].line == "original worker message" && routed[1].instance == "captured-instance"
                        && routed[1].operation == "captured-operation" && routed[1].publishes,
                        "Valid Worker message lost its captured identity or publication")
            for index in [2, 3] {
                try require(routed[index].instance == "runtime" && routed[index].operation.isEmpty
                            && !routed[index].publishes && routed[index].line.utf8.count < 100,
                            "Invalid captured output was relayed or retained without a bound")
            }
        }
        test("Native runtime event adapter preserves the console contract and rejects obsolete local modes") { _, _ in
            let log = IOSRuntimeEvents.log(instance: "fixture-instance", operation: "fixture-operation", line: "retained message")
            try require(log["message"] as? String == "retained message" && log["line"] as? String == "retained message",
                        "Legacy or scoped log payload was lost")
            try require(log["instanceId"] as? String == "fixture-instance" && log["operationId"] as? String == "fixture-operation",
                        "Runtime event identity was changed")
            let ready: [String: Any] = ["state": "ready", "instanceId": "fixture-instance",
                "operationId": "fixture-operation", "mode": "local", "serverReady": true]
            let active = IOSRuntimeEvents.mode(ready, current: ready, remoteActive: false)
            try require(active?["mode"] as? String == "launcher" && active?["tavernRunning"] as? Bool == true,
                        "Ready event did not preserve the existing console contract")
            try require(active?["runtimeMode"] as? String == "local", "Runtime ownership mode was lost")
            try require(IOSRuntimeEvents.mode(ready, current: ready, remoteActive: true) == nil,
                        "Local mode replaced an active remote session")
            for (key, value) in [("state", "stopped"), ("instanceId", "different-instance"), ("operationId", "different-operation")] {
                var newer = ready
                newer[key] = value
                try require(IOSRuntimeEvents.mode(ready, current: newer, remoteActive: false) == nil,
                            "Obsolete local mode was accepted")
            }
            let stopped: [String: Any] = ["state": "stopped", "mode": "local", "serverReady": false]
            let closed = IOSRuntimeEvents.mode(stopped, current: stopped, remoteActive: false)
            try require(closed?["mode"] as? String == "launcher" && closed?["tavernRunning"] as? Bool == false,
                        "Stopped event cannot reset the existing instance cards")
            for state in ["provisioning", "starting", "stopping", "uncertain", "failed"] {
                var unresolved = ready
                unresolved["serverReady"] = false
                unresolved["state"] = state
                try require(IOSRuntimeEvents.mode(unresolved, current: unresolved, remoteActive: false) == nil,
                            "An unresolved local operation was reported as stopped")
            }
        }
        test("Application-owned WebView credentials refresh and clear without crossing challenge origins") { _, _ in
            let controller = TavernViewController.shared
            guard let webView = controller.tavernWebView else { throw IOSFileError.invalid("Actual Tavern WebView is unavailable") }
            let sender = IOSFixtureChallengeSender()
            let source = URL(string: "https://example.test/a")!
            defer { controller.clearRemoteCredentials() }
            func received(host: String = "example.test", scheme: String = "https", port: Int = 443,
                          failures: Int = 0, method: String = NSURLAuthenticationMethodHTTPBasic)
                throws -> (URLSession.AuthChallengeDisposition, URLCredential?) {
                let space = URLProtectionSpace(host: host, port: port, protocol: scheme, realm: nil, authenticationMethod: method)
                let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                    previousFailureCount: failures, failureResponse: nil, error: nil, sender: sender)
                var disposition: URLSession.AuthChallengeDisposition?
                var credential: URLCredential?
                var calls = 0
                controller.webView(webView, didReceive: challenge) { value, supplied in
                    calls += 1
                    disposition = value
                    credential = supplied
                }
                guard calls == 1, let value = disposition else { throw IOSFileError.invalid("Challenge was not completed exactly once") }
                return (value, credential)
            }
            controller.updateRemoteCredentials(url: source, username: "first-fixture", password: "old-fixture")
            try require(received().1?.password == "old-fixture", "Initial application credential was not supplied")
            controller.updateRemoteCredentials(url: source, username: "second-fixture", password: "new-fixture")
            let refreshed = try received()
            try require(refreshed.0 == .useCredential && refreshed.1?.user == "second-fixture"
                        && refreshed.1?.password == "new-fixture", "Same-origin application credential was not refreshed")
            let refused = try [received(host: "other.test"), received(scheme: "http"), received(port: 444),
                               received(failures: 1), received(method: NSURLAuthenticationMethodHTTPDigest)]
            for value in refused {
                try require(value.0 != .useCredential && value.1 == nil, "Credentials were reused for an unrelated or failed challenge")
            }
            controller.updateRemoteCredentials(url: source, username: nil, password: nil)
            try require(received().1 == nil, "An unconfigured remote retained another instance's application credential")
            controller.updateRemoteCredentials(url: source, username: "first-fixture", password: "old-fixture")
            controller.clearRemoteCredentials()
            try require(received().1 == nil, "Clearing credentials retained the application-owned password")
        }
        test("Links and sibling-prefix paths cannot escape managed storage") { root, files in
            let outside = parent.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("preserved".utf8).write(to: outside.appendingPathComponent("secret"))
            let linked = root.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
            do { _ = try files.data(linked.appendingPathComponent("secret")); throw IOSFileError.invalid("Link was followed") }
            catch let error as IOSFileError {
                guard error.localizedDescription != "Link was followed" else { throw error }
            }
            do { _ = try files.checked(URL(fileURLWithPath: root.path + "-sibling/file"), allowMissing: true)
                throw IOSFileError.invalid("Sibling prefix was accepted")
            } catch let error as IOSFileError {
                guard error.localizedDescription != "Sibling prefix was accepted" else { throw error }
            }
            try require(String(data: Data(contentsOf: outside.appendingPathComponent("secret")), encoding: .utf8) == "preserved",
                        "Outside data changed")
        }
        test("Snapshot detects same-size changes inside a directory") { root, files in
            let tree = root.appendingPathComponent("extension")
            try files.createDirectory(tree)
            let file = tree.appendingPathComponent("index.js")
            try files.write(Data("before".utf8), to: file)
            let before = try files.snapshot(tree)
            try files.write(Data("after!".utf8), to: file)
            try require(files.snapshot(tree).digest != before.digest, "Changed contents were not detected")
        }
        test("Atomic no-clobber move preserves both occupied paths") { root, files in
            let source = root.appendingPathComponent("source")
            let target = root.appendingPathComponent("target")
            try files.write(Data("original".utf8), to: source)
            try files.write(Data("reinstalled".utf8), to: target)
            do { try files.move(source, to: target); throw IOSFileError.invalid("Move overwrote its target") }
            catch let error as IOSFileError {
                guard error.localizedDescription != "Move overwrote its target" else { throw error }
            } catch {}
            try require(String(data: files.data(source), encoding: .utf8) == "original", "Source was lost")
            try require(String(data: files.data(target), encoding: .utf8) == "reinstalled", "Target was overwritten")
        }
        test("Archive extraction verifies real entries and rejects traversal") { root, files in
            let archiveURL = root.appendingPathComponent("safe.zip")
            let bytes = Data("verified asset".utf8)
            do {
                let archive = try Archive(url: archiveURL, accessMode: .create)
                try archive.addEntry(with: "package/index.js", type: .file, uncompressedSize: Int64(bytes.count),
                                     compressionMethod: .deflate, provider: { offset, size in
                    bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + size))
                })
            }
            let output = root.appendingPathComponent("output")
            try files.createDirectory(output)
            try IOSSafeArchive.extract(archiveURL, to: output, stripSingleRoot: true)
            try require(files.data(output.appendingPathComponent("index.js")) == bytes, "Extracted bytes did not match")
            for path in ["../outside", "/absolute", "a\\b", "a/../b", "a//b"] {
                do { _ = try IOSSafeArchive.relativePath(path); throw IOSFileError.invalid("Unsafe archive path accepted") }
                catch let error as IOSFileError {
                    guard error.localizedDescription != "Unsafe archive path accepted" else { throw error }
                }
            }
        }
        test("Filtered streaming migration verifies data without copying dependencies or credentials") { root, files in
            let source = root.appendingPathComponent("source")
            let target = root.appendingPathComponent("target")
            for name in ["default-user/chats", "default-user/node_modules", ".git"] {
                try files.createDirectory(source.appendingPathComponent(name))
            }
            let original = Data("verified chat data".utf8)
            try files.write(original, to: source.appendingPathComponent("default-user/chats/chat.jsonl"))
            try files.write(Data("private".utf8), to: source.appendingPathComponent("default-user/secrets.json"))
            try files.write(Data("old dependency".utf8), to: source.appendingPathComponent("default-user/node_modules/old.js"))
            try files.copyTree(source, to: target, destination: files, include: {
                !$0.split(separator: "/").contains(where: { [".git", "node_modules", "secrets.json"].contains(String($0)) })
            })
            try require(files.data(target.appendingPathComponent("default-user/chats/chat.jsonl")) == original, "Copied chat changed")
            try require(!files.exists(target.appendingPathComponent("default-user/secrets.json")), "Credential was copied")
            try require(!files.exists(target.appendingPathComponent("default-user/node_modules")), "Dependency was copied")
            try require(!files.exists(target.appendingPathComponent(".git")), "Git history was copied")
            try require(String(data: files.data(source.appendingPathComponent("default-user/secrets.json")), encoding: .utf8) == "private",
                        "Source credential was changed")
        }
        test("Streaming migration rejects links, byte overflow, and cancellation while preserving sources") { root, files in
            let source = root.appendingPathComponent("source")
            try files.createDirectory(source)
            try files.write(Data("original".utf8), to: source.appendingPathComponent("chat"))
            try rejects("Migration ignored its byte limit") {
                try files.copyTree(source, to: root.appendingPathComponent("bounded"), destination: files,
                                   budget: IOSInspectionBudget(maxEntries: 8, maxBytes: 4))
            }
            try rejects("Migration ignored cancellation") {
                try files.copyTree(source, to: root.appendingPathComponent("cancelled"), destination: files,
                                   cancelled: { throw IOSFileError.invalid("Synthetic cancellation") })
            }
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked"),
                                                      withDestinationURL: source.appendingPathComponent("chat"))
            try rejects("Migration followed a linked data file") {
                try files.copyTree(source, to: root.appendingPathComponent("linked-copy"), destination: files)
            }
            try require(String(data: files.data(source.appendingPathComponent("chat")), encoding: .utf8) == "original", "Source changed")
        }
        test("Migration detects bounded custom dataRoot without flattening a single-user data directory") { root, files in
            let store = IOSInstanceStore(root: root)
            let source = root.appendingPathComponent("source")
            let data = source.appendingPathComponent("custom-data")
            try files.createDirectory(data.appendingPathComponent("default-user"))
            try files.write(Data("dataRoot: custom-data\n".utf8), to: source.appendingPathComponent("config.yaml"))
            try require(store.migrationDataDirectory(source, files: files).path == data.path, "Custom dataRoot was not selected")
            try require(store.migrationDataDirectory(data, files: files).path == data.path, "Single-user data root was flattened")
            try files.write(Data("dataRoot: ../outside\n".utf8), to: source.appendingPathComponent("config.yaml"))
            try files.createDirectory(root.appendingPathComponent("outside"))
            try rejects("Migration read outside the selected source") { _ = try store.migrationDataDirectory(source, files: files) }
        }
        test("Flat user folders and ZIPs map into default-user while multi-user roots keep their layout") { root, files in
            let store = IOSInstanceStore(root: root)
            let single = root.appendingPathComponent("single-user")
            let settings = Data("{\"unrelated\":\"preserved\"}\n".utf8)
            let chat = Data("{\"chat\":\"preserved\"}\n".utf8)
            try files.createDirectory(single.appendingPathComponent("chats"))
            try files.write(settings, to: single.appendingPathComponent("settings.json"))
            try files.write(chat, to: single.appendingPathComponent("chats/chat.jsonl"))
            let before = try files.snapshot(single)
            func copyAndCheck(_ source: URL, to dataRoot: URL) throws {
                let data = try store.migrationDataDirectory(source, files: files, portableBackup: true)
                let target = try store.migrationDataTarget(data, files: files, dataRoot: dataRoot)
                try files.copyTree(data, to: target, destination: files)
                try require(files.data(dataRoot.appendingPathComponent("default-user/settings.json")) == settings,
                            "Flat user settings did not reach default-user")
                try require(files.data(dataRoot.appendingPathComponent("default-user/chats/chat.jsonl")) == chat,
                            "Flat user chats did not reach default-user")
                try require(!files.exists(dataRoot.appendingPathComponent("settings.json"))
                            && !files.exists(dataRoot.appendingPathComponent("chats")), "Flat data was orphaned at the multi-user root")
            }
            try copyAndCheck(single, to: root.appendingPathComponent("folder-copy/data"))
            let zip = root.appendingPathComponent("flat-user.zip")
            do {
                let archive = try Archive(url: zip, accessMode: .create)
                for (name, bytes) in [("settings.json", settings), ("chats/chat.jsonl", chat)] {
                    try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(bytes.count),
                                         compressionMethod: .deflate, provider: { offset, size in
                        bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + size))
                    })
                }
            }
            let extracted = root.appendingPathComponent("flat-extracted")
            try files.createDirectory(extracted)
            try IOSSafeArchive.extract(zip, to: extracted)
            try copyAndCheck(extracted, to: root.appendingPathComponent("zip-copy/data"))
            try require(files.snapshot(single) == before, "Flat source data changed")
            let multi = root.appendingPathComponent("multi-user")
            for name in ["default-user", "another-user", "chats", "characters"] {
                try files.createDirectory(multi.appendingPathComponent(name))
                try files.write(settings, to: multi.appendingPathComponent("\(name)/settings.json"))
            }
            let multiTarget = root.appendingPathComponent("multi-copy/data")
            let target = try store.migrationDataTarget(multi, files: files, dataRoot: multiTarget)
            try require(target.path == multiTarget.path, "Multi-user data acquired an extra default-user layer")
            try files.copyTree(multi, to: target, destination: files)
            for name in ["default-user", "another-user", "chats", "characters"] {
                try require(files.data(multiTarget.appendingPathComponent("\(name)/settings.json")) == settings,
                            "Multi-user layout changed")
            }
            try files.write(settings, to: multi.appendingPathComponent("settings.json"))
            try rejects("Ambiguous flat and nested user data was accepted") {
                _ = try store.migrationDataTarget(multi, files: files, dataRoot: root.appendingPathComponent("ambiguous/data"))
            }
        }
        test("YAML configuration preserves unrelated values and validates Boolean and heartbeat inputs") { root, files in
            let store = IOSInstanceStore(root: root)
            let configURL = root.appendingPathComponent("config.yaml")
            try files.write(Data("unrelated: preserved\nprotocol:\n  unrelatedProtocol: retained\nbrowserLaunch:\n  unrelatedBrowser: retained\n".utf8), to: configURL)
            try store.updateConfig(root, port: 8123, config: ["ipv4": false, "ipv6": true, "heartbeat": 20])
            try require(!store.ipv4(root), "IPv6-only configuration was not applied")
            let yaml = String(data: try files.data(root.appendingPathComponent("config.yaml")), encoding: .utf8) ?? ""
            try require(yaml.contains("preserved") && yaml.contains("8123") && yaml.contains("unrelatedProtocol") && yaml.contains("unrelatedBrowser"),
                        "Unrelated YAML, mapping sibling, or port was lost")
            let invalidValues: [[String: Any]] = [["heartbeat": true], ["heartbeat": -1], ["heartbeat": 1.5], ["heartbeat": "20"],
                                                 ["heartbeat": 2147483648], ["ipv4": 1], ["ipv4": false, "ipv6": false], ["unknown": true]]
            let original = try files.data(configURL)
            for invalid in invalidValues {
                try rejects("Invalid configuration was accepted") { try store.updateConfig(root, port: 8123, config: invalid) }
                try require(files.data(configURL) == original, "Rejected configuration changed the original YAML")
            }
            try store.updateConfig(root, port: 8123, config: ["heartbeat": 2147483647])
            try require(String(decoding: files.data(configURL), as: UTF8.self).contains("2147483647"), "Maximum cross-platform heartbeat was rejected")
            for key in ["protocol", "browserLaunch"] {
                for conflicting in ["false", "legacy-scalar", "[one, two]", "null"] {
                    let bytes = Data("unrelated: preserved\n\(key): \(conflicting)\n".utf8)
                    try files.write(bytes, to: configURL)
                    try rejects("Existing conflicting YAML mapping was replaced") { try store.updateConfig(root, port: 8123, config: [:]) }
                    try require(files.data(configURL) == bytes, "Conflicting existing mapping was not preserved")
                }
            }
        }
        test("Preinstalled manifest validation accepts omitted, null, and empty optional assets") { root, files in
            try files.write(Data("verified entry".utf8), to: root.appendingPathComponent("index.js"))
            let optionalAssets: [Any] = ["", NSNull()]
            for css in optionalAssets {
                try IOSPreinstaller.validateManifest(["js": "./index.js", "css": css], directory: root)
            }
            try IOSPreinstaller.validateManifest(["js": "index.js"], directory: root)
            try rejects("Non-string optional manifest asset was accepted") {
                try IOSPreinstaller.validateManifest(["js": "index.js", "css": false], directory: root)
            }
            try rejects("Missing manifest entry was accepted") {
                try IOSPreinstaller.validateManifest(["js": "missing.js"], directory: root)
            }
        }
        test("Prepared runtime validation rejects missing and empty version identities") { root, files in
            let store = IOSInstanceStore(root: root)
            for name in ["server.js", "ios-loader.mjs"] {
                try files.write(Data("synthetic runtime".utf8), to: root.appendingPathComponent(name))
            }
            try files.createDirectory(root.appendingPathComponent("node_modules"))
            try files.createDirectory(root.appendingPathComponent("dist/ios-frontend"))
            let package = root.appendingPathComponent("package.json")
            let manifest = root.appendingPathComponent("dist/ios-frontend/manifest.json")
            try files.writeJSON([:], to: package)
            try files.writeJSON(["format": 1], to: manifest)
            try rejects("Missing versions compared equal") { _ = try store.validateRuntime(root, files: files) }
            try files.writeJSON(["version": " "], to: package)
            try files.writeJSON(["format": 1, "version": " "], to: manifest)
            try rejects("Empty runtime version was accepted") { _ = try store.validateRuntime(root, files: files) }
            try files.writeJSON(["version": "1.0.0"], to: package)
            try files.writeJSON(["format": 1, "version": "1.0.0"], to: manifest)
            try require(store.validateRuntime(root, files: files) == "1.0.0", "Matching version was rejected")
            try files.writeJSON(["format": 1, "version": "1.0.1"], to: manifest)
            try rejects("Mismatched frontend version was accepted") { _ = try store.validateRuntime(root, files: files) }
        }
        func maintenanceFixture(_ root: URL, _ files: IOSManagedFiles) throws -> (IOSInstanceStore, URL, URL) {
            let instance = root.appendingPathComponent("instances/test-instance")
            let user = instance.appendingPathComponent("data/default-user")
            try files.createDirectory(user.appendingPathComponent("extensions"))
            try files.write(Data("listen: false\n".utf8), to: instance.appendingPathComponent("config.yaml"))
            return (IOSInstanceStore(root: root), instance, user)
        }
        func selection(_ scan: [String: Any], kind: String) throws -> [[String: Any]] {
            guard let items = scan["items"] as? [[String: Any]], let item = items.first(where: { $0["kind"] as? String == kind }),
                  let id = item["id"] as? String, let token = item["token"] as? String else {
                throw IOSFileError.invalid("Expected maintenance candidate is missing")
            }
            return [["id": id, "token": token]]
        }
        test("Actual maintenance quarantines and restores extensions with single-use tokens and archived history") { root, files in
            let (store, instance, user) = try maintenanceFixture(root, files)
            let extensionURL = user.appendingPathComponent("extensions/broken")
            try files.createDirectory(extensionURL)
            try files.write(Data("retained extension".utf8), to: extensionURL.appendingPathComponent("index.js"))
            let maintenance = IOSInstanceMaintenance(store: store)
            let scan = try maintenance.scan("test-instance")
            let chosen = try selection(scan, kind: "broken_extension")
            let applied = try maintenance.apply(instance: "test-instance", scanId: scan["scanId"] as! String, selections: chosen)
            try require(applied["success"] as? Bool == true && !files.exists(extensionURL), "Extension was not quarantined")
            try rejects("Scan token was reused") { _ = try maintenance.apply(instance: "test-instance", scanId: scan["scanId"] as! String, selections: chosen) }
            let listed = try maintenance.list("test-instance")
            guard let item = (listed["items"] as? [[String: Any]])?.first,
                  let recovery = item["recoveryId"] as? String, let token = item["token"] as? String else {
                throw IOSFileError.invalid("Recovery was not listed")
            }
            let restored = try maintenance.restore(instance: "test-instance", recovery: recovery, token: token)
            try require(restored["success"] as? Bool == true, "Extension restore failed")
            try require(String(data: files.data(extensionURL.appendingPathComponent("index.js")), encoding: .utf8) == "retained extension",
                        "Restored contents changed")
            try require(files.exists(instance.appendingPathComponent(".sillyclient-maintenance/history/\(recovery)")), "Recovery history was not archived")
            try require((maintenance.list("test-instance")["items"] as? [[String: Any]])?.isEmpty == true, "Restored record remained active")
            try rejects("Restore token was reused") { _ = try maintenance.restore(instance: "test-instance", recovery: recovery, token: token) }
        }
        test("Disabled-reference maintenance changes only the selected references and restores original settings") { root, files in
            let (store, _, user) = try maintenanceFixture(root, files)
            let settings = user.appendingPathComponent("settings.json")
            let original: [String: Any] = ["extension_settings": ["disabledExtensions": ["third-party/missing", "built-in"]],
                                           "unrelated": ["nested": "preserved"]]
            try files.writeJSON(original, to: settings)
            let before = try files.data(settings)
            let maintenance = IOSInstanceMaintenance(store: store)
            let scan = try maintenance.scan("test-instance")
            let applied = try maintenance.apply(instance: "test-instance", scanId: scan["scanId"] as! String,
                                                selections: selection(scan, kind: "stale_extension_reference"))
            try require(applied["success"] as? Bool == true, "Disabled references were not updated")
            let updated = try files.json(settings)
            try require((updated["extension_settings"] as? [String: Any])?["disabledExtensions"] as? [String] == ["built-in"],
                        "Unselected disabled reference changed")
            try require((updated["unrelated"] as? [String: String])?["nested"] == "preserved", "Unrelated settings changed")
            let item = (try maintenance.list("test-instance")["items"] as! [[String: Any]])[0]
            _ = try maintenance.restore(instance: "test-instance", recovery: item["recoveryId"] as! String, token: item["token"] as! String)
            try require(files.data(settings) == before, "Original settings were not restored exactly")
        }
        test("Maintenance preserves settings for extensions reinstalled after scanning") { root, files in
            let (store, _, user) = try maintenanceFixture(root, files)
            let settings = user.appendingPathComponent("settings.json")
            try files.writeJSON(["extension_settings": ["disabledExtensions": ["third-party/reinstalled"]]], to: settings)
            let before = try files.data(settings)
            let maintenance = IOSInstanceMaintenance(store: store)
            let scan = try maintenance.scan("test-instance")
            try files.createDirectory(user.appendingPathComponent("extensions/reinstalled"))
            let applied = try maintenance.apply(instance: "test-instance", scanId: scan["scanId"] as! String,
                                                selections: selection(scan, kind: "stale_extension_reference"))
            try require(applied["success"] as? Bool == false && files.data(settings) == before, "Reinstalled extension settings were overwritten")
        }
        test("Maintenance expiry and configuration changes cannot mutate scanned content") { root, files in
            let (store, instance, user) = try maintenanceFixture(root, files)
            let extensionURL = user.appendingPathComponent("extensions/broken")
            try files.createDirectory(extensionURL)
            var clock: TimeInterval = 1000
            let maintenance = IOSInstanceMaintenance(store: store, now: { clock })
            let expired = try maintenance.scan("test-instance")
            clock += 301
            try rejects("Expired scan was accepted") {
                _ = try maintenance.apply(instance: "test-instance", scanId: expired["scanId"] as! String,
                                           selections: selection(expired, kind: "broken_extension"))
            }
            let changed = try maintenance.scan("test-instance")
            try files.write(Data("listen: true\n".utf8), to: instance.appendingPathComponent("config.yaml"))
            try rejects("Changed configuration was accepted") {
                _ = try maintenance.apply(instance: "test-instance", scanId: changed["scanId"] as! String,
                                           selections: selection(changed, kind: "broken_extension"))
            }
            try require(files.exists(extensionURL), "Scanned content was removed")
        }
        test("Sixteen live scan plans survive a capacity rejection and remain single-use") { root, files in
            let maintenance = IOSInstanceMaintenance(store: IOSInstanceStore(root: root), now: { 1000 })
            var plans: [(String, String)] = []
            for index in 0..<17 {
                let id = "scan-capacity-\(index)"
                try files.createDirectory(root.appendingPathComponent("instances/\(id)"))
                if index == 16 {
                    try rejects("Scan issuance exceeded its bounded capacity") { _ = try maintenance.scan(id) }
                } else {
                    let scan = try maintenance.scan(id)
                    guard let scanId = scan["scanId"] as? String else { throw IOSFileError.invalid("Scan identity is missing") }
                    plans.append((id, scanId))
                }
            }
            for (id, scanId) in plans {
                let result = try maintenance.apply(instance: id, scanId: scanId, selections: [])
                try require(result["success"] as? Bool == true, "A live plan was invalidated at capacity")
                try rejects("Capacity plan could be replayed") {
                    _ = try maintenance.apply(instance: id, scanId: scanId, selections: [])
                }
            }
            _ = try maintenance.scan("scan-capacity-16")
        }
        test("A full 256-payload recovery batch remains usable across another instance listing") { root, files in
            let (store, _, user) = try maintenanceFixture(root, files)
            var originals: [String: Data] = [:]
            for index in 0..<256 {
                let relative = "data/default-user/extensions/broken-\(index)"
                let bytes = Data("backup-\(index)".utf8)
                try files.createDirectory(user.appendingPathComponent("extensions/broken-\(index)"))
                try files.write(bytes, to: user.appendingPathComponent("extensions/broken-\(index)/index.js"))
                originals[relative] = bytes
            }
            let maintenance = IOSInstanceMaintenance(store: store, now: { 1000 })
            for _ in 0..<2 {
                let scan = try maintenance.scan("test-instance")
                guard let items = scan["items"] as? [[String: Any]], items.count == 128,
                      let scanId = scan["scanId"] as? String else { throw IOSFileError.invalid("Full quarantine batch is missing") }
                let chosen = items.map { ["id": $0["id"]!, "token": $0["token"]!] }
                let applied = try maintenance.apply(instance: "test-instance", scanId: scanId, selections: chosen)
                try require(applied["success"] as? Bool == true, "Full quarantine batch failed")
            }
            let overflow = user.appendingPathComponent("extensions/overflow")
            try files.createDirectory(overflow)
            let scan = try maintenance.scan("test-instance")
            let rejected = try maintenance.apply(instance: "test-instance", scanId: scan["scanId"] as! String,
                                                selections: selection(scan, kind: "broken_extension"))
            try require(rejected["success"] as? Bool == false && files.exists(overflow), "Recovery overflow moved new content")
            guard let items = try maintenance.list("test-instance")["items"] as? [[String: Any]],
                  items.count == 256, items.allSatisfy({ $0["canRestore"] as? Bool == true }),
                  let first = items.first, let last = items.last else { throw IOSFileError.invalid("Full recovery batch is not usable") }
            let other = root.appendingPathComponent("instances/other-instance/data/default-user/extensions/other-broken")
            try files.createDirectory(other)
            try files.write(Data("other backup".utf8), to: other.appendingPathComponent("index.js"))
            let otherScan = try maintenance.scan("other-instance")
            let otherApplied = try maintenance.apply(instance: "other-instance", scanId: otherScan["scanId"] as! String,
                                                     selections: selection(otherScan, kind: "broken_extension"))
            try require(otherApplied["success"] as? Bool == true, "Other-instance quarantine failed")
            guard let limited = (try maintenance.list("other-instance")["items"] as? [[String: Any]])?.first else {
                throw IOSFileError.invalid("Other-instance recovery is missing")
            }
            try require(limited["canRestore"] as? Bool == false && limited["token"] as? String == "",
                        "Global recovery token capacity was exceeded")
            func restoreOriginal(_ item: [String: Any]) throws {
                guard let recovery = item["recoveryId"] as? String, let token = item["token"] as? String,
                      let relative = item["relativePath"] as? String, let expected = originals[relative] else {
                    throw IOSFileError.invalid("Recovery identity or original bytes are missing")
                }
                let restored = try maintenance.restore(instance: "test-instance", recovery: recovery, token: token)
                try require(restored["success"] as? Bool == true, "A live full-capacity recovery token was invalidated")
                let path = root.appendingPathComponent("instances/test-instance/\(relative)/index.js")
                try require(files.data(path) == expected, "Full-capacity restore changed its payload")
                try rejects("Full-capacity recovery token was replayed") {
                    _ = try maintenance.restore(instance: "test-instance", recovery: recovery, token: token)
                }
            }
            try restoreOriginal(first)
            guard let available = (try maintenance.list("other-instance")["items"] as? [[String: Any]])?.first,
                  available["canRestore"] as? Bool == true, let recovery = available["recoveryId"] as? String,
                  let token = available["token"] as? String else { throw IOSFileError.invalid("Consumed token capacity was not reusable") }
            _ = try maintenance.restore(instance: "other-instance", recovery: recovery, token: token)
            try require(files.data(other.appendingPathComponent("index.js")) == Data("other backup".utf8), "Other recovery changed")
            try restoreOriginal(last)
        }
        test("Recovery capacity detects same-guard phase changes and resets between apply requests") { root, files in
            let (store, instance, user) = try maintenanceFixture(root, files)
            let parent = instance.appendingPathComponent(".sillyclient-maintenance/recovery")
            func seed(_ phase: String) throws -> URL {
                let folder = parent.appendingPathComponent(UUID().uuidString)
                try files.createDirectory(folder)
                try files.write(Data("retained recovery".utf8), to: folder.appendingPathComponent("payload"))
                let record = folder.appendingPathComponent("record.json")
                try files.writeJSON(["phase": phase], to: record)
                return record
            }
            for _ in 0..<254 { _ = try seed("prepared") }
            let changedRecord = try seed("restored")
            func changePhase(_ phase: String) throws {
                let before = try files.guardValue(changedRecord)
                let changed = try JSONSerialization.data(withJSONObject: ["phase": phase],
                                                        options: [.prettyPrinted, .sortedKeys])
                try require(Int64(changed.count) == before.size, "Phase fixture changed its metadata size")
                let handle = try FileHandle(forWritingTo: changedRecord)
                defer { try? handle.close() }
                try handle.write(contentsOf: changed)
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                             timespec(tv_sec: Int(before.modifiedSeconds), tv_nsec: Int(before.modifiedNanos))]
                try require(futimens(handle.fileDescriptor, &times) == 0, "Could not preserve fixture metadata timestamps")
                try require(files.guardValue(changedRecord) == before, "Phase fixture changed its file guard")
            }
            for name in ["first", "second"] {
                try files.createDirectory(user.appendingPathComponent("extensions/\(name)"))
                try files.write(Data(name.utf8), to: user.appendingPathComponent("extensions/\(name)/index.js"))
            }
            var mutationRequested = false
            var mutationPerformed = false
            var mutationError: Error?
            let maintenance = IOSInstanceMaintenance(store: store, now: {
                if mutationRequested, !mutationPerformed, (try? files.children(parent).count) == 256 {
                    mutationPerformed = true
                    do { try changePhase("prepared") } catch { mutationError = error }
                }
                return 1000
            })
            let scan = try maintenance.scan("test-instance")
            guard let candidates = scan["items"] as? [[String: Any]], candidates.count == 2,
                  candidates.map({ $0["relativePath"] as? String ?? "" }) ==
                    ["data/default-user/extensions/first", "data/default-user/extensions/second"] else {
                throw IOSFileError.invalid("Both ordered capacity candidates are required")
            }
            let chosen = candidates.map { ["id": $0["id"]!, "token": $0["token"]!] }
            mutationRequested = true
            let applied = try maintenance.apply(instance: "test-instance", scanId: scan["scanId"] as! String,
                                                selections: chosen)
            if let error = mutationError { throw error }
            guard mutationPerformed, let results = applied["results"] as? [[String: Any]], results.count == 2,
                  results[0]["success"] as? Bool == true, results[1]["success"] as? Bool == false,
                  let recovery = results[0]["recoveryId"] as? String else {
                throw IOSFileError.invalid("Cached restored metadata hid an active recovery payload")
            }
            let first = parent.appendingPathComponent("\(recovery)/payload/index.js")
            let second = user.appendingPathComponent("extensions/second/index.js")
            try require(files.data(first) == Data("first".utf8) && files.data(second) == Data("second".utf8),
                        "Changed recovery metadata or capacity rejection altered original contents")
            try changePhase("restored")
            let retry = try maintenance.scan("test-instance")
            let reapplied = try maintenance.apply(instance: "test-instance", scanId: retry["scanId"] as! String,
                                                  selections: selection(retry, kind: "broken_extension"))
            try require(reapplied["success"] as? Bool == true, "A new apply request reused obsolete recovery phases")
            guard let recovered = (reapplied["recoveryIds"] as? [String])?.first else {
                throw IOSFileError.invalid("Retried recovery payload is missing")
            }
            try require(files.data(parent.appendingPathComponent("\(recovered)/payload/index.js")) == Data("second".utf8),
                        "Retried maintenance changed its original payload")
        }
        test("Control-character user and extension names are preserved instead of becoming unrecoverable candidates") { root, files in
            let (store, _, user) = try maintenanceFixture(root, files)
            let names = ["broken\n", "broken\r", "broken\u{2028}"]
            for name in names {
                try files.createDirectory(user.appendingPathComponent("extensions/\(name)"))
                try files.write(Data("preserved".utf8), to: user.appendingPathComponent("extensions/\(name)/index.js"))
            }
            let other = root.appendingPathComponent("instances/test-instance/data/user\n/extensions/broken")
            try files.createDirectory(other)
            try files.write(Data("user preserved".utf8), to: other.appendingPathComponent("index.js"))
            try files.createDirectory(user.appendingPathComponent("extensions/valid-broken"))
            let maintenance = IOSInstanceMaintenance(store: store)
            let scan = try maintenance.scan("test-instance")
            try require((scan["items"] as? [[String: Any]])?.count == 1, "Control-character name became a maintenance candidate")
            let applied = try maintenance.apply(instance: "test-instance", scanId: scan["scanId"] as! String,
                                                selections: selection(scan, kind: "broken_extension"))
            try require(applied["success"] as? Bool == true, "Valid maintenance candidate was rejected")
            for name in names {
                try require(files.data(user.appendingPathComponent("extensions/\(name)/index.js")) == Data("preserved".utf8),
                            "Control-character extension was moved or changed")
            }
            try require(files.data(other.appendingPathComponent("index.js")) == Data("user preserved".utf8), "Control-character user data changed")
        }
        test("Restore conflicts preserve both replacement content and the recovery payload") { root, files in
            let (store, instance, user) = try maintenanceFixture(root, files)
            let extensionURL = user.appendingPathComponent("extensions/broken")
            try files.createDirectory(extensionURL)
            try files.write(Data("original".utf8), to: extensionURL.appendingPathComponent("index.js"))
            let maintenance = IOSInstanceMaintenance(store: store)
            let scan = try maintenance.scan("test-instance")
            _ = try maintenance.apply(instance: "test-instance", scanId: scan["scanId"] as! String,
                                       selections: selection(scan, kind: "broken_extension"))
            let item = (try maintenance.list("test-instance")["items"] as! [[String: Any]])[0]
            try files.createDirectory(extensionURL)
            try files.write(Data("replacement".utf8), to: extensionURL.appendingPathComponent("index.js"))
            try rejects("Restore overwrote same-name replacement") {
                _ = try maintenance.restore(instance: "test-instance", recovery: item["recoveryId"] as! String, token: item["token"] as! String)
            }
            try require(String(data: files.data(extensionURL.appendingPathComponent("index.js")), encoding: .utf8) == "replacement", "Replacement changed")
            let payload = instance.appendingPathComponent(".sillyclient-maintenance/recovery/\(item["recoveryId"] as! String)/payload/index.js")
            try require(String(data: files.data(payload), encoding: .utf8) == "original", "Recovery payload changed")
        }
        test("Prepared records without payloads do not consume active recovery capacity") { root, files in
            let (store, instance, user) = try maintenanceFixture(root, files)
            try files.createDirectory(user.appendingPathComponent("extensions/broken"))
            let parent = instance.appendingPathComponent(".sillyclient-maintenance/recovery")
            for _ in 0..<256 { try files.createDirectory(parent.appendingPathComponent(UUID().uuidString)) }
            let maintenance = IOSInstanceMaintenance(store: store)
            let scan = try maintenance.scan("test-instance")
            let result = try maintenance.apply(instance: "test-instance", scanId: scan["scanId"] as! String,
                                               selections: selection(scan, kind: "broken_extension"))
            try require(result["success"] as? Bool == true, "Empty prepared records exhausted active recovery capacity")
        }
        test("Bounded directory enumeration returns partial results and preserves overflow") { root, files in
            for name in ["first", "second", "third"] { try files.createDirectory(root.appendingPathComponent(name)) }
            let listing = try files.boundedChildren(root, limit: 2)
            try require(listing.items.count == 2 && listing.truncated, "Bounded listing did not report overflow")
            try rejects("Strict enumeration hid overflow") { _ = try files.children(root, limit: 2) }
            try require(files.children(root).count == 3, "Overflow entries were changed")
        }
        test("Keychain credentials are origin-bound and explicit verification receipts are single-use") { _, _ in
            let id = "ios-auth-\(UUID().uuidString)"
            let other = "ios-auth-\(UUID().uuidString)"
            defer { try? IOSRemoteCredentials.clear(id); try? IOSRemoteCredentials.clear(other) }
            let first = URL(string: "https://example.test/a")!
            let same = URL(string: "https://example.test:443/b")!
            let changed = URL(string: "http://example.test/b")!
            let username = "synthetic-\(UUID().uuidString)"
            let password = UUID().uuidString
            try rejects("Unverified credentials were persisted") { try IOSRemoteCredentials.save(id, username: username, password: password) }
            try IOSRemoteCredentials.recordVerifiedPreflight(url: first, username: username, password: password)
            try IOSRemoteCredentials.save(id, username: username, password: password)
            try require(IOSRemoteCredentials.read(id, for: same)?.0 == username, "Same-origin credentials were not retained")
            try require(IOSRemoteCredentials.read(id, for: changed) == nil, "Credentials crossed origins")
            try rejects("Verification receipt was reused") { try IOSRemoteCredentials.save(other, username: username, password: password) }
            try IOSRemoteCredentials.save(id, username: username, password: nil)
            try require(IOSRemoteCredentials.read(id, for: first)?.1 == password, "Omitted password was lost")
            try rejects("Changing username retained another username's password") {
                try IOSRemoteCredentials.save(id, username: "changed", password: nil)
            }
            try IOSRemoteCredentials.recordVerifiedPreflight(url: first, username: username, password: password)
            try IOSRemoteCredentials.recordVerifiedPreflight(url: changed, username: username, password: password)
            try rejects("Ambiguous verification bound an arbitrary origin") { try IOSRemoteCredentials.save(other, username: username, password: password) }
            let oversized = String(repeating: "\\", count: 16384)
            try IOSRemoteCredentials.recordVerifiedPreflight(url: first, username: username, password: oversized)
            try rejects("Unreadable encoded credentials were persisted") {
                try IOSRemoteCredentials.save(id, username: username, password: oversized)
            }
            try require(IOSRemoteCredentials.read(id, for: first)?.1 == password, "Rejected credential update changed stored data")
        }
        return ["success": results.allSatisfy { $0["passed"] as? Bool == true }, "results": results,
                "scope": "Actual Swift modules on synthetic sandbox fixtures"]
    }
}
#endif
