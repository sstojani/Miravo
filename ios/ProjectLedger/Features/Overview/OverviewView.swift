import SwiftData
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var transactions: [LedgerTransaction]
    @Query private var trackers: [LocalTracker]
    @Query private var accounts: [LocalAccount]
    @Query private var outbox: [OutboxMutation]

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
                    $0.archivedAt == nil &&
                    $0.accessRevokedAt == nil
            },
            sort: \LocalTracker.sortOrder
        )
        _accounts = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.deletedAt == nil && $0.archivedAt == nil
            },
            sort: \LocalAccount.name
        )
        _outbox = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.stateRaw == "pending" },
            sort: \OutboxMutation.createdAt
        )
    }

    private var monthTransactions: [LedgerTransaction] {
        guard let trackerID = trackers.first?.id,
              let interval = Calendar.current.dateInterval(of: .month, for: .now)
        else {
            return []
        }
        return transactions.filter {
            $0.trackerID == trackerID && interval.contains($0.occurredAt)
        }
    }

    private var trackerAccounts: [LocalAccount] {
        guard let trackerID = trackers.first?.id else { return [] }
        return accounts.filter { $0.trackerID == trackerID }
    }

    private var trackerTransactions: [LedgerTransaction] {
        guard let trackerID = trackers.first?.id else { return [] }
        return transactions.filter { $0.trackerID == trackerID }
    }

    private var currencySummaries: [CurrencySummary] {
        let grouped = Dictionary(grouping: monthTransactions, by: \.currencyCode)
        return grouped.map { currency, items in
            let expenseValues = items.compactMap { transaction -> Int64? in
                switch transaction.kind {
                case .expense: transaction.amountMinor
                case .refund: -transaction.amountMinor
                default: nil
                }
            }
            return CurrencySummary(
                currency: currency,
                exponent: items.first?.currencyExponent ?? 2,
                expenseMinor: safeSum(expenseValues),
                incomeMinor: safeSum(items.filter { $0.kind == .income }.map(\.amountMinor))
            )
        }
        .sorted { $0.currency < $1.currency }
    }

    private func safeSum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerTheme.contentSpacing) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This month")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(trackers.first?.name ?? String(localized: "No available tracker"))
                            .font(.title.bold())
                    }
                    Spacer()
                    SyncBadge(state: syncPresentationState)
                }

                if trackers.isEmpty {
                    ContentUnavailableView(
                        "No available tracker",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text(
                            "Create a tracker in Settings or connect to receive an invitation."
                        )
                    )
                    .ledgerCard()
                } else if currencySummaries.isEmpty {
                    ContentUnavailableView(
                        "No transactions yet",
                        systemImage: "tray",
                        description: Text("Use Add to save the first offline expense.")
                    )
                    .ledgerCard()
                } else {
                    ForEach(currencySummaries) { summary in
                        HStack(spacing: 24) {
                            AmountSummary(
                                title: "Spending",
                                value: summary.expense,
                                color: LedgerTheme.negative
                            )
                            Divider()
                            AmountSummary(
                                title: "Income",
                                value: summary.income,
                                color: LedgerTheme.positive
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .ledgerCard()
                        .accessibilityElement(children: .combine)
                    }
                }

                if !trackerAccounts.isEmpty {
                    Text("Accounts")
                        .font(.title2.bold())
                    VStack(spacing: 12) {
                        ForEach(trackerAccounts.prefix(4)) { account in
                            LabeledContent(account.name) {
                                Text(
                                    LocalBalanceCalculator.balance(
                                        for: account,
                                        transactions: trackerTransactions
                                    )?.formatted(locale: .current) ?? "—"
                                )
                                .font(.headline.monospacedDigit())
                                .minimumScaleFactor(0.7)
                            }
                        }
                    }
                    .ledgerCard()
                }

                if !trackers.isEmpty {
                    Text("Recent transactions")
                        .font(.title2.bold())

                    ForEach(trackerTransactions.prefix(5)) { transaction in
                        TransactionRow(transaction: transaction)
                            .ledgerCard()
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await sync.synchronize(session: session)
        }
        .navigationTitle("Overview")
    }

    private var syncPresentationState: SyncPresentationState {
        let diagnostics = sync.diagnostics
        return SyncPresentationState.resolve(
            isRunning: sync.isRunning || diagnostics.isSyncing,
            pendingCount: max(outbox.count, diagnostics.pendingCount),
            failedCount: diagnostics.failedCount,
            conflictCount: diagnostics.conflictCount,
            lastSuccessfulSyncAt: diagnostics.lastSuccessfulSyncAt,
            lastSafeErrorCode: diagnostics.lastSafeErrorCode
        )
    }
}

private struct CurrencySummary: Identifiable {
    let currency: String
    let exponent: Int
    let expenseMinor: Int64?
    let incomeMinor: Int64?

    var id: String { currency }
    var expense: Money? {
        guard let expenseMinor else { return nil }
        return try? Money(minorUnits: expenseMinor, currencyCode: currency, exponent: exponent)
    }

    var income: Money? {
        guard let incomeMinor else { return nil }
        return try? Money(minorUnits: incomeMinor, currencyCode: currency, exponent: exponent)
    }
}

private struct AmountSummary: View {
    let title: LocalizedStringKey
    let value: Money?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value?.formatted(locale: .current) ?? "—")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SyncBadge: View {
    let state: SyncPresentationState

    var body: some View {
        Label(title, systemImage: symbol)
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.10), in: Capsule())
    }

    private var title: String {
        switch state {
        case .syncing:
            String(localized: "Syncing")
        case let .conflict(count):
            String.localizedStringWithFormat(String(localized: "Conflict count format"), count)
        case let .failed(count):
            String.localizedStringWithFormat(String(localized: "Failed count format"), count)
        case .offline:
            String(localized: "Offline — local data available")
        case let .pending(count):
            String.localizedStringWithFormat(
                String(localized: "Pending count format"),
                String(count)
            )
        case .synced:
            String(localized: "Synced")
        case .notSynchronized:
            String(localized: "Not synchronized")
        }
    }

    private var symbol: String {
        switch state {
        case .syncing: "arrow.triangle.2.circlepath"
        case .conflict: "arrow.triangle.branch"
        case .failed: "exclamationmark.triangle"
        case .offline: "wifi.slash"
        case .pending: "clock.arrow.circlepath"
        case .synced: "checkmark.circle"
        case .notSynchronized: "icloud.slash"
        }
    }

    private var color: Color {
        switch state {
        case .synced: LedgerTheme.positive
        case .failed, .conflict: LedgerTheme.negative
        case .syncing, .offline, .pending, .notSynchronized: LedgerTheme.warning
        }
    }
}
