import Foundation
import Testing
@testable import ProjectLedger

struct ShortcutCredentialTests {
    @Test func decodesIssuedCredentialAndEncodesOnlyTheNarrowCreateContract() throws {
        let issued = try issuedCredential()

        #expect(issued.credential.id == credentialID)
        #expect(issued.credential.trackerID == trackerID)
        #expect(issued.credential.scopes == ShortcutScope.allCases)
        #expect(issued.rawToken.hasPrefix("pls."))
        #expect(!String(describing: issued).contains(issued.rawToken))
        #expect(!String(reflecting: issued).contains(issued.rawToken))

        let request = ShortcutCredentialCreateRequest(
            name: "Wallet automation",
            trackerID: trackerID,
            scopes: ShortcutScope.allCases
        )
        let encoded = try JSONEncoder().encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(Set(object.keys) == ["name", "tracker_id", "scopes"])
        let encodedTrackerID = try #require(object["tracker_id"] as? String)
        #expect(UUID(uuidString: encodedTrackerID) == trackerID)
        #expect(object["raw_token"] == nil)
        #expect(
            object["scopes"] as? [String] == [
                "categories:read",
                "accounts:read",
                "transactions:create",
            ]
        )
    }

    @Test func rejectsAnUnexpectedRawCredentialFormat() {
        let fixture = issuedFixture(rawToken: "normal-access-token")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IssuedShortcutCredential.self, from: fixture)
        }
    }

    @Test func invalidExpiryFailsClosedWhileNoExpiryRemainsActive() {
        let active = summary(expiresAt: nil)
        let malformed = summary(expiresAt: "not-a-date")
        let expired = summary(expiresAt: "2026-08-09T12:30:00.000000Z")

        #expect(!active.isExpired(at: Date.distantFuture))
        #expect(malformed.isExpired(at: .now))
        #expect(expired.isExpired(at: Date.distantFuture))
    }

    @MainActor
    @Test func controllerClearsTheOneTimeTokenAndCannotRecoverItFromListing() async throws {
        let issued = try issuedCredential()
        let transport = ShortcutTransportStub(issued: issued)
        let controller = ShortcutCredentialController { _ in transport }
        let authentication = authenticationContext()

        await controller.load(authentication: authentication)
        #expect(controller.credentials.isEmpty)

        let created = await controller.create(
            name: "  Wallet automation  ",
            trackerID: trackerID,
            authentication: authentication
        )
        #expect(created)
        #expect(controller.credentials == [issued.credential])
        #expect(controller.oneTimeToken?.rawValue == issued.rawToken)

        let captured = await transport.capturedCreateRequest()
        #expect(captured?.name == "Wallet automation")
        #expect(captured?.trackerID == trackerID)
        #expect(captured?.scopes == ShortcutScope.allCases)

        controller.clearOneTimeToken()
        #expect(controller.oneTimeToken == nil)
        await controller.load(authentication: authentication)
        #expect(controller.credentials == [issued.credential])
        #expect(controller.oneTimeToken == nil)

        let revoked = await controller.revoke(
            id: credentialID,
            authentication: authentication
        )
        #expect(revoked)
        #expect(controller.credentials.isEmpty)
        #expect(await transport.revokedCredentialIDs() == [credentialID])
    }

    @MainActor
    @Test func controllerRejectsInvalidNamesBeforeNetworking() async {
        let transport = ShortcutTransportStub(issued: nil)
        let controller = ShortcutCredentialController { _ in transport }
        let authentication = authenticationContext()

        let emptyAccepted = await controller.create(
            name: "   ",
            trackerID: trackerID,
            authentication: authentication
        )
        let longAccepted = await controller.create(
            name: String(repeating: "a", count: 121),
            trackerID: trackerID,
            authentication: authentication
        )
        #expect(!emptyAccepted)
        #expect(!longAccepted)
        #expect(await transport.createCallCount() == 0)
    }

    private let credentialID = UUID(
        uuidString: "90000000-0000-4000-8000-000000000009"
    )!
    private let trackerID = UUID(
        uuidString: "91000000-0000-4000-8000-000000000019"
    )!

    private func issuedCredential() throws -> IssuedShortcutCredential {
        try JSONDecoder().decode(
            IssuedShortcutCredential.self,
            from: issuedFixture(
                rawToken: "pls.0123456789abcdef.abcdefghijklmnopqrstuvwxyzABCDEFGH"
            )
        )
    }

    private func issuedFixture(rawToken: String) -> Data {
        Data(
            #"{"id":"90000000-0000-4000-8000-000000000009","name":"Wallet automation","tracker_id":"91000000-0000-4000-8000-000000000019","token_prefix":"0123456789abcdef","scopes":["categories:read","accounts:read","transactions:create"],"expires_at":"2026-11-07T12:30:00Z","last_used_at":null,"revoked_at":null,"created_at":"2026-08-09T12:30:00Z","raw_token":"\#(rawToken)"}"#.utf8
        )
    }

    private func summary(expiresAt: String?) -> ShortcutCredentialSummary {
        ShortcutCredentialSummary(
            id: credentialID,
            name: "Wallet automation",
            trackerID: trackerID,
            tokenPrefix: "0123456789abcdef",
            scopes: ShortcutScope.allCases,
            expiresAt: expiresAt,
            lastUsedAt: nil,
            revokedAt: nil,
            createdAt: "2026-08-09T12:30:00Z"
        )
    }

    @MainActor
    private func authenticationContext() -> SyncAuthenticationContext {
        SyncAuthenticationContext(
            scopeKey: "https://ledger.example.test|92000000-0000-4000-8000-000000000029",
            baseURL: URL(string: "https://ledger.example.test")!,
            tokens: SessionTokenBundle(
                accessToken: "synthetic-access-token",
                accessTokenExpiresAt: "2026-08-09T12:40:00Z",
                refreshToken: "synthetic-refresh-token",
                refreshTokenExpiresAt: "2026-09-08T12:30:00Z",
                tokenType: "Bearer",
                sessionID: UUID(
                    uuidString: "93000000-0000-4000-8000-000000000039"
                )!
            ),
            tokenStore: KeychainSessionTokenStore(
                service: "ProjectLedgerTests.shortcut.\(UUID().uuidString)"
            )
        )
    }
}

private actor ShortcutTransportStub: ShortcutCredentialTransport {
    private var credentials = [ShortcutCredentialSummary]()
    private let issued: IssuedShortcutCredential?
    private var createRequest: ShortcutCredentialCreateRequest?
    private var createCalls = 0
    private var revokedIDs = [UUID]()

    init(issued: IssuedShortcutCredential?) {
        self.issued = issued
    }

    func listShortcutCredentials(
        accessToken: String
    ) async throws -> [ShortcutCredentialSummary] {
        credentials
    }

    func createShortcutCredential(
        _ request: ShortcutCredentialCreateRequest,
        accessToken: String
    ) async throws -> IssuedShortcutCredential {
        createCalls += 1
        createRequest = request
        guard let issued else { throw ShortcutTransportStubError.unexpectedCall }
        credentials = [issued.credential]
        return issued
    }

    func revokeShortcutCredential(id: UUID, accessToken: String) async throws {
        revokedIDs.append(id)
        credentials.removeAll { $0.id == id }
    }

    func capturedCreateRequest() -> ShortcutCredentialCreateRequest? { createRequest }
    func createCallCount() -> Int { createCalls }
    func revokedCredentialIDs() -> [UUID] { revokedIDs }
}

private enum ShortcutTransportStubError: Error {
    case unexpectedCall
}
