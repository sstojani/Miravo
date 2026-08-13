import Foundation
import Testing
@testable import ProjectLedger

@MainActor
struct AppPreferencesTests {
    @Test func authenticationMetadataContainsNoPasswordAndKeepsStableDeviceID() throws {
        let suite = "ProjectLedgerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)

        let firstDeviceID = preferences.deviceID
        let scope = "https://ledger.example|40000000-0000-0000-0000-000000000004"
        preferences.recordAuthentication(
            serverURL: URL(string: "https://ledger.example")!,
            email: " USER@Example.test ",
            scopeKey: scope
        )

        #expect(preferences.deviceID == firstDeviceID)
        #expect(preferences.lastEmail == "user@example.test")
        #expect(preferences.currentScopeKey == scope)
        #expect(preferences.hasAuthenticatedBefore)
        #expect(!preferences.isSignedOut)
        #expect(defaults.dictionaryRepresentation().values.allSatisfy { value in
            String(describing: value) != "never-store-this-password"
        })
    }

    @Test func recurringReminderPreferencesAreScopedWithoutStoringRawScope() throws {
        let suite = "ProjectLedgerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let first = "https://ledger.example|40000000-0000-0000-0000-000000000004"
        let second = "https://ledger.example|50000000-0000-0000-0000-000000000005"

        #expect(!preferences.recurringRemindersEnabled(scopeKey: first))
        #expect(preferences.recurringReminderLeadTime(scopeKey: first) == .oneDay)
        preferences.setRecurringRemindersEnabled(true, scopeKey: first)
        preferences.setRecurringReminderLeadTime(.threeDays, scopeKey: first)

        #expect(preferences.recurringRemindersEnabled(scopeKey: first))
        #expect(preferences.recurringReminderLeadTime(scopeKey: first) == .threeDays)
        #expect(!preferences.recurringRemindersEnabled(scopeKey: second))
        #expect(preferences.recurringReminderLeadTime(scopeKey: second) == .oneDay)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy {
            !$0.contains(first) && !$0.contains(second)
        })
    }
}
