import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct GuestRecoveryTests {
    let fixtures = LedgerSyncActorTests()
    let guest = "local|guest-recovery"
    let remote = "https://ledger.example|10000000-0000-0000-0000-000000000001"

    @Test(arguments: ["rename", "balance", "budget", "altered-payload", "altered-duplicate"])
    func customizedGuestIsPreservedAndResequenced(kind: String) throws {
        let container = try fixtures.makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let target = try repository.bootstrapDefaults(scopeKey: remote)
        let tracker = try repository.bootstrapDefaults(scopeKey: guest)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first { $0.scopeKey == guest })
        let original = try context.fetch(FetchDescriptor<OutboxMutation>()).filter { $0.scopeKey == guest }
        switch kind {
        case "rename": try repository.renameTracker(tracker, name: "Travel")
        case "balance": account.openingBalanceMinor = 500
        case "budget":
            _ = try repository.createBudget(scopeKey: guest, tracker: tracker, name: "Offline plan", budgetScope: .tracker, period: .monthly, money: Money(minorUnits: 10000, currencyCode: "ALL", exponent: 2), timeZoneIdentifier: "Europe/Tirane", startsOn: .now, endsOn: nil, rollover: false, categories: [])
        default:
            let row = try #require(original.first { $0.entityType == "tracker" && $0.command == "update" })
            var payload = try #require(JSONDecoder().decode(JSONValue.self, from: row.payloadJSON).objectValue)
            payload["name"] = .string("Important unsaved name")
            let data = try JSONEncoder().encode(JSONValue.object(payload))
            if kind == "altered-duplicate" {
                context.insert(OutboxMutation(scopeKey: guest, localSequence: 5, entityID: tracker.id, entityType: "tracker", command: "update", payloadJSON: data))
            } else { row.payloadJSON = data }
        }
        try context.save()
        let result = try repository.adoptGuestProfileForAuthentication(sourceScopeKey: guest, targetScopeKey: remote)
        #expect(result == .migratedLocalProfile)
        #expect(Set(try context.fetch(FetchDescriptor<LocalTracker>()).map(\.id)) == Set([target.id, tracker.id]))
        let rows = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(rows.allSatisfy { $0.scopeKey == remote })
        #expect(Set(rows.map(\.localSequence)).count == rows.count)
        #expect(Set(original.map(\.operationID)).isSubset(of: Set(rows.map(\.operationID))))
        #expect(try repository.adoptGuestProfileForAuthentication(sourceScopeKey: guest, targetScopeKey: remote) == .notNeeded)
    }

    @Test(arguments: [false, true])
    func untouchedGuestRestoresExistingOrEmptyServer(existing: Bool) async throws {
        let container = try fixtures.makeContainer()
        let repository = LocalLedgerRepository(context: container.mainContext)
        _ = try repository.bootstrapDefaults(scopeKey: guest)
        #expect(try repository.adoptGuestProfileForAuthentication(sourceScopeKey: guest, targetScopeKey: remote) == .discardedDisposableProfile)
        let id = UUID()
        let records = existing ? [fixtures.trackerRepresentation(id: id, name: "Existing cloud", version: 4)] : []
        let transport = ScriptedSyncTransport(pushResponses: [], pullResponses: [fixtures.emptyPull(cursor: "after")], bootstrapResponses: [SyncBootstrapResponse(protocolVersion: 1, generatedAt: "2026-09-07T08:00:00Z", cursor: "snapshot", bootstrapCursor: nil, hasMore: false, data: fixtures.bootstrapData(trackers: records))], ackResponses: [fixtures.ack(cursor: "after")])
        _ = try await LedgerSyncActor(modelContainer: container).synchronize(authentication: fixtures.authentication(), transport: transport)
        let restored = try ModelContext(container).fetch(FetchDescriptor<LocalTracker>())
        #expect(restored.map(\.id) == (existing ? [id] : []))
        #expect(await transport.capturedPushRequests().isEmpty)
    }

    @Test func guestAdoptionMarkerSurvivesPreferencesRestartAndBlocksSync() async throws {
        let suite = "ProjectLedgerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let adoption = PendingGuestProfileAdoption(sourceScopeKey: guest, targetScopeKey: remote)
        preferences.pendingGuestAdoption = adoption
        preferences.hasCompletedOnboarding = true
        preferences.recordAuthentication(serverURL: try #require(URL(string: "https://ledger.example")), email: "test@example.test", scopeKey: remote)
        let restarted = SessionController(preferences: AppPreferences(defaults: defaults))
        #expect(restarted.pendingGuestAdoption(for: remote) == adoption)
        let authentication = try await restarted.synchronizationContext()
        #expect(authentication == nil)
        restarted.clearPendingGuestAdoption(PendingGuestProfileAdoption(sourceScopeKey: "local|different", targetScopeKey: remote))
        #expect(preferences.pendingGuestAdoption == adoption)
        restarted.clearPendingGuestAdoption(adoption)
        #expect(preferences.pendingGuestAdoption == nil)
    }
}
