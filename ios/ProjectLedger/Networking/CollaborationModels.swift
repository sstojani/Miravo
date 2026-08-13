import Foundation

struct TrackerInvitationSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let email: String
    let role: TrackerRole
    let expiresAt: String
    let acceptedAt: String?
    let revokedAt: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, email, role
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case revokedAt = "revoked_at"
        case createdAt = "created_at"
    }

    var expirationDate: Date? {
        CollaborationTimestamp.date(from: expiresAt)
    }

    var isActive: Bool {
        acceptedAt == nil && revokedAt == nil && !isExpired()
    }

    func isExpired(at date: Date = .now) -> Bool {
        guard let expirationDate else { return true }
        return expirationDate <= date
    }
}

struct TrackerInvitationCreateRequest: Encodable, Equatable, Sendable {
    let email: String
    let role: TrackerRole
    let expiresInDays: Int

    enum CodingKeys: String, CodingKey {
        case email, role
        case expiresInDays = "expires_in_days"
    }
}

struct IssuedTrackerInvitation: CustomDebugStringConvertible, CustomStringConvertible, Decodable, Equatable, Sendable {
    let invitation: TrackerInvitationSummary
    let rawToken: String

    private enum CodingKeys: String, CodingKey {
        case rawToken = "raw_token"
    }

    init(from decoder: Decoder) throws {
        invitation = try TrackerInvitationSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawToken = try container.decode(String.self, forKey: .rawToken)
        guard rawToken.hasPrefix("pli_"),
              rawToken.utf8.count >= 40,
              rawToken.utf8.count <= 256
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawToken,
                in: container,
                debugDescription: "Invalid tracker invitation format."
            )
        }
    }

    var description: String {
        "IssuedTrackerInvitation(id: \(invitation.id), rawToken: <redacted>)"
    }

    var debugDescription: String { description }
}

struct OneTimeTrackerInvitation: CustomDebugStringConvertible, CustomStringConvertible, Equatable, Identifiable, Sendable {
    let invitationID: UUID
    let email: String
    let rawValue: String

    var id: UUID { invitationID }
    var description: String {
        "OneTimeTrackerInvitation(id: \(invitationID), rawValue: <redacted>)"
    }
    var debugDescription: String { description }
}

struct CollaborationMembershipSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let userID: UUID
    let email: String
    let role: TrackerRole
    let state: String
    let joinedAt: String
    let version: Int64
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case email, role, state
        case joinedAt = "joined_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CollaborationRoleUpdateRequest: Encodable, Equatable, Sendable {
    let role: TrackerRole
}

struct TrackerInvitationAcceptRequest: Encodable, Equatable, Sendable {
    let token: String
}

struct GuestParticipantMergeRequest: Encodable, Equatable, Sendable {
    let targetParticipantID: UUID
    let baseVersion: Int64

    enum CodingKeys: String, CodingKey {
        case targetParticipantID = "target_participant_id"
        case baseVersion = "base_version"
    }
}

protocol CollaborationTransport: Sendable {
    func listTrackerInvitations(
        trackerID: UUID,
        accessToken: String
    ) async throws -> [TrackerInvitationSummary]
    func createTrackerInvitation(
        trackerID: UUID,
        request: TrackerInvitationCreateRequest,
        accessToken: String
    ) async throws -> IssuedTrackerInvitation
    func revokeTrackerInvitation(
        trackerID: UUID,
        invitationID: UUID,
        accessToken: String
    ) async throws
    func updateTrackerMemberRole(
        trackerID: UUID,
        membershipID: UUID,
        role: TrackerRole,
        accessToken: String
    ) async throws -> CollaborationMembershipSummary
    func removeTrackerMember(
        trackerID: UUID,
        membershipID: UUID,
        accessToken: String
    ) async throws
    func acceptTrackerInvitation(
        token: String,
        accessToken: String
    ) async throws -> CollaborationMembershipSummary
    func mergeGuestParticipant(
        sourceParticipantID: UUID,
        targetParticipantID: UUID,
        baseVersion: Int64,
        accessToken: String
    ) async throws -> ParticipantSnapshot
}

private enum CollaborationTimestamp {
    static func date(from value: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}
