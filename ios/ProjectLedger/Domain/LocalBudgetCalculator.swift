import Foundation

enum BudgetCalculationError: Error, Equatable {
    case invalidConfiguration
    case overflow
}

struct LocalUnconvertedBudgetAmount: Equatable, Sendable {
    let currency: String
    let amountMinor: Int64
    let transactionCount: Int
}

struct LocalBudgetProgress: Equatable, Sendable {
    let periodStart: Date
    let periodEnd: Date
    let isActive: Bool
    let carriedMinor: Int64?
    let availableMinor: Int64
    let spentMinor: Int64
    let remainingMinor: Int64
    let progressBasisPoints: Int?
    let crossedThresholdPercent: Int?
    let isPartial: Bool
    let rolloverComplete: Bool
    let unconverted: [LocalUnconvertedBudgetAmount]
}

enum LocalBudgetCalculator {
    private struct Bounds {
        let start: Date
        let end: Date
        let isActive: Bool
    }

    private struct Spending {
        let amount: Int64
        let unconverted: [LocalUnconvertedBudgetAmount]
    }

    static func calculate(
        budget: LocalBudget,
        categoryLinks: [LocalBudgetCategory],
        thresholds: [LocalBudgetThreshold],
        transactions: [LedgerTransaction],
        allocations: [LocalCategoryAllocation],
        asOf: Date = .now
    ) throws -> LocalBudgetProgress {
        guard let zone = TimeZone(identifier: budget.timeZoneIdentifier),
              budget.amountMinor > 0,
              budget.currencyExponent >= 0,
              budget.currencyExponent <= 6
        else {
            throw BudgetCalculationError.invalidConfiguration
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let currentBounds = try bounds(for: budget, containing: asOf, calendar: calendar)
        let current = try spending(
            budget: budget,
            bounds: currentBounds,
            categoryLinks: categoryLinks,
            transactions: transactions,
            allocations: allocations,
            calendar: calendar
        )

        var carried: Int64? = 0
        var rolloverComplete = true
        if budget.rollover, currentBounds.isActive {
            let completed = try completedPeriods(
                budget: budget,
                before: currentBounds.start,
                calendar: calendar
            )
            rolloverComplete = completed.complete
            var total: Int64 = 0
            for priorBounds in completed.periods {
                let prior = try spending(
                    budget: budget,
                    bounds: priorBounds,
                    categoryLinks: categoryLinks,
                    transactions: transactions,
                    allocations: allocations,
                    calendar: calendar
                )
                if !prior.unconverted.isEmpty {
                    rolloverComplete = false
                    break
                }
                total = try safeAdd(total, try safeSubtract(budget.amountMinor, prior.amount))
            }
            carried = rolloverComplete ? total : nil
        }

        let available = try safeAdd(budget.amountMinor, carried ?? 0)
        let remaining = try safeSubtract(available, current.amount)
        let progress = available > 0
            ? try scaledRatio(current.amount, multiplier: 10_000, divisor: available)
            : nil
        let crossed = available > 0
            ? thresholds.map(\.percent).filter {
                Decimal(current.amount) * 100 >= Decimal(available) * Decimal($0)
            }.max()
            : nil
        return LocalBudgetProgress(
            periodStart: currentBounds.start,
            periodEnd: currentBounds.end,
            isActive: currentBounds.isActive,
            carriedMinor: carried,
            availableMinor: available,
            spentMinor: current.amount,
            remainingMinor: remaining,
            progressBasisPoints: progress.map(Int.init),
            crossedThresholdPercent: crossed,
            isPartial: !current.unconverted.isEmpty || !rolloverComplete,
            rolloverComplete: rolloverComplete,
            unconverted: current.unconverted
        )
    }

    private static func bounds(
        for budget: LocalBudget,
        containing day: Date,
        calendar: Calendar
    ) throws -> Bounds {
        let normalizedDay = calendar.startOfDay(for: day)
        let startLimit = try civilDate(budget.startsOn, calendar: calendar)
        let endLimit = try budget.endsOn.map { try civilDate($0, calendar: calendar) }
        if budget.period == .custom {
            guard let endLimit, endLimit >= startLimit else {
                throw BudgetCalculationError.invalidConfiguration
            }
            return Bounds(
                start: startLimit,
                end: endLimit,
                isActive: normalizedDay >= startLimit && normalizedDay <= endLimit
            )
        }

        let interval: DateInterval?
        switch budget.period {
        case .monthly:
            interval = calendar.dateInterval(of: .month, for: normalizedDay)
        case .weekly:
            interval = calendar.dateInterval(of: .weekOfYear, for: normalizedDay)
        case .custom:
            interval = nil
        }
        guard let interval,
              let rawEnd = calendar.date(byAdding: .day, value: -1, to: interval.end)
        else {
            throw BudgetCalculationError.invalidConfiguration
        }
        let active = normalizedDay >= startLimit && (endLimit == nil || normalizedDay <= endLimit!)
        guard active else {
            return Bounds(start: interval.start, end: rawEnd, isActive: false)
        }
        return Bounds(
            start: max(interval.start, startLimit),
            end: min(rawEnd, endLimit ?? rawEnd),
            isActive: true
        )
    }

    private static func completedPeriods(
        budget: LocalBudget,
        before currentStart: Date,
        calendar: Calendar
    ) throws -> (periods: [Bounds], complete: Bool) {
        guard budget.period != .custom else { return ([], true) }
        var cursor = try civilDate(budget.startsOn, calendar: calendar)
        var result = [Bounds]()
        let maximumPeriods = 600
        while cursor < currentStart, result.count < maximumPeriods {
            let value = try bounds(for: budget, containing: cursor, calendar: calendar)
            if value.end >= currentStart { break }
            if value.isActive { result.append(value) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: value.end) else {
                throw BudgetCalculationError.invalidConfiguration
            }
            cursor = next
            if let endsOn = budget.endsOn,
               cursor > (try civilDate(endsOn, calendar: calendar)) {
                break
            }
        }
        let ended: Bool
        if let endsOn = budget.endsOn {
            ended = cursor > (try civilDate(endsOn, calendar: calendar))
        } else {
            ended = false
        }
        let complete = cursor >= currentStart || ended
        return (result, complete)
    }

    private static func civilDate(_ stored: Date, calendar: Calendar) throws -> Date {
        var storageCalendar = Calendar(identifier: .gregorian)
        storageCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = storageCalendar.dateComponents([.year, .month, .day], from: stored)
        guard let value = calendar.date(from: components) else {
            throw BudgetCalculationError.invalidConfiguration
        }
        return value
    }

    private static func spending(
        budget: LocalBudget,
        bounds: Bounds,
        categoryLinks: [LocalBudgetCategory],
        transactions: [LedgerTransaction],
        allocations: [LocalCategoryAllocation],
        calendar: Calendar
    ) throws -> Spending {
        guard bounds.isActive else { return Spending(amount: 0, unconverted: []) }
        let selectedCategories = Set(categoryLinks.map(\.categoryID))
        let allocationsByTransaction = Dictionary(grouping: allocations, by: \.transactionID)
        var spent: Int64 = 0
        var missingAmounts = [String: Int64]()
        var missingCounts = [String: Int]()
        for record in transactions where record.trackerID == budget.trackerID &&
            record.kind == .expense && record.status == .posted && record.deletedAt == nil {
            let occurrence = calendar.startOfDay(for: record.occurredAt)
            guard occurrence >= bounds.start, occurrence <= bounds.end else { continue }
            let selected: Int64
            if budget.budgetScope == .tracker {
                selected = record.amountMinor
            } else {
                selected = try (allocationsByTransaction[record.id] ?? [])
                    .filter { selectedCategories.contains($0.categoryID) }
                    .reduce(into: Int64(0)) { total, allocation in
                        total = try safeAdd(total, allocation.amountMinor)
                    }
            }
            guard selected > 0 else { continue }
            if record.currencyCode == budget.currencyCode {
                spent = try safeAdd(spent, selected)
            } else if record.baseCurrencyCode == budget.currencyCode {
                let converted = selected == record.amountMinor
                    ? record.baseAmountMinor
                    : try scaledRatio(
                        record.baseAmountMinor,
                        multiplier: selected,
                        divisor: record.amountMinor
                    )
                spent = try safeAdd(spent, converted)
            } else {
                missingAmounts[record.currencyCode] = try safeAdd(
                    missingAmounts[record.currencyCode] ?? 0,
                    selected
                )
                missingCounts[record.currencyCode, default: 0] += 1
            }
        }
        return Spending(
            amount: spent,
            unconverted: missingAmounts.keys.sorted().map {
                LocalUnconvertedBudgetAmount(
                    currency: $0,
                    amountMinor: missingAmounts[$0] ?? 0,
                    transactionCount: missingCounts[$0] ?? 0
                )
            }
        )
    }

    private static func safeAdd(_ first: Int64, _ second: Int64) throws -> Int64 {
        let (value, overflow) = first.addingReportingOverflow(second)
        guard !overflow else { throw BudgetCalculationError.overflow }
        return value
    }

    private static func safeSubtract(_ first: Int64, _ second: Int64) throws -> Int64 {
        let (value, overflow) = first.subtractingReportingOverflow(second)
        guard !overflow else { throw BudgetCalculationError.overflow }
        return value
    }

    private static func scaledRatio(
        _ value: Int64,
        multiplier: Int64,
        divisor: Int64
    ) throws -> Int64 {
        guard divisor > 0 else { throw BudgetCalculationError.invalidConfiguration }
        var source = Decimal(value) * Decimal(multiplier) / Decimal(divisor)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber,
              number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
              number.compare(NSDecimalNumber(value: Int64.min)) != .orderedAscending
        else {
            throw BudgetCalculationError.overflow
        }
        return number.int64Value
    }
}
