import Foundation

@MainActor
final class AppPreferences {
    static let standard = AppPreferences(defaults: .standard)

    private enum Key {
        static let appLockEnabled = "privacy.appLockEnabled"
        static let budgetThresholdNotification =
            "planning.budgetThresholdNotification."
        static let completedOnboarding = "onboarding.completed"
        static let currentScopeKey = "session.currentScopeKey"
        static let deviceID = "device.identifier"
        static let hasAuthenticated = "session.hasAuthenticated"
        static let lastEmail = "session.lastEmail"
        static let recurringReminderLeadHours = "planning.recurringReminderLeadHours."
        static let recurringRemindersEnabled = "planning.recurringRemindersEnabled."
        static let remoteIdentity = "server.remoteIdentity"
        static let serverConnectionEnabled = "server.connectionEnabled"
        static let serverURL = "server.baseURL"
        static let shortcutExpenseNotification =
            "shortcut.expenseNotification."
        static let shortcutExpenseNotificationScanAt =
            "shortcut.expenseNotificationScanAt."
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

    var serverConnectionEnabled: Bool {
        get { defaults.bool(forKey: Key.serverConnectionEnabled) }
        set { defaults.set(newValue, forKey: Key.serverConnectionEnabled) }
    }

    var hasExplicitServerConnectionPreference: Bool {
        defaults.object(forKey: Key.serverConnectionEnabled) != nil
    }

    var remoteIdentityKey: String {
        get { defaults.string(forKey: Key.remoteIdentity) ?? "" }
        set { defaults.set(newValue, forKey: Key.remoteIdentity) }
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

    func recurringRemindersEnabled(scopeKey: String) -> Bool {
        defaults.bool(forKey: scopedKey(Key.recurringRemindersEnabled, scopeKey: scopeKey))
    }

    func setRecurringRemindersEnabled(_ enabled: Bool, scopeKey: String) {
        defaults.set(
            enabled,
            forKey: scopedKey(Key.recurringRemindersEnabled, scopeKey: scopeKey)
        )
    }

    func recurringReminderLeadTime(scopeKey: String) -> RecurringReminderLeadTime {
        let key = scopedKey(Key.recurringReminderLeadHours, scopeKey: scopeKey)
        guard defaults.object(forKey: key) != nil,
              let value = RecurringReminderLeadTime(rawValue: defaults.integer(forKey: key))
        else {
            return .oneDay
        }
        return value
    }

    func setRecurringReminderLeadTime(
        _ leadTime: RecurringReminderLeadTime,
        scopeKey: String
    ) {
        defaults.set(
            leadTime.rawValue,
            forKey: scopedKey(Key.recurringReminderLeadHours, scopeKey: scopeKey)
        )
    }

    func hasSentBudgetThresholdNotification(identifier: String) -> Bool {
        defaults.bool(
            forKey: Key.budgetThresholdNotification + identifier
        )
    }

    func recordBudgetThresholdNotification(identifier: String) {
        defaults.set(
            true,
            forKey: Key.budgetThresholdNotification + identifier
        )
    }

    func hasSentShortcutExpenseNotification(identifier: String) -> Bool {
        defaults.bool(
            forKey: Key.shortcutExpenseNotification + identifier
        )
    }

    func recordShortcutExpenseNotification(identifier: String) {
        defaults.set(
            true,
            forKey: Key.shortcutExpenseNotification + identifier
        )
    }

    func shortcutExpenseNotificationScanAt(scopeKey: String) -> Date? {
        let interval = defaults.double(
            forKey: scopedKey(
                Key.shortcutExpenseNotificationScanAt,
                scopeKey: scopeKey
            )
        )
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    func setShortcutExpenseNotificationScanAt(_ date: Date, scopeKey: String) {
        defaults.set(
            date.timeIntervalSince1970,
            forKey: scopedKey(
                Key.shortcutExpenseNotificationScanAt,
                scopeKey: scopeKey
            )
        )
    }

    var deviceID: String {
        if let existing = defaults.string(forKey: Key.deviceID), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Key.deviceID)
        return created
    }

    func beginLocalProfile(scopeKey: String) {
        serverURLString = ""
        lastEmail = ""
        remoteIdentityKey = ""
        serverConnectionEnabled = false
        currentScopeKey = scopeKey
        hasAuthenticatedBefore = false
        isSignedOut = false
    }

    func recordAuthentication(
        serverURL: URL,
        email: String,
        scopeKey: String,
        remoteIdentityKey: String? = nil
    ) {
        serverURLString = serverURL.absoluteString
        lastEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        currentScopeKey = scopeKey
        self.remoteIdentityKey = remoteIdentityKey ?? scopeKey
        serverConnectionEnabled = true
        hasAuthenticatedBefore = true
        isSignedOut = false
    }

    func recordServerDisconnect() {
        serverConnectionEnabled = false
        isSignedOut = false
    }

    private func scopedKey(_ prefix: String, scopeKey: String) -> String {
        prefix + RecurringReminderPlanner.scopeDigest(scopeKey)
    }

#if DEBUG
    func resetForUITests() {
        for key in [
            Key.appLockEnabled,
            Key.completedOnboarding,
            Key.currentScopeKey,
            Key.hasAuthenticated,
            Key.lastEmail,
            Key.remoteIdentity,
            Key.serverConnectionEnabled,
            Key.serverURL,
            Key.signedOut,
        ] {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where
            key.hasPrefix(Key.budgetThresholdNotification) ||
            key.hasPrefix(Key.recurringReminderLeadHours) ||
            key.hasPrefix(Key.recurringRemindersEnabled) ||
            key.hasPrefix(Key.shortcutExpenseNotification) ||
            key.hasPrefix(Key.shortcutExpenseNotificationScanAt) {
            defaults.removeObject(forKey: key)
        }
    }
#endif
}
