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
    @State private var kind = TransactionKind.expense
    @State private var amount = ""
    @State private var merchant = ""
    @State private var note = ""
    @State private var occurredAt = Date.now
    @State private var trackerID: UUID?
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var errorMessage: String?
    @State private var didSave = false

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
    }

    private var selectedTracker: LocalTracker? {
        trackers.first { $0.id == trackerID }
    }

    private var availableAccounts: [LocalAccount] {
        accounts.filter { $0.trackerID == trackerID }
    }

    private var availableCategories: [LocalCategory] {
        let categoryKind: LocalCategoryKind = kind == .income ? .income : .expense
        return categories.filter { $0.trackerID == trackerID && $0.kind == categoryKind }
    }

    private var selectedAccount: LocalAccount? {
        availableAccounts.first { $0.id == accountID }
    }

    private var selectedCategory: LocalCategory? {
        availableCategories.first { $0.id == categoryID }
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    Text("Expense").tag(TransactionKind.expense)
                    Text("Income").tag(TransactionKind.income)
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
                    ForEach(trackers) { tracker in
                        Text(tracker.name).tag(Optional(tracker.id))
                    }
                }
                Picker("Account", selection: $accountID) {
                    ForEach(availableAccounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                Picker("Category", selection: $categoryID) {
                    Text("Uncategorized").tag(UUID?.none)
                    ForEach(availableCategories) { category in
                        Text(category.name).tag(Optional(category.id))
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
                    .disabled(amount.isEmpty || selectedTracker == nil || selectedAccount == nil)
            } footer: {
                Text("Saving never waits for the network. Synchronization is attempted separately.")
            }
        }
        .navigationTitle("Quick add")
        .onAppear(perform: configureDefaults)
        .onChange(of: trackers.count) { _, _ in configureDefaults() }
        .onChange(of: trackerID) { _, _ in configureChildDefaults() }
        .onChange(of: kind) { _, _ in configureCategoryDefault() }
        .alert("Saved on this iPhone", isPresented: $didSave) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Synchronization can happen later without blocking this entry.")
        }
    }

    private func configureDefaults() {
        if trackerID == nil { trackerID = trackers.first?.id }
        configureChildDefaults()
    }

    private func configureChildDefaults() {
        guard let tracker = selectedTracker else {
            accountID = nil
            categoryID = nil
            return
        }
        if !availableAccounts.contains(where: { $0.id == accountID }) {
            accountID = availableAccounts.first { $0.id == tracker.defaultAccountID }?.id ?? availableAccounts.first?.id
        }
        configureCategoryDefault()
    }

    private func configureCategoryDefault() {
        guard let tracker = selectedTracker else { return }
        if !availableCategories.contains(where: { $0.id == categoryID }) {
            categoryID = availableCategories.first { $0.id == tracker.defaultCategoryID }?.id ?? availableCategories.first?.id
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
            try LocalLedgerRepository(context: modelContext).createTransaction(
                scopeKey: scopeKey,
                tracker: tracker,
                account: account,
                category: selectedCategory,
                kind: kind,
                money: money,
                merchant: merchant,
                note: note,
                occurredAt: occurredAt
            )
            amount = ""
            merchant = ""
            note = ""
            occurredAt = .now
            errorMessage = nil
            didSave = true
            Task { await sync.synchronize(session: session) }
        } catch MoneyError.tooManyFractionDigits {
            errorMessage = String(localized: "Use no more fraction digits than this currency supports.")
        } catch {
            errorMessage = String(localized: "Enter a valid positive amount.")
        }
    }
}
