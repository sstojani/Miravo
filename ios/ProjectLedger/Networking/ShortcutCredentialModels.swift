import Foundation

enum ShortcutScope: String, Codable, CaseIterable, Sendable {
    case categoriesRead = "categories:read"
    case accountsRead = "accounts:read"
    case transactionsCreate = "transactions:create"
}

struct ShortcutCredentialSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let trackerID: UUID?
    let tokenPrefix: String
    let scopes: [ShortcutScope]
    let expiresAt: String?
    let lastUsedAt: String?
    let revokedAt: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case trackerID = "tracker_id"
        case tokenPrefix = "token_prefix"
        case scopes
        case expiresAt = "expires_at"
        case lastUsedAt = "last_used_at"
        case revokedAt = "revoked_at"
        case createdAt = "created_at"
    }

    var expirationDate: Date? {
        expiresAt.flatMap(APITimestamp.date(from:))
    }

    var isRevoked: Bool { revokedAt != nil }

    func isExpired(at date: Date = .now) -> Bool {
        guard expiresAt != nil else { return false }
        guard let expirationDate else { return true }
        return expirationDate <= date
    }
}

struct ShortcutCredentialCreateRequest: Encodable, Equatable, Sendable {
    let name: String
    let trackerID: UUID?
    let scopes: [ShortcutScope]

    enum CodingKeys: String, CodingKey {
        case name
        case trackerID = "tracker_id"
        case scopes
    }
}

struct IssuedShortcutCredential: CustomDebugStringConvertible, CustomStringConvertible, Decodable, Equatable, Sendable {
    let credential: ShortcutCredentialSummary
    let rawToken: String

    private enum CodingKeys: String, CodingKey {
        case rawToken = "raw_token"
    }

    init(from decoder: Decoder) throws {
        credential = try ShortcutCredentialSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawToken = try container.decode(String.self, forKey: .rawToken)
        guard rawToken.hasPrefix("pls."),
              rawToken.utf8.count >= 48,
              rawToken.utf8.count <= 256
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawToken,
                in: container,
                debugDescription: "Invalid Shortcut credential format."
            )
        }
    }

    var description: String {
        "IssuedShortcutCredential(id: \(credential.id), rawToken: <redacted>)"
    }

    var debugDescription: String { description }
}

struct OneTimeShortcutToken: CustomDebugStringConvertible, CustomStringConvertible, Equatable, Identifiable, Sendable {
    let credentialID: UUID
    let name: String
    let rawValue: String

    var id: UUID { credentialID }
    var description: String { "OneTimeShortcutToken(id: \(credentialID), value: <redacted>)" }
    var debugDescription: String { description }
}

protocol ShortcutCredentialTransport: Sendable {
    func listShortcutCredentials(accessToken: String) async throws -> [ShortcutCredentialSummary]
    func createShortcutCredential(
        _ request: ShortcutCredentialCreateRequest,
        accessToken: String
    ) async throws -> IssuedShortcutCredential
    func revokeShortcutCredential(id: UUID, accessToken: String) async throws
}

private enum APITimestamp {
    static func date(from value: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}
