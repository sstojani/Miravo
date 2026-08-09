import SwiftData
import SwiftUI

struct TransactionDetailView: View {
    let scopeKey: String
    let transaction: LedgerTransaction

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var trackers: [LocalTracker]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @Query private var transactions: [LedgerTransaction]
    @State private var showingEditor = false
    @State private var showingRefund = false
    @State private var safeError: String?

    init(scopeKey: String, transaction: LedgerTransaction) {
        self.scopeKey = scopeKey
        self.transaction = transaction
        _trackers = Query(filter: #Predicate {
            $0.scopeKey == scopeKey &&
                $0.deletedAt == nil &&
                $0.accessRevokedAt == nil
        })
        _accounts = Query(filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil })
        _categories = Query(filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil })
        _transactions = Query(filter: #Predicate { $0.scopeKey == scopeKey })
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

    private var destinationAccountName: String? {
        guard let destinationAccountID = transaction.destinationAccountID else { return nil }
        return accounts.first { $0.id == destinationAccountID }?.name ??
            String(localized: "Unknown account")
    }

    private var refundOriginal: LedgerTransaction? {
        guard let refundOfID = transaction.refundOfID else { return nil }
        return transactions.first { $0.id == refundOfID }
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
                if let destinationAccountName {
                    LabeledContent("To account", value: destinationAccountName)
                }
                if transaction.kind != .transfer {
                    LabeledContent("Category", value: categoryName)
                }
                if transaction.currencyCode != transaction.baseCurrencyCode {
                    LabeledContent("Base amount") {
                        Text(
                            (try? Money(
                                minorUnits: transaction.baseAmountMinor,
                                currencyCode: transaction.baseCurrencyCode,
                                exponent: trackers.first {
                                    $0.id == transaction.trackerID
                                }?.baseCurrencyExponent ?? 2
                            ))?.formatted(locale: .current) ?? "—"
                        )
                    }
                    LabeledContent("Rate source", value: transaction.rateSource)
                }
                if let refundOriginal {
                    LabeledContent("Refund of") {
                        Text(
                            refundOriginal.merchant.isEmpty
                                ? String(localized: "Original expense")
                                : refundOriginal.merchant
                        )
                    }
                }
                LabeledContent("Date") {
                    Text(transaction.occurredAt, format: .dateTime.day().month().year().hour().minute())
                }
                LabeledContent("Sync state", value: transaction.syncState.displayName)
            }

            if !transaction.note.isEmpty {
                Section("Note") { Text(transaction.note) }
            }

            Section {
                if transaction.kind == .expense, transaction.deletedAt == nil {
                    Button("Record refund") { showingRefund = true }
                }
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
        .sheet(isPresented: $showingRefund) {
            RefundEntryView(
                original: transaction,
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
            Task { await sync.synchronize(session: session) }
        } catch {
            safeError = String(localized: "The local change could not be saved.")
        }
    }

    private func setDeleted(_ deleted: Bool) {
        do {
            try LocalLedgerRepository(context: modelContext)
                .setTransactionDeleted(transaction, deleted: deleted)
            Task { await sync.synchronize(session: session) }
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
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var amount: String
    @State private var merchant: String
    @State private var note: String
    @State private var occurredAt: Date
    @State private var accountID: UUID
    @State private var destinationAccountID: UUID?
    @State private var categoryID: UUID?
    @State private var destinationAmount: String
    @State private var baseAmount: String
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
        _destinationAccountID = State(initialValue: transaction.destinationAccountID)
        _categoryID = State(initialValue: transaction.categoryID)
        if let destinationAccountID = transaction.destinationAccountID,
           let destination = accounts.first(where: { $0.id == destinationAccountID }),
           let destinationAmountMinor = transaction.destinationAmountMinor,
           let money = try? Money(
               minorUnits: destinationAmountMinor,
               currencyCode: destination.currencyCode,
               exponent: destination.currencyExponent
           ) {
            _destinationAmount = State(
                initialValue: money.editableMajorUnits(locale: .current)
            )
        } else {
            _destinationAmount = State(initialValue: "")
        }
        if transaction.currencyCode != transaction.baseCurrencyCode,
           let tracker = trackers.first(where: { $0.id == transaction.trackerID }),
           let money = try? Money(
               minorUnits: transaction.baseAmountMinor,
               currencyCode: transaction.baseCurrencyCode,
               exponent: tracker.baseCurrencyExponent
           ) {
            _baseAmount = State(initialValue: money.editableMajorUnits(locale: .current))
        } else {
            _baseAmount = State(initialValue: "")
        }
    }

    private var availableAccounts: [LocalAccount] {
        accounts.filter { $0.trackerID == transaction.trackerID && $0.archivedAt == nil }
    }

    private var availableCategories: [LocalCategory] {
        guard transaction.kind != .transfer else { return [] }
        let expected: LocalCategoryKind = transaction.kind == .income ? .income : .expense
        return categories.filter {
            $0.trackerID == transaction.trackerID && $0.kind == expected && $0.archivedAt == nil
        }
    }

    private var tracker: LocalTracker? {
        trackers.first { $0.id == transaction.trackerID }
    }

    private var selectedAccount: LocalAccount? {
        availableAccounts.first { $0.id == accountID }
    }

    private var availableDestinationAccounts: [LocalAccount] {
        availableAccounts.filter { $0.id != accountID }
    }

    private var selectedDestinationAccount: LocalAccount? {
        availableDestinationAccounts.first { $0.id == destinationAccountID }
    }

    private var requiresDestinationAmount: Bool {
        guard transaction.kind == .transfer,
              let selectedAccount,
              let selectedDestinationAccount
        else { return false }
        return selectedAccount.currencyCode != selectedDestinationAccount.currencyCode ||
            selectedAccount.currencyExponent != selectedDestinationAccount.currencyExponent
    }

    private var requiresBaseAmount: Bool {
        guard let tracker, let selectedAccount else { return false }
        if selectedAccount.currencyCode == tracker.baseCurrencyCode,
           selectedAccount.currencyExponent == tracker.baseCurrencyExponent {
            return false
        }
        if transaction.kind == .transfer,
           let selectedDestinationAccount,
           selectedDestinationAccount.currencyCode == tracker.baseCurrencyCode,
           selectedDestinationAccount.currencyExponent == tracker.baseCurrencyExponent {
            return false
        }
        return true
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
                if transaction.kind == .transfer {
                    Picker("To account", selection: $destinationAccountID) {
                        ForEach(availableDestinationAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    if requiresDestinationAmount, let destination = selectedDestinationAccount {
                        HStack {
                            TextField("Destination amount", text: $destinationAmount)
                                .keyboardType(.decimalPad)
                            Text(destination.currencyCode).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Picker("Category", selection: $categoryID) {
                        Text("Uncategorized").tag(UUID?.none)
                        ForEach(availableCategories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }
                if requiresBaseAmount, let tracker {
                    HStack {
                        TextField("Amount in base currency", text: $baseAmount)
                            .keyboardType(.decimalPad)
                        Text(tracker.baseCurrencyCode).foregroundStyle(.secondary)
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
        .onChange(of: accountID) { _, _ in
            if !availableDestinationAccounts.contains(where: {
                $0.id == destinationAccountID
            }) {
                destinationAccountID = availableDestinationAccounts.first?.id
            }
        }
    }

    private func save() {
        guard let tracker,
              let account = selectedAccount
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
            let destinationMoney = try parsedDestinationMoney(sourceMoney: money)
            let reportingBaseMoney = try parsedBaseMoney(
                destinationMoney: destinationMoney,
                tracker: tracker,
                account: account
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
                occurredAt: occurredAt,
                destinationAccount: selectedDestinationAccount,
                destinationMoney: destinationMoney,
                baseMoney: reportingBaseMoney
            )
            Task { await sync.synchronize(session: session) }
            dismiss()
        } catch {
            safeError = String(localized: "Enter valid transaction details.")
        }
    }

    private func parsedDestinationMoney(sourceMoney: Money) throws -> Money? {
        guard transaction.kind == .transfer,
              let destination = selectedDestinationAccount
        else { return nil }
        if !requiresDestinationAmount {
            return try Money(
                minorUnits: sourceMoney.minorUnits,
                currencyCode: destination.currencyCode,
                exponent: destination.currencyExponent
            )
        }
        return try Money.positive(
            majorUnits: destinationAmount,
            currencyCode: destination.currencyCode,
            exponent: destination.currencyExponent,
            locale: .current
        )
    }

    private func parsedBaseMoney(
        destinationMoney: Money?,
        tracker: LocalTracker,
        account: LocalAccount
    ) throws -> Money? {
        if account.currencyCode == tracker.baseCurrencyCode,
           account.currencyExponent == tracker.baseCurrencyExponent {
            return nil
        }
        if transaction.kind == .transfer,
           let destinationMoney,
           destinationMoney.currencyCode == tracker.baseCurrencyCode,
           destinationMoney.exponent == tracker.baseCurrencyExponent {
            return destinationMoney
        }
        return try Money.positive(
            majorUnits: baseAmount,
            currencyCode: tracker.baseCurrencyCode,
            exponent: tracker.baseCurrencyExponent,
            locale: .current
        )
    }
}

private struct RefundEntryView: View {
    let original: LedgerTransaction
    let trackers: [LocalTracker]
    let accounts: [LocalAccount]
    let categories: [LocalCategory]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var amount: String
    @State private var accountID: UUID
    @State private var categoryID: UUID?
    @State private var merchant: String
    @State private var note = ""
    @State private var baseAmount = ""
    @State private var occurredAt = Date.now
    @State private var safeError: String?

    init(
        original: LedgerTransaction,
        trackers: [LocalTracker],
        accounts: [LocalAccount],
        categories: [LocalCategory]
    ) {
        self.original = original
        self.trackers = trackers
        self.accounts = accounts
        self.categories = categories
        _amount = State(
            initialValue: original.money?.editableMajorUnits(locale: .current) ?? ""
        )
        _accountID = State(initialValue: original.accountID)
        _categoryID = State(initialValue: original.categoryID)
        _merchant = State(initialValue: original.merchant)
    }

    private var tracker: LocalTracker? {
        trackers.first { $0.id == original.trackerID }
    }

    private var availableAccounts: [LocalAccount] {
        accounts.filter { $0.trackerID == original.trackerID && $0.archivedAt == nil }
    }

    private var selectedAccount: LocalAccount? {
        availableAccounts.first { $0.id == accountID }
    }

    private var availableCategories: [LocalCategory] {
        categories.filter {
            $0.trackerID == original.trackerID &&
                $0.kind == .expense &&
                $0.archivedAt == nil
        }
    }

    private var requiresBaseAmount: Bool {
        guard let tracker, let selectedAccount else { return false }
        return selectedAccount.currencyCode != tracker.baseCurrencyCode ||
            selectedAccount.currencyExponent != tracker.baseCurrencyExponent
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Refund amount", text: $amount)
                        .keyboardType(.decimalPad)
                        .font(.title.bold().monospacedDigit())
                    Text("A refund adds money back without reducing historical spending silently.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Where") {
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
                    if requiresBaseAmount, let tracker {
                        HStack {
                            TextField("Amount in base currency", text: $baseAmount)
                                .keyboardType(.decimalPad)
                            Text(tracker.baseCurrencyCode).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Optional details") {
                    TextField("Merchant or payee", text: $merchant)
                    TextField("Note", text: $note, axis: .vertical)
                    DatePicker("Date", selection: $occurredAt)
                }
                if let safeError {
                    Text(safeError).foregroundStyle(LedgerTheme.negative)
                }
            }
            .navigationTitle("Record refund")
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
        guard let tracker, let account = selectedAccount else {
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
            let reportingBaseMoney = if requiresBaseAmount {
                try Money.positive(
                    majorUnits: baseAmount,
                    currencyCode: tracker.baseCurrencyCode,
                    exponent: tracker.baseCurrencyExponent,
                    locale: .current
                )
            } else {
                nil
            }
            let category = availableCategories.first { $0.id == categoryID }
            try LocalLedgerRepository(context: modelContext).createTransaction(
                scopeKey: original.scopeKey,
                tracker: tracker,
                account: account,
                category: category,
                kind: .refund,
                money: money,
                merchant: merchant,
                note: note,
                occurredAt: occurredAt,
                refundOf: original,
                baseMoney: reportingBaseMoney
            )
            Task { await sync.synchronize(session: session) }
            dismiss()
        } catch MoneyError.tooManyFractionDigits {
            safeError = String(
                localized: "Use no more fraction digits than this currency supports."
            )
        } catch {
            safeError = String(localized: "Enter valid transaction details.")
        }
    }
}
