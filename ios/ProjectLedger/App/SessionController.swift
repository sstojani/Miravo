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

struct PendingGuestProfileAdoption: Codable, Equatable {
    let sourceScopeKey: String
    let targetScopeKey: String
}

@MainActor
final class SessionController: ObservableObject {
    typealias TransportFactory = @Sendable (URL) -> any SessionTransport
    @Published private(set) var phase: SessionPhase = .loading
    @Published private(set) var scopeKey: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isUnlocking = false
    @Published private(set) var isSigningOut = false
    @Published var errorMessage: String?
    @Published var requestID: String?
    @Published var logoutWarning: String?
    @Published private(set) var appAppearance: AppAppearanceMode

    let preferences: AppPreferences
    private let tokenStore: KeychainSessionTokenStore
    private let transportFactory: TransportFactory
    private var sessionRevision = UUID()
    private var logoutTask: Task<Void, Never>?

    init(
        preferences: AppPreferences = .standard,
        tokenStore: KeychainSessionTokenStore = KeychainSessionTokenStore(),
        transportFactory: @escaping TransportFactory = { APIClient(baseURL: $0, timeout: 8) }
    ) {
        self.preferences = preferences
        self.tokenStore = tokenStore
        self.transportFactory = transportFactory
        appAppearance = preferences.appAppearance
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset-onboarding") {
                preferences.resetForUITests()
                phase = .onboarding
                return
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-authenticated") {
                preferences.resetForUITests()
                let serverTest = ProcessInfo.processInfo.arguments.contains("-ui-testing-server-session")
                let testScope = serverTest ? "https://ledger.example.test|ui-testing" : "local|ui-testing"
                preferences.hasCompletedOnboarding = true
                preferences.beginLocalProfile(scopeKey: testScope)
                if serverTest {
                    preferences.serverURLString = "https://ledger.example.test"
                    preferences.serverConnectionEnabled = true
                    preferences.lastEmail = "ui-test@example.test"
                }
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

    var configuredServerURL: String { preferredServerURLString }

    var defaultServerURLString: String {
        BundledServerConfiguration.defaultServerURLString
    }

    private var preferredServerURLString: String {
        let saved = preferences.serverURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? defaultServerURLString : saved
    }

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
            !preferredServerURLString.isEmpty &&
            !SessionScope.isLocal(scopeKey)
    }

    var appLockEnabled: Bool { preferences.appLockEnabled }

    func setAppAppearance(_ mode: AppAppearanceMode) {
        preferences.appAppearance = mode
        appAppearance = mode
    }

    func synchronizationContext() async throws -> SyncAuthenticationContext? {
        let revision = sessionRevision
        guard hasServerConnection,
              let scopeKey,
              pendingGuestAdoption(for: scopeKey) == nil,
              let tokens = try await tokenStore.load(scopeKey: scopeKey)
        else {
            return nil
        }
        let baseURL = try ServerURLPolicy.validated(preferredServerURLString)
        guard revision == sessionRevision, hasServerConnection, self.scopeKey == scopeKey else { return nil }
        guard let userID = JWTSubjectParser.subject(from: tokens.accessToken),
              SessionScope.key(serverURL: baseURL, userID: userID) == scopeKey
        else { throw KeychainStoreError.invalidData }
        return SyncAuthenticationContext(
            scopeKey: scopeKey,
            baseURL: baseURL,
            tokens: tokens,
            tokenStore: tokenStore
        )
    }

    func shortcutAuthenticationContext() async throws -> SyncAuthenticationContext? {
        let revision = sessionRevision
        guard let context = try await synchronizationContext() else { return nil }
        let expiresAt = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(context.tokens.accessTokenExpiresAt)) ??
            (try? Date.ISO8601FormatStyle().parse(context.tokens.accessTokenExpiresAt))
        if let expiresAt, expiresAt.timeIntervalSinceNow > 60 { return context }
        let client = APIClient(baseURL: context.baseURL, timeout: 8)
        let tokens = try await tokenStore.refresh(scopeKey: context.scopeKey, replacing: context.tokens) { token in
            try await client.refresh(refreshToken: token)
        }
        try Task.checkCancellation()
        guard revision == sessionRevision, hasServerConnection, scopeKey == context.scopeKey else { return nil }
        return SyncAuthenticationContext(
            scopeKey: context.scopeKey,
            baseURL: context.baseURL,
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
        guard !isSigningOut else { return }
        sessionRevision = UUID()
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
        guard !isWorking, !isSigningOut else { return }
        sessionRevision = UUID()
        let revision = sessionRevision
        isWorking = true
        errorMessage = nil
        requestID = nil
        logoutWarning = nil
        defer { isWorking = false }

        do {
            let requestedServerURL = serverURL.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let baseURL = try ServerURLPolicy.validated(
                requestedServerURL.isEmpty ? preferredServerURLString : requestedServerURL
            )
            let client = transportFactory(baseURL)
            let tokens = try await client.login(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                deviceID: preferences.deviceID,
                deviceName: UIDevice.current.model,
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? ""
            )
            try Task.checkCancellation()
            guard revision == sessionRevision else { return }
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
            if let pending = preferences.pendingGuestAdoption,
               pending.targetScopeKey != remoteIdentityKey {
                errorMessage = String(localized: "This local profile is already linked to a different server account.")
                return
            }
            let activeScopeKey = remoteIdentityKey
            let pendingAdoption: PendingGuestProfileAdoption?

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

                pendingAdoption = PendingGuestProfileAdoption(
                    sourceScopeKey: existingScope,
                    targetScopeKey: remoteIdentityKey
                )
            } else {
                pendingAdoption = nil
            }

            try await tokenStore.save(tokens, scopeKey: activeScopeKey)
            guard revision == sessionRevision, !Task.isCancelled else {
                try? await tokenStore.delete(scopeKey: activeScopeKey, matching: tokens)
                return
            }

            // Persist the handoff before switching scope. A restart can safely repeat adoption.
            preferences.pendingGuestAdoption = pendingAdoption ?? preferences.pendingGuestAdoption
            preferences.recordAuthentication(
                serverURL: baseURL,
                email: email,
                scopeKey: activeScopeKey,
                remoteIdentityKey: remoteIdentityKey
            )

            scopeKey = activeScopeKey
            phase = .authenticated
        } catch is CancellationError {
            return
        } catch let error as APIClientError {
            guard revision == sessionRevision else { return }
            errorMessage = localizedMessage(for: error)
            requestID = error.requestID
        } catch let error as ServerURLError {
            guard revision == sessionRevision else { return }
            errorMessage = localizedMessage(for: error)
        } catch let error as URLError {
            guard revision == sessionRevision, error.code != .cancelled else { return }
            errorMessage = networkMessage(for: error)
        } catch {
            guard revision == sessionRevision else { return }
            errorMessage = String(localized: "Sign in could not be completed securely.")
        }
    }

    func pendingGuestAdoption(for scopeKey: String) -> PendingGuestProfileAdoption? {
        guard preferences.pendingGuestAdoption?.targetScopeKey == scopeKey else { return nil }
        return preferences.pendingGuestAdoption
    }

    func clearPendingGuestAdoption(_ adoption: PendingGuestProfileAdoption) {
        guard preferences.pendingGuestAdoption == adoption else { return }
        preferences.pendingGuestAdoption = nil
    }

    func reportGuestAdoptionFailure() {
        errorMessage = String(
            localized: "Guest data could not be prepared for server sync. Open Miravo offline and try again."
        )
        requestID = nil
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

    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        sessionRevision = UUID()
        let revision = sessionRevision
        let baseURL = try? ServerURLPolicy.validated(preferredServerURLString)
        logoutWarning = nil
        errorMessage = nil
        requestID = nil
        guard let currentScope = scopeKey else {
            finishLocalSignOut()
            return
        }
        // Hide the account immediately. Server availability cannot gate local sign-out.
        finishLocalSignOut()
        let savedTokens: SessionTokenBundle?
        do {
            savedTokens = try await tokenStore.load(scopeKey: currentScope)
        } catch {
            savedTokens = nil
        }
        do {
            try await tokenStore.delete(scopeKey: currentScope)
        } catch {
            // Local sign-out still hides the scoped store if Keychain cleanup fails.
        }
        if let baseURL, let tokens = savedTokens {
            let client = transportFactory(baseURL)
            logoutTask = Task { [weak self] in
                do {
                    try await client.logout(accessToken: tokens.accessToken)
                } catch {
                    guard let self, self.sessionRevision == revision, self.phase == .signIn else { return }
                    self.logoutWarning = String(
                        localized: "This phone signed out locally, but the server session could not be revoked while offline. Revoke it from Device sessions after reconnecting."
                    )
                }
            }
        }
    }

    private func restoreLocalSession() {
        guard preferences.hasCompletedOnboarding else {
            phase = .loading
            Task { await prepareFreshInstallOnboarding() }
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

    private func prepareFreshInstallOnboarding() async {
        guard !preferences.hasCompletedOnboarding else { return }
        try? await tokenStore.deleteAll()
        scopeKey = nil
        errorMessage = nil
        requestID = nil
        phase = .onboarding
    }

    private func finishLocalSignOut() {
        preferences.isSignedOut = true
        preferences.serverConnectionEnabled = false
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
