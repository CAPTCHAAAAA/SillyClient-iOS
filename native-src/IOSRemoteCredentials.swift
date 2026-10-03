import Foundation
import Security
import CryptoKit

enum IOSRemoteCredentials {
    private struct Credential {
        let username: String
        let password: String
        let origin: String?
    }
    private static let lock = NSLock()
    private static var proofs: [String: [String: TimeInterval]] = [:]
    private static func origin(_ url: URL) throws -> String {
        let safe = try IOSNavigationPolicy.validatedURL(url.absoluteString)
        let scheme = safe.scheme!.lowercased()
        return "\(scheme)://\(safe.host!.lowercased()):\(safe.port ?? (scheme == "https" ? 443 : 80))"
    }
    private static func validate(username: String, password: String) throws {
        guard !username.isEmpty, username.utf8.count <= 512, !username.contains(":"),
              username.rangeOfCharacter(from: .controlCharacters) == nil, password.utf8.count <= 16384 else {
            throw IOSFileError.invalid("Invalid Basic Auth credentials")
        }
    }
    private static func proofKey(username: String, password: String) throws -> String {
        try validate(username: username, password: password)
        let bytes = try JSONSerialization.data(withJSONObject: [username, password])
        return IOSManagedFiles.hex(SHA256.hash(data: bytes))
    }
    private static func expireProofs() {
        let now = Date().timeIntervalSince1970
        proofs = proofs.mapValues { $0.filter { $0.value > now } }.filter { !$0.value.isEmpty }
    }
    static func recordVerifiedPreflight(url: URL, username: String, password: String) throws {
        let key = try proofKey(username: username, password: password)
        let source = try origin(url)
        lock.lock()
        defer { lock.unlock() }
        expireProofs()
        guard proofs[key] != nil || proofs.count < 64 else { throw IOSFileError.invalid("Too many pending credential verifications") }
        var values = proofs[key] ?? [:]
        guard values[source] != nil || values.count < 8 else { throw IOSFileError.invalid("Credential verification is ambiguous") }
        values[source] = Date().timeIntervalSince1970 + 300
        proofs[key] = values
    }
    private static func consumePreflight(username: String, password: String) throws -> String {
        let key = try proofKey(username: username, password: password)
        lock.lock()
        defer { lock.unlock() }
        expireProofs()
        guard let values = proofs.removeValue(forKey: key), values.count == 1, let source = values.keys.first else {
            throw IOSFileError.invalid("Verify these credentials against one remote address before saving them")
        }
        return source
    }
    private static func query(_ id: String) throws -> [String: Any] {
        ["\(kSecClass)": kSecClassGenericPassword, "\(kSecAttrService)": "com.sillyclient.remote-auth",
         "\(kSecAttrAccount)": try IOSInstanceStore.identity(id)]
    }
    private static func record(_ id: String) throws -> Credential? {
        var value = try query(id)
        value[kSecReturnData as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 32768,
              let record = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let username = record["username"], let password = record["password"] else {
            throw IOSFileError.invalid("Secure credential storage is unavailable")
        }
        try validate(username: username, password: password)
        return Credential(username: username, password: password, origin: record["origin"])
    }
    static func read(_ id: String, for url: URL) throws -> (String, String)? {
        guard let value = try record(id), let expected = value.origin, expected == (try origin(url)) else { return nil }
        return (value.username, value.password)
    }
    static func status(_ id: String) throws -> [String: Any] {
        let value = try record(id)
        return ["configured": value?.origin != nil, "username": value?.username ?? "",
                "requiresRevalidation": value != nil && value?.origin == nil]
    }
    static func save(_ id: String, username: String, password: String?) throws {
        let retained: String
        let source: String
        if let password = password {
            try validate(username: username, password: password)
            retained = password
            source = try consumePreflight(username: username, password: password)
        } else {
            guard let existing = try record(id), existing.username == username, let bound = existing.origin else {
                throw IOSFileError.invalid("Re-enter and verify the password for a new or changed credential setup")
            }
            retained = existing.password
            source = bound
        }
        let data = try JSONSerialization.data(withJSONObject: ["username": username, "password": retained, "origin": source])
        guard data.count <= 32768 else {
            throw IOSFileError.invalid("Encoded credentials exceed the secure storage limit")
        }
        var value = try query(id)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(value as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            for (key, field) in attributes { value[key] = field }
            guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else {
                throw IOSFileError.invalid("Could not save credentials securely")
            }
        } else if status != errSecSuccess { throw IOSFileError.invalid("Could not update credentials securely") }
    }
    static func clear(_ id: String) throws {
        let status = SecItemDelete(try query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IOSFileError.invalid("Could not remove secure credentials")
        }
    }
}

final class IOSBoundedHTTP: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private let completion: (Result<(HTTPURLResponse, Data), Error>) -> Void
    private var bytes = Data()
    private var rejection: Error?
    private var session: URLSession?

    private init(limit: Int, completion: @escaping (Result<(HTTPURLResponse, Data), Error>) -> Void) {
        self.limit = limit
        self.completion = completion
    }

    static func send(_ request: URLRequest, maximumBytes: Int,
                     completion: @escaping (Result<(HTTPURLResponse, Data), Error>) -> Void) {
        let client = IOSBoundedHTTP(limit: maximumBytes, completion: completion)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = max(5, min(30, request.timeoutInterval + 2))
        let session = URLSession(configuration: configuration, delegate: client, delegateQueue: nil)
        client.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if !(response is HTTPURLResponse)
            || (dataTask.originalRequest?.httpMethod != "HEAD" && response.expectedContentLength > Int64(limit)) {
            rejection = IOSFileError.invalid("HTTP response exceeded its metadata limit")
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= limit - bytes.count else {
            rejection = IOSFileError.invalid("HTTP response exceeded its metadata limit")
            bytes.removeAll()
            dataTask.cancel()
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate(); self.session = nil }
        if let error = rejection ?? error { completion(.failure(error)) }
        else if let response = task.response as? HTTPURLResponse { completion(.success((response, bytes))) }
        else { completion(.failure(IOSFileError.invalid("HTTP response was unavailable"))) }
    }
}
