import SwiftData
import SwiftUI

private enum TransactionListFilter: String, CaseIterable, Identifiable {
    case all
    case expense
    case income

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All types"
        case .expense: "Expenses"
        case .income: "Income"
        }
    }
}

struct TransactionsView: View {
    let scopeKey: String

    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [LedgerTransaction]
    @State private var searchText = ""
    @State private var filter = TransactionListFilter.all
    @State private var showDeleted = false
    @State private var safeError: String?

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _transactions = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LedgerTransaction.occurredAt,
            order: .reverse
        )
    }

    private var filteredTransactions: [LedgerTransaction] {
        transactions.filter { transaction in
            let deletionMatches = showDeleted ? transaction.deletedAt != nil : transaction.deletedAt == nil
            let kindMatches = filter == .all || transaction.kindRaw == filter.rawValue
            let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches = normalizedSearch.isEmpty ||
                transaction.merchant.localizedCaseInsensitiveContains(normalizedSearch) ||
                transaction.note.localizedCaseInsensitiveContains(normalizedSearch) ||
                (transaction.money?.formatted(locale: .current) ?? "").localizedCaseInsensitiveContains(normalizedSearch)
            return deletionMatches && kindMatches && searchMatches
        }
    }

    var body: some View {
        Group {
            if filteredTransactions.isEmpty {
                ContentUnavailableView {
                    if showDeleted {
                        Label("No deleted transactions", systemImage: "trash")
                    } else {
                        Label("No transactions", systemImage: "list.bullet.rectangle")
                    }
                } description: {
                    if searchText.isEmpty {
                        Text("Transactions saved offline will appear here.")
                    } else {
                        Text("Try another search or reset the filters.")
                    }
                }
            } else {
                List(filteredTransactions) { transaction in
                    NavigationLink {
                        TransactionDetailView(scopeKey: scopeKey, transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if transaction.deletedAt == nil {
                            Button("Delete", role: .destructive) { setDeleted(transaction, true) }
                        } else {
                            Button("Restore") { setDeleted(transaction, false) }
                                .tint(LedgerTheme.positive)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(
            showDeleted ? String(localized: "Recently deleted") : String(localized: "Transactions")
        )
        .searchable(text: $searchText, prompt: "Merchant, note, or amount")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Type", selection: $filter) {
                        ForEach(TransactionListFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    Divider()
                    Toggle("Show recently deleted", isOn: $showDeleted)
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
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
        } catch {
            safeError = String(localized: "The local change could not be saved.")
        }
    }
}

struct TransactionRow: View {
    let transaction: LedgerTransaction

    private var title: String {
        if !transaction.merchant.isEmpty { return transaction.merchant }
        return transaction.kind == .income ? String(localized: "Income") : String(localized: "Expense")
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
                Text(transaction.occurredAt, format: .dateTime.day().month().year())
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
                Image(systemName: transaction.syncState == .synced ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(transaction.syncState.displayName)
            }
        }
        .opacity(transaction.deletedAt == nil ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}
