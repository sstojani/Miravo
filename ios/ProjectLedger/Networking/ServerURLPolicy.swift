import Foundation

enum ServerURLError: Error, Equatable {
    case invalid
    case httpsRequired
    case cleartextHostNotAllowed
}

enum ServerURLPolicy {
    static var allowsDevelopmentHTTP: Bool { _isDebugAssertConfiguration() }

    static func validated(
        _ input: String,
        allowsDevelopmentHTTP: Bool = ServerURLPolicy.allowsDevelopmentHTTP
    ) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw ServerURLError.invalid
        }

        if scheme == "http" {
            let loopbackHosts = ["localhost", "127.0.0.1", "::1"]
            guard allowsDevelopmentHTTP else { throw ServerURLError.httpsRequired }
            guard loopbackHosts.contains(host) else {
                throw ServerURLError.cleartextHostNotAllowed
            }
        } else if scheme != "https" {
            throw ServerURLError.httpsRequired
        }

        components.scheme = scheme
        components.host = host
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else { throw ServerURLError.invalid }
        return url
    }
}

enum SessionScope {
    static func key(serverURL: URL, userID: UUID) -> String {
        "\(serverURL.absoluteString)|\(userID.uuidString.lowercased())"
    }

    static func localKey(deviceID: String) -> String {
        "local|\(deviceID.lowercased())"
    }

    static func isLocal(_ scopeKey: String) -> Bool {
        scopeKey.hasPrefix("local|")
    }
}

enum JWTSubjectParser {
    static func subject(from token: String) -> UUID? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String
        else {
            return nil
        }
        return UUID(uuidString: subject)
    }
}
