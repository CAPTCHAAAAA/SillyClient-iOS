#if DEBUG
import Foundation
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
