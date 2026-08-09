import SwiftData
import SwiftUI

struct QuickAddView: View {
    let scopeKey: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var trackers: [LocalTracker]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @Query private var tags: [LocalTag]
    @State private var kind = TransactionKind.expense
    @State private var amount = ""
    @State private var merchant = ""
    @State private var note = ""
    @State private var occurredAt = Date.now
    @State private var trackerID: UUID?
    @State private var accountID: UUID?
    @State private var destinationAccountID: UUID?
    @State private var categoryID: UUID?
    @State private var selectedTagIDs = Set<UUID>()
    @State private var destinationAmount = ""
    @State private var baseAmount = ""
    @State private var errorMessage: String?
    @State private var undoCandidate: LedgerTransaction?
    @State private var undoExpiryTask: Task<Void, Never>?

    init(scopeKey: String) {
        self.scopeKey = scopeKey
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
        _categories = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.deletedAt == nil && $0.archivedAt == nil
            },
            sort: \LocalCategory.sortOrder
        )
        _tags = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.deletedAt == nil && $0.archivedAt == nil
            },
            sort: \LocalTag.name
        )
    }

    private var editableTrackers: [LocalTracker] {
        trackers.filter { $0.role.canEditFinancialData }
    }

    private var selectedTracker: LocalTracker? {
        editableTrackers.first { $0.id == trackerID }
    }

    private var availableAccounts: [LocalAccount] {
        accounts.filter { $0.trackerID == trackerID }
    }

    private var availableCategories: [LocalCategory] {
        guard kind != .transfer else { return [] }
        let categoryKind: LocalCategoryKind = kind == .income ? .income : .expense
        return categories.filter { $0.trackerID == trackerID && $0.kind == categoryKind }
    }

    private var availableDestinationAccounts: [LocalAccount] {
        availableAccounts.filter { $0.id != accountID }
    }

    private var availableTags: [LocalTag] {
        tags.filter { $0.trackerID == trackerID }
    }

    private var selectedAccount: LocalAccount? {
        availableAccounts.first { $0.id == accountID }
    }

    private var selectedCategory: LocalCategory? {
        availableCategories.first { $0.id == categoryID }
    }

    private var selectedDestinationAccount: LocalAccount? {
        availableDestinationAccounts.first { $0.id == destinationAccountID }
    }

    private var accountPickerTitle: LocalizedStringKey {
        kind == .transfer ? "From account" : "Account"
    }

    private var requiresDestinationAmount: Bool {
        guard kind == .transfer,
              let source = selectedAccount,
              let destination = selectedDestinationAccount
        else { return false }
        return source.currencyCode != destination.currencyCode ||
            source.currencyExponent != destination.currencyExponent
    }

    private var requiresManualBaseAmount: Bool {
        guard let tracker = selectedTracker, let source = selectedAccount else { return false }
        if source.currencyCode == tracker.baseCurrencyCode,
           source.currencyExponent == tracker.baseCurrencyExponent {
            return false
        }
        if kind == .transfer,
           let destination = selectedDestinationAccount,
           destination.currencyCode == tracker.baseCurrencyCode,
           destination.currencyExponent == tracker.baseCurrencyExponent {
            return false
        }
        return true
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    Text("Expense").tag(TransactionKind.expense)
                    Text("Income").tag(TransactionKind.income)
                    Text("Transfer").tag(TransactionKind.transfer)
                }
                .pickerStyle(.segmented)

                TextField("Amount", text: $amount)
                    .keyboardType(.decimalPad)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Transaction amount")
            }

            Section("Where") {
                Picker("Tracker", selection: $trackerID) {
                    ForEach(editableTrackers) { tracker in
                        Text(tracker.name).tag(Optional(tracker.id))
                    }
                }
                Picker(accountPickerTitle, selection: $accountID) {
                    ForEach(availableAccounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                if kind == .transfer {
                    Picker("To account", selection: $destinationAccountID) {
                        ForEach(availableDestinationAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    if requiresDestinationAmount, let destination = selectedDestinationAccount {
                        HStack {
                            TextField("Destination amount", text: $destinationAmount)
                                .keyboardType(.decimalPad)
                            Text(destination.currencyCode)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Destination currency")
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
                if requiresManualBaseAmount, let tracker = selectedTracker {
                    HStack {
                        TextField("Amount in base currency", text: $baseAmount)
                            .keyboardType(.decimalPad)
                        Text(tracker.baseCurrencyCode)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Base currency")
                    }
                }
            }

            Section("Optional details") {
                TextField("Merchant or payee", text: $merchant)
                    .textContentType(.organizationName)
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(2 ... 5)
                DatePicker("Date", selection: $occurredAt)
            }

            TagSelectionSection(tags: availableTags, selectedIDs: $selectedTagIDs)

            if editableTrackers.isEmpty {
                Section {
                    Label("Your trackers are read only.", systemImage: "eye")
                } footer: {
                    Text("An owner or admin must grant editor access before you can add transactions.")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LedgerTheme.negative)
                }
            }

            Section {
                Button("Save on this iPhone") { save() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(!canSave)
            } footer: {
                Text("Saving never waits for the network. Synchronization is attempted separately.")
            }
        }
        .navigationTitle("Quick add")
        .onAppear(perform: configureDefaults)
        .onChange(of: trackers.count) { _, _ in configureDefaults() }
        .onChange(of: trackerID) { _, _ in configureChildDefaults() }
        .onChange(of: accountID) { _, _ in configureDestinationDefault() }
        .onChange(of: kind) { _, _ in
            configureCategoryDefault()
            configureDestinationDefault()
        }
        .safeAreaInset(edge: .bottom) {
            if undoCandidate != nil {
                HStack(spacing: 12) {
                    Label("Saved on this iPhone", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("Undo") { undoLastSave() }
                        .fontWeight(.semibold)
                }
                .padding()
                .background(.regularMaterial)
                .accessibilityElement(children: .contain)
            }
        }
        .onDisappear { undoExpiryTask?.cancel() }
    }

    private var canSave: Bool {
        guard !amount.isEmpty, selectedTracker != nil, selectedAccount != nil else {
            return false
        }
        if kind == .transfer {
            guard selectedDestinationAccount != nil else { return false }
            if requiresDestinationAmount, destinationAmount.isEmpty { return false }
        }
        if requiresManualBaseAmount, baseAmount.isEmpty { return false }
        return true
    }

    private func configureDefaults() {
        if !editableTrackers.contains(where: { $0.id == trackerID }) {
            trackerID = editableTrackers.first?.id
        }
        configureChildDefaults()
    }

    private func configureChildDefaults() {
        guard let tracker = selectedTracker else {
            accountID = nil
            categoryID = nil
            selectedTagIDs.removeAll()
            return
        }
        if !availableAccounts.contains(where: { $0.id == accountID }) {
            accountID = availableAccounts.first { $0.id == tracker.defaultAccountID }?.id ?? availableAccounts.first?.id
        }
        configureCategoryDefault()
        configureDestinationDefault()
        let availableIDs = Set(availableTags.map(\.id))
        selectedTagIDs.formIntersection(availableIDs)
    }

    private func configureCategoryDefault() {
        guard let tracker = selectedTracker else { return }
        guard kind != .transfer else {
            categoryID = nil
            return
        }
        if !availableCategories.contains(where: { $0.id == categoryID }) {
            categoryID = availableCategories.first { $0.id == tracker.defaultCategoryID }?.id ?? availableCategories.first?.id
        }
    }

    private func configureDestinationDefault() {
        guard kind == .transfer else {
            destinationAccountID = nil
            destinationAmount = ""
            return
        }
        if !availableDestinationAccounts.contains(where: { $0.id == destinationAccountID }) {
            destinationAccountID = availableDestinationAccounts.first?.id
            destinationAmount = ""
        }
    }

    private func save() {
        guard let tracker = selectedTracker, let account = selectedAccount else { return }
        do {
            let money = try Money.positive(
                majorUnits: amount,
                currencyCode: account.currencyCode,
                exponent: account.currencyExponent,
                locale: .current
            )
            let destinationMoney = try parsedDestinationMoney(sourceMoney: money)
            let baseMoney = try parsedBaseMoney(destinationMoney: destinationMoney)
            let transaction = try LocalLedgerRepository(context: modelContext).createTransaction(
                scopeKey: scopeKey,
                tracker: tracker,
                account: account,
                category: selectedCategory,
                kind: kind,
                money: money,
                merchant: merchant,
                note: note,
                occurredAt: occurredAt,
                destinationAccount: selectedDestinationAccount,
                destinationMoney: destinationMoney,
                baseMoney: baseMoney,
                tags: availableTags.filter { selectedTagIDs.contains($0.id) }
            )
            amount = ""
            merchant = ""
            note = ""
            destinationAmount = ""
            self.baseAmount = ""
            occurredAt = .now
            selectedTagIDs.removeAll()
            errorMessage = nil
            presentUndo(for: transaction)
            Task { await sync.synchronize(session: session) }
        } catch MoneyError.tooManyFractionDigits {
            errorMessage = String(localized: "Use no more fraction digits than this currency supports.")
        } catch MoneyError.conversionRequired {
            errorMessage = String(localized: "Enter the amount in the tracker base currency.")
        } catch {
            errorMessage = String(localized: "Enter a valid positive amount.")
        }
    }

    private func parsedDestinationMoney(sourceMoney: Money) throws -> Money? {
        guard kind == .transfer, let destination = selectedDestinationAccount else { return nil }
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

    private func parsedBaseMoney(destinationMoney: Money?) throws -> Money? {
        guard let tracker = selectedTracker, let source = selectedAccount else { return nil }
        if source.currencyCode == tracker.baseCurrencyCode,
           source.currencyExponent == tracker.baseCurrencyExponent {
            return nil
        }
        if kind == .transfer,
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

    private func presentUndo(for transaction: LedgerTransaction) {
        undoExpiryTask?.cancel()
        undoCandidate = transaction
        let transactionID = transaction.id
        undoExpiryTask = Task { @MainActor in
            do {
                try await ContinuousClock().sleep(for: .seconds(8))
            } catch {
                return
            }
            if undoCandidate?.id == transactionID {
                undoCandidate = nil
            }
        }
    }

    private func undoLastSave() {
        guard let transaction = undoCandidate else { return }
        do {
            try LocalLedgerRepository(context: modelContext)
                .setTransactionDeleted(transaction, deleted: true)
            undoExpiryTask?.cancel()
            undoCandidate = nil
            Task { await sync.synchronize(session: session) }
        } catch {
            errorMessage = String(localized: "The local change could not be saved.")
        }
    }
}
