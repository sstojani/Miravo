import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct LocalRecurringTests {
    private let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"

    @Test func calendarPreservesMonthAndLeapAnchorsAndDefinesDSTBehavior() throws {
        let january = try dateOnly("2026-01-31")
        let february = try LocalRecurrenceCalculator.nextDueDate(
            after: january,
            cadence: .monthly,
            customIntervalUnit: nil,
            customIntervalCount: 1,
            anchorDay: 31,
            anchorMonth: 1
        )
        let march = try LocalRecurrenceCalculator.nextDueDate(
            after: february,
            cadence: .monthly,
            customIntervalUnit: nil,
            customIntervalCount: 1,
            anchorDay: 31,
            anchorMonth: 1
        )
        let leapYear = try LocalRecurrenceCalculator.nextDueDate(
            after: try dateOnly("2027-02-28"),
            cadence: .yearly,
            customIntervalUnit: nil,
            customIntervalCount: 1,
            anchorDay: 29,
            anchorMonth: 2
        )

        #expect(BudgetDateCodec.string(from: february) == "2026-02-28")
        #expect(BudgetDateCodec.string(from: march) == "2026-03-31")
        #expect(BudgetDateCodec.string(from: leapYear) == "2028-02-29")

        let gap = try LocalRecurrenceCalculator.scheduledDate(
            civilDate: try dateOnly("2026-03-08"),
            localTimeSeconds: 2 * 3_600 + 30 * 60,
            timeZoneIdentifier: "America/New_York"
        )
        let fold = try LocalRecurrenceCalculator.scheduledDate(
            civilDate: try dateOnly("2026-11-01"),
            localTimeSeconds: 1 * 3_600 + 30 * 60,
            timeZoneIdentifier: "America/New_York"
        )
        #expect(gap == try timestamp("2026-03-08T07:00:00Z"))
        #expect(fold == try timestamp("2026-11-01T05:30:00Z"))
    }

    @Test func localSubscriptionLifecycleIsImmediateAndOutboxOrdered() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let start = try dateOnly("2026-01-31")

        let rule = try repository.createRecurringRule(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: category,
            name: "Music",
            kind: .expense,
            isSubscription: true,
            money: try Money(minorUnits: 999, currencyCode: "ALL", exponent: 2),
            merchant: "Example Music",
            cadence: .monthly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: start,
            localTimeSeconds: 9 * 3_600 + 15 * 60,
            subscriptionProvider: "Example Music",
            cancellationURL: "https://example.com/cancel"
        )
        #expect(rule.state == .active)
        #expect(rule.nextDueOn == start)

        try repository.pauseRecurringRule(rule)
        #expect(rule.state == .paused)
        try repository.resumeRecurringRule(rule)
        #expect(rule.state == .active)
        try repository.skipNextRecurringOccurrence(rule)
        #expect(BudgetDateCodec.string(from: rule.nextDueOn) == "2026-02-28")
        try repository.skipNextRecurringOccurrence(rule)
        #expect(BudgetDateCodec.string(from: rule.nextDueOn) == "2026-03-31")
        try repository.endRecurringRule(rule)
        #expect(rule.state == .ended)
        try repository.deleteRecurringRule(rule)
        #expect(rule.deletedAt != nil)

        let mutations = try context.fetch(FetchDescriptor<OutboxMutation>())
            .filter { $0.entityID == rule.id }
            .sorted { $0.localSequence < $1.localSequence }
        #expect(mutations.map(\.entityType).allSatisfy {
            $0 == LocalMutationEntity.recurringRule.rawValue
        })
        #expect(mutations.map(\.command) == [
            "create", "pause", "resume", "skip_next", "skip_next", "end", "delete",
        ])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(
            RecurringRuleMutationPayload.self,
            from: try #require(mutations.first).payloadJSON
        )
        #expect(payload.amountMinor == 999)
        #expect(payload.localTime == "09:15:00")
        #expect(payload.nextDueOn == "2026-01-31")
        #expect(payload.subscriptionProvider == "Example Music")
    }

    @Test func subscriptionCostAndOccurrenceIdentityAreDeterministic() throws {
        let ruleID = UUID(uuidString: "75000000-0000-0000-0000-000000000007")!
        let money = try Money(minorUnits: 1_000, currencyCode: "EUR", exponent: 2)
        let conversion = try ReportingConversionSnapshot.resolved(
            original: money,
            baseCurrencyCode: "EUR",
            baseCurrencyExponent: 2,
            manualBaseMoney: nil,
            effectiveAt: try timestamp("2026-08-31T07:15:00Z")
        )
        let rule = LocalRecurringRule(
            id: ruleID,
            scopeKey: scope,
            trackerID: UUID(),
            name: "Weekly subscription",
            kind: .expense,
            isSubscription: true,
            money: money,
            accountID: UUID(),
            accountAmountMinor: money.minorUnits,
            categoryID: nil,
            merchant: "",
            note: "",
            conversion: conversion,
            cadence: .weekly,
            customIntervalUnit: nil,
            customIntervalCount: 1,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: try dateOnly("2026-08-31"),
            endsOn: nil,
            localTimeSeconds: 9 * 3_600 + 15 * 60,
            nextDueOn: try dateOnly("2026-08-31"),
            nextDueAt: try timestamp("2026-08-31T07:15:00Z"),
            subscriptionProvider: "Provider"
        )
        let normalized = try LocalRecurrenceCalculator.normalizedCost(
            for: rule,
            baseCurrencyExponent: 2
        )
        #expect(normalized.monthly.minorUnits == 4_333)
        #expect(normalized.annual.minorUnits == 52_000)
        #expect(
            LocalRecurrenceCalculator.occurrenceKey(
                ruleID: ruleID,
                dueOn: try dateOnly("2026-08-31")
            ) == "be775a3d4e64436b4a1240088e5cbcf4b5e18d46360ee1fcd77ae39ba93fe735"
        )
    }

    @Test func nonfinancialEditPreservesExplicitConversionSnapshot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try repository.createAccount(
            scopeKey: scope,
            tracker: tracker,
            name: "Euro account",
            type: .checking,
            currencyCode: "EUR",
            currencyExponent: 2
        )
        let original = try Money(minorUnits: 1_000, currencyCode: "EUR", exponent: 2)
        let base = try Money(minorUnits: 1_100, currencyCode: "ALL", exponent: 2)
        let start = try dateOnly("2026-08-31")
        let rule = try repository.createRecurringRule(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: nil,
            name: "Converted",
            kind: .expense,
            isSubscription: false,
            money: original,
            manualBaseMoney: base,
            cadence: .monthly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: start,
            localTimeSeconds: 9 * 3_600 + 15 * 60
        )
        let rate = rule.rateSnapshot
        let effectiveAt = rule.rateEffectiveAt
        let baseCost = try LocalRecurrenceCalculator.normalizedCost(
            for: rule,
            baseCurrencyExponent: tracker.baseCurrencyExponent
        )
        #expect(baseCost.monthly == base)
        #expect(baseCost.annual.minorUnits == 13_200)

        try repository.updateRecurringRule(
            rule,
            tracker: tracker,
            account: account,
            category: nil,
            name: "Converted renamed",
            kind: .expense,
            isSubscription: false,
            money: original,
            manualBaseMoney: base,
            cadence: .weekly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: start,
            localTimeSeconds: 10 * 3_600 + 15 * 60
        )

        #expect(rule.rateSnapshot == rate)
        #expect(rule.rateEffectiveAt == effectiveAt)
        #expect(rule.baseAmountMinor == base.minorUnits)
        #expect(rule.nextDueAt != effectiveAt)
    }

    @Test func invalidSubscriptionAndViewerWriteRollbackCompletely() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let before = try context.fetch(FetchDescriptor<OutboxMutation>()).count

        #expect(throws: LocalLedgerError.blankName) {
            try repository.createRecurringRule(
                scopeKey: scope,
                tracker: tracker,
                account: account,
                category: nil,
                name: "Invalid",
                kind: .expense,
                isSubscription: true,
                money: Money(minorUnits: 500, currencyCode: "ALL", exponent: 2),
                cadence: .monthly,
                timeZoneIdentifier: "Europe/Tirane",
                startsOn: try dateOnly("2026-08-31"),
                localTimeSeconds: 0
            )
        }
        tracker.roleRaw = TrackerRole.viewer.rawValue
        #expect(throws: LocalLedgerError.permissionDenied) {
            try repository.createRecurringRule(
                scopeKey: scope,
                tracker: tracker,
                account: account,
                category: nil,
                name: "Forbidden",
                kind: .expense,
                isSubscription: false,
                money: Money(minorUnits: 500, currencyCode: "ALL", exponent: 2),
                cadence: .monthly,
                timeZoneIdentifier: "Europe/Tirane",
                startsOn: try dateOnly("2026-08-31"),
                localTimeSeconds: 0
            )
        }
        #expect(try context.fetch(FetchDescriptor<LocalRecurringRule>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<OutboxMutation>()).count == before)
    }

    private func dateOnly(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return try #require(formatter.date(from: value))
    }

    private func timestamp(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: LocalTracker.self,
            LocalTrackerMembership.self,
            LocalAccount.self,
            LocalCategory.self,
            LocalTag.self,
            LocalParticipant.self,
            LocalBudget.self,
            LocalBudgetCategory.self,
            LocalBudgetThreshold.self,
            LocalRecurringRule.self,
            LocalRecurringOccurrence.self,
            LocalInstallmentPlan.self,
            LocalInstallmentScheduleItem.self,
            LocalInstallmentPayment.self,
            LedgerTransaction.self,
            LocalAccountMovement.self,
            LocalCategoryAllocation.self,
            LocalTransactionTag.self,
            LocalSplitPayment.self,
            LocalSplitShare.self,
            LocalSettlement.self,
            LocalAttachment.self,
            OutboxMutation.self,
            AttachmentTransfer.self,
            SyncCursor.self,
            SyncConflict.self,
            BootstrapStagedEntity.self,
            configurations: configuration
        )
    }
}
