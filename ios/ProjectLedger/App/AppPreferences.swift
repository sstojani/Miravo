import Foundation

@MainActor
final class AppPreferences {
    static let standard = AppPreferences(defaults: .standard)

    private enum Key {
        static let appLockEnabled = "privacy.appLockEnabled"
        static let completedOnboarding = "onboarding.completed"
        static let currentScopeKey = "session.currentScopeKey"
        static let deviceID = "device.identifier"
        static let hasAuthenticated = "session.hasAuthenticated"
        static let lastEmail = "session.lastEmail"
        static let serverURL = "server.baseURL"
        static let signedOut = "session.signedOut"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.completedOnboarding) }
        set { defaults.set(newValue, forKey: Key.completedOnboarding) }
    }

    var serverURLString: String {
        get { defaults.string(forKey: Key.serverURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.serverURL) }
    }

    var lastEmail: String {
        get { defaults.string(forKey: Key.lastEmail) ?? "" }
        set { defaults.set(newValue, forKey: Key.lastEmail) }
    }

    var currentScopeKey: String? {
        get { defaults.string(forKey: Key.currentScopeKey) }
        set { defaults.set(newValue, forKey: Key.currentScopeKey) }
    }

    var hasAuthenticatedBefore: Bool {
        get { defaults.bool(forKey: Key.hasAuthenticated) }
        set { defaults.set(newValue, forKey: Key.hasAuthenticated) }
    }

    var isSignedOut: Bool {
        get { defaults.bool(forKey: Key.signedOut) }
        set { defaults.set(newValue, forKey: Key.signedOut) }
    }

    var appLockEnabled: Bool {
        get { defaults.bool(forKey: Key.appLockEnabled) }
        set { defaults.set(newValue, forKey: Key.appLockEnabled) }
    }

    var deviceID: String {
        if let existing = defaults.string(forKey: Key.deviceID), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Key.deviceID)
        return created
    }

    func recordAuthentication(serverURL: URL, email: String, scopeKey: String) {
        serverURLString = serverURL.absoluteString
        lastEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        currentScopeKey = scopeKey
        hasAuthenticatedBefore = true
        isSignedOut = false
    }

#if DEBUG
    func resetForUITests() {
        for key in [
            Key.appLockEnabled,
            Key.completedOnboarding,
            Key.currentScopeKey,
            Key.hasAuthenticated,
            Key.lastEmail,
            Key.serverURL,
            Key.signedOut,
        ] {
            defaults.removeObject(forKey: key)
        }
    }
#endif
}
