import Foundation
import Testing
@testable import ProjectLedger

struct SessionRefreshTests {
    @Test func deletedSessionCannotBeResurrectedByDelayedRefresh() async throws {
        let store = KeychainSessionTokenStore(service: "SessionRefreshTests.\(UUID().uuidString)")
        let original = tokens()
        let scope = "synthetic-scope"
        let gate = RefreshGate()
        try await store.save(original, scopeKey: scope)
        let request = Task {
            try await store.refresh(scopeKey: scope, replacing: original) { _ in
                await gate.wait()
                return tokens(sessionID: original.sessionID, accessToken: "refreshed")
            }
        }
        await gate.waitUntilStarted()
        try await store.delete(scopeKey: scope)
        await gate.release()
        do {
            _ = try await request.value
            Issue.record("A refresh restored a signed-out session")
        } catch is CancellationError {
            // Expected: sign-out invalidated the pending result.
        }
        let saved = try await store.load(scopeKey: scope)
        #expect(saved == nil)
    }

    @Test func concurrentRefreshAndStaleCallerRotateOnlyOnce() async throws {
        let store = KeychainSessionTokenStore(service: "SessionRefreshTests.\(UUID().uuidString)")
        let original = tokens()
        let updated = tokens(sessionID: original.sessionID, accessToken: "refreshed")
        let scope = "synthetic-scope"
        let gate = RefreshGate()
        try await store.save(original, scopeKey: scope)
        let first = Task {
            try await store.refresh(scopeKey: scope, replacing: original) { _ in
                await gate.wait()
                return updated
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await store.refresh(scopeKey: scope, replacing: original) { _ in
                Issue.record("Refresh token was used a second time")
                return updated
            }
        }
        await gate.release()
        let results = try await [first.value, second.value]
        #expect(results == [updated, updated])
        let stale = try await store.refresh(scopeKey: scope, replacing: original) { _ in
            Issue.record("A stale caller replayed a refresh token")
            return updated
        }
        #expect(stale == updated)
        try await store.delete(scopeKey: scope)
    }

    @Test func oldRefreshCannotOverwriteNewLoginForSameAccount() async throws {
        let store = KeychainSessionTokenStore(service: "SessionRefreshTests.\(UUID().uuidString)")
        let original = tokens()
        let newLogin = tokens()
        let scope = "synthetic-scope"
        let gate = RefreshGate()
        try await store.save(original, scopeKey: scope)
        let request = Task {
            try await store.refresh(scopeKey: scope, replacing: original) { _ in
                await gate.wait()
                return tokens(sessionID: original.sessionID, accessToken: "old-refresh")
            }
        }
        await gate.waitUntilStarted()
        try await store.save(newLogin, scopeKey: scope)
        await gate.release()
        do {
            _ = try await request.value
            Issue.record("Old refresh replaced a new login")
        } catch is CancellationError {}
        let saved = try await store.load(scopeKey: scope)
        #expect(saved == newLogin)
        try await store.delete(scopeKey: scope)
    }

    private func tokens(sessionID: UUID = UUID(), accessToken: String = "original") -> SessionTokenBundle {
        SessionTokenBundle(
            accessToken: accessToken,
            accessTokenExpiresAt: "2099-01-01T00:00:00Z",
            refreshToken: "synthetic-refresh-\(accessToken)",
            refreshTokenExpiresAt: "2099-02-01T00:00:00Z",
            tokenType: "Bearer",
            sessionID: sessionID
        )
    }
}

private actor RefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
