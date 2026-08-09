import SwiftData
import SwiftUI

struct OverviewView: View {
    @Query(
        filter: #Predicate<LedgerTransaction> { $0.deletedAt == nil },
        sort: \LedgerTransaction.occurredAt,
        order: .reverse
    ) private var transactions: [LedgerTransaction]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                GroupBox("This month") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local-first foundation")
                            .font(.headline)
                        Text("Records save on this iPhone before any network request.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Recent transactions")
                    .font(.title2.bold())

                if transactions.isEmpty {
                    ContentUnavailableView(
                        "No transactions yet",
                        systemImage: "tray",
                        description: Text("Use Add to save the first offline expense.")
                    )
                } else {
                    ForEach(transactions.prefix(5)) { transaction in
                        TransactionRow(transaction: transaction)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Overview")
    }
}

