import SwiftData
import SwiftUI

private enum LocalDataSheet: Identifiable {
    case addTracker
    case addAccount
    case addCategory
    case renameTracker(LocalTracker)
    case renameAccount(LocalAccount)
    case renameCategory(LocalCategory)

    var id: String {
        switch self {
        case .addTracker: "add-tracker"
        case .addAccount: "add-account"
        case .addCategory: "add-category"
        case let .renameTracker(item): "tracker-\(item.id)"
        case let .renameAccount(item): "account-\(item.id)"
        case let .renameCategory(item): "category-\(item.id)"
        }
    }
}

struct LocalDataSettingsView: View {
    let scopeKey: String

    @Environment(\.modelContext) private var modelContext
    @Query private var trackers: [LocalTracker]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @State private var sheet: LocalDataSheet?
    @State private var safeError: String?

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _trackers = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
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
    }

    private var activeTrackers: [LocalTracker] {
        trackers.filter { $0.archivedAt == nil }
    }

    var body: some View {
        List {
            Section("Trackers") {
                ForEach(trackers) { tracker in
                    EntityRow(
                        name: tracker.name,
                        detail: tracker.baseCurrencyCode,
                        symbol: tracker.icon,
                        colorHex: tracker.colorHex,
                        archived: tracker.archivedAt != nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { sheet = .renameTracker(tracker) }
                    .swipeActions {
                        archiveButton(archived: tracker.archivedAt != nil) {
                            try repository.setTrackerArchived(tracker, archived: tracker.archivedAt == nil)
                        }
                    }
                }
            }

            Section("Accounts") {
                ForEach(accounts) { account in
                    EntityRow(
                        name: account.name,
                        detail: "\(account.type.displayName) · \(account.currencyCode)",
                        symbol: account.icon,
                        colorHex: account.colorHex,
                        archived: account.archivedAt != nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { sheet = .renameAccount(account) }
                    .swipeActions {
                        archiveButton(archived: account.archivedAt != nil) {
                            try repository.setAccountArchived(account, archived: account.archivedAt == nil)
                        }
                    }
                }
            }

            Section("Categories") {
                ForEach(categories) { category in
                    EntityRow(
                        name: category.name,
                        detail: category.kind.displayName,
                        symbol: category.icon,
                        colorHex: category.colorHex,
                        archived: category.archivedAt != nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { sheet = .renameCategory(category) }
                    .swipeActions {
                        archiveButton(archived: category.archivedAt != nil) {
                            try repository.setCategoryArchived(category, archived: category.archivedAt == nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("Local data")
        .toolbar {
            Menu {
                Button("New tracker", systemImage: "square.stack.3d.up.badge.plus") {
                    sheet = .addTracker
                }
                Button("New account", systemImage: "creditcard") {
                    sheet = .addAccount
                }
                .disabled(activeTrackers.isEmpty)
                Button("New category", systemImage: "tag") {
                    sheet = .addCategory
                }
                .disabled(activeTrackers.isEmpty)
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .sheet(item: $sheet) { route in
            switch route {
            case .addTracker:
                AddTrackerSheet(scopeKey: scopeKey)
            case .addAccount:
                AddAccountSheet(scopeKey: scopeKey, trackers: activeTrackers)
            case .addCategory:
                AddCategorySheet(scopeKey: scopeKey, trackers: activeTrackers)
            case let .renameTracker(item):
                RenameSheet(title: "Rename tracker", currentName: item.name) { name in
                    try repository.renameTracker(item, name: name)
                }
            case let .renameAccount(item):
                RenameSheet(title: "Rename account", currentName: item.name) { name in
                    try repository.renameAccount(item, name: name)
                }
            case let .renameCategory(item):
                RenameSheet(title: "Rename category", currentName: item.name) { name in
                    try repository.renameCategory(item, name: name)
                }
            }
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

    private var repository: LocalLedgerRepository {
        LocalLedgerRepository(context: modelContext)
    }

    private func archiveButton(
        archived: Bool,
        action: @escaping () throws -> Void
    ) -> some View {
        Button(archived ? "Restore" : "Archive") {
            do {
                try action()
            } catch {
                safeError = String(localized: "The local change could not be saved.")
            }
        }
        .tint(archived ? LedgerTheme.positive : LedgerTheme.warning)
    }
}

private struct EntityRow: View {
    let name: String
    let detail: String
    let symbol: String
    let colorHex: String
    let archived: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 34, height: 34)
                .background((Color(ledgerHex: colorHex) ?? LedgerTheme.accent).opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(
                    archived ? String.localizedStringWithFormat(
                        String(localized: "Archived detail format"),
                        detail
                    ) : detail
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(archived ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct RenameSheet: View {
    let title: LocalizedStringKey
    let onSave: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var safeError: String?

    init(
        title: LocalizedStringKey,
        currentName: String,
        onSave: @escaping (String) throws -> Void
    ) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: currentName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                if let safeError { Text(safeError).foregroundStyle(LedgerTheme.negative) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try onSave(name)
                            dismiss()
                        } catch {
                            safeError = String(localized: "Enter a nonempty name.")
                        }
                    }
                }
            }
        }
    }
}

private struct AddTrackerSheet: View {
    let scopeKey: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var currency = "ALL"
    @State private var safeError: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Base currency", selection: $currency) {
                    ForEach(CurrencyCatalog.priority) { item in
                        Text(item.code).tag(item.code)
                    }
                }
                if let safeError { Text(safeError).foregroundStyle(LedgerTheme.negative) }
            }
            .navigationTitle("New tracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar(save: save, dismiss: dismiss) }
        }
    }

    private func save() {
        do {
            try LocalLedgerRepository(context: modelContext).createTracker(
                scopeKey: scopeKey,
                name: name,
                currencyCode: currency,
                currencyExponent: CurrencyCatalog.exponent(for: currency) ?? 2
            )
            dismiss()
        } catch {
            safeError = String(localized: "Enter valid tracker details.")
        }
    }
}

private struct AddAccountSheet: View {
    let scopeKey: String
    let trackers: [LocalTracker]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var trackerID: UUID?
    @State private var type = LocalAccountType.cash
    @State private var currency = "ALL"
    @State private var safeError: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Tracker", selection: $trackerID) {
                    ForEach(trackers) { item in Text(item.name).tag(Optional(item.id)) }
                }
                Picker("Account type", selection: $type) {
                    ForEach(LocalAccountType.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                Picker("Currency", selection: $currency) {
                    ForEach(CurrencyCatalog.priority) { item in Text(item.code).tag(item.code) }
                }
                if let safeError { Text(safeError).foregroundStyle(LedgerTheme.negative) }
            }
            .navigationTitle("New account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar(save: save, dismiss: dismiss) }
            .onAppear { trackerID = trackerID ?? trackers.first?.id }
        }
    }

    private func save() {
        guard let tracker = trackers.first(where: { $0.id == trackerID }) else { return }
        do {
            try LocalLedgerRepository(context: modelContext).createAccount(
                scopeKey: scopeKey,
                tracker: tracker,
                name: name,
                type: type,
                currencyCode: currency,
                currencyExponent: CurrencyCatalog.exponent(for: currency) ?? 2
            )
            dismiss()
        } catch {
            safeError = String(localized: "Enter valid account details.")
        }
    }
}

private struct AddCategorySheet: View {
    let scopeKey: String
    let trackers: [LocalTracker]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var trackerID: UUID?
    @State private var kind = LocalCategoryKind.expense
    @State private var safeError: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Tracker", selection: $trackerID) {
                    ForEach(trackers) { item in Text(item.name).tag(Optional(item.id)) }
                }
                Picker("Category type", selection: $kind) {
                    ForEach(LocalCategoryKind.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                if let safeError { Text(safeError).foregroundStyle(LedgerTheme.negative) }
            }
            .navigationTitle("New category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar(save: save, dismiss: dismiss) }
            .onAppear { trackerID = trackerID ?? trackers.first?.id }
        }
    }

    private func save() {
        guard let tracker = trackers.first(where: { $0.id == trackerID }) else { return }
        do {
            try LocalLedgerRepository(context: modelContext).createCategory(
                scopeKey: scopeKey,
                tracker: tracker,
                name: name,
                kind: kind
            )
            dismiss()
        } catch {
            safeError = String(localized: "Enter valid category details.")
        }
    }
}

@ToolbarContentBuilder
private func editorToolbar(save: @escaping () -> Void, dismiss: DismissAction) -> some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
    }
    ToolbarItem(placement: .confirmationAction) {
        Button("Save", action: save)
    }
}

private extension LocalAccountType {
    var displayName: String {
        switch self {
        case .cash: String(localized: "Cash")
        case .checking: String(localized: "Checking")
        case .savings: String(localized: "Savings")
        case .credit: String(localized: "Credit")
        case .digitalWallet: String(localized: "Digital wallet")
        case .custom: String(localized: "Custom")
        }
    }
}

private extension LocalCategoryKind {
    var displayName: String {
        switch self {
        case .expense: String(localized: "Expense")
        case .income: String(localized: "Income")
        }
    }
}
