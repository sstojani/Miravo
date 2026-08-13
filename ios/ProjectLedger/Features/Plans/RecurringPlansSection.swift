import Foundation
import SwiftData
import SwiftUI
import UIKit

private enum RecurringSheet: Identifiable {
    case create
    case edit(LocalRecurringRule)

    var id: String {
        switch self {
        case .create: "create-recurring"
        case let .edit(rule): "edit-recurring-\(rule.id)"
        }
    }
}

struct RecurringPlansSection: View {
    let scopeKey: String
    let tracker: LocalTracker

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var rules: [LocalRecurringRule]
    @Query private var occurrences: [LocalRecurringOccurrence]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @State private var sheet: RecurringSheet?
    @State private var pendingDelete: LocalRecurringRule?
    @State private var includeArchived = false
    @State private var safeError: String?

    init(scopeKey: String, tracker: LocalTracker) {
        self.scopeKey = scopeKey
        self.tracker = tracker
        _rules = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalRecurringRule.nextDueAt
        )
        _occurrences = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalRecurringOccurrence.scheduledFor,
            order: .reverse
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

    private var trackerRules: [LocalRecurringRule] {
        rules.filter {
            $0.trackerID == tracker.id && (includeArchived || $0.archivedAt == nil)
        }
    }

    private var trackerAccounts: [LocalAccount] {
        accounts.filter { $0.trackerID == tracker.id }
    }

    private var trackerCategories: [LocalCategory] {
        categories.filter { $0.trackerID == tracker.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerTheme.contentSpacing) {
            HStack {
                Label("Recurring and subscriptions", systemImage: "clock.arrow.circlepath")
                    .font(.title3.bold())
                Spacer()
                Menu {
                    Toggle("Show archived recurring rules", isOn: $includeArchived)
                } label: {
                    Label("Recurring options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Recurring options")
                if tracker.role.canEditFinancialData {
                    Button {
                        sheet = .create
                    } label: {
                        Label("Create recurring rule", systemImage: "plus.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Create recurring rule")
                }
            }

            if let safeError {
                Label(safeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(LedgerTheme.negative)
                    .ledgerCard()
            }

            if trackerRules.isEmpty {
                ContentUnavailableView {
                    Label("No recurring rules yet", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Schedule an expense, income, or subscription. Changes save offline first.")
                } actions: {
                    if tracker.role.canEditFinancialData {
                        Button("Create recurring rule") { sheet = .create }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .ledgerCard()
            } else {
                ForEach(trackerRules) { rule in
                    ruleCard(rule)
                        .contextMenu { contextActions(rule) }
                }
            }

            reminderSettingsCard

            Label(
                "Installment plans are the next planning slice.",
                systemImage: "calendar.badge.plus"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .sheet(item: $sheet) { destination in
            RecurringRuleEditorView(
                scopeKey: scopeKey,
                tracker: tracker,
                rule: rule(for: destination),
                accounts: trackerAccounts,
                categories: trackerCategories
            )
        }
        .confirmationDialog(
            "Delete this recurring rule?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete recurring rule", role: .destructive) {
                if let rule = pendingDelete { delete(rule) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Posted occurrences remain in transaction history. The rule deletion syncs as a tombstone.")
        }
    }

    private var reminderSettingsCard: some View {
        VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
            Toggle(
                "Local recurring reminders",
                isOn: Binding(
                    get: { reminders.isEnabled },
                    set: { enabled in
                        Task { await reminders.setEnabled(enabled, scopeKey: scopeKey) }
                    }
                )
            )
            .font(.headline)

            if reminders.isEnabled {
                Picker(
                    "Reminder timing",
                    selection: Binding(
                        get: { reminders.leadTime },
                        set: { value in
                            Task { await reminders.setLeadTime(value, scopeKey: scopeKey) }
                        }
                    )
                ) {
                    ForEach(RecurringReminderLeadTime.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }

            LabeledContent(
                "Notification permission",
                value: reminders.authorizationState.displayName
            )
            LabeledContent(
                "Scheduled reminders",
                value: reminders.scheduledCount.formatted()
            )

            if reminders.authorizationState == .denied {
                Button("Open notification settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.bordered)
            }

            Text("Reminder notifications use generic text and never show an amount, merchant, note, or subscription name.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = reminders.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(LedgerTheme.warning)
            }
        }
        .disabled(reminders.isUpdating)
        .ledgerCard()
    }

    private func ruleCard(_ rule: LocalRecurringRule) -> some View {
        let lastOccurrence = occurrences.first { $0.ruleID == rule.id }
        let normalized = rule.isSubscription
            ? try? LocalRecurrenceCalculator.normalizedCost(
                for: rule,
                baseCurrencyExponent: tracker.baseCurrencyExponent
            ) : nil
        return Button {
            if tracker.role.canEditFinancialData && rule.state != .ended {
                sheet = .edit(rule)
            }
        } label: {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(rule.name)
                                .font(.headline)
                            if rule.isSubscription {
                                Text("Subscription")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(LedgerTheme.accent.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(ruleDescriptor(rule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    SyncStateIcon(state: rule.syncState)
                    stateLabel(rule)
                }

                HStack {
                    Text(rule.money?.formatted(locale: .current) ?? "—")
                        .font(.title3.bold().monospacedDigit())
                    Spacer()
                    Label(nextDueText(rule), systemImage: dueSymbol(rule))
                        .font(.subheadline)
                        .foregroundStyle(dueColor(rule))
                }

                if let normalized {
                    HStack {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Monthly cost format"),
                                normalized.monthly.formatted(locale: .current)
                            )
                        )
                        Spacer()
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Annual cost format"),
                                normalized.annual.formatted(locale: .current)
                            )
                        )
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                if let lastOccurrence {
                    Label(
                        occurrenceText(lastOccurrence),
                        systemImage: occurrenceSymbol(lastOccurrence)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ledgerCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            tracker.role.canEditFinancialData && rule.state != .ended
                ? Text("Opens recurring rule editing") : Text("Read-only recurring rule")
        )
    }

    @ViewBuilder
    private func stateLabel(_ rule: LocalRecurringRule) -> some View {
        if rule.archivedAt != nil {
            Text("Archived")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        } else if rule.state != .active {
            Text(rule.state.displayName)
                .font(.caption2.bold())
                .foregroundStyle(
                    rule.state == .paused
                        ? LedgerTheme.warning : Color(uiColor: .secondaryLabel)
                )
        }
    }

    @ViewBuilder
    private func contextActions(_ rule: LocalRecurringRule) -> some View {
        if tracker.role.canEditFinancialData {
            if rule.state != .ended && rule.archivedAt == nil {
                Button("Edit recurring rule", systemImage: "pencil") {
                    sheet = .edit(rule)
                }
                if rule.state == .active {
                    Button("Pause", systemImage: "pause.circle") { pause(rule) }
                } else if rule.state == .paused {
                    Button("Resume", systemImage: "play.circle") { resume(rule) }
                }
                Button("Skip next occurrence", systemImage: "forward.end.circle") {
                    skip(rule)
                }
                Button("End recurring rule", systemImage: "stop.circle") { end(rule) }
            }
            if rule.archivedAt == nil {
                Button("Archive recurring rule", systemImage: "archivebox") {
                    archive(rule, archived: true)
                }
            } else {
                Button("Restore recurring rule", systemImage: "arrow.uturn.backward") {
                    archive(rule, archived: false)
                }
            }
            Button("Delete recurring rule", systemImage: "trash", role: .destructive) {
                pendingDelete = rule
            }
        }
    }

    private func rule(for destination: RecurringSheet) -> LocalRecurringRule? {
        guard case let .edit(rule) = destination else { return nil }
        return rule
    }

    private func ruleDescriptor(_ rule: LocalRecurringRule) -> String {
        if rule.cadence == .custom, let unit = rule.customIntervalUnit {
            return String.localizedStringWithFormat(
                String(localized: "Custom cadence format"),
                rule.customIntervalCount,
                unit.displayName
            )
        }
        return "\(rule.kind.displayName) · \(rule.cadence.displayName)"
    }

    private func nextDueText(_ rule: LocalRecurringRule) -> String {
        guard rule.state != .ended else { return String(localized: "No future occurrence") }
        return String.localizedStringWithFormat(
            String(localized: "Next due format"),
            rule.nextDueAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    private func dueSymbol(_ rule: LocalRecurringRule) -> String {
        rule.state == .active && rule.nextDueAt < .now
            ? "exclamationmark.circle" : "calendar"
    }

    private func dueColor(_ rule: LocalRecurringRule) -> Color {
        rule.state == .active && rule.nextDueAt < .now
            ? LedgerTheme.negative : Color(uiColor: .secondaryLabel)
    }

    private func occurrenceText(_ occurrence: LocalRecurringOccurrence) -> String {
        switch occurrence.state {
        case .posted:
            String(localized: "Last occurrence posted")
        case .skipped:
            String(localized: "Last occurrence skipped")
        case .failed:
            String(localized: "Last occurrence needs attention")
        }
    }

    private func occurrenceSymbol(_ occurrence: LocalRecurringOccurrence) -> String {
        switch occurrence.state {
        case .posted: "checkmark.circle"
        case .skipped: "forward.end.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func pause(_ rule: LocalRecurringRule) {
        perform { try LocalLedgerRepository(context: modelContext).pauseRecurringRule(rule) }
    }

    private func resume(_ rule: LocalRecurringRule) {
        perform { try LocalLedgerRepository(context: modelContext).resumeRecurringRule(rule) }
    }

    private func skip(_ rule: LocalRecurringRule) {
        perform {
            try LocalLedgerRepository(context: modelContext).skipNextRecurringOccurrence(rule)
        }
    }

    private func end(_ rule: LocalRecurringRule) {
        perform { try LocalLedgerRepository(context: modelContext).endRecurringRule(rule) }
    }

    private func archive(_ rule: LocalRecurringRule, archived: Bool) {
        perform {
            try LocalLedgerRepository(context: modelContext).setRecurringRuleArchived(
                rule,
                archived: archived
            )
        }
    }

    private func delete(_ rule: LocalRecurringRule) {
        perform { try LocalLedgerRepository(context: modelContext).deleteRecurringRule(rule) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            safeError = nil
            Task {
                await reminders.refresh(scopeKey: scopeKey)
                await sync.synchronize(session: session)
            }
        } catch {
            safeError = String(localized: "The recurring rule could not be updated locally.")
        }
    }
}

private struct RecurringRuleEditorView: View {
    let scopeKey: String
    let tracker: LocalTracker
    let rule: LocalRecurringRule?
    let accounts: [LocalAccount]
    let categories: [LocalCategory]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var name: String
    @State private var amountText: String
    @State private var kind: RecurringRuleKind
    @State private var isSubscription: Bool
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var merchant: String
    @State private var note: String
    @State private var cadence: RecurringCadence
    @State private var customUnit: RecurringIntervalUnit
    @State private var customCount: Int
    @State private var startsOn: Date
    @State private var hasEndDate: Bool
    @State private var endsOn: Date
    @State private var localTime: Date
    @State private var provider: String
    @State private var hasTrialEnd: Bool
    @State private var trialEndsOn: Date
    @State private var cancellationURL: String
    @State private var subscriptionNote: String
    @State private var safeError: String?

    init(
        scopeKey: String,
        tracker: LocalTracker,
        rule: LocalRecurringRule?,
        accounts: [LocalAccount],
        categories: [LocalCategory]
    ) {
        self.scopeKey = scopeKey
        self.tracker = tracker
        self.rule = rule
        self.accounts = accounts
        self.categories = categories
        let initialStart = rule.flatMap {
            BudgetDateCodec.presentationDate(from: $0.startsOn)
        } ?? .now
        let initialKind = rule?.kind ?? .expense
        let defaultAccountID = accounts.first(where: {
            $0.id == tracker.defaultAccountID &&
                $0.archivedAt == nil &&
                $0.currencyCode == tracker.baseCurrencyCode
        })?.id ?? accounts.first(where: {
            $0.archivedAt == nil && $0.currencyCode == tracker.baseCurrencyCode
        })?.id
        let defaultCategoryID = categories.first(where: {
            $0.id == tracker.defaultCategoryID &&
                $0.archivedAt == nil &&
                $0.kind == (initialKind == .income ? .income : .expense)
        })?.id
        _name = State(initialValue: rule?.name ?? String(localized: "Monthly payment"))
        _amountText = State(initialValue: rule?.money?.editableMajorUnits(locale: .current) ?? "")
        _kind = State(initialValue: initialKind)
        _isSubscription = State(initialValue: rule?.isSubscription ?? false)
        _accountID = State(initialValue: rule?.accountID ?? defaultAccountID)
        _categoryID = State(initialValue: rule?.categoryID ?? defaultCategoryID)
        _merchant = State(initialValue: rule?.merchant ?? "")
        _note = State(initialValue: rule?.note ?? "")
        _cadence = State(initialValue: rule?.cadence ?? .monthly)
        _customUnit = State(initialValue: rule?.customIntervalUnit ?? .month)
        _customCount = State(initialValue: rule?.customIntervalCount ?? 2)
        _startsOn = State(initialValue: initialStart)
        _hasEndDate = State(initialValue: rule?.endsOn != nil)
        _endsOn = State(initialValue: rule?.endsOn.flatMap {
            BudgetDateCodec.presentationDate(from: $0)
        } ?? Calendar.current.date(byAdding: .year, value: 1, to: initialStart) ?? initialStart)
        _localTime = State(initialValue: RecurringTimeCodec.date(
            from: rule?.localTimeSeconds ?? 9 * 3_600
        ))
        _provider = State(initialValue: rule?.subscriptionProvider ?? "")
        _hasTrialEnd = State(initialValue: rule?.trialEndsOn != nil)
        _trialEndsOn = State(initialValue: rule?.trialEndsOn.flatMap {
            BudgetDateCodec.presentationDate(from: $0)
        } ?? initialStart)
        _cancellationURL = State(initialValue: rule?.cancellationURL ?? "")
        _subscriptionNote = State(initialValue: rule?.subscriptionNote ?? "")
    }

    private var eligibleAccounts: [LocalAccount] {
        if locksConvertedMoney, let rule {
            return accounts.filter {
                $0.id == rule.accountID ||
                    ($0.archivedAt == nil && $0.currencyCode == rule.currencyCode)
            }
        }
        return accounts.filter {
            ($0.archivedAt == nil && $0.currencyCode == tracker.baseCurrencyCode) ||
                $0.id == rule?.accountID
        }
    }

    private var locksConvertedMoney: Bool {
        guard let rule,
              let currentAccount = accounts.first(where: { $0.id == rule.accountID })
        else {
            return self.rule != nil
        }
        return rule.currencyCode != tracker.baseCurrencyCode ||
            currentAccount.currencyCode != rule.currencyCode
    }

    private var selectedAccount: LocalAccount? {
        eligibleAccounts.first { $0.id == accountID }
    }

    private var matchingCategories: [LocalCategory] {
        categories.filter {
            $0.kind == (kind == .income ? .income : .expense) &&
                ($0.archivedAt == nil || $0.id == rule?.categoryID)
        }
    }

    private var ruleCurrencyCode: String {
        rule?.currencyCode ?? tracker.baseCurrencyCode
    }

    private var ruleCurrencyExponent: Int {
        rule?.currencyExponent ?? tracker.baseCurrencyExponent
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

                Section("Recurring rule") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(RecurringRuleKind.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .disabled(locksConvertedMoney)
                    LabeledContent("Currency", value: ruleCurrencyCode)
                    Picker("Account", selection: $accountID) {
                        if rule == nil {
                            Text("Choose account").tag(UUID?.none)
                        }
                        ForEach(eligibleAccounts) { account in
                            Text("\(account.name) · \(account.currencyCode)")
                                .tag(Optional(account.id))
                        }
                    }
                    Picker("Category", selection: $categoryID) {
                        Text("No category").tag(UUID?.none)
                        ForEach(matchingCategories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    TextField("Merchant or payee", text: $merchant)
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(2 ... 5)
                } footer: {
                    Text("New rules use the tracker base currency. Existing converted rules keep their amount and stored rate; account changes are limited to matching-currency accounts.")
                }

                Section("Schedule") {
                    Picker("Cadence", selection: $cadence) {
                        ForEach(RecurringCadence.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    if cadence == .custom {
                        Stepper(
                            String.localizedStringWithFormat(
                                String(localized: "Every count format"),
                                customCount
                            ),
                            value: $customCount,
                            in: 2 ... 365
                        )
                        Picker("Interval unit", selection: $customUnit) {
                            ForEach(RecurringIntervalUnit.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                    }
                    DatePicker("Starts", selection: $startsOn, displayedComponents: .date)
                    DatePicker("Time", selection: $localTime, displayedComponents: .hourAndMinute)
                    Toggle("End on a date", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("Ends", selection: $endsOn, displayedComponents: .date)
                    }
                } footer: {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Recurring time zone format"),
                            rule?.timeZoneIdentifier ?? TimeZone.current.identifier
                        )
                    )
                }

                Section("Subscription") {
                    Toggle("Track as subscription", isOn: $isSubscription)
                    if isSubscription {
                        TextField("Provider", text: $provider)
                        Toggle("Trial ends on a date", isOn: $hasTrialEnd)
                        if hasTrialEnd {
                            DatePicker(
                                "Trial ends",
                                selection: $trialEndsOn,
                                displayedComponents: .date
                            )
                        }
                        TextField("Cancellation URL", text: $cancellationURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        TextField("Subscription note", text: $subscriptionNote, axis: .vertical)
                            .lineLimit(2 ... 4)
                    }
                }
            }
            .navigationTitle(
                rule == nil
                    ? String(localized: "New recurring rule")
                    : String(localized: "Edit recurring rule")
            )
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
            .onChange(of: kind) { _, _ in categoryID = nil }
            .onChange(of: isSubscription) { _, enabled in
                if !enabled {
                    provider = ""
                    hasTrialEnd = false
                    cancellationURL = ""
                    subscriptionNote = ""
                }
            }
        }
    }

    private func save() {
        do {
            guard let account = selectedAccount else {
                throw LocalLedgerError.invalidReference
            }
            let money = try Money.positive(
                majorUnits: amountText,
                currencyCode: ruleCurrencyCode,
                exponent: ruleCurrencyExponent,
                locale: .current
            )
            let category = matchingCategories.first { $0.id == categoryID }
            let accountMoney = try existingAccountMoney(account: account, original: money)
            let baseMoney = try existingBaseMoney(original: money)
            let repository = LocalLedgerRepository(context: modelContext)
            let sharedArguments = RecurringEditorValues(
                category: category,
                money: money,
                accountMoney: accountMoney,
                baseMoney: baseMoney,
                customUnit: cadence == .custom ? customUnit : nil,
                customCount: cadence == .custom ? customCount : 1,
                endsOn: hasEndDate ? endsOn : nil,
                localTimeSeconds: RecurringTimeCodec.seconds(from: localTime),
                trialEndsOn: isSubscription && hasTrialEnd ? trialEndsOn : nil
            )
            if let rule {
                try repository.updateRecurringRule(
                    rule,
                    tracker: tracker,
                    account: account,
                    category: sharedArguments.category,
                    name: name,
                    kind: kind,
                    isSubscription: isSubscription,
                    money: sharedArguments.money,
                    accountMoney: sharedArguments.accountMoney,
                    manualBaseMoney: sharedArguments.baseMoney,
                    merchant: merchant,
                    note: note,
                    cadence: cadence,
                    customIntervalUnit: sharedArguments.customUnit,
                    customIntervalCount: sharedArguments.customCount,
                    timeZoneIdentifier: rule.timeZoneIdentifier,
                    startsOn: startsOn,
                    endsOn: sharedArguments.endsOn,
                    localTimeSeconds: sharedArguments.localTimeSeconds,
                    subscriptionProvider: provider,
                    trialEndsOn: sharedArguments.trialEndsOn,
                    cancellationURL: cancellationURL,
                    subscriptionNote: subscriptionNote
                )
            } else {
                try repository.createRecurringRule(
                    scopeKey: scopeKey,
                    tracker: tracker,
                    account: account,
                    category: sharedArguments.category,
                    name: name,
                    kind: kind,
                    isSubscription: isSubscription,
                    money: sharedArguments.money,
                    accountMoney: sharedArguments.accountMoney,
                    manualBaseMoney: sharedArguments.baseMoney,
                    merchant: merchant,
                    note: note,
                    cadence: cadence,
                    customIntervalUnit: sharedArguments.customUnit,
                    customIntervalCount: sharedArguments.customCount,
                    timeZoneIdentifier: TimeZone.current.identifier,
                    startsOn: startsOn,
                    endsOn: sharedArguments.endsOn,
                    localTimeSeconds: sharedArguments.localTimeSeconds,
                    subscriptionProvider: provider,
                    trialEndsOn: sharedArguments.trialEndsOn,
                    cancellationURL: cancellationURL,
                    subscriptionNote: subscriptionNote
                )
            }
            dismiss()
            Task {
                await reminders.refresh(scopeKey: scopeKey)
                await sync.synchronize(session: session)
            }
        } catch let error as MoneyError {
            safeError = error == .tooManyFractionDigits
                ? String(localized: "The amount has too many decimal places.")
                : String(localized: "Enter a valid recurring amount.")
        } catch {
            safeError = String(
                localized: "Check the account, schedule, subscription fields, and tracker access."
            )
        }
    }

    private func existingAccountMoney(account: LocalAccount, original: Money) throws -> Money? {
        guard account.currencyCode != original.currencyCode else { return nil }
        guard let rule, rule.accountID == account.id else {
            throw MoneyError.conversionRequired
        }
        return try Money(
            minorUnits: rule.accountAmountMinor,
            currencyCode: account.currencyCode,
            exponent: account.currencyExponent
        )
    }

    private func existingBaseMoney(original: Money) throws -> Money? {
        guard original.currencyCode != tracker.baseCurrencyCode else { return nil }
        guard let rule else { throw MoneyError.conversionRequired }
        return try Money(
            minorUnits: rule.baseAmountMinor,
            currencyCode: tracker.baseCurrencyCode,
            exponent: tracker.baseCurrencyExponent
        )
    }
}

private struct RecurringEditorValues {
    let category: LocalCategory?
    let money: Money
    let accountMoney: Money?
    let baseMoney: Money?
    let customUnit: RecurringIntervalUnit?
    let customCount: Int
    let endsOn: Date?
    let localTimeSeconds: Int
    let trialEndsOn: Date?
}
