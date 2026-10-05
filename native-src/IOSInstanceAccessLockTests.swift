#if DEBUG
import Foundation

enum IOSInstanceAccessLockTests {
    private static let salt = "000102030405060708090a0b0c0d0e0f"
    private static let englishHash = "935e0bb26a2cc9b65bca457b4d191b151bfd3f51273cedb0f119ce9f6042c2b7"
    private static let date = "2026-01-01T00:00:00.000Z"

    private final class Storage {
        var data: Data?
        var loadFails = false
        var saveFails = false
        var saves = 0
        init(_ data: Data? = nil) { self.data = data }
        func make(random: @escaping () throws -> Data = { Data((0..<16).map { UInt8($0) }) }) -> IOSInstanceAccessLock {
            IOSInstanceAccessLock(load: {
                if self.loadFails { throw IOSFileError.invalid("Synthetic storage read failure") }
                return self.data
            }, save: { data in
                if self.saveFails { throw IOSFileError.invalid("Synthetic storage write failure") }
                self.data = data
                self.saves += 1
            }, randomBytes: random, now: { Date(timeIntervalSince1970: 1767225600) })
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw IOSFileError.invalid(message) }
    }

    private static func rejects(_ message: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try require(rejected, message)
    }

    private static func record(hash: String = englishHash) -> [String: String] {
        ["salt": salt, "hash": hash, "updatedAt": date]
    }

    private static func registry(_ records: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "passwords": records], options: [.sortedKeys])
    }

    static func run() throws {
        try vectors()
        try lifecycle()
        try corruption()
        try limitsAndFailures()
        try concurrentWrites()
    }

    private static func vectors() throws {
        // Generated with Node crypto.pbkdf2Sync(password, saltText, 10000, 32, 'sha256').
        let cases = [
            ("correct horse battery staple", englishHash),
            ("\u{9152}\u{9986}\u{5bc6}\u{7801}\u{1F510}", "63cd9d38b1fc8e2ef9dcd4f33ff9ef597c4e6b664717699315d0ad3d8f5f3a39"),
            ("nul\u{0000}byte", "ae33938ca85f2bb1d9ba7e2c155ddcdc5601eee479ba80cfaa5b8a909076747c"),
            ("", "b19386ab293100d40b8839b1361bb475f750274fd7708ee38ac58a9188dbeb7a")
        ]
        for (password, hash) in cases {
            let storage = Storage(try registry(["vector": record(hash: hash)]))
            let locks = storage.make()
            try require(locks.verify(instanceId: "vector", password: password), "The Windows PBKDF2 vector did not match")
            try require(!locks.verify(instanceId: "vector", password: password + "x"), "A wrong vector password was accepted")
        }
        let storage = Storage()
        let locks = storage.make()
        _ = try locks.set(instanceId: "vector", password: cases[1].0)
        let value = try JSONSerialization.jsonObject(with: storage.data!) as! [String: Any]
        let records = value["passwords"] as! [String: [String: String]]
        try require(records["vector"]?["salt"] == salt && records["vector"]?["hash"] == cases[1].1,
                    "Generated lock did not use Windows-compatible salt text and UTF-8")
        try require(!(String(data: storage.data!, encoding: .utf8) ?? "").contains(cases[1].0), "Plaintext password was stored")
    }

    private static func lifecycle() throws {
        let storage = Storage()
        let locks = storage.make()
        try require(!locks.has(instanceId: "stable-id") && locks.list().isEmpty, "A new registry was not empty")
        try require(locks.verify(instanceId: "stable-id", password: ""), "An unprotected instance required a password")
        _ = try locks.set(instanceId: "stable-id", password: " \u{FEFF}old-password\u{00A0} ")
        try require(locks.verify(instanceId: "stable-id", password: "old-password"), "Windows trim semantics changed")
        let before = storage.data
        try rejects("Password change did not require the old password") {
            _ = try locks.set(instanceId: "stable-id", password: "new-password")
        }
        try rejects("Wrong old password cleared protection") {
            _ = try locks.clear(instanceId: "stable-id", oldPassword: " old-password ")
        }
        try require(storage.data == before, "Rejected password change wrote storage")
        _ = try locks.set(instanceId: "stable-id", password: "new-password", oldPassword: "old-password")
        let recreated = storage.make()
        try require(recreated.has(instanceId: "stable-id") && recreated.list() == ["stable-id": true],
                    "Recreating storage lost the stable instance lock")
        try require(recreated.verify(instanceId: "stable-id", password: "new-password"), "The new password was not persisted")
        try require(!recreated.verify(instanceId: "stable-id", password: "old-password"), "The old password remained valid")
        _ = try recreated.clear(instanceId: "stable-id", oldPassword: "new-password")
        try require(storage.data == nil && storage.make().list().isEmpty, "Clearing the final lock did not persist removal")
        _ = try recreated.set(instanceId: "stable-id", password: "\u{0085}kept\u{0085}")
        try require(recreated.verify(instanceId: "stable-id", password: "\u{0085}kept\u{0085}"), "Non-JavaScript whitespace was trimmed")
        try recreated.remove(instanceId: "stable-id")
        try recreated.remove(instanceId: "stable-id")
        try require(storage.data == nil && !storage.make().has(instanceId: "stable-id"), "Uninstall removal was not persistent or idempotent")
    }

    private static func corruption() throws {
        var corrupt = [Data(), Data("not-json".utf8), Data("[]".utf8), Data("null".utf8)]
        for version: Any in [true, 2, 1.5, "1"] {
            corrupt.append(try JSONSerialization.data(withJSONObject: ["version": version, "passwords": [:]]))
        }
        for (key, value) in [("salt", "00"), ("salt", String(repeating: "g", count: 32)),
                             ("hash", "00"), ("hash", String(repeating: "g", count: 64)),
                             ("updatedAt", "invalid-date")] {
            var broken = record()
            broken[key] = value
            corrupt.append(try registry(["protected": broken]))
        }
        corrupt.append(try registry(["../invalid": record()]))
        corrupt.append(try registry(["protected": ["salt": salt, "hash": englishHash]]))
        corrupt.append(try registry(["protected": NSNull()]))
        corrupt.append(try JSONSerialization.data(withJSONObject: ["version": 1, "passwords": [], "extra": true]))
        for data in corrupt {
            let storage = Storage(data)
            let locks = storage.make()
            try rejects("Corrupt storage appeared unlocked") { _ = try locks.has(instanceId: "protected") }
            try rejects("Corrupt storage accepted verification") { _ = try locks.verify(instanceId: "protected", password: "anything") }
            try rejects("Corrupt storage returned an empty lock list") { _ = try locks.list() }
            try rejects("Corrupt storage was overwritten by set") { _ = try locks.set(instanceId: "new", password: "password") }
            try rejects("Corrupt storage was cleared") { _ = try locks.clear(instanceId: "protected", oldPassword: "anything") }
            try rejects("Corrupt storage was removed") { try locks.remove(instanceId: "protected") }
            try require(storage.data == data && storage.saves == 0, "Corrupt lock data changed")
        }
    }

    private static func limitsAndFailures() throws {
        let storage = Storage()
        let locks = storage.make()
        let oversized = String(repeating: "x", count: IOSInstanceAccessLock.maximumPasswordBytes + 1)
        try rejects("Oversized password was accepted") { _ = try locks.set(instanceId: "id", password: oversized) }
        try rejects("Oversized verification was accepted") { _ = try locks.verify(instanceId: "id", password: oversized) }
        try rejects("Oversized old password was accepted") { _ = try locks.clear(instanceId: "id", oldPassword: oversized) }
        for id in ["", "../id", "path/id", String(repeating: "x", count: 129)] {
            try rejects("Invalid instance identity was accepted") { _ = try locks.set(instanceId: id, password: "password") }
        }
        var full: [String: Any] = [:]
        for index in 0..<IOSInstanceAccessLock.maximumRecords { full["instance-\(index)"] = record() }
        storage.data = try registry(full)
        let before = storage.data
        try rejects("A full registry accepted another lock") { _ = try locks.set(instanceId: "overflow", password: "password") }
        try require(storage.data == before, "Capacity rejection changed existing locks")
        _ = try locks.set(instanceId: "instance-0", password: "replacement", oldPassword: "correct horse battery staple")
        try require(locks.list().count == IOSInstanceAccessLock.maximumRecords, "Updating a full registry changed its capacity")
        try locks.remove(instanceId: "instance-1")
        _ = try locks.set(instanceId: "new-slot", password: "password")
        full["overflow"] = record()
        storage.data = try registry(full)
        try rejects("An oversized registry was accepted") { _ = try locks.list() }
        storage.data = Data(repeating: 32, count: IOSInstanceAccessLock.maximumRegistryBytes + 1)
        try rejects("An oversized serialized registry was accepted") { _ = try locks.list() }
        storage.data = nil
        storage.loadFails = true
        try rejects("A read failure appeared unlocked") { _ = try locks.verify(instanceId: "id", password: "password") }
        storage.loadFails = false
        _ = try locks.set(instanceId: "id", password: "password")
        let protected = storage.data
        storage.saveFails = true
        try rejects("A write failure reported a successful password change") {
            _ = try locks.set(instanceId: "id", password: "replacement", oldPassword: "password")
        }
        try rejects("A write failure reported successful clearing") { _ = try locks.clear(instanceId: "id", oldPassword: "password") }
        try require(storage.data == protected && locks.verify(instanceId: "id", password: "password"), "Failed persistence dropped protection")
        storage.saveFails = false
        try rejects("An invalid random salt was accepted") { _ = try storage.make(random: { Data([1]) }).set(instanceId: "bad-salt", password: "password") }
        try rejects("A random source failure was ignored") {
            _ = try storage.make(random: { throw IOSFileError.invalid("Synthetic random failure") }).set(instanceId: "bad-random", password: "password")
        }
        try require(storage.data == protected, "Salt failure changed storage")
    }

    private static func concurrentWrites() throws {
        let storage = Storage()
        let first = storage.make()
        let second = storage.make()
        let failureLock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do { _ = try (index % 2 == 0 ? first : second).set(instanceId: "concurrent-\(index)", password: "password") }
            catch { failureLock.lock(); failures += 1; failureLock.unlock() }
        }
        try require(failures == 0 && first.list().count == 16, "Concurrent lock writes lost a record")
        for index in 0..<16 {
            try require(second.has(instanceId: "concurrent-\(index)"), "Another store did not see a persisted lock")
        }
    }

    static func runKeychain() throws {
        let service = "com.sillyclient.instance-access-lock.fixture.\(UUID().uuidString)"
        let first = IOSInstanceAccessLock(service: service)
        defer { try? first.remove(instanceId: "keychain-fixture") }
        _ = try first.set(instanceId: "keychain-fixture", password: "\u{5bc6}\u{7801}-fixture")
        let recreated = IOSInstanceAccessLock(service: service)
        try require(recreated.verify(instanceId: "keychain-fixture", password: "\u{5bc6}\u{7801}-fixture"), "Keychain did not persist the password hash")
        try require(recreated.list() == ["keychain-fixture": true], "Keychain status did not survive store recreation")
        try recreated.remove(instanceId: "keychain-fixture")
        try require(!first.has(instanceId: "keychain-fixture"), "Keychain deletion was not persisted")
    }
}
#endif
