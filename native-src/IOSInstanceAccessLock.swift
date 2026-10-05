import Foundation
import CoreFoundation
import Security
import CommonCrypto

final class IOSInstanceAccessLock {
    static let shared = IOSInstanceAccessLock()
    static let maximumRecords = 256
    static let maximumPasswordBytes = 4096
    static let maximumRegistryBytes = 128 * 1024
    private static let queue = DispatchQueue(label: "com.sillyclient.instance-access-lock")
    private static let trimCharacters = CharacterSet(charactersIn:
        "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}"
        + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
        + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

    private struct Record {
        let salt: String
        let hash: String
        let updatedAt: String
        var value: [String: String] { ["salt": salt, "hash": hash, "updatedAt": updatedAt] }
    }

    private let load: () throws -> Data?
    private let save: (Data?) throws -> Void
    private let randomBytes: () throws -> Data
    private let now: () -> Date

    convenience init(service: String = "com.sillyclient.instance-access-lock", account: String = "registry-v1") {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        self.init(load: {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw IOSFileError.invalid("Instance access lock storage is unavailable (Keychain OSStatus \(status))")
            }
            return data
        }, save: { data in
            guard let data = data else {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw IOSFileError.invalid("Could not remove instance access locks (Keychain OSStatus \(status))")
                }
                return
            }
            let attributes: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var added = query
                for (key, value) in attributes { added[key] = value }
                let result = SecItemAdd(added as CFDictionary, nil)
                guard result == errSecSuccess else {
                    throw IOSFileError.invalid("Could not save instance access locks (Keychain OSStatus \(result))")
                }
            } else if status != errSecSuccess {
                throw IOSFileError.invalid("Could not update instance access locks (Keychain OSStatus \(status))")
            }
        })
    }

    init(load: @escaping () throws -> Data?, save: @escaping (Data?) throws -> Void,
         randomBytes: @escaping () throws -> Data = {
             var bytes = [UInt8](repeating: 0, count: 16)
             let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
             guard status == errSecSuccess else { throw IOSFileError.invalid("Could not generate an instance access lock salt") }
             return Data(bytes)
         }, now: @escaping () -> Date = Date.init) {
        self.load = load
        self.save = save
        self.randomBytes = randomBytes
        self.now = now
    }

    private static func formatter() -> ISO8601DateFormatter {
        let result = ISO8601DateFormatter()
        result.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        result.timeZone = TimeZone(secondsFromGMT: 0)
        return result
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private func read() throws -> [String: Record] {
        guard let data = try load() else { return [:] }
        guard !data.isEmpty, data.count <= Self.maximumRegistryBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let value = object as? [String: Any], Set(value.keys) == Set(["version", "passwords"]),
              let version = value["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let passwords = value["passwords"] as? [String: Any], passwords.count <= Self.maximumRecords else {
            throw IOSFileError.invalid("Instance access lock storage is invalid; protection was not removed")
        }
        var result: [String: Record] = [:]
        let dates = Self.formatter()
        for (rawId, rawRecord) in passwords {
            let id = try IOSInstanceStore.identity(rawId)
            guard let record = rawRecord as? [String: String], Set(record.keys) == Set(["salt", "hash", "updatedAt"]),
                  let salt = record["salt"], Self.matches(salt, "^[a-f0-9]{32}\\z"),
                  let hash = record["hash"], Self.matches(hash, "^[a-f0-9]{64}\\z"),
                  let updatedAt = record["updatedAt"],
                  Self.matches(updatedAt, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z\\z"),
                  dates.date(from: updatedAt) != nil else {
                throw IOSFileError.invalid("An instance access lock record is invalid; protection was not removed")
            }
            result[id] = Record(salt: salt, hash: hash, updatedAt: updatedAt)
        }
        return result
    }

    private func write(_ records: [String: Record]) throws {
        if records.isEmpty { try save(nil); return }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "passwords": records.mapValues { $0.value }],
                                              options: [.sortedKeys])
        guard records.count <= Self.maximumRecords, data.count <= Self.maximumRegistryBytes else {
            throw IOSFileError.invalid("Instance access lock storage capacity reached")
        }
        try save(data)
    }

    private static func validatePassword(_ password: String?) throws {
        if let password = password, password.utf8.count > maximumPasswordBytes {
            throw IOSFileError.invalid("Instance access password exceeds its size limit")
        }
    }

    private static func derive(_ password: String, salt: String) throws -> [UInt8] {
        let passwordBytes = Array(password.utf8) + [0]
        // Windows passes the hexadecimal salt as UTF-8 text, not as decoded salt bytes.
        let saltBytes = Array(salt.utf8)
        var result = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            saltBytes.withUnsafeBufferPointer { saltBuffer in
                result.withUnsafeMutableBufferPointer { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress!.assumingMemoryBound(to: Int8.self), passwordBytes.count - 1,
                        saltBuffer.baseAddress!, saltBuffer.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        10000, output.baseAddress!, output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw IOSFileError.invalid("Instance access password derivation failed") }
        return result
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func verifies(_ password: String, record: Record) throws -> Bool {
        let actual = try derive(password, salt: record.salt)
        let hash = Array(record.hash.utf8)
        func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
        var difference: UInt8 = 0
        // Validated hashes always have 32 bytes; inspect all bytes without an early return.
        for index in 0..<32 {
            let expected = (nibble(hash[index * 2]) << 4) | nibble(hash[index * 2 + 1])
            difference |= actual[index] ^ expected
        }
        return difference == 0
    }

    func set(instanceId: String, password: String?, oldPassword: String? = nil) throws -> [String: Any] {
        try Self.queue.sync {
            let id = try IOSInstanceStore.identity(instanceId)
            try Self.validatePassword(password)
            try Self.validatePassword(oldPassword)
            var records = try read()
            if let existing = records[id] {
                guard let oldPassword = oldPassword, !oldPassword.isEmpty,
                      try Self.verifies(oldPassword, record: existing) else {
                    throw IOSFileError.invalid("The current access password is incorrect")
                }
            }
            let clean = (password ?? "").trimmingCharacters(in: Self.trimCharacters)
            if clean.isEmpty {
                if records.removeValue(forKey: id) != nil { try write(records) }
                return ["success": true, "hasPassword": false]
            }
            guard records[id] != nil || records.count < Self.maximumRecords else {
                throw IOSFileError.invalid("Instance access lock storage capacity reached")
            }
            let saltBytes = try randomBytes()
            let date = now()
            guard saltBytes.count == 16, date.timeIntervalSince1970.isFinite else {
                throw IOSFileError.invalid("Instance access lock metadata could not be generated")
            }
            let salt = Self.hex(Array(saltBytes))
            let hash = Self.hex(try Self.derive(clean, salt: salt))
            records[id] = Record(salt: salt, hash: hash, updatedAt: Self.formatter().string(from: date))
            try write(records)
            return ["success": true, "hasPassword": true]
        }
    }

    func verify(instanceId: String, password: String) throws -> Bool {
        try Self.queue.sync {
            let id = try IOSInstanceStore.identity(instanceId)
            try Self.validatePassword(password)
            guard let record = try read()[id] else { return true }
            return try Self.verifies(password, record: record)
        }
    }

    func has(instanceId: String) throws -> Bool {
        try Self.queue.sync { try read()[IOSInstanceStore.identity(instanceId)] != nil }
    }

    func clear(instanceId: String, oldPassword: String? = nil) throws -> [String: Any] {
        _ = try set(instanceId: instanceId, password: nil, oldPassword: oldPassword)
        return ["success": true]
    }

    func list() throws -> [String: Bool] {
        try Self.queue.sync { try read().mapValues { _ in true } }
    }

    // The owner calls this only after successful uninstall; a path/name change keeps the same ID.
    func remove(instanceId: String) throws {
        try Self.queue.sync {
            let id = try IOSInstanceStore.identity(instanceId)
            var records = try read()
            if records.removeValue(forKey: id) != nil { try write(records) }
        }
    }
}
