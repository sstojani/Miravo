import SwiftData
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var rawTransactions: [LedgerTransaction]
    @Query private var rawTrackers: [LocalTracker]
    @Query private var rawAccounts: [LocalAccount]
    @Query private var rawCategories: [LocalCategory]
    @Query private var rawAllocations: [LocalCategoryAllocation]
    @Query private var rawOutbox: [OutboxMutation]

    init(scopeKey: String) {
        _rawTransactions = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LedgerTransaction.occurredAt,
            order: .reverse
        )
        _rawTrackers = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LocalTracker.sortOrder
        )
        _rawAccounts = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LocalAccount.name
        )
        _rawCategories = Query(filter: #Predicate { $0.scopeKey == scopeKey })
        _rawAllocations = Query(filter: #Predicate { $0.scopeKey == scopeKey })
        _rawOutbox = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \OutboxMutation.createdAt
        )
    }

    private var transactions: [LedgerTransaction] {
        rawTransactions.filter { transaction in
            transaction.deletedAt == nil && transaction.statusRaw != "voided"
        }
    }

    private var trackers: [LocalTracker] {
        rawTrackers.filter { tracker in
            tracker.deletedAt == nil &&
                tracker.archivedAt == nil &&
                tracker.accessRevokedAt == nil
        }
    }

    private var accounts: [LocalAccount] {
        rawAccounts.filter { account in
            account.deletedAt == nil && account.archivedAt == nil
        }
    }

    private var outbox: [OutboxMutation] {
        rawOutbox.filter { $0.stateRaw == "pending" }
    }

    private var selectedTracker: LocalTracker? {
        trackers.first { tracker in
            transactions.contains { $0.trackerID == tracker.id }
        } ?? trackers.first { tracker in
            accounts.contains { $0.trackerID == tracker.id }
        } ?? trackers.first
    }

    private var monthTransactions: [LedgerTransaction] {
        guard let trackerID = selectedTracker?.id,
              let interval = AnalyticsRangePreset.thisMonth.interval(
                  asOf: .now,
                  calendar: AnalyticsReportingCalendar.make()
              )
        else {
            return []
        }
        return transactions.filter {
            $0.trackerID == trackerID && interval.contains($0.occurredAt)
        }
    }

    private var trackerAccounts: [LocalAccount] {
        guard let trackerID = selectedTracker?.id else { return [] }
        return accounts.filter { $0.trackerID == trackerID }
    }

    private var trackerTransactions: [LedgerTransaction] {
        guard let trackerID = selectedTracker?.id else { return [] }
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

    private var spendingSnapshotResult: Result<LocalAnalyticsSnapshot, Error>? {
        guard let tracker = selectedTracker else { return nil }
        let now = Date()
        let calendar = AnalyticsReportingCalendar.make()
        guard let interval = AnalyticsRangePreset.thisMonth.interval(asOf: now, calendar: calendar)
        else { return nil }
        let currentRecords = rawTransactions.filter {
            $0.trackerID == tracker.id && interval.contains($0.occurredAt)
        }
        guard currentRecords.contains(where: {
            ($0.kind == .expense || $0.kind == .refund) &&
                ($0.status == .posted || $0.status == .reconciled) &&
                $0.deletedAt == nil
        }) else { return nil }
        let originalIDs = Set(currentRecords.compactMap(\.refundOfID))
        let reportRecords = rawTransactions.filter {
            $0.trackerID == tracker.id &&
                (interval.contains($0.occurredAt) || originalIDs.contains($0.id))
        }
        return Result {
            try LocalAnalyticsSnapshotFactory.calculate(
                tracker: tracker,
                reportingCurrencyCode: tracker.baseCurrencyCode,
                reportingCurrencyExponent: tracker.baseCurrencyExponent,
                range: .thisMonth,
                transactions: reportRecords,
                categories: rawCategories,
                allocations: rawAllocations,
                asOf: now,
                calendar: calendar
            )
        }
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
                        Text(selectedTracker?.name ?? String(localized: "No available tracker"))
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

                if let spendingSnapshotResult {
                    switch spendingSnapshotResult {
                    case let .success(snapshot):
                        SpendingCategoriesCard(snapshot: snapshot, categories: rawCategories)
                    case .failure:
                        ContentUnavailableView(
                            "Spending breakdown unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("The local report could not be calculated.")
                        )
                        .ledgerCard()
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

private struct SpendingCategoriesCard: View {
    let snapshot: LocalAnalyticsSnapshot
    let categories: [LocalCategory]

    private var leadingCategories: [LocalAnalyticsBreakdownItem] {
        Array(snapshot.categories.filter { $0.amountMinor > 0 }.sorted {
            if $0.amountMinor != $1.amountMinor { return $0.amountMinor > $1.amountMinor }
            return $0.name < $1.name
        }.prefix(4))
    }

    var body: some View {
        if !leadingCategories.isEmpty || snapshot.isPartial {
            VStack(alignment: .leading, spacing: LedgerTheme.contentSpacing) {
                Text("Spending by category")
                    .font(.headline)

                if let largest = leadingCategories.first?.amountMinor {
                    ForEach(leadingCategories) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(categoryName(item))
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer(minLength: 4)
                                    Text(formatted(item.amountMinor))
                                        .font(.subheadline.monospacedDigit())
                                        .lineLimit(1)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(categoryName(item))
                                        .font(.subheadline.weight(.medium))
                                    Text(formatted(item.amountMinor))
                                        .font(.subheadline.monospacedDigit())
                                }
                            }
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(Color(uiColor: .tertiarySystemFill))
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(categoryColor(item))
                                            .frame(width: max(
                                                4,
                                                geometry.size.width * CGFloat(
                                                    Double(item.amountMinor) / Double(largest)
                                                )
                                            ))
                                    }
                            }
                            .frame(height: 8)
                            .accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    Text("No converted spending this month.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if snapshot.categories.filter({ $0.amountMinor > 0 }).count > 4 {
                    Text("Top four categories shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if snapshot.isPartial {
                    Label(
                        "Some spending could not be converted.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(LedgerTheme.warning)
                }
            }
            .ledgerCard()
        }
    }

    private func categoryName(_ item: LocalAnalyticsBreakdownItem) -> String {
        item.name.isEmpty ? String(localized: "Uncategorized") : item.name
    }

    private func formatted(_ amountMinor: Int64) -> String {
        (try? Money(
            minorUnits: amountMinor,
            currencyCode: snapshot.reportingCurrencyCode,
            exponent: snapshot.reportingCurrencyExponent
        ))?.formatted(locale: .current) ?? "—"
    }

    private func categoryColor(_ item: LocalAnalyticsBreakdownItem) -> Color {
        guard let id = UUID(uuidString: item.id),
              let category = categories.first(where: { $0.id == id }),
              let color = Color(ledgerHex: category.colorHex)
        else { return LedgerTheme.accent }
        return color
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
