import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct RecurringReminderControllerTests {
    private let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"

    @Test func permissionIsRequestedOnlyOnOptInAndContentStaysGeneric() async throws {
        let container = try makeContainer()
        let rule = try makeRule(scopeKey: scope, dueAt: .now.addingTimeInterval(2 * 86_400))
        container.mainContext.insert(rule)
        try container.mainContext.save()
        let fixture = try makePreferences()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let scheduler = FakeRecurringNotificationScheduler(state: .notDetermined)
        let controller = RecurringReminderController(
            modelContainer: container,
            preferences: fixture.preferences,
            scheduler: scheduler
        )

        await controller.configure(scopeKey: scope)
        #expect(scheduler.requestCount == 0)
        #expect(!controller.isEnabled)

        await controller.setEnabled(true, scopeKey: scope)

        #expect(scheduler.requestCount == 1)
        #expect(controller.isEnabled)
        #expect(controller.authorizationState == .authorized)
        #expect(controller.scheduledCount == 1)
        let scheduled = try #require(scheduler.scheduled.last)
        let visibleContent = scheduled.title + " " + scheduled.body
        #expect(!visibleContent.contains("Private music plan"))
        #expect(!visibleContent.contains("4242"))
        #expect(!scheduled.plan.identifier.contains(scope))
        #expect(!scheduled.plan.identifier.contains(rule.id.uuidString))

        await controller.setLeadTime(.threeDays, scopeKey: scope)
        #expect(controller.leadTime == .threeDays)
        #expect(controller.scheduledCount == 1)
        #expect(scheduler.scheduled.count == 2)

        await controller.setEnabled(false, scopeKey: scope)
        #expect(!controller.isEnabled)
        #expect(controller.scheduledCount == 0)
        #expect(scheduler.pending.isEmpty)
        #expect(!fixture.preferences.recurringRemindersEnabled(scopeKey: scope))
    }

    @Test func deniedPermissionDisablesStoredPreferenceWithoutPromptingAgain() async throws {
        let container = try makeContainer()
        let fixture = try makePreferences()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.preferences.setRecurringRemindersEnabled(true, scopeKey: scope)
        let scheduler = FakeRecurringNotificationScheduler(state: .denied)
        let controller = RecurringReminderController(
            modelContainer: container,
            preferences: fixture.preferences,
            scheduler: scheduler
        )

        await controller.configure(scopeKey: scope)

        #expect(!controller.isEnabled)
        #expect(controller.authorizationState == .denied)
        #expect(scheduler.requestCount == 0)
        #expect(scheduler.scheduled.isEmpty)
        #expect(!fixture.preferences.recurringRemindersEnabled(scopeKey: scope))
        #expect(controller.message != nil)
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: LocalRecurringRule.self,
            configurations: configuration
        )
    }

    private func makeRule(scopeKey: String, dueAt: Date) throws -> LocalRecurringRule {
        let money = try Money(minorUnits: 4_242, currencyCode: "EUR", exponent: 2)
        let conversion = try ReportingConversionSnapshot.resolved(
            original: money,
            baseCurrencyCode: "EUR",
            baseCurrencyExponent: 2,
            manualBaseMoney: nil,
            effectiveAt: dueAt
        )
        return LocalRecurringRule(
            scopeKey: scopeKey,
            trackerID: UUID(),
            name: "Private music plan",
            kind: .expense,
            isSubscription: true,
            money: money,
            accountID: UUID(),
            accountAmountMinor: money.minorUnits,
            categoryID: nil,
            merchant: "Private merchant",
            note: "Private note",
            conversion: conversion,
            cadence: .monthly,
            customIntervalUnit: nil,
            customIntervalCount: 1,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: dueAt,
            endsOn: nil,
            localTimeSeconds: 9 * 3_600,
            nextDueOn: dueAt,
            nextDueAt: dueAt,
            subscriptionProvider: "Private provider"
        )
    }

    private func makePreferences() throws -> (
        suite: String,
        defaults: UserDefaults,
        preferences: AppPreferences
    ) {
        let suite = "ProjectLedgerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (suite, defaults, AppPreferences(defaults: defaults))
    }
}

@MainActor
private final class FakeRecurringNotificationScheduler: RecurringNotificationScheduling {
    struct ScheduledRecord {
        let plan: RecurringReminderPlan
        let title: String
        let body: String
    }

    var state: RecurringReminderAuthorizationState
    var pending = Set<String>()
    var requestCount = 0
    var scheduled: [ScheduledRecord] = []

    init(state: RecurringReminderAuthorizationState) {
        self.state = state
    }

    func authorizationState() async -> RecurringReminderAuthorizationState {
        state
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        state = .authorized
        return true
    }

    func pendingIdentifiers() async -> [String] {
        pending.sorted()
    }

    func schedule(
        _ plan: RecurringReminderPlan,
        title: String,
        body: String
    ) async throws {
        pending.insert(plan.identifier)
        scheduled.append(ScheduledRecord(plan: plan, title: title, body: body))
    }

    func removePending(identifiers: [String]) {
        pending.subtract(identifiers)
    }
}
