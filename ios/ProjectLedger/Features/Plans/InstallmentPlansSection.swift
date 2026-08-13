import Foundation
import SwiftData
import SwiftUI
import UIKit

private enum InstallmentSheet: Identifiable {
    case create
    case edit(LocalInstallmentPlan)
    case detail(LocalInstallmentPlan)

    var id: String {
        switch self {
        case .create: "create-installment"
        case let .edit(plan): "edit-installment-\(plan.id)"
        case let .detail(plan): "detail-installment-\(plan.id)"
        }
    }
}

struct InstallmentPlansSection: View {
    let scopeKey: String
    let tracker: LocalTracker

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var plans: [LocalInstallmentPlan]
    @Query private var scheduleItems: [LocalInstallmentScheduleItem]
    @Query private var payments: [LocalInstallmentPayment]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @State private var sheet: InstallmentSheet?
    @State private var pendingDelete: LocalInstallmentPlan?
    @State private var includeArchived = false
    @State private var safeError: String?

    init(scopeKey: String, tracker: LocalTracker) {
        self.scopeKey = scopeKey
        self.tracker = tracker
        _plans = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalInstallmentPlan.startsOn
        )
        _scheduleItems = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalInstallmentScheduleItem.dueOn
        )
        _payments = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalInstallmentPayment.appliedAt,
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

    private var trackerPlans: [LocalInstallmentPlan] {
        plans.filter {
            $0.trackerID == tracker.id && (includeArchived || $0.archivedAt == nil)
        }
    }

    private var trackerAccounts: [LocalAccount] {
        accounts.filter { $0.trackerID == tracker.id }
    }

    private var trackerCategories: [LocalCategory] {
        categories.filter { $0.trackerID == tracker.id && $0.kind == .expense }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerTheme.contentSpacing) {
            HStack {
                Label("Installment plans", systemImage: "calendar.badge.plus")
                    .font(.title3.bold())
                Spacer()
                Menu {
                    Toggle("Show archived installment plans", isOn: $includeArchived)
                } label: {
                    Label("Installment options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Installment options")
                if tracker.role.canEditFinancialData {
                    Button {
                        sheet = .create
                    } label: {
                        Label("Create installment plan", systemImage: "plus.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Create installment plan")
                }
            }

            if let safeError {
                Label(safeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(LedgerTheme.negative)
                    .ledgerCard()
            }

            if trackerPlans.isEmpty {
                ContentUnavailableView {
                    Label("No installment plans yet", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Build an exact local schedule and sync payments when a connection is available.")
                } actions: {
                    if tracker.role.canEditFinancialData {
                        Button("Create installment plan") { sheet = .create }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .ledgerCard()
            } else {
                ForEach(trackerPlans) { plan in
                    planCard(plan)
                        .contextMenu { contextActions(plan) }
                }
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .create:
                InstallmentPlanEditorView(
                    scopeKey: scopeKey,
                    tracker: tracker,
                    plan: nil,
                    accounts: trackerAccounts,
                    categories: trackerCategories,
                    hasPaymentHistory: false
                )
            case let .edit(plan):
                InstallmentPlanEditorView(
                    scopeKey: scopeKey,
                    tracker: tracker,
                    plan: plan,
                    accounts: trackerAccounts,
                    categories: trackerCategories,
                    hasPaymentHistory: payments.contains { $0.planID == plan.id } ||
                        scheduleItems.contains {
                            $0.planID == plan.id && $0.supersededAt == nil && $0.paidMinor > 0
                        }
                )
            case let .detail(plan):
                InstallmentPlanDetailView(
                    scopeKey: scopeKey,
                    tracker: tracker,
                    plan: plan,
                    account: trackerAccounts.first { $0.id == plan.accountID }
                )
            }
        }
        .confirmationDialog(
            "Delete this installment plan?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete installment plan", role: .destructive) {
                if let plan = pendingDelete { delete(plan) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Payments and linked transactions stay auditable. The plan deletion syncs as a tombstone.")
        }
    }

    private func planCard(_ plan: LocalInstallmentPlan) -> some View {
        let progress = try? LocalInstallmentCalculator.progress(
            plan: plan,
            scheduleItems: scheduleItems.filter { $0.planID == plan.id },
            payments: payments.filter { $0.planID == plan.id }
        )
        return Button {
            sheet = .detail(plan)
        } label: {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name)
                            .font(.headline)
                        Text("\(plan.cadence.displayName) · \(plan.installmentCount.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    SyncStateIcon(state: plan.syncState)
                    if plan.archivedAt != nil {
                        Text("Archived")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    } else if plan.state != .active {
                        Text(plan.state.displayName)
                            .font(.caption2.bold())
                            .foregroundStyle(
                                plan.state == .cancelled
                                    ? LedgerTheme.warning : Color(uiColor: .secondaryLabel)
                            )
                    }
                }

                ProgressView(value: progressFraction(progress))
                    .tint(plan.state == .paidOff ? LedgerTheme.positive : LedgerTheme.accent)
                    .accessibilityLabel("Installment progress")
                    .accessibilityValue(progressAccessibility(progress, plan: plan))

                HStack {
                    VStack(alignment: .leading) {
                        Text("Remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(money(progress?.remainingMinor ?? plan.plannedTotalMinor, plan: plan))
                            .font(.title3.bold().monospacedDigit())
                    }
                    Spacer()
                    if let nextDue = progress?.nextDueOn {
                        VStack(alignment: .trailing) {
                            Text("Next due")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(presentedDate(nextDue))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(
                                    nextDue < today
                                        ? LedgerTheme.negative : Color(uiColor: .label)
                                )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ledgerCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens installment plan details")
    }

    @ViewBuilder
    private func contextActions(_ plan: LocalInstallmentPlan) -> some View {
        if tracker.role.canEditFinancialData {
            if plan.state == .active && plan.archivedAt == nil {
                Button("Edit installment plan", systemImage: "pencil") {
                    sheet = .edit(plan)
                }
                Button("Cancel installment plan", systemImage: "xmark.circle") {
                    perform { try LocalLedgerRepository(context: modelContext)
                        .cancelInstallmentPlan(plan) }
                }
            }
            if plan.archivedAt == nil {
                Button("Archive installment plan", systemImage: "archivebox") {
                    archive(plan, archived: true)
                }
            } else {
                Button("Restore installment plan", systemImage: "arrow.uturn.backward") {
                    archive(plan, archived: false)
                }
            }
            Button("Delete installment plan", systemImage: "trash", role: .destructive) {
                pendingDelete = plan
            }
        }
    }

    private var today: Date {
        Calendar.current.startOfDay(for: .now)
    }

    private func progressFraction(_ progress: LocalInstallmentProgress?) -> Double {
        guard let progress, progress.plannedTotalMinor > 0 else { return 0 }
        return min(max(Double(progress.paidMinor) / Double(progress.plannedTotalMinor), 0), 1)
    }

    private func progressAccessibility(
        _ progress: LocalInstallmentProgress?,
        plan: LocalInstallmentPlan
    ) -> String {
        guard let progress else { return String(localized: "Progress unavailable") }
        return String.localizedStringWithFormat(
            String(localized: "Installment paid and remaining format"),
            money(progress.paidMinor, plan: plan),
            money(progress.remainingMinor, plan: plan)
        )
    }

    private func money(_ minor: Int64, plan: LocalInstallmentPlan) -> String {
        (try? Money(
            minorUnits: minor,
            currencyCode: plan.currencyCode,
            exponent: plan.currencyExponent
        ).formatted(locale: .current)) ?? "—"
    }

    private func presentedDate(_ value: Date) -> String {
        (BudgetDateCodec.presentationDate(from: value) ?? value).formatted(
            date: .abbreviated,
            time: .omitted
        )
    }

    private func archive(_ plan: LocalInstallmentPlan, archived: Bool) {
        perform {
            try LocalLedgerRepository(context: modelContext).setInstallmentPlanArchived(
                plan,
                archived: archived
            )
        }
    }

    private func delete(_ plan: LocalInstallmentPlan) {
        perform { try LocalLedgerRepository(context: modelContext).deleteInstallmentPlan(plan) }
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
            safeError = String(localized: "The installment plan could not be updated locally.")
        }
    }
}

private struct InstallmentPlanEditorView: View {
    let scopeKey: String
    let tracker: LocalTracker
    let plan: LocalInstallmentPlan?
    let accounts: [LocalAccount]
    let categories: [LocalCategory]
    let hasPaymentHistory: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var name: String
    @State private var principalText: String
    @State private var interestText: String
    @State private var feesText: String
    @State private var installmentCount: Int
    @State private var usesRegularAmount: Bool
    @State private var regularAmountText: String
    @State private var cadence: InstallmentCadence
    @State private var startsOn: Date
    @State private var timeZoneIdentifier: String
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var safeError: String?

    init(
        scopeKey: String,
        tracker: LocalTracker,
        plan: LocalInstallmentPlan?,
        accounts: [LocalAccount],
        categories: [LocalCategory],
        hasPaymentHistory: Bool
    ) {
        self.scopeKey = scopeKey
        self.tracker = tracker
        self.plan = plan
        self.accounts = accounts
        self.categories = categories
        self.hasPaymentHistory = hasPaymentHistory
        let defaultAccount = accounts.first {
            $0.id == tracker.defaultAccountID && $0.archivedAt == nil
        } ?? accounts.first { $0.archivedAt == nil }
        let defaultCategory = categories.first {
            $0.id == tracker.defaultCategoryID && $0.archivedAt == nil
        }
        _name = State(initialValue: plan?.name ?? String(localized: "New purchase"))
        _principalText = State(initialValue: Self.editable(plan?.principalMinor, plan: plan))
        _interestText = State(initialValue: Self.editable(plan?.interestMinor, plan: plan))
        _feesText = State(initialValue: Self.editable(plan?.feesMinor, plan: plan))
        _installmentCount = State(initialValue: plan?.installmentCount ?? 12)
        _usesRegularAmount = State(initialValue: plan?.plannedInstallmentMinor != nil)
        _regularAmountText = State(
            initialValue: Self.editable(plan?.plannedInstallmentMinor, plan: plan)
        )
        _cadence = State(initialValue: plan?.cadence ?? .monthly)
        _startsOn = State(
            initialValue: plan.flatMap { BudgetDateCodec.presentationDate(from: $0.startsOn) } ?? .now
        )
        _timeZoneIdentifier = State(
            initialValue: plan?.timeZoneIdentifier ?? TimeZone.current.identifier
        )
        _accountID = State(initialValue: plan?.accountID ?? defaultAccount?.id)
        _categoryID = State(initialValue: plan?.categoryID ?? defaultCategory?.id)
    }

    private var currencyCode: String { plan?.currencyCode ?? tracker.baseCurrencyCode }
    private var currencyExponent: Int {
        plan?.currencyExponent ?? tracker.baseCurrencyExponent
    }
    private var eligibleAccounts: [LocalAccount] {
        accounts.filter {
            $0.archivedAt == nil || $0.id == plan?.accountID
        }
    }
    private var eligibleCategories: [LocalCategory] {
        categories.filter { $0.archivedAt == nil || $0.id == plan?.categoryID }
    }
    private var termsLocked: Bool { hasPaymentHistory }

    var body: some View {
        NavigationStack {
            Form {
                if let safeError {
                    Section {
                        Label(safeError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LedgerTheme.negative)
                    }
                }

                Section("Installment plan") {
                    TextField("Name", text: $name)
                    Picker("Account", selection: $accountID) {
                        Text("Choose account").tag(UUID?.none)
                        ForEach(eligibleAccounts) { account in
                            Text("\(account.name) · \(account.currencyCode)")
                                .tag(Optional(account.id))
                        }
                    }
                    Picker("Category", selection: $categoryID) {
                        Text("No category").tag(UUID?.none)
                        ForEach(eligibleCategories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    TextField("Time zone", text: $timeZoneIdentifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Terms") {
                    TextField("Principal", text: $principalText)
                        .keyboardType(.decimalPad)
                    TextField("Interest", text: $interestText)
                        .keyboardType(.decimalPad)
                    TextField("Fees", text: $feesText)
                        .keyboardType(.decimalPad)
                    LabeledContent("Currency", value: currencyCode)
                    Stepper(
                        String.localizedStringWithFormat(
                            String(localized: "Installment count format"),
                            installmentCount
                        ),
                        value: $installmentCount,
                        in: 1 ... LocalInstallmentCalculator.maximumInstallmentCount
                    )
                    Toggle("Use a regular payment amount", isOn: $usesRegularAmount)
                    if usesRegularAmount {
                        TextField("Regular payment", text: $regularAmountText)
                            .keyboardType(.decimalPad)
                    }
                }
                .disabled(termsLocked)

                Section("Schedule") {
                    Picker("Cadence", selection: $cadence) {
                        ForEach(InstallmentCadence.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    DatePicker("Starts", selection: $startsOn, displayedComponents: .date)
                } footer: {
                    if termsLocked {
                        Text("Financial terms stay fixed after the first payment. Name, account, category, and time zone metadata remain editable.")
                    } else {
                        Text("Monthly schedules keep the original day and clamp only when a month is shorter.")
                    }
                }
                .disabled(termsLocked)
            }
            .navigationTitle(plan == nil ? "New installment plan" : "Edit installment plan")
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
        }
    }

    private func save() {
        do {
            guard let account = eligibleAccounts.first(where: { $0.id == accountID }) else {
                throw LocalLedgerError.invalidReference
            }
            let principal = try Money.positive(
                majorUnits: principalText,
                currencyCode: currencyCode,
                exponent: currencyExponent,
                locale: .current
            )
            let interest = try nonnegativeMinor(interestText)
            let fees = try nonnegativeMinor(feesText)
            let regular = usesRegularAmount
                ? try Money.positive(
                    majorUnits: regularAmountText,
                    currencyCode: currencyCode,
                    exponent: currencyExponent,
                    locale: .current
                ).minorUnits
                : nil
            let category = eligibleCategories.first { $0.id == categoryID }
            let repository = LocalLedgerRepository(context: modelContext)
            if let plan {
                try repository.updateInstallmentPlan(
                    plan,
                    tracker: tracker,
                    account: account,
                    category: category,
                    name: name,
                    principal: principal,
                    interestMinor: interest,
                    feesMinor: fees,
                    installmentCount: installmentCount,
                    plannedInstallmentMinor: regular,
                    cadence: cadence,
                    timeZoneIdentifier: timeZoneIdentifier,
                    startsOn: startsOn
                )
            } else {
                try repository.createInstallmentPlan(
                    scopeKey: scopeKey,
                    tracker: tracker,
                    account: account,
                    category: category,
                    name: name,
                    principal: principal,
                    interestMinor: interest,
                    feesMinor: fees,
                    installmentCount: installmentCount,
                    plannedInstallmentMinor: regular,
                    cadence: cadence,
                    timeZoneIdentifier: timeZoneIdentifier,
                    startsOn: startsOn
                )
            }
            Task {
                await reminders.refresh(scopeKey: scopeKey)
                await sync.synchronize(session: session)
            }
            dismiss()
        } catch {
            safeError = String(localized: "Check the account, amounts, count, schedule, and tracker access.")
        }
    }

    private func nonnegativeMinor(_ text: String) throws -> Int64 {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return 0 }
        let separator = Locale.current.decimalSeparator ?? "."
        let digits = clean.replacingOccurrences(of: separator, with: "")
        if !digits.isEmpty && digits.allSatisfy({ $0 == "0" }) { return 0 }
        return try Money.positive(
            majorUnits: clean,
            currencyCode: currencyCode,
            exponent: currencyExponent,
            locale: .current
        ).minorUnits
    }

    private static func editable(
        _ value: Int64?,
        plan: LocalInstallmentPlan?
    ) -> String {
        guard let value else { return "" }
        return (try? Money(
            minorUnits: value,
            currencyCode: plan?.currencyCode ?? "ALL",
            exponent: plan?.currencyExponent ?? 2
        ).editableMajorUnits(locale: .current)) ?? ""
    }
}

private enum InstallmentPaymentMode: Identifiable {
    case regular(LocalInstallmentScheduleItem)
    case extra
    case payoff

    var id: String {
        switch self {
        case let .regular(item): "regular-\(item.id)"
        case .extra: "extra"
        case .payoff: "payoff"
        }
    }
}

private struct InstallmentPlanDetailView: View {
    let scopeKey: String
    let tracker: LocalTracker
    let plan: LocalInstallmentPlan
    let account: LocalAccount?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var scheduleItems: [LocalInstallmentScheduleItem]
    @Query private var payments: [LocalInstallmentPayment]
    @State private var paymentMode: InstallmentPaymentMode?
    @State private var rescheduleItem: LocalInstallmentScheduleItem?
    @State private var confirmsCancel = false
    @State private var safeError: String?

    init(
        scopeKey: String,
        tracker: LocalTracker,
        plan: LocalInstallmentPlan,
        account: LocalAccount?
    ) {
        self.scopeKey = scopeKey
        self.tracker = tracker
        self.plan = plan
        self.account = account
        let planID = plan.id
        _scheduleItems = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.planID == planID && $0.deletedAt == nil
            },
            sort: \LocalInstallmentScheduleItem.dueOn
        )
        _payments = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.planID == planID && $0.deletedAt == nil
            },
            sort: \LocalInstallmentPayment.appliedAt,
            order: .reverse
        )
    }

    private var activeSchedule: [LocalInstallmentScheduleItem] {
        scheduleItems.filter { $0.supersededAt == nil }.sorted {
            $0.dueOn == $1.dueOn ? $0.sequence < $1.sequence : $0.dueOn < $1.dueOn
        }
    }

    private var progress: LocalInstallmentProgress? {
        try? LocalInstallmentCalculator.progress(
            plan: plan,
            scheduleItems: scheduleItems,
            payments: payments
        )
    }

    private var canRecordPayment: Bool {
        guard let account else { return false }
        return tracker.role.canEditFinancialData &&
            plan.state == .active &&
            plan.archivedAt == nil &&
            account.archivedAt == nil &&
            account.deletedAt == nil
    }

    var body: some View {
        NavigationStack {
            List {
                if let safeError {
                    Section {
                        Label(safeError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LedgerTheme.negative)
                    }
                }

                Section("Progress") {
                    LabeledContent("Planned total", value: money(plan.plannedTotalMinor))
                    LabeledContent("Paid", value: money(progress?.paidMinor ?? 0))
                    LabeledContent(
                        "Remaining",
                        value: money(progress?.remainingMinor ?? plan.plannedTotalMinor)
                    )
                    if let next = progress?.nextDueOn {
                        LabeledContent("Next due", value: presentedDate(next))
                    }
                    if let payoff = progress?.estimatedPayoffOn {
                        LabeledContent("Estimated payoff", value: presentedDate(payoff))
                    }
                    LabeledContent("State", value: plan.state.displayName)
                    LabeledContent("Revision", value: plan.revisionNumber.formatted())
                }

                if canRecordPayment {
                    Section("Payment actions") {
                        Button("Record extra payment", systemImage: "plus.circle") {
                            paymentMode = .extra
                        }
                        Button("Pay off plan", systemImage: "checkmark.seal") {
                            paymentMode = .payoff
                        }
                    }
                } else if tracker.role.canEditFinancialData,
                          plan.state == .active,
                          plan.archivedAt == nil {
                    Section {
                        Label(
                            "Restore or replace the linked account before recording a payment.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(LedgerTheme.warning)
                    }
                }

                Section("Schedule") {
                    ForEach(activeSchedule) { item in
                        VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                            HStack {
                                Text(
                                    String.localizedStringWithFormat(
                                        String(localized: "Installment number format"),
                                        item.sequence
                                    )
                                )
                                .font(.headline)
                                Spacer()
                                Text(item.state.displayName)
                                    .font(.caption.bold())
                                    .foregroundStyle(itemStateColor(item))
                            }
                            HStack {
                                Text(presentedDate(item.dueOn))
                                Spacer()
                                Text(money(item.plannedTotalMinor))
                                    .font(.body.monospacedDigit())
                            }
                            if item.paidMinor > 0 && item.state != .paid {
                                Text(
                                    String.localizedStringWithFormat(
                                        String(localized: "Installment paid format"),
                                        money(item.paidMinor)
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            if canRecordPayment,
                               item.state != .paid,
                               item.state != .skipped {
                                HStack {
                                    Button("Record payment") {
                                        paymentMode = .regular(item)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    Button("Reschedule") { rescheduleItem = item }
                                        .buttonStyle(.bordered)
                                    if item.state == .planned {
                                        Button("Skip") { skip(item) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !payments.isEmpty {
                    Section("Payment history") {
                        ForEach(payments) { payment in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(money(payment.amountMinor))
                                        .font(.headline.monospacedDigit())
                                    Spacer()
                                    Text(payment.appliedAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Text(paymentLabel(payment))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if payment.overpaymentMinor > 0 {
                                    Text(
                                        String.localizedStringWithFormat(
                                            String(localized: "Overpayment format"),
                                            money(payment.overpaymentMinor)
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(LedgerTheme.warning)
                                }
                            }
                        }
                    }
                }

                if tracker.role.canEditFinancialData,
                   plan.state == .active,
                   plan.archivedAt == nil {
                    Section {
                        Button("Cancel installment plan", role: .destructive) {
                            confirmsCancel = true
                        }
                    } footer: {
                        Text("Cancelling stops future payments but preserves the original schedule and history.")
                    }
                }
            }
            .navigationTitle(plan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $paymentMode) { mode in
                if let account {
                    InstallmentPaymentEditorView(
                        tracker: tracker,
                        plan: plan,
                        account: account,
                        mode: mode,
                        remainingMinor: progress?.remainingMinor ?? plan.plannedTotalMinor
                    )
                }
            }
            .sheet(item: $rescheduleItem) { item in
                InstallmentRescheduleView(plan: plan, item: item)
            }
            .confirmationDialog(
                "Cancel this installment plan?",
                isPresented: $confirmsCancel,
                titleVisibility: .visible
            ) {
                Button("Cancel installment plan", role: .destructive) { cancelPlan() }
                Button("Keep plan", role: .cancel) {}
            } message: {
                Text("Existing payments and transactions remain unchanged and auditable.")
            }
        }
    }

    private func skip(_ item: LocalInstallmentScheduleItem) {
        perform {
            try LocalLedgerRepository(context: modelContext).skipInstallmentPayment(
                item,
                in: plan
            )
        }
    }

    private func cancelPlan() {
        perform { try LocalLedgerRepository(context: modelContext).cancelInstallmentPlan(plan) }
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
            safeError = String(localized: "The installment action could not be saved locally.")
        }
    }

    private func money(_ minor: Int64) -> String {
        (try? Money(
            minorUnits: minor,
            currencyCode: plan.currencyCode,
            exponent: plan.currencyExponent
        ).formatted(locale: .current)) ?? "—"
    }

    private func presentedDate(_ value: Date) -> String {
        (BudgetDateCodec.presentationDate(from: value) ?? value).formatted(
            date: .abbreviated,
            time: .omitted
        )
    }

    private func itemStateColor(_ item: LocalInstallmentScheduleItem) -> Color {
        switch item.state {
        case .planned: .secondary
        case .partiallyPaid: LedgerTheme.warning
        case .paid: LedgerTheme.positive
        case .skipped: .secondary
        }
    }

    private func paymentLabel(_ payment: LocalInstallmentPayment) -> String {
        if payment.overpaymentMinor > 0 { return String(localized: "Confirmed overpayment") }
        return payment.extraPayment
            ? String(localized: "Extra payment") : String(localized: "Regular payment")
    }
}

private struct InstallmentPaymentEditorView: View {
    let tracker: LocalTracker
    let plan: LocalInstallmentPlan
    let account: LocalAccount
    let mode: InstallmentPaymentMode
    let remainingMinor: Int64

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var amountText: String
    @State private var accountAmountText = ""
    @State private var baseAmountText = ""
    @State private var occurredAt = Date.now
    @State private var confirmsOverpayment = false
    @State private var safeError: String?

    init(
        tracker: LocalTracker,
        plan: LocalInstallmentPlan,
        account: LocalAccount,
        mode: InstallmentPaymentMode,
        remainingMinor: Int64
    ) {
        self.tracker = tracker
        self.plan = plan
        self.account = account
        self.mode = mode
        self.remainingMinor = remainingMinor
        let suggested: Int64
        switch mode {
        case let .regular(item):
            suggested = max(item.plannedTotalMinor - item.paidMinor, 0)
        case .extra:
            suggested = min(plan.plannedInstallmentMinor ?? remainingMinor, remainingMinor)
        case .payoff:
            suggested = remainingMinor
        }
        _amountText = State(
            initialValue: (try? Money(
                minorUnits: suggested,
                currencyCode: plan.currencyCode,
                exponent: plan.currencyExponent
            ).editableMajorUnits(locale: .current)) ?? ""
        )
    }

    private var needsAccountConversion: Bool {
        account.currencyCode != plan.currencyCode ||
            account.currencyExponent != plan.currencyExponent
    }
    private var needsBaseConversion: Bool { tracker.baseCurrencyCode != plan.currencyCode }
    private var enteredMinor: Int64? {
        try? Money.positive(
            majorUnits: amountText,
            currencyCode: plan.currencyCode,
            exponent: plan.currencyExponent,
            locale: .current
        ).minorUnits
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
                Section("Payment") {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    LabeledContent("Currency", value: plan.currencyCode)
                    DatePicker("Date", selection: $occurredAt)
                }
                if needsAccountConversion {
                    Section("Account conversion") {
                        TextField("Account amount", text: $accountAmountText)
                            .keyboardType(.decimalPad)
                        LabeledContent("Account currency", value: account.currencyCode)
                    } footer: {
                        Text("Enter the exact account-currency amount. No exchange rate is invented.")
                    }
                }
                if needsBaseConversion {
                    Section("Reporting conversion") {
                        TextField("Base amount", text: $baseAmountText)
                            .keyboardType(.decimalPad)
                        LabeledContent("Base currency", value: tracker.baseCurrencyCode)
                    } footer: {
                        Text("This manual snapshot is retained for historical reports.")
                    }
                }
                if let enteredMinor, enteredMinor > remainingMinor {
                    Section {
                        Toggle("Confirm overpayment", isOn: $confirmsOverpayment)
                    } footer: {
                        Text("Only the remaining balance is applied to the plan. The excess stays explicit in payment history.")
                    }
                }
                Section {
                    Text("The expense and account movement are saved on this iPhone before synchronization. Payment history becomes authoritative after the server acknowledges it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
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
        }
    }

    private var title: String {
        switch mode {
        case .regular: String(localized: "Record payment")
        case .extra: String(localized: "Extra payment")
        case .payoff: String(localized: "Pay off plan")
        }
    }

    private func save() {
        do {
            let amount = try Money.positive(
                majorUnits: amountText,
                currencyCode: plan.currencyCode,
                exponent: plan.currencyExponent,
                locale: .current
            )
            let accountMoney = needsAccountConversion ? try Money.positive(
                majorUnits: accountAmountText,
                currencyCode: account.currencyCode,
                exponent: account.currencyExponent,
                locale: .current
            ) : nil
            let baseMoney = needsBaseConversion ? try Money.positive(
                majorUnits: baseAmountText,
                currencyCode: tracker.baseCurrencyCode,
                exponent: tracker.baseCurrencyExponent,
                locale: .current
            ) : nil
            let repository = LocalLedgerRepository(context: modelContext)
            switch mode {
            case let .regular(item):
                try repository.recordInstallmentPayment(
                    in: plan,
                    tracker: tracker,
                    account: account,
                    scheduleItem: item,
                    amount: amount,
                    accountMoney: accountMoney,
                    baseMoney: baseMoney,
                    occurredAt: occurredAt,
                    confirmOverpayment: confirmsOverpayment
                )
            case .extra:
                try repository.recordInstallmentPayment(
                    in: plan,
                    tracker: tracker,
                    account: account,
                    scheduleItem: nil,
                    amount: amount,
                    accountMoney: accountMoney,
                    baseMoney: baseMoney,
                    occurredAt: occurredAt,
                    extraPayment: true,
                    confirmOverpayment: confirmsOverpayment
                )
            case .payoff:
                try repository.payOffInstallmentPlan(
                    plan,
                    tracker: tracker,
                    account: account,
                    amount: amount,
                    accountMoney: accountMoney,
                    baseMoney: baseMoney,
                    occurredAt: occurredAt,
                    confirmOverpayment: confirmsOverpayment
                )
            }
            Task {
                await reminders.refresh(scopeKey: plan.scopeKey)
                await sync.synchronize(session: session)
            }
            dismiss()
        } catch {
            safeError = String(localized: "Check the payment amount, conversions, remaining balance, and tracker access.")
        }
    }
}

private struct InstallmentRescheduleView: View {
    let plan: LocalInstallmentPlan
    let item: LocalInstallmentScheduleItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var dueOn: Date
    @State private var safeError: String?

    init(plan: LocalInstallmentPlan, item: LocalInstallmentScheduleItem) {
        self.plan = plan
        self.item = item
        _dueOn = State(
            initialValue: BudgetDateCodec.presentationDate(from: item.dueOn) ?? item.dueOn
        )
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
                Section("Reschedule payment") {
                    DatePicker("New due date", selection: $dueOn, displayedComponents: .date)
                } footer: {
                    Text("The original due date remains in revision history.")
                }
            }
            .navigationTitle("Reschedule payment")
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
        do {
            try LocalLedgerRepository(context: modelContext).rescheduleInstallmentPayment(
                item,
                in: plan,
                dueOn: dueOn
            )
            Task {
                await reminders.refresh(scopeKey: plan.scopeKey)
                await sync.synchronize(session: session)
            }
            dismiss()
        } catch {
            safeError = String(localized: "The new due date could not be saved locally.")
        }
    }
}
