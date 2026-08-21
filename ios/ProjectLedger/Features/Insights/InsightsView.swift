import Charts
import Foundation
import SwiftData
import SwiftUI

struct InsightsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [LedgerTransaction]
    @Query private var trackers: [LocalTracker]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @Query private var allocations: [LocalCategoryAllocation]
    @Query private var budgets: [LocalBudget]
    @Query private var budgetCategories: [LocalBudgetCategory]
    @Query private var budgetThresholds: [LocalBudgetThreshold]
    @Query private var recurringRules: [LocalRecurringRule]
    @Query private var installmentPlans: [LocalInstallmentPlan]
    @Query private var scheduleItems: [LocalInstallmentScheduleItem]
    @Query private var installmentPayments: [LocalInstallmentPayment]
    @Query private var participants: [LocalParticipant]

    private let scopeKey: String

    @State private var selectedTrackerID: UUID?
    @State private var selectedAccountID: UUID?
    @State private var selectedCurrencyCode = ""
    @State private var selectedRange = AnalyticsRangePreset.thisMonth

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _transactions = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LedgerTransaction.occurredAt,
            order: .reverse
        )
        _trackers = Query(sort: \LocalTracker.sortOrder)
        _accounts = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalAccount.name
        )
        _categories = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalCategory.sortOrder
        )
        _allocations = Query(filter: #Predicate { $0.scopeKey == scopeKey })
        _budgets = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.deletedAt == nil && $0.archivedAt == nil
            },
            sort: \LocalBudget.name
        )
        _budgetCategories = Query(filter: #Predicate { $0.scopeKey == scopeKey })
        _budgetThresholds = Query(filter: #Predicate { $0.scopeKey == scopeKey })
        _recurringRules = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.deletedAt == nil && $0.archivedAt == nil
            },
            sort: \LocalRecurringRule.name
        )
        _installmentPlans = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.deletedAt == nil && $0.archivedAt == nil
            },
            sort: \LocalInstallmentPlan.name
        )
        _scheduleItems = Query(filter: #Predicate { $0.scopeKey == scopeKey })
        _installmentPayments = Query(filter: #Predicate { $0.scopeKey == scopeKey })
        _participants = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalParticipant.displayName
        )
    }

    private var availableTrackers: [LocalTracker] {
        trackers.filter { tracker in
            tracker.scopeKey == scopeKey &&
                tracker.deletedAt == nil &&
                tracker.archivedAt == nil &&
                tracker.accessRevokedAt == nil
        }
    }

    private var selectedTracker: LocalTracker? {
        availableTrackers.first { $0.id == selectedTrackerID } ?? availableTrackers.first
    }

    private var trackerAccounts: [LocalAccount] {
        guard let tracker = selectedTracker else { return [] }
        return accounts.filter { $0.trackerID == tracker.id && $0.archivedAt == nil }
    }

    private var reportingCurrencies: [AnalyticsCurrencyOption] {
        guard let tracker = selectedTracker else { return [] }
        var exponents = [tracker.baseCurrencyCode: tracker.baseCurrencyExponent]
        for transaction in transactions where transaction.trackerID == tracker.id {
            exponents[transaction.currencyCode] = exponents[transaction.currencyCode]
                ?? transaction.currencyExponent
        }
        return exponents.map { AnalyticsCurrencyOption(code: $0.key, exponent: $0.value) }
            .sorted {
                if $0.code == tracker.baseCurrencyCode { return true }
                if $1.code == tracker.baseCurrencyCode { return false }
                return $0.code < $1.code
            }
    }

    private var selectedCurrency: AnalyticsCurrencyOption? {
        reportingCurrencies.first { $0.code == selectedCurrencyCode }
            ?? reportingCurrencies.first
    }

    private var snapshotResult: Result<LocalAnalyticsSnapshot, Error>? {
        guard let tracker = selectedTracker, let currency = selectedCurrency else { return nil }
        let trackerCategories = categories.filter { $0.trackerID == tracker.id }
        let rawCategoryNames = trackerCategories.reduce(into: [UUID: String]()) {
            $0[$1.id] = $1.name
        }
        let categoryNames = trackerCategories.reduce(into: [UUID: String]()) { values, category in
            if let parentID = category.parentID, let parentName = rawCategoryNames[parentID] {
                values[category.id] = "\(parentName) · \(category.name)"
            } else {
                values[category.id] = category.name
            }
        }
        let records = transactions.filter { $0.trackerID == tracker.id }.map {
            LocalAnalyticsTransactionInput(
                id: $0.id,
                trackerID: $0.trackerID,
                accountID: $0.accountID,
                destinationAccountID: $0.destinationAccountID,
                categoryID: $0.categoryID,
                kind: $0.kind,
                source: $0.source,
                status: $0.status,
                amountMinor: $0.amountMinor,
                currencyCode: $0.currencyCode,
                currencyExponent: $0.currencyExponent,
                baseAmountMinor: $0.baseAmountMinor,
                baseCurrencyCode: $0.baseCurrencyCode,
                baseCurrencyExponent: tracker.baseCurrencyExponent,
                rateSource: $0.rateSource,
                merchant: $0.merchant,
                occurredAt: $0.occurredAt,
                refundOfID: $0.refundOfID,
                deleted: $0.deletedAt != nil
            )
        }
        let recordIDs = Set(records.map(\.id))
        let categoryAllocations: [LocalAnalyticsAllocationInput] = allocations.compactMap { allocation -> LocalAnalyticsAllocationInput? in
            guard recordIDs.contains(allocation.transactionID) else { return nil }
            return LocalAnalyticsAllocationInput(
                transactionID: allocation.transactionID,
                categoryID: allocation.categoryID,
                amountMinor: allocation.amountMinor
            )
        }
        return Result {
            try LocalAnalyticsCalculator.calculate(
                configuration: LocalAnalyticsConfiguration(
                    trackerID: tracker.id,
                    accountID: selectedAccountID,
                    reportingCurrencyCode: currency.code,
                    reportingCurrencyExponent: currency.exponent,
                    range: selectedRange
                ),
                transactions: records,
                allocations: categoryAllocations,
                categoryNames: categoryNames
            )
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerTheme.contentSpacing) {
                if availableTrackers.isEmpty {
                    ContentUnavailableView(
                        "No available tracker",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Create or synchronize a tracker before viewing insights.")
                    )
                    .ledgerCard()
                } else {
                    filters
                    if let snapshotResult {
                        switch snapshotResult {
                        case let .success(snapshot):
                            analyticsContent(snapshot)
                        case .failure:
                            ContentUnavailableView(
                                "Insights unavailable",
                                systemImage: "exclamationmark.triangle",
                                description: Text(
                                    "A local financial invariant failed. No partial total was guessed."
                                )
                            )
                            .ledgerCard()
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Insights")
        .task { normalizeSelections(resetCurrency: false) }
        .onChange(of: availableTrackers.map(\.id)) { _, _ in
            normalizeSelections(resetCurrency: false)
        }
        .onChange(of: selectedTrackerID) { _, _ in
            normalizeSelections(resetCurrency: true)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
            Label("Report filters", systemImage: "line.3.horizontal.decrease.circle")
                .font(.headline)
            Picker("Tracker", selection: $selectedTrackerID) {
                ForEach(availableTrackers) { tracker in
                    Text(tracker.name).tag(Optional(tracker.id))
                }
            }
            Picker("Time range", selection: $selectedRange) {
                ForEach(AnalyticsRangePreset.allCases) { range in
                    Text(range.displayName).tag(range)
                }
            }
            Picker("Account", selection: $selectedAccountID) {
                Text("All accounts").tag(Optional<UUID>.none)
                ForEach(trackerAccounts) { account in
                    Text(account.name).tag(Optional(account.id))
                }
            }
            Picker("Reporting currency", selection: $selectedCurrencyCode) {
                ForEach(reportingCurrencies) { currency in
                    Text(verbatim: currency.code).tag(currency.code)
                }
            }
        }
        .ledgerCard()
    }

    @ViewBuilder
    private func analyticsContent(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        summary(snapshot)

        if snapshot.isPartial {
            partialConversion(snapshot)
        }

        if snapshot.recordCount == 0 {
            if snapshot.unconverted.isEmpty {
                ContentUnavailableView(
                    "No reportable transactions",
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        "Change the filters or add a posted expense or income record."
                    )
                )
                .ledgerCard()
            } else {
                ContentUnavailableView(
                    "No converted records",
                    systemImage: "coloncurrencysign.circle",
                    description: Text(
                        "Choose an original transaction currency or add the missing historical rates."
                    )
                )
                .ledgerCard()
            }
        } else {
            trend(snapshot)
            categoryBreakdown(snapshot)
            merchantBreakdown(snapshot)
            sourceBreakdown(snapshot)
        }

        accountBalances(snapshot)
        budgetProgress
        subscriptionCosts(snapshot)
        installmentProgress
        splitBalances
        methodology(snapshot)
    }

    private func summary(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
            HStack {
                InsightMetric(
                    title: "Spending",
                    value: formatted(snapshot.spendingMinor, snapshot: snapshot),
                    color: LedgerTheme.negative
                )
                Divider()
                InsightMetric(
                    title: "Income",
                    value: formatted(snapshot.incomeMinor, snapshot: snapshot),
                    color: LedgerTheme.positive
                )
            }
            Divider()
            LabeledContent("Net cash flow") {
                Text(formatted(snapshot.cashFlowMinor, snapshot: snapshot))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(
                        snapshot.cashFlowMinor < 0 ? LedgerTheme.negative : LedgerTheme.positive
                    )
                    .minimumScaleFactor(0.7)
            }
            LabeledContent("Included records", value: snapshot.recordCount, format: .number)
        }
        .ledgerCard()
        .accessibilityElement(children: .combine)
    }

    private func partialConversion(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
            Label("Partial currency conversion", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(LedgerTheme.warning)
            Text(
                "These records have no stored snapshot into the selected reporting currency and are excluded from combined totals."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(snapshot.unconverted) { item in
                LabeledContent(
                    String.localizedStringWithFormat(
                        String(localized: "Excluded records count format"),
                        item.transactionCount
                    )
                ) {
                    Text(formatted(
                        item.amountMinor,
                        currencyCode: item.currencyCode,
                        exponent: item.currencyExponent
                    ))
                    .font(.subheadline.monospacedDigit())
                }
            }
        }
        .ledgerCard()
    }

    private func trend(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
            Text("Spending and income trend")
                .font(.headline)
            Chart(snapshot.trend) { point in
                LineMark(
                    x: .value("Period", point.bucketStart),
                    y: .value(
                        "Spending",
                        majorUnits(
                            point.spendingMinor,
                            exponent: snapshot.reportingCurrencyExponent
                        )
                    ),
                    series: .value("Series", String(localized: "Spending"))
                )
                .foregroundStyle(LedgerTheme.negative)
                LineMark(
                    x: .value("Period", point.bucketStart),
                    y: .value(
                        "Income",
                        majorUnits(
                            point.incomeMinor,
                            exponent: snapshot.reportingCurrencyExponent
                        )
                    ),
                    series: .value("Series", String(localized: "Income"))
                )
                .foregroundStyle(LedgerTheme.positive)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            .frame(height: 210)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .accessibilityLabel("Spending and income trend chart")
            .accessibilityValue(String.localizedStringWithFormat(
                String(localized: "Trend summary accessibility format"),
                formatted(snapshot.spendingMinor, snapshot: snapshot),
                formatted(snapshot.incomeMinor, snapshot: snapshot),
                snapshot.trend.count
            ))
            HStack(spacing: LedgerTheme.contentSpacing) {
                Label("Spending", systemImage: "circle.fill")
                    .foregroundStyle(LedgerTheme.negative)
                Label("Income", systemImage: "square.fill")
                    .foregroundStyle(LedgerTheme.positive)
            }
            .font(.caption)
            if snapshot.trendWasTruncated {
                Text(String.localizedStringWithFormat(
                    String(localized: "Trend limited periods format"),
                    LocalAnalyticsCalculator.maximumTrendPointCount
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .ledgerCard()
    }

    @ViewBuilder
    private func categoryBreakdown(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        if !snapshot.categories.isEmpty {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                Text("Spending by category")
                    .font(.headline)
                Chart(snapshot.categories.prefix(6)) { item in
                    BarMark(
                        x: .value("Amount", majorUnits(item.amountMinor, exponent: snapshot.reportingCurrencyExponent)),
                        y: .value("Category", categoryName(item))
                    )
                    .foregroundStyle(LedgerTheme.accent)
                }
                .frame(minHeight: 180)
                .accessibilityLabel("Spending by category chart")
                .accessibilityValue(categoryAccessibilitySummary(snapshot))
                ForEach(snapshot.categories.prefix(8)) { item in
                    breakdownRow(item, name: categoryName(item), snapshot: snapshot)
                }
            }
            .ledgerCard()
        }
    }

    @ViewBuilder
    private func merchantBreakdown(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        if !snapshot.merchants.isEmpty {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                Text("Merchant totals")
                    .font(.headline)
                ForEach(snapshot.merchants.prefix(8)) { item in
                    breakdownRow(
                        item,
                        name: item.name.isEmpty ? String(localized: "No merchant") : item.name,
                        snapshot: snapshot
                    )
                }
            }
            .ledgerCard()
        }
    }

    @ViewBuilder
    private func sourceBreakdown(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        if !snapshot.sources.isEmpty {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                Text("Expense sources")
                    .font(.headline)
                ForEach(snapshot.sources) { item in
                    breakdownRow(item, name: sourceName(item.id), snapshot: snapshot)
                }
            }
            .ledgerCard()
        }
    }

    @ViewBuilder
    private func accountBalances(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        let result = currentAccountBalanceResult
        if !result.items.isEmpty || result.failureCount > 0 {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                Text("Account balances and net worth")
                    .font(.headline)
                ForEach(result.items) { balance in
                    LabeledContent(balance.name) {
                        Text(balance.money.formatted(locale: .current))
                            .font(.subheadline.monospacedDigit())
                    }
                }
                Divider()
                LabeledContent("Net worth in reporting currency") {
                    Text(netWorth(snapshot: snapshot, balances: result.items) ?? "—")
                        .font(.headline.monospacedDigit())
                }
                let excluded = result.items.filter {
                    $0.includeInNetWorth &&
                        ($0.money.currencyCode != snapshot.reportingCurrencyCode ||
                            $0.money.exponent != snapshot.reportingCurrencyExponent)
                }.count
                if excluded > 0 {
                    Text(String.localizedStringWithFormat(
                        String(localized: "Net worth excluded accounts format"),
                        excluded
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                calculationWarning(count: result.failureCount)
            }
            .ledgerCard()
        }
    }

    @ViewBuilder
    private var budgetProgress: some View {
        let result = currentBudgetResult
        if !result.items.isEmpty || result.failureCount > 0 {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                Text("Budget progress")
                    .font(.headline)
                ForEach(result.items) { insight in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(insight.name) {
                            Text(formatted(
                                insight.spentMinor,
                                currencyCode: insight.currencyCode,
                                exponent: insight.currencyExponent
                            ))
                            .font(.subheadline.monospacedDigit())
                        }
                        ProgressView(value: insight.progress)
                            .tint(insight.progress > 1 ? LedgerTheme.negative : LedgerTheme.accent)
                            .accessibilityLabel(insight.name)
                            .accessibilityValue(String.localizedStringWithFormat(
                                String(localized: "Budget progress accessibility format"),
                                formatted(
                                    insight.spentMinor,
                                    currencyCode: insight.currencyCode,
                                    exponent: insight.currencyExponent
                                ),
                                formatted(
                                    insight.availableMinor,
                                    currencyCode: insight.currencyCode,
                                    exponent: insight.currencyExponent
                                )
                            ))
                        if insight.isPartial {
                            Label("Partial conversion", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(LedgerTheme.warning)
                        }
                    }
                }
                calculationWarning(count: result.failureCount)
            }
            .ledgerCard()
        }
    }

    @ViewBuilder
    private func subscriptionCosts(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        if let subscriptions = subscriptionSummary {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                Text("Active subscription cost")
                    .font(.headline)
                if let monthly = subscriptions.monthly,
                   let annual = subscriptions.annual {
                    LabeledContent("Monthly") {
                        Text(monthly.formatted(locale: .current))
                            .font(.subheadline.monospacedDigit())
                    }
                    LabeledContent("Annualized") {
                        Text(annual.formatted(locale: .current))
                            .font(.subheadline.monospacedDigit())
                    }
                }
                LabeledContent("Subscriptions", value: subscriptions.count, format: .number)
                if let monthly = subscriptions.monthly,
                   snapshot.reportingCurrencyCode != monthly.currencyCode {
                    Text("Subscription totals use the tracker's stored base-currency snapshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                calculationWarning(count: subscriptions.failureCount)
            }
            .ledgerCard()
        }
    }

    @ViewBuilder
    private var installmentProgress: some View {
        let result = currentInstallmentResult
        if !result.items.isEmpty || result.failureCount > 0 {
            VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                Text("Installment remaining")
                    .font(.headline)
                ForEach(result.items) { insight in
                    LabeledContent(insight.name) {
                        Text(insight.remaining.formatted(locale: .current))
                            .font(.subheadline.monospacedDigit())
                    }
                }
                calculationWarning(count: result.failureCount)
            }
            .ledgerCard()
        }
    }

    @ViewBuilder
    private var splitBalances: some View {
        if let result = currentSplitDebtResult {
            switch result {
            case let .success(debts):
                if !debts.isEmpty {
                    VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                        Text("Open split balances")
                            .font(.headline)
                        ForEach(debts.prefix(8)) { debt in
                            LabeledContent(
                                String.localizedStringWithFormat(
                                    String(localized: "Debt direction format"),
                                    participantName(debt.fromParticipantID),
                                    participantName(debt.toParticipantID)
                                )
                            ) {
                                Text(formatted(
                                    debt.amountMinor,
                                    currencyCode: debt.currencyCode,
                                    exponent: debt.currencyExponent
                                ))
                                .font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                    .ledgerCard()
                }
            case .failure:
                VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
                    Text("Open split balances")
                        .font(.headline)
                    calculationWarning(count: 1)
                }
                .ledgerCard()
            }
        }
    }

    private func methodology(_ snapshot: LocalAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How this report is calculated")
                .font(.headline)
            Text(
                "Only locally available posted or reconciled records are included. Transfers and settlements never count as spending or income. Refunds reduce spending. Historical stored rate snapshots are used; a missing conversion is shown instead of invented."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String.localizedStringWithFormat(
                String(localized: "Report currency format"),
                snapshot.reportingCurrencyCode
            ))
                .font(.caption.weight(.semibold))
            Text(String.localizedStringWithFormat(
                String(localized: "Report time zone format"),
                TimeZone.current.identifier
            ))
                .font(.caption.weight(.semibold))
        }
        .ledgerCard()
    }

    private var currentAccountBalanceResult: AnalyticsAccountBalanceResult {
        guard let tracker = selectedTracker else {
            return AnalyticsAccountBalanceResult(items: [], failureCount: 0)
        }
        let records = transactions.filter { $0.trackerID == tracker.id }
        var items = [AnalyticsAccountBalance]()
        var failureCount = 0
        let visibleAccounts: [LocalAccount]
        if let selectedAccountID {
            visibleAccounts = trackerAccounts.filter { $0.id == selectedAccountID }
        } else {
            visibleAccounts = trackerAccounts
        }
        for account in visibleAccounts {
            if let money = LocalBalanceCalculator.balance(for: account, transactions: records) {
                items.append(AnalyticsAccountBalance(
                    id: account.id,
                    name: account.name,
                    money: money,
                    includeInNetWorth: account.includeInNetWorth
                ))
            } else {
                failureCount += 1
            }
        }
        return AnalyticsAccountBalanceResult(items: items, failureCount: failureCount)
    }

    private var currentBudgetResult: AnalyticsBudgetResult {
        guard let tracker = selectedTracker else {
            return AnalyticsBudgetResult(items: [], failureCount: 0)
        }
        var items = [AnalyticsBudgetInsight]()
        var failureCount = 0
        for budget in budgets where budget.trackerID == tracker.id {
            do {
                let progress = try LocalBudgetCalculator.calculate(
                    budget: budget,
                    categoryLinks: budgetCategories.filter { $0.budgetID == budget.id },
                    thresholds: budgetThresholds.filter { $0.budgetID == budget.id },
                    transactions: transactions,
                    allocations: allocations
                )
                let fraction = progress.availableMinor > 0
                    ? max(Double(progress.spentMinor) / Double(progress.availableMinor), 0)
                    : 0
                items.append(AnalyticsBudgetInsight(
                    id: budget.id,
                    name: budget.name,
                    currencyCode: budget.currencyCode,
                    currencyExponent: budget.currencyExponent,
                    spentMinor: progress.spentMinor,
                    availableMinor: progress.availableMinor,
                    progress: fraction,
                    isPartial: progress.isPartial
                ))
            } catch {
                failureCount += 1
            }
        }
        return AnalyticsBudgetResult(items: items, failureCount: failureCount)
    }

    private var subscriptionSummary: AnalyticsSubscriptionSummary? {
        guard let tracker = selectedTracker else { return nil }
        let rules = recurringRules.filter {
            $0.trackerID == tracker.id &&
                $0.isSubscription &&
                $0.kind == .expense &&
                $0.state == .active
        }
        guard !rules.isEmpty else { return nil }
        var normalized = [LocalNormalizedRecurringCost]()
        var failureCount = 0
        for rule in rules {
            do {
                normalized.append(try LocalRecurrenceCalculator.normalizedCost(
                    for: rule,
                    baseCurrencyExponent: tracker.baseCurrencyExponent
                ))
            } catch {
                failureCount += 1
            }
        }
        guard !normalized.isEmpty else {
            return AnalyticsSubscriptionSummary(
                monthly: nil,
                annual: nil,
                count: 0,
                failureCount: rules.count
            )
        }
        guard let monthlyMinor = safeSum(normalized.map(\.monthly.minorUnits)),
              let annualMinor = safeSum(normalized.map(\.annual.minorUnits))
        else {
            return AnalyticsSubscriptionSummary(
                monthly: nil,
                annual: nil,
                count: 0,
                failureCount: rules.count
            )
        }
        let monthly = try? Money(
            minorUnits: monthlyMinor,
            currencyCode: tracker.baseCurrencyCode,
            exponent: tracker.baseCurrencyExponent
        )
        let annual = try? Money(
            minorUnits: annualMinor,
            currencyCode: tracker.baseCurrencyCode,
            exponent: tracker.baseCurrencyExponent
        )
        if monthly == nil || annual == nil {
            return AnalyticsSubscriptionSummary(
                monthly: nil,
                annual: nil,
                count: 0,
                failureCount: rules.count
            )
        }
        return AnalyticsSubscriptionSummary(
            monthly: monthly,
            annual: annual,
            count: normalized.count,
            failureCount: failureCount
        )
    }

    private var currentInstallmentResult: AnalyticsInstallmentResult {
        guard let tracker = selectedTracker else {
            return AnalyticsInstallmentResult(items: [], failureCount: 0)
        }
        var items = [AnalyticsInstallmentInsight]()
        var failureCount = 0
        for plan in installmentPlans where
            plan.trackerID == tracker.id && plan.state != .cancelled {
            do {
                let progress = try LocalInstallmentCalculator.progress(
                    plan: plan,
                    scheduleItems: scheduleItems,
                    payments: installmentPayments
                )
                let remaining = try Money(
                    minorUnits: progress.remainingMinor,
                    currencyCode: plan.currencyCode,
                    exponent: plan.currencyExponent
                )
                items.append(AnalyticsInstallmentInsight(
                    id: plan.id,
                    name: plan.name,
                    remaining: remaining
                ))
            } catch {
                failureCount += 1
            }
        }
        return AnalyticsInstallmentResult(items: items, failureCount: failureCount)
    }

    private var currentSplitDebtResult: Result<[LocalSimplifiedDebt], Error>? {
        guard let tracker = selectedTracker else { return nil }
        return Result {
            try LocalLedgerRepository(context: modelContext).simplifiedDebts(tracker: tracker)
        }
    }

    private func participantName(_ participantID: UUID) -> String {
        participants.first { $0.id == participantID }?.displayName
            ?? String(localized: "Unknown participant")
    }

    private func netWorth(
        snapshot: LocalAnalyticsSnapshot,
        balances: [AnalyticsAccountBalance]
    ) -> String? {
        let values = balances.filter {
            $0.includeInNetWorth &&
                $0.money.currencyCode == snapshot.reportingCurrencyCode &&
                $0.money.exponent == snapshot.reportingCurrencyExponent
        }.map(\.money.minorUnits)
        guard !values.isEmpty, let total = safeSum(values) else { return nil }
        return formatted(total, snapshot: snapshot)
    }

    @ViewBuilder
    private func calculationWarning(count: Int) -> some View {
        if count > 0 {
            Label(
                String.localizedStringWithFormat(
                    String(localized: "Unavailable calculations count format"),
                    count
                ),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(LedgerTheme.warning)
        }
    }

    private func breakdownRow(
        _ item: LocalAnalyticsBreakdownItem,
        name: String,
        snapshot: LocalAnalyticsSnapshot
    ) -> some View {
        LabeledContent {
            Text(formatted(item.amountMinor, snapshot: snapshot))
                .font(.subheadline.monospacedDigit())
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(String.localizedStringWithFormat(
                    String(localized: "Records count format"),
                    item.transactionCount
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func categoryName(_ item: LocalAnalyticsBreakdownItem) -> String {
        item.name.isEmpty ? String(localized: "Uncategorized") : item.name
    }

    private func sourceName(_ rawValue: String) -> String {
        TransactionSource(rawValue: rawValue)?.displayName ?? rawValue
    }

    private func categoryAccessibilitySummary(_ snapshot: LocalAnalyticsSnapshot) -> String {
        snapshot.categories.prefix(5).map {
            "\(categoryName($0)): \(formatted($0.amountMinor, snapshot: snapshot))"
        }.joined(separator: ", ")
    }

    private func formatted(_ amountMinor: Int64, snapshot: LocalAnalyticsSnapshot) -> String {
        formatted(
            amountMinor,
            currencyCode: snapshot.reportingCurrencyCode,
            exponent: snapshot.reportingCurrencyExponent
        )
    }

    private func formatted(
        _ amountMinor: Int64,
        currencyCode: String,
        exponent: Int
    ) -> String {
        (try? Money(
            minorUnits: amountMinor,
            currencyCode: currencyCode,
            exponent: exponent
        ))?.formatted(locale: .current) ?? "—"
    }

    private func majorUnits(_ amountMinor: Int64, exponent: Int) -> Double {
        Double(amountMinor) / pow(10, Double(exponent))
    }

    private func safeSum(_ values: [Int64]) -> Int64? {
        var result: Int64 = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            result = next.partialValue
        }
        return result
    }

    private func normalizeSelections(resetCurrency: Bool) {
        guard let tracker = selectedTracker else {
            selectedTrackerID = nil
            selectedAccountID = nil
            selectedCurrencyCode = ""
            return
        }
        if selectedTrackerID != tracker.id { selectedTrackerID = tracker.id }
        if let currentAccountID = selectedAccountID,
           !trackerAccounts.contains(where: { $0.id == currentAccountID }) {
            selectedAccountID = nil
        }
        if resetCurrency || !reportingCurrencies.contains(where: { $0.code == selectedCurrencyCode }) {
            selectedCurrencyCode = tracker.baseCurrencyCode
        }
    }
}

private struct AnalyticsCurrencyOption: Identifiable, Equatable {
    let code: String
    let exponent: Int

    var id: String { "\(code):\(exponent)" }
}

private struct AnalyticsAccountBalance: Identifiable {
    let id: UUID
    let name: String
    let money: Money
    let includeInNetWorth: Bool
}

private struct AnalyticsAccountBalanceResult {
    let items: [AnalyticsAccountBalance]
    let failureCount: Int
}

private struct AnalyticsBudgetInsight: Identifiable {
    let id: UUID
    let name: String
    let currencyCode: String
    let currencyExponent: Int
    let spentMinor: Int64
    let availableMinor: Int64
    let progress: Double
    let isPartial: Bool
}

private struct AnalyticsBudgetResult {
    let items: [AnalyticsBudgetInsight]
    let failureCount: Int
}

private struct AnalyticsSubscriptionSummary {
    let monthly: Money?
    let annual: Money?
    let count: Int
    let failureCount: Int
}

private struct AnalyticsInstallmentInsight: Identifiable {
    let id: UUID
    let name: String
    let remaining: Money
}

private struct AnalyticsInstallmentResult {
    let items: [AnalyticsInstallmentInsight]
    let failureCount: Int
}

private struct InsightMetric: View {
    let title: LocalizedStringKey
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
