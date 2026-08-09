import SwiftData
import SwiftUI

private enum LocalDataSheet: Identifiable {
    case addTracker
    case addAccount
    case addCategory
    case addTag
    case renameTracker(LocalTracker)
    case renameAccount(LocalAccount)
    case renameCategory(LocalCategory)
    case renameTag(LocalTag)

    var id: String {
        switch self {
        case .addTracker: "add-tracker"
        case .addAccount: "add-account"
        case .addCategory: "add-category"
        case .addTag: "add-tag"
        case let .renameTracker(item): "tracker-\(item.id)"
        case let .renameAccount(item): "account-\(item.id)"
        case let .renameCategory(item): "category-\(item.id)"
        case let .renameTag(item): "tag-\(item.id)"
        }
    }
}

struct LocalDataSettingsView: View {
    let scopeKey: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var trackers: [LocalTracker]
    @Query private var memberships: [LocalTrackerMembership]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @Query private var tags: [LocalTag]
    @State private var sheet: LocalDataSheet?
    @State private var safeError: String?

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _trackers = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey &&
                    $0.deletedAt == nil &&
                    $0.accessRevokedAt == nil
            },
            sort: \LocalTracker.sortOrder
        )
        _memberships = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.deletedAt == nil && $0.stateRaw == "active"
            },
            sort: \LocalTrackerMembership.email
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
    }

    private var activeTrackers: [LocalTracker] {
        trackers.filter { $0.archivedAt == nil }
    }

    private var editableTrackers: [LocalTracker] {
        activeTrackers.filter { $0.role.canEditFinancialData }
    }

    private var visibleAccounts: [LocalAccount] {
        let trackerIDs = Set(trackers.map(\.id))
        return accounts.filter { trackerIDs.contains($0.trackerID) }
    }

    private var visibleCategories: [LocalCategory] {
        let trackerIDs = Set(trackers.map(\.id))
        return categories.filter { trackerIDs.contains($0.trackerID) }
    }

    private var visibleTags: [LocalTag] {
        let trackerIDs = Set(trackers.map(\.id))
        return tags.filter { trackerIDs.contains($0.trackerID) }
    }

    var body: some View {
        List {
            Section("Trackers") {
                ForEach(trackers) { tracker in
                    EntityRow(
                        name: tracker.name,
                        detail: "\(tracker.baseCurrencyCode) · \(tracker.role.displayName)",
                        symbol: tracker.icon,
                        colorHex: tracker.colorHex,
                        archived: tracker.archivedAt != nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if tracker.role.canManageTracker { sheet = .renameTracker(tracker) }
                    }
                    .swipeActions {
                        if tracker.role.canManageTracker {
                            archiveButton(archived: tracker.archivedAt != nil) {
                                try repository.setTrackerArchived(
                                    tracker,
                                    archived: tracker.archivedAt == nil
                                )
                            }
                        }
                    }
                }
            }

            Section("Collaborators") {
                ForEach(memberships.filter { member in
                    trackers.contains { $0.id == member.trackerID }
                }) { member in
                    EntityRow(
                        name: member.email,
                        detail: "\(trackerName(id: member.trackerID)) · \(member.role.displayName)",
                        symbol: "person.crop.circle",
                        colorHex: "#73819B",
                        archived: false
                    )
                }
            } footer: {
                Text("The synchronized roster remains visible offline. Invitations and role changes require a connection.")
            }

            Section("Accounts") {
                ForEach(visibleAccounts) { account in
                    EntityRow(
                        name: account.name,
                        detail: "\(account.type.displayName) · \(account.currencyCode)",
                        symbol: account.icon,
                        colorHex: account.colorHex,
                        archived: account.archivedAt != nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if canEdit(trackerID: account.trackerID) {
                            sheet = .renameAccount(account)
                        }
                    }
                    .swipeActions {
                        if canEdit(trackerID: account.trackerID) {
                            archiveButton(archived: account.archivedAt != nil) {
                                try repository.setAccountArchived(
                                    account,
                                    archived: account.archivedAt == nil
                                )
                            }
                        }
                    }
                }
            }

            Section("Categories") {
                ForEach(visibleCategories) { category in
                    EntityRow(
                        name: category.name,
                        detail: category.kind.displayName,
                        symbol: category.icon,
                        colorHex: category.colorHex,
                        archived: category.archivedAt != nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if canEdit(trackerID: category.trackerID) {
                            sheet = .renameCategory(category)
                        }
                    }
                    .swipeActions {
                        if canEdit(trackerID: category.trackerID) {
                            archiveButton(archived: category.archivedAt != nil) {
                                try repository.setCategoryArchived(
                                    category,
                                    archived: category.archivedAt == nil
                                )
                            }
                        }
                    }
                }
            }

            Section("Tags") {
                ForEach(visibleTags) { tag in
                    EntityRow(
                        name: tag.name,
                        detail: trackerName(id: tag.trackerID),
                        symbol: "tag",
                        colorHex: tag.colorHex,
                        archived: tag.archivedAt != nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if canEdit(trackerID: tag.trackerID) { sheet = .renameTag(tag) }
                    }
                    .swipeActions {
                        if canEdit(trackerID: tag.trackerID) {
                            archiveButton(archived: tag.archivedAt != nil) {
                                try repository.setTagArchived(tag, archived: tag.archivedAt == nil)
                            }
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
                .disabled(editableTrackers.isEmpty)
                Button("New category", systemImage: "tag") {
                    sheet = .addCategory
                }
                .disabled(editableTrackers.isEmpty)
                Button("New tag", systemImage: "tag.fill") {
                    sheet = .addTag
                }
                .disabled(editableTrackers.isEmpty)
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .sheet(item: $sheet) { route in
            switch route {
            case .addTracker:
                AddTrackerSheet(scopeKey: scopeKey)
            case .addAccount:
                AddAccountSheet(scopeKey: scopeKey, trackers: editableTrackers)
            case .addCategory:
                AddCategorySheet(scopeKey: scopeKey, trackers: editableTrackers)
            case .addTag:
                AddTagSheet(scopeKey: scopeKey, trackers: editableTrackers)
            case let .renameTracker(item):
                RenameSheet(title: "Rename tracker", currentName: item.name) { name in
                    try repository.renameTracker(item, name: name)
                    requestSync()
                }
            case let .renameAccount(item):
                RenameSheet(title: "Rename account", currentName: item.name) { name in
                    try repository.renameAccount(item, name: name)
                    requestSync()
                }
            case let .renameCategory(item):
                RenameSheet(title: "Rename category", currentName: item.name) { name in
                    try repository.renameCategory(item, name: name)
                    requestSync()
                }
            case let .renameTag(item):
                RenameSheet(title: "Rename tag", currentName: item.name) { name in
                    try repository.renameTag(item, name: name)
                    requestSync()
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

    private func canEdit(trackerID: UUID) -> Bool {
        trackers.first { $0.id == trackerID }?.role.canEditFinancialData == true
    }

    private func trackerName(id: UUID) -> String {
        trackers.first { $0.id == id }?.name ?? String(localized: "Unknown tracker")
    }

    private func requestSync() {
        Task { await sync.synchronize(session: session) }
    }

    private func archiveButton(
        archived: Bool,
        action: @escaping () throws -> Void
    ) -> some View {
        Button(archived ? "Restore" : "Archive") {
            do {
                try action()
                requestSync()
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
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
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
            Task { await sync.synchronize(session: session) }
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
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
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
            Task { await sync.synchronize(session: session) }
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
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
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
            Task { await sync.synchronize(session: session) }
            dismiss()
        } catch {
            safeError = String(localized: "Enter valid category details.")
        }
    }
}

private struct AddTagSheet: View {
    let scopeKey: String
    let trackers: [LocalTracker]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var name = ""
    @State private var trackerID: UUID?
    @State private var safeError: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Tracker", selection: $trackerID) {
                    ForEach(trackers) { item in Text(item.name).tag(Optional(item.id)) }
                }
                if let safeError { Text(safeError).foregroundStyle(LedgerTheme.negative) }
            }
            .navigationTitle("New tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar(save: save, dismiss: dismiss) }
            .onAppear { trackerID = trackerID ?? trackers.first?.id }
        }
    }

    private func save() {
        guard let tracker = trackers.first(where: { $0.id == trackerID }) else { return }
        do {
            try LocalLedgerRepository(context: modelContext).createTag(
                scopeKey: scopeKey,
                tracker: tracker,
                name: name
            )
            Task { await sync.synchronize(session: session) }
            dismiss()
        } catch {
            safeError = String(localized: "Enter a unique nonempty tag name.")
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

private extension TrackerRole {
    var displayName: String {
        switch self {
        case .owner: String(localized: "Owner")
        case .admin: String(localized: "Admin")
        case .editor: String(localized: "Editor")
        case .viewer: String(localized: "Viewer")
        }
    }
}
