import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct LocalBudgetTests {
    private let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"

    @Test func localCreateUpdateArchiveAndDeleteUseOneDurableOutbox() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let money = try Money(minorUnits: 25_000, currencyCode: "ALL", exponent: 2)

        let budget = try repository.createBudget(
            scopeKey: scope,
            tracker: tracker,
            name: "Groceries",
            budgetScope: .categories,
            period: .monthly,
            money: money,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: try dateOnly("2026-08-01"),
            endsOn: nil,
            rollover: true,
            categories: [category]
        )

        let macroSafeExpectation1: Bool = try {
            try context.fetch(FetchDescriptor<LocalBudget>()).map(\.id) == [budget.id]
        }()
        #expect(macroSafeExpectation1)
        let macroSafeExpectation2: Bool = try {
            try context.fetch(FetchDescriptor<LocalBudgetCategory>()).count == 1
        }()
        #expect(macroSafeExpectation2)
        let macroSafeExpectation3: Bool = try {
            try context.fetch(FetchDescriptor<LocalBudgetThreshold>()).map(\.percent) == [50, 80, 100]
        }()
        #expect(macroSafeExpectation3)
        var mutations = try budgetMutations(context: context, id: budget.id)
        #expect(mutations.map(\.command) == ["create"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let createdPayload = try decoder.decode(
            BudgetMutationPayload.self,
            from: try #require(mutations.first).payloadJSON
        )
        #expect(createdPayload.amountMinor == 25_000)
        #expect(createdPayload.startsOn == "2026-08-01")
        #expect(createdPayload.categoryIDs == [category.id])
        #expect(createdPayload.thresholdPercentages == [50, 80, 100])

        try repository.updateBudget(
            budget,
            tracker: tracker,
            name: "Food",
            budgetScope: .categories,
            period: .weekly,
            money: try Money(minorUnits: 7_500, currencyCode: "ALL", exponent: 2),
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: budget.startsOn,
            endsOn: nil,
            rollover: false,
            categories: [category]
        )
        try repository.setBudgetArchived(budget, archived: true)
        try repository.setBudgetArchived(budget, archived: false)
        try repository.deleteBudget(budget)
        mutations = try budgetMutations(context: context, id: budget.id)
        #expect(mutations.map(\.command) == ["create", "update", "archive", "restore", "delete"])
        #expect(budget.deletedAt != nil)
        #expect(budget.syncState == .pending)
    }

    @Test func invalidBudgetAndViewerWriteRollbackWithoutMutation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let before = try context.fetch(FetchDescriptor<OutboxMutation>()).count
        let money = try Money(minorUnits: 10_000, currencyCode: "ALL", exponent: 2)

        #expect(throws: LocalLedgerError.invalidReference) {
            try repository.createBudget(
                scopeKey: scope,
                tracker: tracker,
                name: "Invalid",
                budgetScope: .categories,
                period: .custom,
                money: money,
                timeZoneIdentifier: "Not/A_Zone",
                startsOn: .now,
                endsOn: nil,
                rollover: false,
                categories: [category]
            )
        }
        tracker.roleRaw = TrackerRole.viewer.rawValue
        #expect(throws: LocalLedgerError.permissionDenied) {
            try repository.createBudget(
                scopeKey: scope,
                tracker: tracker,
                name: "Forbidden",
                budgetScope: .tracker,
                period: .monthly,
                money: money,
                timeZoneIdentifier: "Europe/Tirane",
                startsOn: .now,
                endsOn: nil,
                rollover: false,
                categories: []
            )
        }
        let macroSafeExpectation4: Bool = try {
            try context.fetch(FetchDescriptor<LocalBudget>()).isEmpty
        }()
        #expect(macroSafeExpectation4)
        let macroSafeExpectation5: Bool = try {
            try context.fetch(FetchDescriptor<OutboxMutation>()).count == before
        }()
        #expect(macroSafeExpectation5)
    }

    @Test func calculatorHandlesAllocationsConversionRolloverAndDST() throws {
        let trackerID = UUID()
        let accountID = UUID()
        let categoryID = UUID()
        let budget = LocalBudget(
            scopeKey: scope,
            trackerID: trackerID,
            name: "Food",
            budgetScope: .categories,
            period: .monthly,
            money: try Money(minorUnits: 10_000, currencyCode: "EUR", exponent: 2),
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: try dateOnly("2026-01-01"),
            rollover: true
        )
        let link = LocalBudgetCategory(
            scopeKey: scope,
            budgetID: budget.id,
            categoryID: categoryID,
            categoryNameSnapshot: "Food",
            categoryVersionSnapshot: 1
        )
        let thresholds = [50, 80, 100].map {
            LocalBudgetThreshold(scopeKey: scope, budgetID: budget.id, percent: $0)
        }
        var transactions = [LedgerTransaction]()
        var allocations = [LocalCategoryAllocation]()
        for (amount, occurredAt) in [
            (6_000, "2026-01-15T10:00:00Z"),
            (12_000, "2026-02-15T10:00:00Z"),
            (3_000, "2026-03-15T10:00:00Z"),
            // UTC+2: this is 00:30 on April 1 in Europe/Tirane.
            (10_000, "2026-03-31T22:30:00Z"),
        ] {
            let transaction = try expense(
                trackerID: trackerID,
                accountID: accountID,
                money: Money(minorUnits: Int64(amount), currencyCode: "EUR", exponent: 2),
                occurredAt: timestamp(occurredAt)
            )
            transactions.append(transaction)
            allocations.append(
                LocalCategoryAllocation(
                    scopeKey: scope,
                    transactionID: transaction.id,
                    categoryID: categoryID,
                    amountMinor: Int64(amount)
                )
            )
        }

        let usd = try expense(
            trackerID: trackerID,
            accountID: accountID,
            money: Money(minorUnits: 1_000, currencyCode: "USD", exponent: 2),
            occurredAt: timestamp("2026-03-20T10:00:00Z")
        )
        usd.baseAmountMinor = 900
        usd.baseCurrencyCode = "EUR"
        usd.rateSnapshot = "0.9"
        usd.rateSource = "manual"
        transactions.append(usd)
        allocations.append(
            LocalCategoryAllocation(
                scopeKey: scope,
                transactionID: usd.id,
                categoryID: categoryID,
                amountMinor: 600
            )
        )

        let march = try LocalBudgetCalculator.calculate(
            budget: budget,
            categoryLinks: [link],
            thresholds: thresholds,
            transactions: transactions,
            allocations: allocations,
            asOf: timestamp("2026-03-20T12:00:00Z")
        )
        #expect(march.carriedMinor == 2_000)
        #expect(march.availableMinor == 12_000)
        #expect(march.spentMinor == 3_540)
        #expect(march.remainingMinor == 8_460)
        #expect(!march.isPartial)

        let april = try LocalBudgetCalculator.calculate(
            budget: budget,
            categoryLinks: [link],
            thresholds: thresholds,
            transactions: transactions,
            allocations: allocations,
            asOf: timestamp("2026-04-01T12:00:00Z")
        )
        #expect(april.spentMinor == 10_000)
        #expect(april.crossedThresholdPercent == 50)

        budget.currencyCode = "USD"
        let partial = try LocalBudgetCalculator.calculate(
            budget: budget,
            categoryLinks: [link],
            thresholds: thresholds,
            transactions: transactions,
            allocations: allocations,
            asOf: timestamp("2026-03-20T12:00:00Z")
        )
        #expect(partial.isPartial)
        #expect(partial.carriedMinor == nil)
        #expect(partial.spentMinor == 600)
        #expect(partial.unconverted.first?.currency == "EUR")
    }

    @Test func budgetSnapshotDecodesStrictFinancialFields() throws {
        let data = Data(
            #"{"id":"10000000-0000-0000-0000-000000000001","tracker_id":"20000000-0000-0000-0000-000000000002","name":"Food","scope":"categories","period":"monthly","amount_minor":25000,"currency":"EUR","currency_exponent":2,"time_zone":"Europe/Tirane","starts_on":"2026-08-01","ends_on":null,"rollover":true,"category_ids":["30000000-0000-0000-0000-000000000003"],"category_snapshots":[{"category_id":"30000000-0000-0000-0000-000000000003","name":"Groceries","version":4}],"threshold_percentages":[50,80,100],"archived_at":null,"version":2,"created_at":"2026-08-09T12:30:00Z","updated_at":"2026-08-09T12:30:00Z","deleted_at":null}"#.utf8
        )
        let snapshot = try JSONDecoder().decode(BudgetSnapshot.self, from: data)
        #expect(snapshot.amountMinor == 25_000)
        #expect(snapshot.categorySnapshots.first?.name == "Groceries")
        #expect(snapshot.thresholdPercentages == [50, 80, 100])
    }

    private func budgetMutations(context: ModelContext, id: UUID) throws -> [OutboxMutation] {
        try context.fetch(FetchDescriptor<OutboxMutation>())
            .filter { $0.entityID == id }
            .sorted { $0.localSequence < $1.localSequence }
    }

    private func expense(
        trackerID: UUID,
        accountID: UUID,
        money: Money,
        occurredAt: Date
    ) throws -> LedgerTransaction {
        LedgerTransaction(
            scopeKey: scope,
            trackerID: trackerID,
            accountID: accountID,
            kind: .expense,
            money: money,
            occurredAt: occurredAt
        )
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
