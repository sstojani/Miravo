import Foundation
import Testing
@testable import ProjectLedger

struct KeychainSessionTokenStoreTests {
    @Test func tokensRoundTripAndDeleteWithoutCustomAccessGroup() async throws {
        let store = KeychainSessionTokenStore(
            service: "ProjectLedgerTests.\(UUID().uuidString)"
        )
        let scope = "https://ledger.example|50000000-0000-0000-0000-000000000005"
        let secondScope = "https://ledger.example|70000000-0000-0000-0000-000000000007"
        let tokens = SessionTokenBundle(
            accessToken: "test-access-token",
            accessTokenExpiresAt: "2026-08-09T12:15:00Z",
            refreshToken: "test-refresh-token",
            refreshTokenExpiresAt: "2026-09-08T12:00:00Z",
            tokenType: "Bearer",
            sessionID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        )

        try await store.delete(scopeKey: scope)
        try await store.save(tokens, scopeKey: scope)
        try await store.save(tokens, scopeKey: secondScope)
        let macroSafeExpectation1: Bool = try await store.load(scopeKey: scope) == tokens
        #expect(macroSafeExpectation1)
        try await store.delete(scopeKey: scope)
        let macroSafeExpectation2: Bool = try await store.load(scopeKey: scope) == nil
        #expect(macroSafeExpectation2)
        let macroSafeExpectation3: Bool = try await store.load(scopeKey: secondScope) == tokens
        #expect(macroSafeExpectation3)
        try await store.deleteAll()
        let macroSafeExpectation4: Bool = try await store.load(scopeKey: secondScope) == nil
        #expect(macroSafeExpectation4)
    }
}
