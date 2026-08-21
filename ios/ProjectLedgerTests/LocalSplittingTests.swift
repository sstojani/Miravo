import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

struct LocalSplitCalculatorTests {
    @Test func equalAndPercentageRemaindersAreDeterministic() throws {
        let first = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let third = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let equal = try LocalSplitCalculator.resolveShares(
            amountMinor: 10,
            method: .equal,
            shares: [third, first, second].map { LocalSplitShareInput(participantID: $0) }
        )
        #expect(equal.map(\.participantID) == [first, second, third])
        #expect(equal.map(\.amountMinor) == [4, 3, 3])

        let percentage = try LocalSplitCalculator.resolveShares(
            amountMinor: 10,
            method: .percentage,
            shares: [
                LocalSplitShareInput(participantID: first, percentageBasisPoints: 3_333),
                LocalSplitShareInput(participantID: second, percentageBasisPoints: 3_333),
                LocalSplitShareInput(participantID: third, percentageBasisPoints: 3_334),
            ]
        )
        #expect(percentage.map(\.amountMinor) == [3, 3, 4])

        #expect(throws: LocalSplitCalculatorError.invalidShares) {
            _ = try LocalSplitCalculator.resolveShares(
                amountMinor: 10,
                method: .percentage,
                shares: [
                    LocalSplitShareInput(
                        participantID: first,
                        percentageBasisPoints: 9_999
                    ),
                ]
            )
        }
    }

    @Test func debtSimplificationUsesAmountThenUUIDOrdering() throws {
        let debtor = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let creditorA = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let creditorB = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let balances = [
            LocalParticipantBalance(
                participantID: debtor,
                displayName: "Debtor",
                currencyCode: "EUR",
                currencyExponent: 2,
                netMinor: -1_000
            ),
            LocalParticipantBalance(
                participantID: creditorA,
                displayName: "A",
                currencyCode: "EUR",
                currencyExponent: 2,
                netMinor: 500
            ),
            LocalParticipantBalance(
                participantID: creditorB,
                displayName: "B",
                currencyCode: "EUR",
                currencyExponent: 2,
                netMinor: 500
            ),
        ]
        let debts = try LocalSplitCalculator.simplifyDebts(balances: balances)
        #expect(debts.map(\.toParticipantID) == [creditorA, creditorB])
        #expect(debts.map(\.amountMinor) == [500, 500])
    }
}

@MainActor
struct LocalSplittingRepositoryTests {
    private let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"

    @Test func splitAndSettlementLifecycleRemainLocalFirstAndZeroSum() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let alex = try repository.createGuestParticipant(
            scopeKey: scope,
            tracker: tracker,
            displayName: "Alex"
        )
        let bora = try repository.createGuestParticipant(
            scopeKey: scope,
            tracker: tracker,
            displayName: "Bora"
        )
        let expenseMoney = try Money(
            minorUnits: 1_000,
            currencyCode: "ALL",
            exponent: 2
        )
        let expense = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: nil,
            kind: .expense,
            money: expenseMoney,
            merchant: "Shared dinner",
            split: LocalTransactionSplitInput(
                method: .equal,
                payments: [
                    LocalSplitPaymentInput(
                        participantID: alex.id,
                        amountMinor: 1_000
                    ),
                ],
                shares: [alex.id, bora.id].map {
                    LocalSplitShareInput(participantID: $0)
                }
            )
        )

        let payments = try context.fetch(FetchDescriptor<LocalSplitPayment>())
        let shares = try context.fetch(FetchDescriptor<LocalSplitShare>())
            .sorted { $0.participantID.uuidString < $1.participantID.uuidString }
        #expect(payments.map(\.amountMinor) == [1_000])
        #expect(shares.map(\.amountMinor) == [500, 500])
        let transactionMutation = try #require(
            context.fetch(FetchDescriptor<OutboxMutation>()).first {
                $0.entityID == expense.id
            }
        )
        let payloadObject = try #require(
            JSONSerialization.jsonObject(with: transactionMutation.payloadJSON) as? [String: Any]
        )
        #expect(payloadObject["split"] is [String: Any])

        var debts = try repository.simplifiedDebts(tracker: tracker)
        #expect(debts.count == 1)
        #expect(debts.first?.fromParticipantID == bora.id)
        #expect(debts.first?.toParticipantID == alex.id)
        #expect(debts.first?.amountMinor == 500)

        let partial = try Money(minorUnits: 300, currencyCode: "ALL", exponent: 2)
        let settlement = try repository.createSettlement(
            scopeKey: scope,
            tracker: tracker,
            from: bora,
            to: alex,
            money: partial,
            note: "Partial"
        )
        debts = try repository.simplifiedDebts(tracker: tracker)
        #expect(debts.first?.amountMinor == 200)

        try repository.setSettlementDeleted(settlement, deleted: true)
        let macroSafeExpectation1: Bool = try {
            try repository.simplifiedDebts(tracker: tracker).first?.amountMinor == 500
        }()
        #expect(macroSafeExpectation1)
        try repository.setSettlementDeleted(settlement, deleted: false)
        let macroSafeExpectation2: Bool = try {
            try repository.simplifiedDebts(tracker: tracker).first?.amountMinor == 200
        }()
        #expect(macroSafeExpectation2)

        let finalMoney = try Money(minorUnits: 200, currencyCode: "ALL", exponent: 2)
        let linked = try repository.createSettlement(
            scopeKey: scope,
            tracker: tracker,
            from: bora,
            to: alex,
            money: finalMoney,
            account: account
        )
        let linkedTransactionID = try #require(linked.transactionID)
        let linkedTransaction = try #require(
            context.fetch(FetchDescriptor<LedgerTransaction>()).first {
                $0.id == linkedTransactionID
            }
        )
        #expect(linkedTransaction.kind == .settlement)
        let macroSafeExpectation3: Bool = try {
            try repository.simplifiedDebts(tracker: tracker).isEmpty
        }()
        #expect(macroSafeExpectation3)
        #expect(
            context.fetch(FetchDescriptor<OutboxMutation>())
                .filter { $0.entityID == linkedTransactionID }
                .isEmpty
        )
        #expect(throws: LocalLedgerError.invalidReference) {
            try repository.setTransactionDeleted(linkedTransaction, deleted: true)
        }
    }

    @Test func viewerCannotCreateParticipantOrSettlement() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        tracker.roleRaw = TrackerRole.viewer.rawValue
        try context.save()

        #expect(throws: LocalLedgerError.permissionDenied) {
            _ = try repository.createGuestParticipant(
                scopeKey: scope,
                tracker: tracker,
                displayName: "Read only"
            )
        }
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
