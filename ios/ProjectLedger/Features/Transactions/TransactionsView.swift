import SwiftData
import SwiftUI

struct TransactionsView: View {
    @Query(
        filter: #Predicate<LedgerTransaction> { $0.deletedAt == nil },
        sort: \LedgerTransaction.occurredAt,
        order: .reverse
    ) private var transactions: [LedgerTransaction]

    var body: some View {
        Group {
            if transactions.isEmpty {
                ContentUnavailableView(
                    "No transactions",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Transactions saved offline will appear here.")
                )
            } else {
                List(transactions) { transaction in
                    TransactionRow(transaction: transaction)
                }
            }
        }
        .navigationTitle("Transactions")
    }
}

struct TransactionRow: View {
    let transaction: LedgerTransaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cart")
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(transaction.merchant.isEmpty ? String(localized: "Expense") : transaction.merchant)
                    .font(.headline)
                Text(transaction.occurredAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(transaction.money?.formatted(locale: .current) ?? "—")
                    .font(.headline.monospacedDigit())
                Label(transaction.syncStateRaw, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

