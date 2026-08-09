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

@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var phase: SessionPhase = .loading
    @Published private(set) var scopeKey: String?
    @Published private(set) var isWorking = false
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
                let testScope = "https://ui-test.invalid|00000000-0000-0000-0000-000000000001"
                preferences.hasCompletedOnboarding = true
                preferences.hasAuthenticatedBefore = true
                preferences.isSignedOut = false
                preferences.currentScopeKey = testScope
                preferences.serverURLString = "https://ui-test.invalid"
                scopeKey = testScope
                phase = .authenticated
                return
            }
        #endif
        restoreLocalSession()
    }

    var canOpenOffline: Bool {
        preferences.hasAuthenticatedBefore &&
            !preferences.isSignedOut &&
            preferences.currentScopeKey != nil
    }

    var configuredServerURL: String { preferences.serverURLString }

    var appLockEnabled: Bool { preferences.appLockEnabled }

    func completeOnboarding() {
        preferences.hasCompletedOnboarding = true
        phase = .signIn
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
            let newScopeKey = SessionScope.key(serverURL: baseURL, userID: userID)
            try await tokenStore.save(tokens, scopeKey: newScopeKey)
            preferences.recordAuthentication(
                serverURL: baseURL,
                email: email,
                scopeKey: newScopeKey
            )
            scopeKey = newScopeKey
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
        guard phase == .locked else { return }
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
        guard canOpenOffline, let savedScope = preferences.currentScopeKey else {
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
