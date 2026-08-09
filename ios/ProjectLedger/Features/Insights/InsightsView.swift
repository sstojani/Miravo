import SwiftData
import SwiftUI

struct InsightsView: View {
    @Query private var transactions: [LedgerTransaction]
    @Query private var trackers: [LocalTracker]

    init(scopeKey: String) {
        _transactions = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.deletedAt == nil && $0.statusRaw != "voided"
            },
            sort: \LedgerTransaction.occurredAt,
            order: .reverse
        )
        _trackers = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey &&
                    $0.deletedAt == nil &&
                    $0.accessRevokedAt == nil
            },
            sort: \LocalTracker.sortOrder
        )
    }

    private var visibleTransactions: [LedgerTransaction] {
        let trackerIDs = Set(trackers.map(\.id))
        return transactions.filter { trackerIDs.contains($0.trackerID) }
    }

    private var merchantCounts: [(name: String, count: Int)] {
        let expenses = visibleTransactions.filter { $0.kind == .expense }
        let grouped = Dictionary(grouping: expenses) { transaction in
            transaction.merchant.isEmpty ? String(localized: "No merchant") : transaction.merchant
        }
        return grouped.map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
            }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Locally available records", value: visibleTransactions.count, format: .number)
                LabeledContent(
                    "Pending records",
                    value: visibleTransactions.filter { $0.syncState != .synced }.count,
                    format: .number
                )
            } header: {
                Text("Local summary")
            } footer: {
                Text("Insights are calculated from records currently stored on this iPhone. Currency totals are never combined without conversion snapshots.")
            }

            Section("Frequent merchants") {
                if merchantCounts.isEmpty {
                    Text("Add an expense to begin local analysis.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(merchantCounts.prefix(8).enumerated()), id: \.offset) { _, item in
                        LabeledContent(item.name, value: item.count, format: .number)
                    }
                }
            }
        }
        .navigationTitle("Insights")
    }
}
