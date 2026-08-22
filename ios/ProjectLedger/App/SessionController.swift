import Combine
import Foundation
import UIKit

enum SessionPhase: Equatable {
    case loading
    case onboarding
    case signIn
    case authenticated
    case locked
}

struct SyncAuthenticationContext: Sendable {
    let scopeKey: String
    let baseURL: URL
    let tokens: SessionTokenBundle
    let tokenStore: KeychainSessionTokenStore
}

@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var phase: SessionPhase = .loading
    @Published private(set) var scopeKey: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isUnlocking = false
    @Published var errorMessage: String?
    @Published var requestID: String?
    @Published var logoutWarning: String?

    let preferences: AppPreferences
    private let tokenStore: KeychainSessionTokenStore

    init(
        preferences: AppPreferences = .standard,
        tokenStore: KeychainSessionTokenStore = KeychainSessionTokenStore()
    ) {
        self.preferences = preferences
        self.tokenStore = tokenStore
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset-onboarding") {
                preferences.resetForUITests()
                phase = .onboarding
                return
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-authenticated") {
                let testScope = "local|ui-testing"
                preferences.hasCompletedOnboarding = true
                preferences.beginLocalProfile(scopeKey: testScope)
                scopeKey = testScope
                phase = .authenticated
                return
            }
        #endif
        restoreLocalSession()
    }

    var canOpenOffline: Bool {
        !preferences.isSignedOut &&
            preferences.currentScopeKey != nil
    }

    var configuredServerURL: String { preferences.serverURLString }

    var hasServerConnection: Bool {
        guard phase == .authenticated,
              !preferences.isSignedOut,
              let scopeKey
        else {
            return false
        }

        if preferences.hasExplicitServerConnectionPreference {
            return preferences.serverConnectionEnabled
        }

        return preferences.hasAuthenticatedBefore &&
            !preferences.serverURLString.isEmpty &&
            !SessionScope.isLocal(scopeKey)
    }

    var appLockEnabled: Bool { preferences.appLockEnabled }

    func synchronizationContext() async throws -> SyncAuthenticationContext? {
        guard phase == .authenticated,
              let scopeKey,
              let tokens = try await tokenStore.load(scopeKey: scopeKey)
        else {
            return nil
        }
        let baseURL = try ServerURLPolicy.validated(preferences.serverURLString)
        return SyncAuthenticationContext(
            scopeKey: scopeKey,
            baseURL: baseURL,
            tokens: tokens,
            tokenStore: tokenStore
        )
    }

    func completeOnboarding() {
        startLocalOnly()
    }

    func configureServerAfterOnboarding() {
        preferences.hasCompletedOnboarding = true
        errorMessage = nil
        requestID = nil
        phase = .signIn
    }

    func startLocalOnly() {
        let localScope = SessionScope.localKey(deviceID: preferences.deviceID)

        preferences.hasCompletedOnboarding = true
        preferences.beginLocalProfile(scopeKey: localScope)

        scopeKey = localScope
        errorMessage = nil
        requestID = nil
        logoutWarning = nil
        phase = preferences.appLockEnabled ? .locked : .authenticated
    }

    func signIn(serverURL: String, email: String, password: String) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        requestID = nil
        defer { isWorking = false }

        do {
            let baseURL = try ServerURLPolicy.validated(serverURL)
            let client = APIClient(baseURL: baseURL)
            let tokens = try await client.login(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                deviceID: preferences.deviceID,
                deviceName: UIDevice.current.model,
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? ""
            )
            guard tokens.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
                  !tokens.accessToken.isEmpty,
                  !tokens.refreshToken.isEmpty
            else {
                throw APIClientError(
                    code: "invalid_response",
                    message: String(localized: "The server returned an invalid response."),
                    requestID: nil,
                    statusCode: nil
                )
            }
            guard let userID = JWTSubjectParser.subject(from: tokens.accessToken) else {
                throw APIClientError(
                    code: "invalid_response",
                    message: String(localized: "The server returned an invalid response."),
                    requestID: nil,
                    statusCode: nil
                )
            }
            let remoteIdentityKey = SessionScope.key(
                serverURL: baseURL,
                userID: userID
            )

            let existingScope = scopeKey ?? preferences.currentScopeKey
            let activeScopeKey: String

            if let existingScope,
               SessionScope.isLocal(existingScope) {
                let existingRemoteIdentity = preferences.remoteIdentityKey

                if !existingRemoteIdentity.isEmpty,
                   existingRemoteIdentity != remoteIdentityKey {
                    errorMessage = String(
                        localized: "This local profile is already linked to a different server account."
                    )
                    requestID = nil
                    return
                }

                activeScopeKey = existingScope
            } else {
                activeScopeKey = remoteIdentityKey
            }

            try await tokenStore.save(tokens, scopeKey: activeScopeKey)

            preferences.recordAuthentication(
                serverURL: baseURL,
                email: email,
                scopeKey: activeScopeKey,
                remoteIdentityKey: remoteIdentityKey
            )

            scopeKey = activeScopeKey
            phase = .authenticated
        } catch let error as APIClientError {
            errorMessage = localizedMessage(for: error)
            requestID = error.requestID
        } catch let error as ServerURLError {
            errorMessage = localizedMessage(for: error)
        } catch let error as URLError {
            errorMessage = networkMessage(for: error)
        } catch {
            errorMessage = String(localized: "Sign in could not be completed securely.")
        }
    }

    func openOffline() {
        guard canOpenOffline, let savedScope = preferences.currentScopeKey else { return }
        scopeKey = savedScope
        phase = preferences.appLockEnabled ? .locked : .authenticated
    }

    func lockIfNeeded() {
        guard preferences.appLockEnabled, phase == .authenticated else { return }
        phase = .locked
    }

    func unlock() async {
        guard phase == .locked, !isUnlocking else { return }

        isUnlocking = true
        defer { isUnlocking = false }

        if await AppLockController.unlock() {
            phase = .authenticated
            errorMessage = nil
        } else {
            errorMessage = String(localized: "The app is still locked.")
        }
    }

    func setAppLockEnabled(_ enabled: Bool) {
        guard !enabled || AppLockController.isAvailable() else {
            errorMessage = String(localized: "A device passcode is required to enable app lock.")
            return
        }
        preferences.appLockEnabled = enabled
    }

    func disconnectServer() async {
        guard let currentScope = scopeKey else { return }

        logoutWarning = nil

        let savedTokens: SessionTokenBundle?
        do {
            savedTokens = try await tokenStore.load(scopeKey: currentScope)
        } catch {
            savedTokens = nil
        }

        if let baseURL = try? ServerURLPolicy.validated(preferences.serverURLString),
           let tokens = savedTokens {
            do {
                try await APIClient(baseURL: baseURL)
                    .logout(accessToken: tokens.accessToken)
            } catch {
                logoutWarning = String(
                    localized: "This phone disconnected locally, but the server session could not be revoked while offline."
                )
            }
        }

        do {
            try await tokenStore.delete(scopeKey: currentScope)
        } catch {
            // The local ledger remains usable even if Keychain cleanup fails.
        }

        preferences.recordServerDisconnect()
        errorMessage = nil
        requestID = nil
        phase = .authenticated
    }

    func signOut() async {
        guard let currentScope = scopeKey else {
            finishLocalSignOut()
            return
        }
        logoutWarning = nil
        let savedTokens: SessionTokenBundle?
        do {
            savedTokens = try await tokenStore.load(scopeKey: currentScope)
        } catch {
            savedTokens = nil
        }
        if let baseURL = try? ServerURLPolicy.validated(preferences.serverURLString),
           let tokens = savedTokens {
            do {
                try await APIClient(baseURL: baseURL).logout(accessToken: tokens.accessToken)
            } catch {
                logoutWarning = String(
                    localized: "This phone signed out locally, but the server session could not be revoked while offline. Revoke it from Device sessions after reconnecting."
                )
            }
        }
        do {
            try await tokenStore.delete(scopeKey: currentScope)
        } catch {
            // Local sign-out still hides the scoped store if Keychain cleanup fails.
        }
        finishLocalSignOut()
    }

    private func restoreLocalSession() {
        guard preferences.hasCompletedOnboarding else {
            phase = .onboarding
            return
        }
        guard !preferences.isSignedOut,
              let savedScope = preferences.currentScopeKey
        else {
            phase = .signIn
            return
        }
        scopeKey = savedScope
        phase = preferences.appLockEnabled ? .locked : .authenticated
    }

    private func finishLocalSignOut() {
        preferences.isSignedOut = true
        scopeKey = nil
        phase = .signIn
    }

    private func localizedMessage(for error: APIClientError) -> String {
        switch error.code {
        case "invalid_credentials":
            String(localized: "The email or password is incorrect.")
        case "rate_limited":
            String(localized: "Too many attempts. Wait a moment and try again.")
        default:
            error.message
        }
    }

    private func localizedMessage(for error: ServerURLError) -> String {
        switch error {
        case .invalid:
            String(localized: "Enter a complete server URL.")
        case .httpsRequired:
            String(localized: "A secure HTTPS server URL is required.")
        case .cleartextHostNotAllowed:
            String(localized: "Development HTTP is allowed only for this device's loopback host.")
        }
    }

    private func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
            String(localized: "The server is unreachable. Check your connection and server URL.")
        default:
            String(localized: "The secure connection could not be completed.")
        }
    }
}
