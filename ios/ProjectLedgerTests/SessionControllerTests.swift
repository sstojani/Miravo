import Foundation
import Testing
@testable import ProjectLedger

@MainActor
struct SessionControllerTests {
    @Test func signOutDoesNotWaitForServerAndSurvivesRelaunch() async throws {
        let suite = "SessionControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let store = KeychainSessionTokenStore(service: suite)
        let scope = "https://ledger.example.test|test-user"
        preferences.recordAuthentication(
            serverURL: URL(string: "https://ledger.example.test")!,
            email: "test@example.test",
            scopeKey: scope
        )
        try await store.save(testTokens(), scopeKey: scope)
        let transport = DelayedLogoutTransport()
        let session = SessionController(preferences: preferences, tokenStore: store) { _ in transport }

        await session.signOut()
        #expect(session.phase == .signIn)
        #expect(session.scopeKey == nil)
        #expect(!session.hasServerConnection)
        #expect(!session.canOpenOffline)
        #expect(preferences.isSignedOut)
        #expect(preferences.currentScopeKey == scope)
        let saved = try await store.load(scopeKey: scope)
        #expect(saved == nil)
        #expect(!session.isSigningOut)
        let relaunched = SessionController(preferences: preferences, tokenStore: store)
        #expect(relaunched.phase == .signIn)

        await transport.waitForLogout()
        let completed = await transport.completed
        #expect(!completed)
        session.startLocalOnly()
        await transport.failLogout()
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(session.phase == .authenticated)
        #expect(session.logoutWarning == nil)
    }

    private func testTokens() -> SessionTokenBundle {
        SessionTokenBundle(
            accessToken: "synthetic-access",
            accessTokenExpiresAt: "2099-01-01T00:00:00Z",
            refreshToken: "synthetic-refresh",
            refreshTokenExpiresAt: "2099-02-01T00:00:00Z",
            tokenType: "Bearer",
            sessionID: UUID()
        )
    }
}

private actor DelayedLogoutTransport: SessionTransport {
    private var logoutContinuation: CheckedContinuation<Void, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var completed = false

    func login(email: String, password: String, deviceID: String, deviceName: String, appVersion: String) async throws -> SessionTokenBundle {
        throw URLError(.notConnectedToInternet)
    }

    func logout(accessToken: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            logoutContinuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitForLogout() async {
        if logoutContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func failLogout() {
        completed = true
        logoutContinuation?.resume(throwing: URLError(.notConnectedToInternet))
        logoutContinuation = nil
    }
}
