import SwiftData
import SwiftUI

struct TransactionDetailView: View {
    let scopeKey: String
    let transaction: LedgerTransaction

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var trackers: [LocalTracker]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @State private var showingEditor = false
    @State private var safeError: String?

    init(scopeKey: String, transaction: LedgerTransaction) {
        self.scopeKey = scopeKey
        self.transaction = transaction
        _trackers = Query(filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil })
        _accounts = Query(filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil })
        _categories = Query(filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil })
    }

    private var trackerName: String {
        trackers.first { $0.id == transaction.trackerID }?.name ?? String(localized: "Unknown tracker")
    }

    private var accountName: String {
        accounts.first { $0.id == transaction.accountID }?.name ?? String(localized: "Unknown account")
    }

    private var categoryName: String {
        guard let categoryID = transaction.categoryID else { return String(localized: "Uncategorized") }
        return categories.first { $0.id == categoryID }?.name ?? String(localized: "Unknown category")
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Text(transaction.money?.formatted(locale: .current) ?? "—")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(transaction.merchant.isEmpty ? String(localized: "No merchant or payee") : transaction.merchant)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }

            Section("Details") {
                LabeledContent("Type", value: transaction.kind.displayName)
                LabeledContent("Tracker", value: trackerName)
                LabeledContent("Account", value: accountName)
                LabeledContent("Category", value: categoryName)
                LabeledContent("Date") {
                    Text(transaction.occurredAt, format: .dateTime.day().month().year().hour().minute())
                }
                LabeledContent("Sync state", value: transaction.syncState.displayName)
            }

            if !transaction.note.isEmpty {
                Section("Note") { Text(transaction.note) }
            }

            Section {
                Button("Duplicate") { duplicate() }
                Button {
                    setDeleted(transaction.deletedAt == nil)
                } label: {
                    if transaction.deletedAt == nil {
                        Text("Delete")
                    } else {
                        Text("Restore")
                    }
                }
                .foregroundStyle(transaction.deletedAt == nil ? LedgerTheme.negative : LedgerTheme.positive)
            }
        }
        .navigationTitle("Transaction")
        .toolbar {
            if transaction.deletedAt == nil {
                Button("Edit") { showingEditor = true }
            }
        }
        .sheet(isPresented: $showingEditor) {
            TransactionEditorView(
                transaction: transaction,
                trackers: trackers,
                accounts: accounts,
                categories: categories
            )
        }
        .alert("Could not save", isPresented: Binding(
            get: { safeError != nil },
            set: { if !$0 { safeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(safeError ?? "")
        }
    }

    private func duplicate() {
        do {
            try LocalLedgerRepository(context: modelContext).duplicate(transaction)
        } catch {
            safeError = String(localized: "The local change could not be saved.")
        }
    }

    private func setDeleted(_ deleted: Bool) {
        do {
            try LocalLedgerRepository(context: modelContext)
                .setTransactionDeleted(transaction, deleted: deleted)
            if deleted { dismiss() }
        } catch {
            safeError = String(localized: "The local change could not be saved.")
        }
    }
}

private struct TransactionEditorView: View {
    let transaction: LedgerTransaction
    let trackers: [LocalTracker]
    let accounts: [LocalAccount]
    let categories: [LocalCategory]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var merchant: String
    @State private var note: String
    @State private var occurredAt: Date
    @State private var accountID: UUID
    @State private var categoryID: UUID?
    @State private var safeError: String?

    init(
        transaction: LedgerTransaction,
        trackers: [LocalTracker],
        accounts: [LocalAccount],
        categories: [LocalCategory]
    ) {
        self.transaction = transaction
        self.trackers = trackers
        self.accounts = accounts
        self.categories = categories
        _amount = State(
            initialValue: transaction.money?.editableMajorUnits(locale: .current) ?? ""
        )
        _merchant = State(initialValue: transaction.merchant)
        _note = State(initialValue: transaction.note)
        _occurredAt = State(initialValue: transaction.occurredAt)
        _accountID = State(initialValue: transaction.accountID)
        _categoryID = State(initialValue: transaction.categoryID)
    }

    private var availableAccounts: [LocalAccount] {
        accounts.filter { $0.trackerID == transaction.trackerID && $0.archivedAt == nil }
    }

    private var availableCategories: [LocalCategory] {
        let expected: LocalCategoryKind = transaction.kind == .income ? .income : .expense
        return categories.filter {
            $0.trackerID == transaction.trackerID && $0.kind == expected && $0.archivedAt == nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Amount", text: $amount)
                    .keyboardType(.decimalPad)
                    .font(.title.bold().monospacedDigit())
                Picker("Account", selection: $accountID) {
                    ForEach(availableAccounts) { account in
                        Text(account.name).tag(account.id)
                    }
                }
                Picker("Category", selection: $categoryID) {
                    Text("Uncategorized").tag(UUID?.none)
                    ForEach(availableCategories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                TextField("Merchant or payee", text: $merchant)
                TextField("Note", text: $note, axis: .vertical)
                DatePicker("Date", selection: $occurredAt)
                if let safeError {
                    Text(safeError).foregroundStyle(LedgerTheme.negative)
                }
            }
            .navigationTitle("Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        guard let tracker = trackers.first(where: { $0.id == transaction.trackerID }),
              let account = availableAccounts.first(where: { $0.id == accountID })
        else {
            safeError = String(localized: "Choose a valid tracker and account.")
            return
        }
        do {
            let money = try Money.positive(
                majorUnits: amount,
                currencyCode: account.currencyCode,
                exponent: account.currencyExponent,
                locale: .current
            )
            let category = availableCategories.first { $0.id == categoryID }
            try LocalLedgerRepository(context: modelContext).updateTransaction(
                transaction,
                tracker: tracker,
                account: account,
                category: category,
                money: money,
                merchant: merchant,
                note: note,
                occurredAt: occurredAt
            )
            dismiss()
        } catch {
            safeError = String(localized: "Enter valid transaction details.")
        }
    }
}
