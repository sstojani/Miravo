import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct LocalLedgerRepositoryTests {
    private let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"

    @Test func bootstrapCreatesCoherentDefaultsAndOutbox() throws {
        let container = try makeContainer()
        let repository = LocalLedgerRepository(context: container.mainContext)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)

        let trackers = try container.mainContext.fetch(FetchDescriptor<LocalTracker>())
        let accounts = try container.mainContext.fetch(FetchDescriptor<LocalAccount>())
        let categories = try container.mainContext.fetch(FetchDescriptor<LocalCategory>())
        let outbox = try container.mainContext.fetch(FetchDescriptor<OutboxMutation>())

        #expect(trackers.map(\.id) == [tracker.id])
        #expect(accounts.first?.id == tracker.defaultAccountID)
        #expect(categories.first?.id == tracker.defaultCategoryID)
        #expect(outbox.count == 3)
        #expect(outbox.allSatisfy { !$0.payloadJSON.isEmpty })
        #expect(outbox.map(\.localSequence).sorted() == [1, 2, 3])
    }

    @Test func createEditDeleteAndRestoreEachAppendDurableMutation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let money = try Money(minorUnits: 500, currencyCode: "ALL", exponent: 2)

        let transaction = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: category,
            kind: .expense,
            money: money,
            merchant: "Test merchant"
        )
        let revisedMoney = try Money(minorUnits: 725, currencyCode: "ALL", exponent: 2)
        try repository.updateTransaction(
            transaction,
            tracker: tracker,
            account: account,
            category: category,
            money: revisedMoney,
            merchant: "Updated merchant",
            note: "local edit",
            occurredAt: transaction.occurredAt
        )
        try repository.setTransactionDeleted(transaction, deleted: true)
        try repository.setTransactionDeleted(transaction, deleted: false)

        let persisted = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let mutations = try context.fetch(FetchDescriptor<OutboxMutation>())
            .filter { $0.entityID == transaction.id }
            .sorted { $0.localSequence < $1.localSequence }
        #expect(persisted.map(\.id) == [transaction.id])
        #expect(transaction.amountMinor == 725)
        #expect(transaction.deletedAt == nil)
        #expect(mutations.map(\.command) == ["create", "update", "delete", "restore"])
    }

    @Test func transactionPayloadUsesIntegerMinorUnitsAndStableIdentifiers() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let money = try Money(minorUnits: 1_250, currencyCode: "ALL", exponent: 2)
        let transaction = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: nil,
            kind: .expense,
            money: money,
            merchant: "Merchant"
        )
        let mutation = try #require(
            context.fetch(FetchDescriptor<OutboxMutation>())
                .first { $0.entityID == transaction.id }
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(TransactionMutationPayload.self, from: mutation.payloadJSON)

        #expect(payload.id == transaction.id)
        #expect(payload.amountMinor == 1_250)
        #expect(payload.currency == "ALL")
        #expect(payload.trackerID == tracker.id)
        #expect(mutation.scopeKey == scope)
    }

    @Test func crossScopeReferenceIsRejectedWithoutPartialMutation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let foreign = LocalAccount(
            scopeKey: "https://other.example|20000000-0000-0000-0000-000000000002",
            trackerID: tracker.id,
            name: "Foreign",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2
        )
        context.insert(foreign)
        try context.save()
        let before = try context.fetch(FetchDescriptor<OutboxMutation>()).count

        #expect(throws: LocalLedgerError.invalidReference) {
            try repository.createTransaction(
                scopeKey: scope,
                tracker: tracker,
                account: foreign,
                category: nil,
                kind: .expense,
                money: Money(minorUnits: 100, currencyCode: "ALL", exponent: 2),
                merchant: "Rejected"
            )
        }
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<OutboxMutation>()).count == before)
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: LocalTracker.self,
            LocalAccount.self,
            LocalCategory.self,
            LedgerTransaction.self,
            OutboxMutation.self,
            SyncCursor.self,
            configurations: configuration
        )
    }
}
