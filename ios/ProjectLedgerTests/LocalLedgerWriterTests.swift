import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct LocalLedgerWriterTests {
    @Test func localWritePersistsTransactionAndOutboxTogether() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: LedgerTransaction.self,
            OutboxMutation.self,
            configurations: configuration
        )
        let money = try Money(minorUnits: 500, currencyCode: "ALL", exponent: 2)
        let transaction = try LocalLedgerWriter(context: container.mainContext).createExpense(
            money: money,
            merchant: "Test merchant"
        )

        let transactions = try container.mainContext.fetch(FetchDescriptor<LedgerTransaction>())
        let outbox = try container.mainContext.fetch(FetchDescriptor<OutboxMutation>())
        #expect(transactions.map(\.id) == [transaction.id])
        #expect(outbox.map(\.entityID) == [transaction.id])
    }
}

