import Foundation
import SwiftData
import SwiftUI

private enum BudgetSheet: Identifiable {
    case create(trackerID: UUID)
    case edit(LocalBudget)

    var id: String {
        switch self {
        case let .create(trackerID): "create-\(trackerID)"
        case let .edit(budget): "edit-\(budget.id)"
        }
    }
}

struct PlansView: View {
    let scopeKey: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var trackers: [LocalTracker]
    @Query private var budgets: [LocalBudget]
    @Query private var budgetCategories: [LocalBudgetCategory]
    @Query private var budgetThresholds: [LocalBudgetThreshold]
    @Query private var categories: [LocalCategory]
    @Query private var transactions: [LedgerTransaction]
    @Query private var recurringRules: [LocalRecurringRule]
    @Query private var installmentPlans: [LocalInstallmentPlan]
    @Query private var allocations: [LocalCategoryAllocation]
    @State private var selectedTrackerID: UUID?
    @State private var sheet: BudgetSheet?
    @State private var pendingDelete: LocalBudget?
    @State private var includeArchived = false
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
        _budgets = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalBudget.createdAt
        )
        _budgetCategories = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LocalBudgetCategory.categoryNameSnapshot
        )
        _budgetThresholds = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LocalBudgetThreshold.percent
        )
        _categories = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalCategory.sortOrder
        )
        _transactions = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LedgerTransaction.occurredAt
        )
        _recurringRules = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalRecurringRule.nextDueAt
        )
        _installmentPlans = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalInstallmentPlan.createdAt
        )
        _allocations = Query(filter: #Predicate { $0.scopeKey == scopeKey })
    }

    private var activeTrackers: [LocalTracker] {
        trackers.filter { $0.archivedAt == nil }
    }

    private var selectedTracker: LocalTracker? {
        activeTrackers.first { $0.id == selectedTrackerID } ?? preferredTracker
    }

    private var preferredTracker: LocalTracker? {
        activeTrackers.first { tracker in
            budgets.contains {
                $0.trackerID == tracker.id && (includeArchived || $0.archivedAt == nil)
            }
        } ?? activeTrackers.first { tracker in
            recurringRules.contains {
                $0.trackerID == tracker.id && $0.archivedAt == nil
            }
        } ?? activeTrackers.first { tracker in
            installmentPlans.contains {
                $0.trackerID == tracker.id && $0.archivedAt == nil
            }
        } ?? activeTrackers.first
    }

    private var visibleBudgets: [LocalBudget] {
        guard let trackerID = selectedTracker?.id else { return [] }
        return budgets.filter {
            $0.trackerID == trackerID && (includeArchived || $0.archivedAt == nil)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerTheme.contentSpacing) {
                if let safeError {
                    Label(safeError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(LedgerTheme.negative)
                        .ledgerCard()
                }

                trackerPicker

                if selectedTracker == nil {
                    ContentUnavailableView(
                        "No available tracker",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Create a tracker in Settings before adding a plan.")
                    )
                    .ledgerCard()
                } else if visibleBudgets.isEmpty {
                    ContentUnavailableView {
                        Label("No budgets yet", systemImage: "chart.bar.doc.horizontal")
                    } description: {
                        Text("Set a spending limit now. It is saved locally and can sync later.")
                    } actions: {
                        if selectedTracker?.role.canEditFinancialData == true {
                            Button("Create budget") { presentCreate() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .ledgerCard()
                } else {
                    ForEach(visibleBudgets) { budget in
                        budgetCard(budget)
                            .contextMenu {
                                if selectedTracker?.role.canEditFinancialData == true {
                                    Button("Edit budget", systemImage: "pencil") {
                                        sheet = .edit(budget)
                                    }
                                    if budget.archivedAt == nil {
                                        Button("Archive budget", systemImage: "archivebox") {
                                            updateArchive(budget)
                                        }
                                    } else {
                                        Button(
                                            "Restore budget",
                                            systemImage: "arrow.uturn.backward"
                                        ) {
                                            updateArchive(budget)
                                        }
                                    }
                                    Button("Delete budget", systemImage: "trash", role: .destructive) {
                                        pendingDelete = budget
                                    }
                                }
                            }
                    }
                }

                if let selectedTracker {
                    RecurringPlansSection(scopeKey: scopeKey, tracker: selectedTracker)
                    InstallmentPlansSection(scopeKey: scopeKey, tracker: selectedTracker)
                    SplitBalancesSection(scopeKey: scopeKey, tracker: selectedTracker)
                }
            }
            .padding()
        }
        .navigationTitle("Plans")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show archived budgets", isOn: $includeArchived)
                } label: {
                    Label("Plan options", systemImage: "ellipsis.circle")
                }
                if selectedTracker?.role.canEditFinancialData == true {
                    Button("Create budget", systemImage: "plus") { presentCreate() }
                }
            }
        }
        .sheet(item: $sheet) { destination in
            if let tracker = tracker(for: destination) {
                BudgetEditorView(
                    scopeKey: scopeKey,
                    tracker: tracker,
                    budget: budget(for: destination),
                    categories: categories.filter {
                        $0.trackerID == tracker.id &&
                            $0.kind == .expense &&
                            $0.archivedAt == nil
                    },
                    selectedCategoryIDs: selectedCategoryIDs(for: destination),
                    thresholdValues: thresholdValues(for: destination)
                )
            } else {
                ContentUnavailableView(
                    "Tracker unavailable",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            }
        }
        .confirmationDialog(
            "Delete this budget?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete budget", role: .destructive) {
                if let budget = pendingDelete { delete(budget) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The deletion is saved as a recoverable sync tombstone. Existing transactions are not changed.")
        }
        .onAppear {
            if selectedTrackerID == nil { selectedTrackerID = preferredTracker?.id }
        }
        .onChange(of: trackers.map(\.id)) { _, _ in
            if selectedTracker == nil { selectedTrackerID = preferredTracker?.id }
        }
    }

    @ViewBuilder
    private var trackerPicker: some View {
        if activeTrackers.count > 1 {
            Picker("Tracker", selection: trackerSelection) {
                ForEach(activeTrackers) { tracker in
                    Text(tracker.name).tag(tracker.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ledgerCard()
        } else if let tracker = selectedTracker {
            Label(tracker.name, systemImage: tracker.icon)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ledgerCard()
        }
    }

    private var trackerSelection: Binding<UUID> {
        Binding(
            get: { selectedTracker?.id ?? UUID() },
            set: { selectedTrackerID = $0 }
        )
    }

    private func budgetCard(_ budget: LocalBudget) -> some View {
        let progress = try? LocalBudgetCalculator.calculate(
            budget: budget,
            categoryLinks: budgetCategories.filter { $0.budgetID == budget.id },
            thresholds: budgetThresholds.filter { $0.budgetID == budget.id },
            transactions: transactions,
            allocations: allocations
        )
        return Button {
            if selectedTracker?.role.canEditFinancialData == true { sheet = .edit(budget) }
        } label: {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(budget.name)
                            .font(.headline)
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Budget descriptor format"),
                                budget.period.displayName,
                                budget.budgetScope.displayName
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    SyncStateIcon(state: budget.syncState)
                    if budget.archivedAt != nil {
                        Text("Archived")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }

                if let progress {
                    let available = budgetMoney(progress.availableMinor, budget: budget)
                    let spent = budgetMoney(progress.spentMinor, budget: budget)
                    HStack {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Budget spent format"),
                                spent
                            )
                        )
                        Spacer()
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Budget available format"),
                                available
                            )
                        )
                    }
                    .font(.subheadline.monospacedDigit())
                    ProgressView(
                        value: min(
                            max(
                                Double(progress.spentMinor) /
                                    Double(max(progress.availableMinor, 1)),
                                0
                            ),
                            1
                        )
                    )
                    .tint(progress.remainingMinor < 0 ? LedgerTheme.negative : LedgerTheme.accent)
                    .accessibilityLabel("Budget progress")
                    .accessibilityValue(
                        progress.progressBasisPoints.map(formattedPercent) ??
                            String(localized: "Unavailable")
                    )
                    HStack {
                        Text("Remaining")
                        Spacer()
                        Text(budgetMoney(progress.remainingMinor, budget: budget))
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    if progress.isPartial {
                        Label(
                            "Some transactions need a conversion rate; this total is partial.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(LedgerTheme.warning)
                    }
                    if !progress.isActive {
                        Text("This budget is outside its active date range.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Progress unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(LedgerTheme.negative)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ledgerCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(
            selectedTracker?.role.canEditFinancialData == true
                ? String(localized: "Opens budget editing")
                : String(localized: "Read-only budget")
        ))
    }

    private func budgetMoney(_ minor: Int64, budget: LocalBudget) -> String {
        (try? Money(
            minorUnits: minor,
            currencyCode: budget.currencyCode,
            exponent: budget.currencyExponent
        ).formatted(locale: .current)) ?? "—"
    }

    private func formattedPercent(_ basisPoints: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(
            from: NSDecimalNumber(value: Double(basisPoints) / 10_000)
        ) ?? "—"
    }

    private func presentCreate() {
        guard let trackerID = selectedTracker?.id else { return }
        sheet = .create(trackerID: trackerID)
    }

    private func tracker(for destination: BudgetSheet) -> LocalTracker? {
        switch destination {
        case let .create(trackerID): trackers.first { $0.id == trackerID }
        case let .edit(budget): trackers.first { $0.id == budget.trackerID }
        }
    }

    private func budget(for destination: BudgetSheet) -> LocalBudget? {
        guard case let .edit(budget) = destination else { return nil }
        return budget
    }

    private func selectedCategoryIDs(for destination: BudgetSheet) -> Set<UUID> {
        guard let budget = budget(for: destination) else { return [] }
        return Set(budgetCategories.filter { $0.budgetID == budget.id }.map(\.categoryID))
    }

    private func thresholdValues(for destination: BudgetSheet) -> [Int] {
        guard let budget = budget(for: destination) else { return [50, 80, 100] }
        return budgetThresholds.filter { $0.budgetID == budget.id }.map(\.percent).sorted()
    }

    private func updateArchive(_ budget: LocalBudget) {
        do {
            try LocalLedgerRepository(context: modelContext).setBudgetArchived(
                budget,
                archived: budget.archivedAt == nil
            )
            triggerSync()
        } catch {
            safeError = String(localized: "The budget could not be updated locally.")
        }
    }

    private func delete(_ budget: LocalBudget) {
        do {
            try LocalLedgerRepository(context: modelContext).deleteBudget(budget)
            triggerSync()
        } catch {
            safeError = String(localized: "The budget could not be deleted locally.")
        }
    }

    private func triggerSync() {
        Task {
            await reminders.refresh(scopeKey: scopeKey)
            await sync.synchronize(session: session)
        }
    }
}

private struct BudgetEditorView: View {
    let scopeKey: String
    let tracker: LocalTracker
    let budget: LocalBudget?
    let categories: [LocalCategory]
    let thresholdValues: [Int]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var name: String
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var budgetScope: BudgetScope
    @State private var period: BudgetPeriod
    @State private var startsOn: Date
    @State private var hasEndDate: Bool
    @State private var endsOn: Date
    @State private var rollover: Bool
    @State private var selectedCategoryIDs: Set<UUID>
    @State private var safeError: String?

    init(
        scopeKey: String,
        tracker: LocalTracker,
        budget: LocalBudget?,
        categories: [LocalCategory],
        selectedCategoryIDs: Set<UUID>,
        thresholdValues: [Int]
    ) {
        self.scopeKey = scopeKey
        self.tracker = tracker
        self.budget = budget
        self.categories = categories
        self.thresholdValues = thresholdValues
        _name = State(initialValue: budget?.name ?? String(localized: "Monthly spending"))
        _amountText = State(
            initialValue: budget?.money?.editableMajorUnits(locale: .current) ?? ""
        )
        _currencyCode = State(initialValue: budget?.currencyCode ?? tracker.baseCurrencyCode)
        _budgetScope = State(initialValue: budget?.budgetScope ?? .tracker)
        _period = State(initialValue: budget?.period ?? .monthly)
        _startsOn = State(
            initialValue: budget.flatMap {
                BudgetDateCodec.presentationDate(from: $0.startsOn)
            } ?? .now
        )
        _hasEndDate = State(initialValue: budget?.endsOn != nil)
        _endsOn = State(
            initialValue: budget?.endsOn.flatMap {
                BudgetDateCodec.presentationDate(from: $0)
            } ?? Calendar.current.date(
                byAdding: .month,
                value: 1,
                to: .now
            ) ?? .now
        )
        _rollover = State(initialValue: budget?.rollover ?? false)
        _selectedCategoryIDs = State(initialValue: selectedCategoryIDs)
    }

    private var selectedCurrency: CurrencyDefinition {
        availableCurrencies.first { $0.code == currencyCode } ?? availableCurrencies[0]
    }

    private var availableCurrencies: [CurrencyDefinition] {
        let exponent = budget?.currencyExponent ?? tracker.baseCurrencyExponent
        let current = CurrencyDefinition(code: currencyCode, exponent: exponent)
        return CurrencyCatalog.priority.contains(where: { $0.code == current.code })
            ? CurrencyCatalog.priority
            : [current] + CurrencyCatalog.priority
    }

    var body: some View {
        NavigationStack {
            Form {
                if let safeError {
                    Section {
                        Label(safeError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LedgerTheme.negative)
                    }
                }

                Section("Budget") {
                    TextField("Name", text: $name)
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(availableCurrencies) { currency in
                            Text(currency.code).tag(currency.code)
                        }
                    }
                    Picker("Period", selection: $period) {
                        ForEach(BudgetPeriod.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Picker("Scope", selection: $budgetScope) {
                        ForEach(BudgetScope.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }

                if budgetScope == .categories {
                    Section("Expense categories") {
                        if categories.isEmpty {
                            Text("Create an active expense category before using a category budget.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(categories) { category in
                            Toggle(
                                category.name,
                                isOn: Binding(
                                    get: { selectedCategoryIDs.contains(category.id) },
                                    set: { selected in
                                        if selected {
                                            selectedCategoryIDs.insert(category.id)
                                        } else {
                                            selectedCategoryIDs.remove(category.id)
                                        }
                                    }
                                )
                            )
                        }
                    }
                }

                Section {
                    DatePicker("Starts", selection: $startsOn, displayedComponents: .date)
                    if period == .custom {
                        DatePicker("Ends", selection: $endsOn, displayedComponents: .date)
                    } else {
                        Toggle("End on a date", isOn: $hasEndDate)
                        if hasEndDate {
                            DatePicker("Ends", selection: $endsOn, displayedComponents: .date)
                        }
                    }
                    Toggle("Roll unused amount forward", isOn: $rollover)
                        .disabled(period == .custom)
                } header: {
                    Text("Dates")
                } footer: {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Budget time zone explanation format"),
                            budget?.timeZoneIdentifier ?? TimeZone.current.identifier
                        )
                    )
                }

                Section {
                    Text(thresholdValues.map { "\($0)%" }.joined(separator: " · "))
                        .monospacedDigit()
                } header: {
                    Text("Alerts")
                } footer: {
                    Text(
                        "When local notifications are enabled, crossing these thresholds can alert you. Budget totals remain correct even if notifications are off."
                    )
                }
            }
            .navigationTitle(budget == nil ? "New budget" : "Edit budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onChange(of: period) { _, value in
                if value == .custom { hasEndDate = true }
                if value == .custom { rollover = false }
            }
            .onChange(of: budgetScope) { _, value in
                if value == .tracker { selectedCategoryIDs.removeAll() }
            }
        }
    }

    private func save() {
        do {
            let money = try Money.positive(
                majorUnits: amountText,
                currencyCode: selectedCurrency.code,
                exponent: selectedCurrency.exponent,
                locale: .current
            )
            let selectedCategories = categories.filter {
                selectedCategoryIDs.contains($0.id)
            }
            let end = period == .custom || hasEndDate ? endsOn : nil
            let repository = LocalLedgerRepository(context: modelContext)
            if let budget {
                try repository.updateBudget(
                    budget,
                    tracker: tracker,
                    name: name,
                    budgetScope: budgetScope,
                    period: period,
                    money: money,
                    timeZoneIdentifier: budget.timeZoneIdentifier,
                    startsOn: startsOn,
                    endsOn: end,
                    rollover: rollover,
                    categories: selectedCategories,
                    thresholds: thresholdValues
                )
            } else {
                try repository.createBudget(
                    scopeKey: scopeKey,
                    tracker: tracker,
                    name: name,
                    budgetScope: budgetScope,
                    period: period,
                    money: money,
                    timeZoneIdentifier: TimeZone.current.identifier,
                    startsOn: startsOn,
                    endsOn: end,
                    rollover: rollover,
                    categories: selectedCategories,
                    thresholds: thresholdValues
                )
            }
            dismiss()
            Task {
                await reminders.refresh(scopeKey: scopeKey)
                await sync.synchronize(session: session)
            }
        } catch let error as MoneyError {
            switch error {
            case .tooManyFractionDigits:
                safeError = String(localized: "The amount has too many decimal places.")
            case .nonPositiveAmount:
                safeError = String(localized: "Enter an amount greater than zero.")
            default:
                safeError = String(localized: "Enter a valid budget amount.")
            }
        } catch {
            safeError = String(localized: "Check the dates, category selection, and tracker access.")
        }
    }
}

struct SyncStateIcon: View {
    let state: LocalSyncState

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityLabel(state.displayName)
    }

    private var symbol: String {
        switch state {
        case .pending: "arrow.triangle.2.circlepath"
        case .syncing: "arrow.triangle.2.circlepath.circle"
        case .synced: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .conflicted: "arrow.triangle.branch"
        }
    }

    private var color: Color {
        switch state {
        case .pending, .syncing: LedgerTheme.warning
        case .synced: LedgerTheme.positive
        case .failed, .conflicted: LedgerTheme.negative
        }
    }
}
