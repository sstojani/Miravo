import Foundation
import SwiftData

@MainActor
struct LocalLedgerWriter {
    let context: ModelContext

    @discardableResult
    func createExpense(
        money: Money,
        merchant: String,
        occurredAt: Date = .now
    ) throws -> LedgerTransaction {
        let transaction = LedgerTransaction(
            kind: .expense,
            money: money,
            merchant: merchant,
            occurredAt: occurredAt
        )
        let outbox = OutboxMutation(
            entityID: transaction.id,
            entityType: "transaction",
            command: "create"
        )
        context.insert(transaction)
        context.insert(outbox)
        do {
            try context.save()
            return transaction
        } catch {
            context.rollback()
            throw error
        }
    }
}

