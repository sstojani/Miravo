import SwiftData
import SwiftUI

private struct TransactionDaySection: Identifiable {
    let day: Date
    let transactions: [LedgerTransaction]

    var id: Date { day }
}

private struct TransactionCurrencyKey: Hashable {
    let code: String
    let exponent: Int
}

struct TransactionsView: View {
    let scopeKey: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var transactions: [LedgerTransaction]
    @Query private var trackers: [LocalTracker]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @Query private var tags: [LocalTag]
    @Query private var transactionTags: [LocalTransactionTag]
    @State private var searchText = ""
    @State private var criteria = TransactionListCriteria()
    @State private var showDeleted = false
    @State private var safeError: String?
    @State private var searchDebounceTask: Task<Void, Never>?

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _transactions = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
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
        _accounts = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalAccount.name
        )
        _categories = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalCategory.sortOrder
        )
        _tags = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalTag.name
        )
        _transactionTags = Query(filter: #Predicate { $0.scopeKey == scopeKey })
    }

    private var filteredTransactions: [LedgerTransaction] {
        let visibleTrackerIDs = Set(trackers.map(\.id))
        let tagNames = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })
        let groupedTagLinks = Dictionary(grouping: transactionTags, by: \.transactionID)
        let searchContext = TransactionSearchContext(
            trackerNames: Dictionary(uniqueKeysWithValues: trackers.map { ($0.id, $0.name) }),
            accountNames: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) }),
            categoryNames: Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) }),
            tagNamesByTransaction: groupedTagLinks.mapValues { links in
                links.compactMap { tagNames[$0.tagID] }
            },
            tagIDsByTransaction: groupedTagLinks.mapValues { Set($0.map(\.tagID)) }
        )
        let now = Date.now
        let calendar = Calendar.autoupdatingCurrent
        return transactions.filter { transaction in
            let deletionMatches = showDeleted ? transaction.deletedAt != nil : transaction.deletedAt == nil
            return visibleTrackerIDs.contains(transaction.trackerID) &&
                deletionMatches &&
                criteria.matches(
                    transaction,
                    context: searchContext,
                    now: now,
                    calendar: calendar,
                    locale: .current
                )
        }
    }

    private var sections: [TransactionDaySection] {
        let calendar = Calendar.autoupdatingCurrent
        return Dictionary(grouping: filteredTransactions) {
            calendar.startOfDay(for: $0.occurredAt)
        }
        .map { TransactionDaySection(day: $0.key, transactions: $0.value) }
        .sorted { $0.day > $1.day }
    }

    private var availableFilterAccounts: [LocalAccount] {
        accounts.filter {
            $0.archivedAt == nil &&
                (criteria.trackerID == nil || $0.trackerID == criteria.trackerID)
        }
    }

    private var availableFilterCategories: [LocalCategory] {
        categories.filter {
            $0.archivedAt == nil &&
                (criteria.trackerID == nil || $0.trackerID == criteria.trackerID)
        }
    }

    private var availableFilterTags: [LocalTag] {
        tags.filter {
            $0.archivedAt == nil &&
                (criteria.trackerID == nil || $0.trackerID == criteria.trackerID)
        }
    }

    private var availableCurrencies: [String] {
        Array(Set(transactions.map(\.currencyCode))).sorted()
    }

    private var filterAccessibilityValue: String {
        let count = criteria.activeFacetCount + (showDeleted ? 1 : 0)
        guard count > 0 else { return String(localized: "No active filters") }
        return String.localizedStringWithFormat(
            String(localized: "Active filters count format"),
            count
        )
    }

    var body: some View {
        let visibleSections = sections
        Group {
            if trackers.isEmpty {
                ContentUnavailableView {
                    Label(
                        "No available trackers",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                } description: {
                    Text("Create a tracker in Settings or connect to receive an invitation.")
                }
            } else if visibleSections.isEmpty {
                ContentUnavailableView {
                    if criteria.isActive {
                        Label("No matching transactions", systemImage: "line.3.horizontal.decrease.circle")
                    } else if showDeleted {
                        Label("No deleted transactions", systemImage: "trash")
                    } else {
                        Label("No transactions", systemImage: "list.bullet.rectangle")
                    }
                } description: {
                    if criteria.isActive {
                        Text("Try another search or reset the filters.")
                    } else if showDeleted {
                        Text("Deleted transactions remain available here until restored.")
                    } else {
                        Text("Transactions saved offline will appear here.")
                    }
                } actions: {
                    if criteria.isActive || showDeleted {
                        Button("Clear filters") { resetFilters() }
                    }
                }
            } else {
                List {
                    ForEach(visibleSections) { section in
                        Section {
                            ForEach(section.transactions) { transaction in
                                NavigationLink {
                                    TransactionDetailView(
                                        scopeKey: scopeKey,
                                        transaction: transaction
                                    )
                                } label: {
                                    TransactionRow(transaction: transaction)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if canEdit(transaction: transaction) {
                                        if transaction.deletedAt == nil {
                                            Button("Delete", role: .destructive) {
                                                setDeleted(transaction, true)
                                            }
                                        } else {
                                            Button("Restore") { setDeleted(transaction, false) }
                                                .tint(LedgerTheme.positive)
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(
                                    section.day,
                                    format: .dateTime.weekday(.wide).day().month()
                                )
                                Spacer()
                                if let net = netSummary(for: section.transactions) {
                                    Text(net)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(
            showDeleted ? String(localized: "Recently deleted") : String(localized: "Transactions")
        )
        .searchable(text: $searchText, prompt: "Merchant, note, tag, account, or amount")
        .onSubmit(of: .search) { applySearchImmediately() }
        .onChange(of: searchText) { _, value in debounceSearch(value) }
        .onChange(of: criteria.trackerID) { _, _ in validateDependentFilters() }
        .onDisappear { searchDebounceTask?.cancel() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Tracker", selection: $criteria.trackerID) {
                        Text("All trackers").tag(UUID?.none)
                        ForEach(trackers) { tracker in
                            Text(tracker.name).tag(Optional(tracker.id))
                        }
                    }
                    Picker("Account", selection: $criteria.accountID) {
                        Text("All accounts").tag(UUID?.none)
                        ForEach(availableFilterAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    Picker("Category", selection: $criteria.categoryID) {
                        Text("All categories").tag(UUID?.none)
                        ForEach(availableFilterCategories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    Picker("Tag", selection: $criteria.tagID) {
                        Text("All tags").tag(UUID?.none)
                        ForEach(availableFilterTags) { tag in
                            Text(tag.name).tag(Optional(tag.id))
                        }
                    }
                    Picker("Type", selection: $criteria.kind) {
                        Text("All types").tag(TransactionKind?.none)
                        ForEach(TransactionKind.allCases, id: \.rawValue) { kind in
                            Text(kind.displayName).tag(Optional(kind))
                        }
                    }
                    Picker("Source", selection: $criteria.source) {
                        Text("All sources").tag(TransactionSource?.none)
                        ForEach(TransactionSource.allCases, id: \.rawValue) { source in
                            Text(source.displayName).tag(Optional(source))
                        }
                    }
                    Picker("Status", selection: $criteria.status) {
                        Text("All statuses").tag(TransactionStatus?.none)
                        ForEach(TransactionStatus.allCases, id: \.rawValue) { status in
                            Text(status.displayName).tag(Optional(status))
                        }
                    }
                    Picker("Sync state", selection: $criteria.syncState) {
                        Text("All sync states").tag(LocalSyncState?.none)
                        ForEach(LocalSyncState.allCases, id: \.rawValue) { state in
                            Text(state.displayName).tag(Optional(state))
                        }
                    }
                    Picker("Currency", selection: $criteria.currencyCode) {
                        Text("All currencies").tag(String?.none)
                        ForEach(availableCurrencies, id: \.self) { currency in
                            Text(currency).tag(Optional(currency))
                        }
                    }
                    Picker("Date range", selection: $criteria.dateWindow) {
                        ForEach(TransactionDateWindow.allCases) { window in
                            Text(window.displayName).tag(window)
                        }
                    }
                    Divider()
                    Toggle("Show recently deleted", isOn: $showDeleted)
                    Button("Clear filters") { resetFilters() }
                } label: {
                    Label(
                        "Filters",
                        systemImage: criteria.activeFacetCount == 0 && !showDeleted
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                    .accessibilityValue(filterAccessibilityValue)
                }
            }
        }
        .alert("Could not update transaction", isPresented: Binding(
            get: { safeError != nil },
            set: { if !$0 { safeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(safeError ?? "")
        }
    }

    private func setDeleted(_ transaction: LedgerTransaction, _ deleted: Bool) {
        do {
            try LocalLedgerRepository(context: modelContext)
                .setTransactionDeleted(transaction, deleted: deleted)
            Task { await sync.synchronize(session: session) }
        } catch {
            safeError = String(localized: "The local change could not be saved.")
        }
    }

    private func debounceSearch(_ value: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(250))
            } catch {
                return
            }
            criteria.query = value
        }
    }

    private func applySearchImmediately() {
        searchDebounceTask?.cancel()
        criteria.query = searchText
    }

    private func validateDependentFilters() {
        if !availableFilterAccounts.contains(where: { $0.id == criteria.accountID }) {
            criteria.accountID = nil
        }
        if !availableFilterCategories.contains(where: { $0.id == criteria.categoryID }) {
            criteria.categoryID = nil
        }
        if !availableFilterTags.contains(where: { $0.id == criteria.tagID }) {
            criteria.tagID = nil
        }
    }

    private func canEdit(transaction: LedgerTransaction) -> Bool {
        trackers.first { $0.id == transaction.trackerID }?.role.canEditFinancialData == true
    }

    private func resetFilters() {
        searchDebounceTask?.cancel()
        searchText = ""
        criteria = TransactionListCriteria()
        showDeleted = false
    }

    private func netSummary(for values: [LedgerTransaction]) -> String? {
        guard !showDeleted else { return nil }
        var totals: [TransactionCurrencyKey: Int64] = [:]
        for transaction in values where
            transaction.status == .posted || transaction.status == .reconciled
        {
            let signedAmount: Int64
            switch transaction.kind {
            case .expense:
                signedAmount = -transaction.amountMinor
            case .income, .refund:
                signedAmount = transaction.amountMinor
            case .transfer, .settlement:
                continue
            }
            let key = TransactionCurrencyKey(
                code: transaction.currencyCode,
                exponent: transaction.currencyExponent
            )
            let (next, overflow) = totals[key, default: 0]
                .addingReportingOverflow(signedAmount)
            guard !overflow else { return nil }
            totals[key] = next
        }
        let formatted = totals.keys.sorted { $0.code < $1.code }.compactMap { key in
            try? Money(
                minorUnits: totals[key, default: 0],
                currencyCode: key.code,
                exponent: key.exponent
            ).formatted(locale: .current)
        }
        guard !formatted.isEmpty else { return nil }
        return String.localizedStringWithFormat(
            String(localized: "Day net format"),
            formatted.joined(separator: " · ")
        )
    }
}

struct TransactionRow: View {
    let transaction: LedgerTransaction

    private var title: String {
        if !transaction.merchant.isEmpty { return transaction.merchant }
        return transaction.kind.displayName
    }

    private var symbol: String {
        switch transaction.kind {
        case .expense: "cart"
        case .income: "arrow.down.circle"
        case .transfer: "arrow.left.arrow.right"
        case .settlement: "person.2"
        case .refund: "arrow.uturn.backward.circle"
        }
    }

    private var amountColor: Color {
        transaction.kind == .income || transaction.kind == .refund ? LedgerTheme.positive : .primary
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 36, height: 36)
                .background(LedgerTheme.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(transaction.occurredAt, format: .dateTime.hour().minute())
                    if transaction.source != .manual {
                        Label(transaction.source.displayName, systemImage: sourceSymbol)
                    }
                    if transaction.status != .posted {
                        Text(transaction.status.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(transaction.money?.formatted(locale: .current) ?? "—")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(amountColor)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Image(systemName: syncSymbol)
                    .font(.caption)
                    .foregroundStyle(syncColor)
                    .accessibilityLabel(transaction.syncState.displayName)
            }
        }
        .opacity(transaction.deletedAt == nil ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private var sourceSymbol: String {
        switch transaction.source {
        case .manual: "hand.tap"
        case .shortcut: "bolt"
        case .recurring: "repeat"
        case .installment: "calendar.badge.clock"
        case .receiptScan: "doc.text.viewfinder"
        case .imported: "square.and.arrow.down"
        case .server: "server.rack"
        }
    }

    private var syncSymbol: String {
        switch transaction.syncState {
        case .pending: "clock.arrow.circlepath"
        case .syncing: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .conflicted: "arrow.triangle.branch"
        }
    }

    private var syncColor: Color {
        switch transaction.syncState {
        case .failed, .conflicted: LedgerTheme.negative
        case .pending, .syncing, .synced: .secondary
        }
    }
}
