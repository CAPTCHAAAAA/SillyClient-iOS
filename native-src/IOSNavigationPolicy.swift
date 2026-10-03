import Foundation

enum IOSNavigationPolicy {
    static func validatedURL(_ raw: String) throws -> URL {
        guard raw.rangeOfCharacter(from: .controlCharacters) == nil,
              let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url, url.baseURL == nil,
              components.port == nil || (1...65535).contains(components.port!) else {
            throw IOSFileError.invalid("An absolute HTTP(S) URL without embedded credentials is required")
        }
        return url
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func origin(_ url: URL) -> String? {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
        }
        guard let left = origin(first), let right = origin(second) else { return false }
        return left == right
    }

    static func originURL(scheme: String, host: String, port: Int) -> URL? {
        var value = URLComponents()
        value.scheme = scheme
        value.host = host
        if port > 0 { value.port = port }
        return value.url
    }
}
