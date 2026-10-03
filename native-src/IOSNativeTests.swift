#if DEBUG
import Foundation
import ZIPFoundation

enum IOSNativeTests {
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw IOSFileError.invalid(message) }
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
        return ["success": results.allSatisfy { $0["passed"] as? Bool == true }, "results": results,
                "scope": "Actual Swift modules on synthetic sandbox fixtures"]
    }
}
#endif
