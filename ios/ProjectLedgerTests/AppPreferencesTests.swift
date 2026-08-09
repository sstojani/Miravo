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
}
