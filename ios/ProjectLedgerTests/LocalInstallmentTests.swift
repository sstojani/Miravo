import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct LocalInstallmentTests {
    private let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"

    @Test func scheduleMatchesServerRemaindersAndOriginalMonthAnchor() throws {
        #expect(try LocalInstallmentCalculator.scheduleItemID(
            planID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            revisionNumber: 1,
            sequence: 1
        ) == UUID(uuidString: "6aeb1cec-6102-510c-975b-96cdfc43718e"))
        let schedule = try LocalInstallmentCalculator.buildSchedule(
            principalMinor: 1_000,
            interestMinor: 101,
            feesMinor: 1,
            installmentCount: 3,
            plannedInstallmentMinor: nil,
            cadence: .monthly,
            startsOn: try dateOnly("2026-01-31")
        )

        #expect(schedule.map(\.totalMinor) == [367, 367, 368])
        #expect(schedule.reduce(0) { $0 + $1.principalMinor } == 1_000)
        #expect(schedule.reduce(0) { $0 + $1.interestMinor } == 101)
        #expect(schedule.reduce(0) { $0 + $1.feesMinor } == 1)
        #expect(schedule.map { BudgetDateCodec.string(from: $0.dueOn) } == [
            "2026-01-31", "2026-02-28", "2026-03-31",
        ])

        let fixed = try LocalInstallmentCalculator.buildSchedule(
            principalMinor: 1_000,
            interestMinor: 101,
            feesMinor: 1,
            installmentCount: 3,
            plannedInstallmentMinor: 400,
            cadence: .weekly,
            startsOn: try dateOnly("2026-01-31")
        )
        #expect(fixed.map(\.totalMinor) == [400, 400, 302])
        #expect(throws: InstallmentCalculationError.invalidConfiguration) {
            try LocalInstallmentCalculator.buildSchedule(
                principalMinor: 1,
                interestMinor: 0,
                feesMinor: 0,
                installmentCount: 2,
                plannedInstallmentMinor: nil,
                cadence: .monthly,
                startsOn: try dateOnly("2026-01-31")
            )
        }
    }

    @Test func localTermsAndScheduleActionsAreAtomicAndVersioned() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let plan = try repository.createInstallmentPlan(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: category,
            name: "Laptop",
            principal: try Money(minorUnits: 1_000, currencyCode: "ALL", exponent: 2),
            interestMinor: 100,
            feesMinor: 2,
            installmentCount: 2,
            cadence: .monthly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: try dateOnly("2026-01-31")
        )
        #expect(plan.plannedTotalMinor == 1_102)
        #expect(plan.revisionNumber == 1)

        try repository.updateInstallmentPlan(
            plan,
            tracker: tracker,
            account: account,
            category: category,
            name: "Laptop plan",
            principal: try Money(minorUnits: 1_000, currencyCode: "ALL", exponent: 2),
            interestMinor: 100,
            feesMinor: 2,
            installmentCount: 3,
            plannedInstallmentMinor: nil,
            cadence: .monthly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: try dateOnly("2026-01-31")
        )
        var schedule = try context.fetch(FetchDescriptor<LocalInstallmentScheduleItem>())
        #expect(plan.revisionNumber == 2)
        #expect(schedule.filter { $0.supersededAt == nil }.count == 3)
        #expect(schedule.filter { $0.supersededAt != nil }.count == 2)

        let first = try #require(
            schedule.filter { $0.supersededAt == nil }.sorted { $0.sequence < $1.sequence }.first
        )
        try repository.rescheduleInstallmentPayment(
            first,
            in: plan,
            dueOn: try dateOnly("2026-02-05")
        )
        #expect(plan.revisionNumber == 3)
        #expect(BudgetDateCodec.string(from: first.dueOn) == "2026-02-05")

        try repository.skipInstallmentPayment(first, in: plan)
        schedule = try context.fetch(FetchDescriptor<LocalInstallmentScheduleItem>())
        let replacement = try #require(
            schedule.filter { $0.supersededAt == nil }.max { $0.sequence < $1.sequence }
        )
        #expect(plan.revisionNumber == 4)
        #expect(first.state == .skipped)
        #expect(replacement.sequence == 4)
        #expect(BudgetDateCodec.string(from: replacement.dueOn) == "2026-04-30")

        let commands = try context.fetch(FetchDescriptor<OutboxMutation>())
            .filter { $0.entityID == plan.id }
            .sorted { $0.localSequence < $1.localSequence }
            .map(\.command)
        #expect(commands == ["create", "update", "reschedule_payment", "skip_payment"])
    }

    @Test func offlinePaymentsCreatePendingLedgerEffectsWithoutInventingHistory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let plan = try repository.createInstallmentPlan(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: category,
            name: "Phone",
            principal: try Money(minorUnits: 1_000, currencyCode: "ALL", exponent: 2),
            installmentCount: 2,
            cadence: .monthly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: try dateOnly("2026-08-31")
        )
        let items = try context.fetch(FetchDescriptor<LocalInstallmentScheduleItem>())
            .sorted { $0.sequence < $1.sequence }
        let transactionID = UUID()
        let paymentID = UUID()

        #expect(throws: LocalLedgerError.invalidReference) {
            try repository.recordInstallmentPayment(
                in: plan,
                tracker: tracker,
                account: account,
                scheduleItem: nil,
                amount: Money(minorUnits: 1_001, currencyCode: "ALL", exponent: 2),
                extraPayment: true,
                confirmOverpayment: false
            )
        }
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)

        let first = try repository.recordInstallmentPayment(
            in: plan,
            tracker: tracker,
            account: account,
            scheduleItem: items[0],
            amount: try Money(minorUnits: 400, currencyCode: "ALL", exponent: 2),
            occurredAt: try timestamp("2026-08-31T10:00:00Z"),
            paymentID: paymentID,
            transactionID: transactionID
        )
        #expect(first.source == .installment)
        #expect(first.syncState == .pending)
        #expect(items[0].paidMinor == 400)
        #expect(items[0].state == .partiallyPaid)
        #expect(try context.fetch(FetchDescriptor<LocalInstallmentPayment>()).isEmpty)
        let movement = try #require(
            context.fetch(FetchDescriptor<LocalAccountMovement>())
                .first { $0.transactionID == transactionID }
        )
        #expect(movement.signedAmountMinor == -400)

        _ = try repository.recordInstallmentPayment(
            in: plan,
            tracker: tracker,
            account: account,
            scheduleItem: nil,
            amount: try Money(minorUnits: 600, currencyCode: "ALL", exponent: 2),
            occurredAt: try timestamp("2026-09-01T10:00:00Z"),
            extraPayment: true
        )
        #expect(plan.state == .paidOff)
        #expect(items.allSatisfy { $0.state == .paid })

        let paymentMutations = try context.fetch(FetchDescriptor<OutboxMutation>())
            .filter {
                $0.entityID == plan.id &&
                    $0.command == LocalMutationCommand.recordPayment.rawValue
            }
            .sorted { $0.localSequence < $1.localSequence }
        #expect(paymentMutations.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(
            InstallmentPlanMutationPayload.self,
            from: try #require(paymentMutations.first).payloadJSON
        )
        #expect(payload.paymentID == paymentID)
        #expect(payload.transactionID == transactionID)
        #expect(payload.paymentAmountMinor == 400)
        #expect(payload.scheduleItemID == items[0].id)
        #expect(payload.rateSource == "identity")

        #expect(throws: LocalLedgerError.invalidReference) {
            try repository.updateInstallmentPlan(
                plan,
                tracker: tracker,
                account: account,
                category: category,
                name: "Changed terms",
                principal: Money(minorUnits: 1_100, currencyCode: "ALL", exponent: 2),
                interestMinor: 0,
                feesMinor: 0,
                installmentCount: 2,
                plannedInstallmentMinor: nil,
                cadence: .monthly,
                timeZoneIdentifier: "Europe/Tirane",
                startsOn: try dateOnly("2026-08-31")
            )
        }
    }

    @Test func payoffAndViewerBoundariesRemainLocalFirst() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let plan = try repository.createInstallmentPlan(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: nil,
            name: "Course",
            principal: try Money(minorUnits: 900, currencyCode: "ALL", exponent: 2),
            installmentCount: 3,
            cadence: .weekly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: try dateOnly("2026-08-13")
        )

        let payoff = try repository.payOffInstallmentPlan(
            plan,
            tracker: tracker,
            account: account,
            occurredAt: try timestamp("2026-08-13T12:00:00Z")
        )
        #expect(payoff.amountMinor == 900)
        #expect(plan.state == .paidOff)
        let mutation = try #require(
            context.fetch(FetchDescriptor<OutboxMutation>())
                .first { $0.entityID == plan.id && $0.command == "payoff" }
        )
        #expect(mutation.baseServerVersion == nil)

        tracker.roleRaw = TrackerRole.viewer.rawValue
        let before = try context.fetch(FetchDescriptor<OutboxMutation>()).count
        #expect(throws: LocalLedgerError.permissionDenied) {
            try repository.createInstallmentPlan(
                scopeKey: scope,
                tracker: tracker,
                account: account,
                category: nil,
                name: "Forbidden",
                principal: Money(minorUnits: 100, currencyCode: "ALL", exponent: 2),
                installmentCount: 1,
                cadence: .monthly,
                timeZoneIdentifier: "Europe/Tirane",
                startsOn: try dateOnly("2026-08-13")
            )
        }
        #expect(try context.fetch(FetchDescriptor<OutboxMutation>()).count == before)
    }

    @Test func crossCurrencyAccountAmountMustBeExplicitAndIsPreserved() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let euroAccount = try repository.createAccount(
            scopeKey: scope,
            tracker: tracker,
            name: "Euro card",
            type: .credit,
            currencyCode: "EUR",
            currencyExponent: 2
        )
        let plan = try repository.createInstallmentPlan(
            scopeKey: scope,
            tracker: tracker,
            account: euroAccount,
            category: nil,
            name: "Appliance",
            principal: try Money(minorUnits: 1_000, currencyCode: "ALL", exponent: 2),
            installmentCount: 2,
            cadence: .monthly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: try dateOnly("2026-08-13")
        )
        let item = try #require(
            context.fetch(FetchDescriptor<LocalInstallmentScheduleItem>())
                .first { $0.planID == plan.id && $0.sequence == 1 }
        )

        #expect(throws: MoneyError.conversionRequired) {
            try repository.recordInstallmentPayment(
                in: plan,
                tracker: tracker,
                account: euroAccount,
                scheduleItem: item,
                amount: Money(minorUnits: 500, currencyCode: "ALL", exponent: 2)
            )
        }
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)

        let transaction = try repository.recordInstallmentPayment(
            in: plan,
            tracker: tracker,
            account: euroAccount,
            scheduleItem: item,
            amount: try Money(minorUnits: 500, currencyCode: "ALL", exponent: 2),
            accountMoney: try Money(minorUnits: 450, currencyCode: "EUR", exponent: 2)
        )
        let movement = try #require(
            context.fetch(FetchDescriptor<LocalAccountMovement>())
                .first { $0.transactionID == transaction.id }
        )
        #expect(transaction.amountMinor == 500)
        #expect(transaction.accountAmountMinor == 450)
        #expect(movement.signedAmountMinor == -450)
        #expect(movement.currencyCode == "EUR")
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
            OutboxMutation.self,
            AttachmentTransfer.self,
            SyncCursor.self,
            SyncConflict.self,
            BootstrapStagedEntity.self,
            configurations: configuration
        )
    }
}
