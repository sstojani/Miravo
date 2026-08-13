import Foundation
import Testing
@testable import ProjectLedger

struct CollaborationTests {
    @Test func invitationDTOIsNarrowRedactedAndFailsClosed() throws {
        let issued = try issuedInvitation()

        #expect(issued.invitation.id == invitationID)
        #expect(issued.invitation.role == .editor)
        #expect(issued.rawToken.hasPrefix("pli_"))
        #expect(!String(describing: issued).contains(issued.rawToken))
        #expect(!String(reflecting: issued).contains(issued.rawToken))
        #expect(issued.invitation.isActive)

        let request = TrackerInvitationCreateRequest(
            email: "member@example.test",
            role: .viewer,
            expiresInDays: 7
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["email", "role", "expires_in_days"])
        #expect(object["raw_token"] == nil)
        #expect(object["role"] as? String == "viewer")

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                IssuedTrackerInvitation.self,
                from: invitationFixture(rawToken: "normal-token")
            )
        }
    }

    @Test func invitationCodeParserAcceptsCodesAndLinksOnly() {
        let token = validRawToken
        #expect(CollaborationController.invitationToken(from: "  \(token)\n") == token)
        #expect(
            CollaborationController.invitationToken(
                from: "https://ledger.example.test/join?token=\(token)"
            ) == token
        )
        #expect(CollaborationController.invitationToken(from: "https://example.test/no-code") == nil)
        #expect(CollaborationController.invitationToken(from: "pls.shortcut-token") == nil)
    }

    @MainActor
    @Test func controllerCreatesShowsOnceRevokesAndAcceptsInvitations() async throws {
        let issued = try issuedInvitation()
        let transport = CollaborationTransportStub(issued: issued)
        let controller = CollaborationController { _ in transport }
        let authentication = authenticationContext()

        let invalid = await controller.createInvitation(
            trackerID: trackerID,
            email: "not-an-email",
            role: .editor,
            expiresInDays: 7,
            authentication: authentication
        )
        #expect(!invalid)
        #expect(await transport.createCallCount() == 0)

        let created = await controller.createInvitation(
            trackerID: trackerID,
            email: "  MEMBER@example.test ",
            role: .editor,
            expiresInDays: 7,
            authentication: authentication
        )
        #expect(created)
        #expect(controller.invitations == [issued.invitation])
        #expect(controller.oneTimeInvitation?.rawValue == issued.rawToken)
        let capturedRequest = await transport.capturedCreateRequest()
        let request = try #require(capturedRequest)
        #expect(request.email == "member@example.test")
        #expect(request.role == .editor)

        controller.clearOneTimeInvitation()
        #expect(controller.oneTimeInvitation == nil)
        await controller.loadInvitations(trackerID: trackerID, authentication: authentication)
        #expect(controller.oneTimeInvitation == nil)

        let accepted = await controller.acceptInvitation(
            enteredValue: "https://ledger.example.test/join?token=\(validRawToken)",
            authentication: authentication
        )
        #expect(accepted)
        #expect(await transport.acceptedTokens() == [validRawToken])

        let revoked = await controller.revokeInvitation(
            trackerID: trackerID,
            invitationID: invitationID,
            authentication: authentication
        )
        #expect(revoked)
        #expect(controller.invitations.isEmpty)
        #expect(await transport.revokedInvitationIDs() == [invitationID])
    }

    @MainActor
    @Test func controllerUpdatesMembersAndMergesOnlySynchronizedGuestIdentity() async throws {
        let transport = CollaborationTransportStub(issued: nil)
        let controller = CollaborationController { _ in transport }
        let authentication = authenticationContext()

        let updated = await controller.updateMemberRole(
            trackerID: trackerID,
            membershipID: membershipID,
            role: .viewer,
            authentication: authentication
        )
        #expect(updated)
        #expect(await transport.roleUpdates() == [.viewer])

        let removed = await controller.removeMember(
            trackerID: trackerID,
            membershipID: membershipID,
            authentication: authentication
        )
        #expect(removed)
        #expect(await transport.removedMembershipIDs() == [membershipID])

        let guest = LocalParticipant(
            id: guestID,
            scopeKey: authentication.scopeKey,
            trackerID: trackerID,
            displayName: "Guest",
            serverVersion: 3,
            syncState: .synced
        )
        let member = LocalParticipant(
            id: participantID,
            scopeKey: authentication.scopeKey,
            trackerID: trackerID,
            linkedUserID: UUID(),
            linkedEmail: "member@example.test",
            displayName: "Member",
            serverVersion: 1,
            syncState: .synced
        )
        let merged = await controller.mergeGuest(
            source: guest,
            target: member,
            authentication: authentication
        )
        #expect(merged)
        #expect(
            await transport.mergeRequests() == [
                MergeCapture(sourceID: guestID, targetID: participantID, baseVersion: 3),
            ]
        )

        let pendingGuest = LocalParticipant(
            scopeKey: authentication.scopeKey,
            trackerID: trackerID,
            displayName: "Pending"
        )
        let pendingMerged = await controller.mergeGuest(
            source: pendingGuest,
            target: member,
            authentication: authentication
        )
        #expect(!pendingMerged)
        #expect((await transport.mergeRequests()).count == 1)
    }

    private let trackerID = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!
    private let invitationID = UUID(uuidString: "a2000000-0000-4000-8000-000000000002")!
    private let membershipID = UUID(uuidString: "a3000000-0000-4000-8000-000000000003")!
    private let guestID = UUID(uuidString: "a4000000-0000-4000-8000-000000000004")!
    private let participantID = UUID(uuidString: "a5000000-0000-4000-8000-000000000005")!
    private let validRawToken = "pli_0123456789abcdefghijklmnopqrstuvwxyzABCDEFGH"

    private func issuedInvitation() throws -> IssuedTrackerInvitation {
        try JSONDecoder().decode(
            IssuedTrackerInvitation.self,
            from: invitationFixture(rawToken: validRawToken)
        )
    }

    private func invitationFixture(rawToken: String) -> Data {
        Data(
            #"{"id":"a2000000-0000-4000-8000-000000000002","email":"member@example.test","role":"editor","expires_at":"2099-08-20T12:30:00Z","accepted_at":null,"revoked_at":null,"created_at":"2026-08-13T12:30:00Z","raw_token":"\#(rawToken)"}"#.utf8
        )
    }

    @MainActor
    private func authenticationContext() -> SyncAuthenticationContext {
        SyncAuthenticationContext(
            scopeKey: "https://ledger.example.test|a6000000-0000-4000-8000-000000000006",
            baseURL: URL(string: "https://ledger.example.test")!,
            tokens: SessionTokenBundle(
                accessToken: "synthetic-access-token",
                accessTokenExpiresAt: "2026-08-13T12:40:00Z",
                refreshToken: "synthetic-refresh-token",
                refreshTokenExpiresAt: "2026-09-12T12:30:00Z",
                tokenType: "Bearer",
                sessionID: UUID(uuidString: "a7000000-0000-4000-8000-000000000007")!
            ),
            tokenStore: KeychainSessionTokenStore(
                service: "ProjectLedgerTests.collaboration.\(UUID().uuidString)"
            )
        )
    }
}

private struct MergeCapture: Equatable, Sendable {
    let sourceID: UUID
    let targetID: UUID
    let baseVersion: Int64
}

private actor CollaborationTransportStub: CollaborationTransport {
    private var invitations = [TrackerInvitationSummary]()
    private let issued: IssuedTrackerInvitation?
    private var createRequest: TrackerInvitationCreateRequest?
    private var createCalls = 0
    private var revokedIDs = [UUID]()
    private var accepted = [String]()
    private var updatedRoles = [TrackerRole]()
    private var removedIDs = [UUID]()
    private var merges = [MergeCapture]()

    init(issued: IssuedTrackerInvitation?) {
        self.issued = issued
    }

    func listTrackerInvitations(
        trackerID: UUID,
        accessToken: String
    ) async throws -> [TrackerInvitationSummary] {
        invitations
    }

    func createTrackerInvitation(
        trackerID: UUID,
        request: TrackerInvitationCreateRequest,
        accessToken: String
    ) async throws -> IssuedTrackerInvitation {
        createCalls += 1
        createRequest = request
        guard let issued else { throw CollaborationTransportStubError.unexpectedCall }
        invitations = [issued.invitation]
        return issued
    }

    func revokeTrackerInvitation(
        trackerID: UUID,
        invitationID: UUID,
        accessToken: String
    ) async throws {
        revokedIDs.append(invitationID)
        invitations.removeAll { $0.id == invitationID }
    }

    func updateTrackerMemberRole(
        trackerID: UUID,
        membershipID: UUID,
        role: TrackerRole,
        accessToken: String
    ) async throws -> CollaborationMembershipSummary {
        updatedRoles.append(role)
        return membership(id: membershipID, role: role)
    }

    func removeTrackerMember(
        trackerID: UUID,
        membershipID: UUID,
        accessToken: String
    ) async throws {
        removedIDs.append(membershipID)
    }

    func acceptTrackerInvitation(
        token: String,
        accessToken: String
    ) async throws -> CollaborationMembershipSummary {
        accepted.append(token)
        return membership(id: UUID(), role: .editor)
    }

    func mergeGuestParticipant(
        sourceParticipantID: UUID,
        targetParticipantID: UUID,
        baseVersion: Int64,
        accessToken: String
    ) async throws -> ParticipantSnapshot {
        merges.append(
            MergeCapture(
                sourceID: sourceParticipantID,
                targetID: targetParticipantID,
                baseVersion: baseVersion
            )
        )
        return ParticipantSnapshot(
            id: targetParticipantID,
            trackerID: UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!,
            linkedUserID: UUID(),
            linkedEmail: "member@example.test",
            displayName: "Member",
            archivedAt: nil,
            version: 2,
            createdAt: "2026-08-13T12:30:00Z",
            updatedAt: "2026-08-13T12:31:00Z",
            deletedAt: nil
        )
    }

    func capturedCreateRequest() -> TrackerInvitationCreateRequest? { createRequest }
    func createCallCount() -> Int { createCalls }
    func revokedInvitationIDs() -> [UUID] { revokedIDs }
    func acceptedTokens() -> [String] { accepted }
    func roleUpdates() -> [TrackerRole] { updatedRoles }
    func removedMembershipIDs() -> [UUID] { removedIDs }
    func mergeRequests() -> [MergeCapture] { merges }

    private func membership(
        id: UUID,
        role: TrackerRole
    ) -> CollaborationMembershipSummary {
        CollaborationMembershipSummary(
            id: id,
            userID: UUID(),
            email: "member@example.test",
            role: role,
            state: "active",
            joinedAt: "2026-08-13T12:30:00Z",
            version: 2,
            createdAt: "2026-08-13T12:30:00Z",
            updatedAt: "2026-08-13T12:31:00Z"
        )
    }
}

private enum CollaborationTransportStubError: Error {
    case unexpectedCall
}
