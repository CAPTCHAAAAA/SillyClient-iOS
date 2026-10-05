#if DEBUG
import Foundation
import Darwin

enum IOSInstanceDeletionTests {
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw IOSFileError.invalid(message) }
    }

    private static func rejects(_ message: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try require(rejected, message)
    }

    private static func fixture(_ root: URL, id: String = "delete-fixture") throws -> (IOSInstanceStore, IOSManagedFiles, URL) {
        let store = IOSInstanceStore(root: root)
        let files = IOSManagedFiles(root: root)
        let source = root.appendingPathComponent("instances/\(id)")
        try files.createDirectory(source.appendingPathComponent("data"))
        try files.write(Data("fixture server".utf8), to: source.appendingPathComponent("server.js"))
        try files.write(Data("fixture data".utf8), to: source.appendingPathComponent("data/chat.txt"))
        try files.writeJSON(["name": "fixture", "version": "1.0.0"], to: source.appendingPathComponent("package.json"))
        let location = try store.locations.acquire(source)
        try files.writeJSON([id: store.registrationRecord(id, location: location)], to: store.registryURL)
        return (store, files, source)
    }

    private static func markPending(_ store: IOSInstanceStore, id: String = "delete-fixture") throws {
        var records = try store.registry()
        records[id]!["removalPending"] = true
        try store.files.writeJSON(records, to: store.registryURL)
    }

    static func run(_ root: URL, files: IOSManagedFiles) throws {
        let cases: [(String, (URL) throws -> Void)] = [
            ("removal-failure", retryPartialRemoval),
            ("registry-failure", retryRegistryCommit),
            ("replacement", preserveReplacement),
            ("ownership", preserveUnrelatedContents),
            ("active", rejectActiveRuntime)
        ]
        for (name, body) in cases {
            let directory = root.appendingPathComponent(name)
            try files.createDirectory(directory)
            try body(directory)
        }
    }

    private static func retryPartialRemoval(_ root: URL) throws {
        let (store, files, source) = try fixture(root)
        let protected = source.appendingPathComponent("data")
        let sibling = root.appendingPathComponent("unrelated.txt")
        try files.write(Data("untouched".utf8), to: sibling)
        try require(chmod(protected.path, mode_t(0o500)) == 0, "Could not deny fixture deletion")
        defer { _ = chmod(protected.path, mode_t(0o700)) }
        try rejects("Partial deletion reported success") { _ = try store.uninstall("delete-fixture") }
        try require(files.exists(source) && store.registry()["delete-fixture"]?["removalPending"] as? Bool == true,
                    "Partial deletion lost its original path or pending registration")
        let recreated = IOSInstanceStore(root: root)
        try require(recreated.records().contains { $0["instanceId"] as? String == "delete-fixture" && $0["removalPending"] as? Bool == true },
                    "A pending deletion disappeared from instance scanning")
        try rejects("A partially deleted instance remained usable") { _ = try recreated.location("delete-fixture", requireExisting: false) }
        try rejects("A partially deleted instance could be renamed") { _ = try recreated.rename(instanceId: "delete-fixture", newName: "renamed") }
        try require(chmod(protected.path, mode_t(0o700)) == 0, "Could not restore fixture deletion")
        try require(recreated.uninstall("delete-fixture")["success"] as? Bool == true, "Retry did not finish deletion")
        try require(!files.exists(source) && recreated.registry()["delete-fixture"] == nil, "Completed deletion retained its source or registration")
        try require(files.data(sibling) == Data("untouched".utf8), "Deletion changed unrelated contents")
    }

    private static func retryRegistryCommit(_ root: URL) throws {
        let (store, files, source) = try fixture(root)
        let before = try files.data(store.registryURL)
        try require(chmod(root.path, mode_t(0o500)) == 0, "Could not deny fixture registry writes")
        defer { _ = chmod(root.path, mode_t(0o700)) }
        try rejects("Deletion proceeded without persisting its intent") { _ = try store.uninstall("delete-fixture") }
        try require(files.data(store.registryURL) == before && files.exists(source.appendingPathComponent("data/chat.txt")),
                    "Failed intent persistence removed instance data")
        try require(chmod(root.path, mode_t(0o700)) == 0, "Could not restore fixture registry writes")
        try markPending(store)
        try require(chmod(root.path, mode_t(0o500)) == 0, "Could not deny the final registry commit")
        try rejects("Failed final registry commit reported success") { _ = try store.uninstall("delete-fixture") }
        try require(!files.exists(source) && store.registry()["delete-fixture"]?["removalPending"] as? Bool == true,
                    "A completed removal lost the pending commit record")
        try require(chmod(root.path, mode_t(0o700)) == 0, "Could not restore the final registry commit")
        let recreated = IOSInstanceStore(root: root)
        try require(recreated.uninstall("delete-fixture")["success"] as? Bool == true && recreated.registry()["delete-fixture"] == nil,
                    "Retry could not finish registration cleanup for a missing directory")
    }

    private static func preserveReplacement(_ root: URL) throws {
        let (store, files, source) = try fixture(root)
        try markPending(store)
        let before = try files.data(store.registryURL)
        let original = root.appendingPathComponent("preserved-original")
        try files.move(source, to: original)
        try files.createDirectory(source)
        let replacement = source.appendingPathComponent("replacement.txt")
        try files.write(Data("foreign contents".utf8), to: replacement)
        let recreated = IOSInstanceStore(root: root)
        try rejects("Retry removed a replacement directory") { _ = try recreated.uninstall("delete-fixture") }
        try rejects("Retry accepted a different requested path") { _ = try recreated.uninstall("delete-fixture", installPath: original.path) }
        try require(files.data(replacement) == Data("foreign contents".utf8)
                    && files.data(original.appendingPathComponent("data/chat.txt")) == Data("fixture data".utf8)
                    && files.data(store.registryURL) == before, "Rejected retry modified a replacement, original, or registry")
    }

    private static func preserveUnrelatedContents(_ root: URL) throws {
        let (store, files, source) = try fixture(root, id: "kept")
        let external = root.appendingPathComponent("takeover-source")
        try files.createDirectory(external)
        try files.write(Data("takeover data".utf8), to: external.appendingPathComponent("keep.txt"))
        var records = try store.registry()
        records["scan-kept"] = ["instanceId": "scan-kept", "path": external.path, "isTakeover": true]
        try files.writeJSON(records, to: store.registryURL)
        let takeoverResult = try store.uninstall("scan-kept")
        try require(takeoverResult["success"] as? Bool == true && takeoverResult["instanceId"] as? String == "scan-kept",
                    "Takeover deregistration lost its real scan-prefixed identity")
        try require(store.registry()["kept"] != nil && store.registry()["scan-kept"] == nil && files.exists(source)
                    && files.data(external.appendingPathComponent("keep.txt")) == Data("takeover data".utf8),
                    "Takeover deregistration removed its source or a colliding managed identity")
        let aliasResult = try store.uninstall("scan-kept")
        try require(aliasResult["success"] as? Bool == true && aliasResult["instanceId"] as? String == "kept",
                    "Alias deletion did not return the canonical managed identity")
        try require(store.registry()["kept"] == nil && !files.exists(source)
                    && files.data(external.appendingPathComponent("keep.txt")) == Data("takeover data".utf8),
                    "Alias deletion retained its managed instance or changed the takeover source")
        try files.writeJSON(["owner": "sillyclient"], to: external.appendingPathComponent(store.ownershipName))
        try rejects("An unregistered directory with an incomplete receipt was removed") {
            _ = try store.uninstall("unknown", installPath: external.path)
        }
        try require(files.data(external.appendingPathComponent("keep.txt")) == Data("takeover data".utf8), "Unregistered contents changed")
    }

    private static func rejectActiveRuntime(_ root: URL) throws {
        let (store, files, source) = try fixture(root)
        let before = try files.data(store.registryURL)
        let operation = UUID().uuidString
        try NodeRunner.shared.reserve(instance: "deletion-busy-fixture", operation: operation)
        defer {
            let stopped = DispatchSemaphore(value: 0)
            NodeRunner.shared.stop(instance: "deletion-busy-fixture", operation: operation) { _ in stopped.signal() }
            _ = stopped.wait(timeout: .now() + 5)
        }
        try rejects("Deletion ignored an active runtime reservation") { _ = try store.uninstall("delete-fixture") }
        try require(files.exists(source) && files.data(store.registryURL) == before, "Rejected active-runtime deletion changed state")
    }
}
#endif
