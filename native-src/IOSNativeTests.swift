#if DEBUG
import Foundation
import ZIPFoundation

enum IOSNativeTests {
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw IOSFileError.invalid(message) }
    }
    private static func rejects(_ message: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try require(rejected, message)
    }

    static func run() -> [String: Any] {
        let parent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath().appendingPathComponent("ios-test-fixtures-\(UUID().uuidString)")
        var results: [[String: Any]] = []
        func test(_ name: String, _ body: (URL, IOSManagedFiles) throws -> Void) {
            let root = parent.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try body(root, IOSManagedFiles(root: root))
                results.append(["name": name, "passed": true])
            } catch { results.append(["name": name, "passed": false, "error": error.localizedDescription]) }
        }
        defer { try? FileManager.default.removeItem(at: parent) }
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
            try require(store.migrationDataDirectory(source, files: files) == data, "Custom dataRoot was not selected")
            try require(store.migrationDataDirectory(data, files: files) == data, "Single-user data root was flattened")
            try files.write(Data("dataRoot: ../outside\n".utf8), to: source.appendingPathComponent("config.yaml"))
            try files.createDirectory(root.appendingPathComponent("outside"))
            try rejects("Migration read outside the selected source") { _ = try store.migrationDataDirectory(source, files: files) }
        }
        test("YAML configuration preserves unrelated values and validates Boolean and heartbeat inputs") { root, files in
            let store = IOSInstanceStore(root: root)
            try files.write(Data("unrelated: preserved\n".utf8), to: root.appendingPathComponent("config.yaml"))
            try store.updateConfig(root, port: 8123, config: ["ipv4": false, "ipv6": true, "heartbeat": 20])
            try require(!store.ipv4(root), "IPv6-only configuration was not applied")
            let yaml = String(data: try files.data(root.appendingPathComponent("config.yaml")), encoding: .utf8) ?? ""
            try require(yaml.contains("preserved") && yaml.contains("8123"), "Unrelated YAML or port was lost")
            let invalidValues: [[String: Any]] = [["heartbeat": true], ["heartbeat": -1], ["heartbeat": 1.5], ["heartbeat": "20"],
                                                 ["ipv4": 1], ["ipv4": false, "ipv6": false]]
            for invalid in invalidValues {
                try rejects("Invalid configuration was accepted") { try store.updateConfig(root, port: 8123, config: invalid) }
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
