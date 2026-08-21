import Foundation

enum AnalyticsRangePreset: String, CaseIterable, Identifiable, Sendable {
    case thisMonth
    case threeMonths
    case thisYear
    case allTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisMonth: String(localized: "This month")
        case .threeMonths: String(localized: "Last 3 months")
        case .thisYear: String(localized: "This year")
        case .allTime: String(localized: "All time")
        }
    }

    var granularity: AnalyticsTrendGranularity {
        switch self {
        case .thisMonth: .day
        case .threeMonths: .week
        case .thisYear, .allTime: .month
        }
    }

    func interval(asOf: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: asOf)
        case .threeMonths:
            guard let current = calendar.dateInterval(of: .month, for: asOf),
                  let start = calendar.date(byAdding: .month, value: -2, to: current.start)
            else { return nil }
            return DateInterval(start: start, end: current.end)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: asOf)
        case .allTime:
            return nil
        }
    }
}

enum AnalyticsTrendGranularity: String, Sendable {
    case day
    case week
    case month
}

enum AnalyticsReportingCalendar {
    static func make(timeZone: TimeZone = .current) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = timeZone
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }
}

struct LocalAnalyticsTransactionInput: Equatable, Sendable {
    let id: UUID
    let trackerID: UUID
    let accountID: UUID
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let kind: TransactionKind
    let source: TransactionSource
    let status: TransactionStatus
    let amountMinor: Int64
    let currencyCode: String
    let currencyExponent: Int
    let baseAmountMinor: Int64
    let baseCurrencyCode: String
    let baseCurrencyExponent: Int
    let rateSource: String
    let merchant: String
    let occurredAt: Date
    let refundOfID: UUID?
    let deleted: Bool
}

struct LocalAnalyticsAllocationInput: Equatable, Sendable {
    let transactionID: UUID
    let categoryID: UUID
    let amountMinor: Int64
}

struct LocalAnalyticsConfiguration: Equatable, Sendable {
    let trackerID: UUID
    let accountID: UUID?
    let reportingCurrencyCode: String
    let reportingCurrencyExponent: Int
    let range: AnalyticsRangePreset
}

struct LocalAnalyticsBreakdownItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let amountMinor: Int64
    let transactionCount: Int
}

struct LocalAnalyticsTrendPoint: Identifiable, Equatable, Sendable {
    let bucketStart: Date
    let spendingMinor: Int64
    let incomeMinor: Int64
    let cashFlowMinor: Int64

    var id: Date { bucketStart }
}

struct LocalAnalyticsUnconvertedAmount: Identifiable, Equatable, Sendable {
    let currencyCode: String
    let currencyExponent: Int
    let amountMinor: Int64
    let transactionCount: Int

    var id: String { "\(currencyCode):\(currencyExponent)" }
}

struct LocalAnalyticsSnapshot: Equatable, Sendable {
    let reportingCurrencyCode: String
    let reportingCurrencyExponent: Int
    let rangeStart: Date?
    let rangeEnd: Date?
    let recordCount: Int
    let spendingMinor: Int64
    let incomeMinor: Int64
    let cashFlowMinor: Int64
    let categories: [LocalAnalyticsBreakdownItem]
    let merchants: [LocalAnalyticsBreakdownItem]
    let sources: [LocalAnalyticsBreakdownItem]
    let trend: [LocalAnalyticsTrendPoint]
    let trendWasTruncated: Bool
    let unconverted: [LocalAnalyticsUnconvertedAmount]

    var isPartial: Bool { !unconverted.isEmpty }
}

enum LocalAnalyticsCalculationError: Error, Equatable {
    case invalidConfiguration
    case invalidTransaction
    case invalidAllocations
    case overflow
}

enum LocalAnalyticsCalculator {
    static let maximumTrendPointCount = 240

    private struct BreakdownAccumulator {
        let id: String
        var name: String
        var amountMinor: Int64
        var transactionCount: Int
    }

    private struct TrendAccumulator {
        var spendingMinor: Int64 = 0
        var incomeMinor: Int64 = 0
        var cashFlowMinor: Int64 = 0
    }

    private struct UnconvertedAccumulator {
        let currencyCode: String
        let currencyExponent: Int
        var amountMinor: Int64
        var transactionCount: Int
    }

    private struct WeightedCategory {
        let categoryID: UUID?
        let weight: Int64
    }

    private struct RoundedCategory {
        let categoryID: UUID?
        var amountMinor: Int64
        let remainder: Decimal
    }

    static func calculate(
        configuration: LocalAnalyticsConfiguration,
        transactions: [LocalAnalyticsTransactionInput],
        allocations: [LocalAnalyticsAllocationInput],
        categoryNames: [UUID: String],
        asOf: Date = .now,
        calendar: Calendar = AnalyticsReportingCalendar.make()
    ) throws -> LocalAnalyticsSnapshot {
        guard validCurrencyCode(configuration.reportingCurrencyCode),
              (0 ... 4).contains(configuration.reportingCurrencyExponent)
        else {
            throw LocalAnalyticsCalculationError.invalidConfiguration
        }
        let interval = configuration.range.interval(asOf: asOf, calendar: calendar)
        let allocationsByTransaction = Dictionary(grouping: allocations, by: \.transactionID)
        let groupedTransactions = Dictionary(grouping: transactions, by: \.id)
        guard groupedTransactions.values.allSatisfy({ $0.count == 1 }) else {
            throw LocalAnalyticsCalculationError.invalidTransaction
        }
        let transactionByID = groupedTransactions.mapValues { $0[0] }

        var spendingMinor: Int64 = 0
        var incomeMinor: Int64 = 0
        var recordCount = 0
        var categories = [String: BreakdownAccumulator]()
        var merchants = [String: BreakdownAccumulator]()
        var sources = [String: BreakdownAccumulator]()
        var trend = [Date: TrendAccumulator]()
        var unconverted = [String: UnconvertedAccumulator]()

        let orderedTransactions = transactions.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for transaction in orderedTransactions {
            guard transaction.trackerID == configuration.trackerID,
                  !transaction.deleted,
                  transaction.status == .posted || transaction.status == .reconciled,
                  interval?.contains(transaction.occurredAt) ?? true,
                  matchesAccount(transaction, accountID: configuration.accountID)
            else { continue }
            guard transaction.amountMinor > 0,
                  validCurrencyCode(transaction.currencyCode),
                  (0 ... 4).contains(transaction.currencyExponent),
                  transaction.baseAmountMinor > 0,
                  validCurrencyCode(transaction.baseCurrencyCode),
                  (0 ... 4).contains(transaction.baseCurrencyExponent)
            else {
                throw LocalAnalyticsCalculationError.invalidTransaction
            }
            guard transaction.kind == .expense ||
                    transaction.kind == .income ||
                    transaction.kind == .refund
            else { continue }

            guard let convertedAmount = convertedAmount(
                for: transaction,
                configuration: configuration
            ) else {
                try accumulateUnconverted(transaction, into: &unconverted)
                continue
            }
            recordCount += 1
            let bucket = try bucketStart(
                for: transaction.occurredAt,
                granularity: configuration.range.granularity,
                calendar: calendar
            )

            switch transaction.kind {
            case .expense:
                spendingMinor = try add(spendingMinor, convertedAmount)
                try addTrend(
                    spending: convertedAmount,
                    income: 0,
                    cashFlow: try negate(convertedAmount),
                    bucket: bucket,
                    into: &trend
                )
                try accumulateCategories(
                    transaction: transaction,
                    targetAmountMinor: convertedAmount,
                    allocations: allocationsByTransaction[transaction.id] ?? [],
                    categoryNames: categoryNames,
                    multiplier: 1,
                    into: &categories
                )
                try accumulateMerchant(
                    merchant: transaction.merchant,
                    amountMinor: convertedAmount,
                    into: &merchants
                )
                try accumulateBreakdown(
                    id: transaction.source.rawValue,
                    name: transaction.source.rawValue,
                    amountMinor: convertedAmount,
                    into: &sources
                )
            case .income:
                incomeMinor = try add(incomeMinor, convertedAmount)
                try addTrend(
                    spending: 0,
                    income: convertedAmount,
                    cashFlow: convertedAmount,
                    bucket: bucket,
                    into: &trend
                )
            case .refund:
                spendingMinor = try subtract(spendingMinor, convertedAmount)
                try addTrend(
                    spending: try negate(convertedAmount),
                    income: 0,
                    cashFlow: convertedAmount,
                    bucket: bucket,
                    into: &trend
                )
                let original: LocalAnalyticsTransactionInput?
                if let originalID = transaction.refundOfID,
                   let candidate = transactionByID[originalID],
                   candidate.trackerID == transaction.trackerID,
                   candidate.kind == .expense {
                    original = candidate
                } else {
                    original = nil
                }
                let categoryOwner = original ?? transaction
                try accumulateCategories(
                    transaction: categoryOwner,
                    targetAmountMinor: convertedAmount,
                    allocations: allocationsByTransaction[categoryOwner.id] ?? [],
                    categoryNames: categoryNames,
                    multiplier: -1,
                    into: &categories
                )
                try accumulateMerchant(
                    merchant: original?.merchant ?? transaction.merchant,
                    amountMinor: try negate(convertedAmount),
                    into: &merchants
                )
            case .transfer, .settlement:
                break
            }
        }

        let cashFlowMinor = try subtract(incomeMinor, spendingMinor)
        let trendResult = try completedTrend(
            trend,
            interval: interval,
            granularity: configuration.range.granularity,
            calendar: calendar
        )
        return LocalAnalyticsSnapshot(
            reportingCurrencyCode: configuration.reportingCurrencyCode,
            reportingCurrencyExponent: configuration.reportingCurrencyExponent,
            rangeStart: interval?.start,
            rangeEnd: interval?.end,
            recordCount: recordCount,
            spendingMinor: spendingMinor,
            incomeMinor: incomeMinor,
            cashFlowMinor: cashFlowMinor,
            categories: finalized(categories),
            merchants: finalized(merchants),
            sources: finalized(sources),
            trend: trendResult.points,
            trendWasTruncated: trendResult.wasTruncated,
            unconverted: unconverted.values.sorted {
                $0.currencyCode == $1.currencyCode
                    ? $0.currencyExponent < $1.currencyExponent
                    : $0.currencyCode < $1.currencyCode
            }.map {
                LocalAnalyticsUnconvertedAmount(
                    currencyCode: $0.currencyCode,
                    currencyExponent: $0.currencyExponent,
                    amountMinor: $0.amountMinor,
                    transactionCount: $0.transactionCount
                )
            }
        )
    }

    private static func convertedAmount(
        for transaction: LocalAnalyticsTransactionInput,
        configuration: LocalAnalyticsConfiguration
    ) -> Int64? {
        if transaction.currencyCode == configuration.reportingCurrencyCode,
           transaction.currencyExponent == configuration.reportingCurrencyExponent {
            return transaction.amountMinor
        }
        if transaction.baseCurrencyCode == configuration.reportingCurrencyCode,
           transaction.baseCurrencyExponent == configuration.reportingCurrencyExponent,
           !transaction.rateSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transaction.baseAmountMinor
        }
        return nil
    }

    private static func matchesAccount(
        _ transaction: LocalAnalyticsTransactionInput,
        accountID: UUID?
    ) -> Bool {
        guard let accountID else { return true }
        return transaction.accountID == accountID || transaction.destinationAccountID == accountID
    }

    private static func accumulateUnconverted(
        _ transaction: LocalAnalyticsTransactionInput,
        into values: inout [String: UnconvertedAccumulator]
    ) throws {
        let id = "\(transaction.currencyCode):\(transaction.currencyExponent)"
        var value = values[id] ?? UnconvertedAccumulator(
            currencyCode: transaction.currencyCode,
            currencyExponent: transaction.currencyExponent,
            amountMinor: 0,
            transactionCount: 0
        )
        value.amountMinor = try add(value.amountMinor, transaction.amountMinor)
        value.transactionCount += 1
        values[id] = value
    }

    private static func accumulateCategories(
        transaction: LocalAnalyticsTransactionInput,
        targetAmountMinor: Int64,
        allocations: [LocalAnalyticsAllocationInput],
        categoryNames: [UUID: String],
        multiplier: Int64,
        into values: inout [String: BreakdownAccumulator]
    ) throws {
        let weights: [WeightedCategory]
        if allocations.isEmpty {
            weights = [WeightedCategory(
                categoryID: transaction.categoryID,
                weight: transaction.amountMinor
            )]
        } else {
            guard allocations.allSatisfy({ $0.amountMinor > 0 }),
                  Set(allocations.map(\.categoryID)).count == allocations.count,
                  try sum(allocations.map(\.amountMinor)) == transaction.amountMinor
            else {
                throw LocalAnalyticsCalculationError.invalidAllocations
            }
            weights = allocations.map {
                WeightedCategory(categoryID: $0.categoryID, weight: $0.amountMinor)
            }
        }
        let resolved = try proportionalAllocation(
            totalMinor: targetAmountMinor,
            weights: weights
        )
        for item in resolved {
            let id = item.categoryID?.uuidString.lowercased() ?? "uncategorized"
            let name = item.categoryID.flatMap { categoryNames[$0] } ?? ""
            try accumulateBreakdown(
                id: id,
                name: name,
                amountMinor: try multiply(item.amountMinor, multiplier),
                into: &values
            )
        }
    }

    private static func proportionalAllocation(
        totalMinor: Int64,
        weights: [WeightedCategory]
    ) throws -> [RoundedCategory] {
        guard totalMinor > 0,
              !weights.isEmpty,
              weights.allSatisfy({ $0.weight > 0 })
        else {
            throw LocalAnalyticsCalculationError.invalidAllocations
        }
        let weightTotal = try sum(weights.map(\.weight))
        var rounded = try weights.map { item -> RoundedCategory in
            let exact = Decimal(totalMinor) * Decimal(item.weight) / Decimal(weightTotal)
            var source = exact
            var floor = Decimal()
            NSDecimalRound(&floor, &source, 0, .down)
            return RoundedCategory(
                categoryID: item.categoryID,
                amountMinor: try int64(floor),
                remainder: exact - floor
            )
        }
        var remaining = try subtract(totalMinor, try sum(rounded.map(\.amountMinor)))
        let order = rounded.indices.sorted { left, right in
            if rounded[left].remainder != rounded[right].remainder {
                return rounded[left].remainder > rounded[right].remainder
            }
            return categoryOrder(rounded[left].categoryID, rounded[right].categoryID)
        }
        guard remaining >= 0, remaining <= Int64(order.count) else {
            throw LocalAnalyticsCalculationError.invalidAllocations
        }
        for index in order where remaining > 0 {
            rounded[index].amountMinor = try add(rounded[index].amountMinor, 1)
            remaining -= 1
        }
        guard remaining == 0,
              try sum(rounded.map(\.amountMinor)) == totalMinor
        else {
            throw LocalAnalyticsCalculationError.invalidAllocations
        }
        return rounded
    }

    private static func categoryOrder(_ lhs: UUID?, _ rhs: UUID?) -> Bool {
        (lhs?.uuidString ?? "") < (rhs?.uuidString ?? "")
    }

    private static func accumulateMerchant(
        merchant: String,
        amountMinor: Int64,
        into values: inout [String: BreakdownAccumulator]
    ) throws {
        let name = merchant.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let id = name.isEmpty ? "no-merchant" : name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        try accumulateBreakdown(
            id: id,
            name: name,
            amountMinor: amountMinor,
            into: &values
        )
    }

    private static func accumulateBreakdown(
        id: String,
        name: String,
        amountMinor: Int64,
        into values: inout [String: BreakdownAccumulator]
    ) throws {
        var value = values[id] ?? BreakdownAccumulator(
            id: id,
            name: name,
            amountMinor: 0,
            transactionCount: 0
        )
        value.amountMinor = try add(value.amountMinor, amountMinor)
        value.transactionCount += 1
        if value.name.isEmpty, !name.isEmpty { value.name = name }
        values[id] = value
    }

    private static func finalized(
        _ values: [String: BreakdownAccumulator]
    ) -> [LocalAnalyticsBreakdownItem] {
        values.values.filter { $0.amountMinor != 0 }.sorted {
            let lhsMagnitude = magnitude($0.amountMinor)
            let rhsMagnitude = magnitude($1.amountMinor)
            if lhsMagnitude != rhsMagnitude { return lhsMagnitude > rhsMagnitude }
            if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }.map {
            LocalAnalyticsBreakdownItem(
                id: $0.id,
                name: $0.name,
                amountMinor: $0.amountMinor,
                transactionCount: $0.transactionCount
            )
        }
    }

    private static func addTrend(
        spending: Int64,
        income: Int64,
        cashFlow: Int64,
        bucket: Date,
        into values: inout [Date: TrendAccumulator]
    ) throws {
        var value = values[bucket] ?? TrendAccumulator()
        value.spendingMinor = try add(value.spendingMinor, spending)
        value.incomeMinor = try add(value.incomeMinor, income)
        value.cashFlowMinor = try add(value.cashFlowMinor, cashFlow)
        values[bucket] = value
    }

    private static func completedTrend(
        _ values: [Date: TrendAccumulator],
        interval: DateInterval?,
        granularity: AnalyticsTrendGranularity,
        calendar: Calendar
    ) throws -> (points: [LocalAnalyticsTrendPoint], wasTruncated: Bool) {
        guard let interval else {
            let keys = values.keys.sorted()
            let wasTruncated = keys.count > maximumTrendPointCount
            return (
                keys.suffix(maximumTrendPointCount).map {
                    point($0, values[$0] ?? TrendAccumulator())
                },
                wasTruncated
            )
        }
        var cursor = try bucketStart(
            for: interval.start,
            granularity: granularity,
            calendar: calendar
        )
        var result = [LocalAnalyticsTrendPoint]()
        while cursor < interval.end, result.count < 400 {
            result.append(point(cursor, values[cursor] ?? TrendAccumulator()))
            guard let next = calendar.date(
                byAdding: calendarComponent(for: granularity),
                value: 1,
                to: cursor
            ), next > cursor else {
                throw LocalAnalyticsCalculationError.invalidConfiguration
            }
            cursor = next
        }
        guard cursor >= interval.end else {
            throw LocalAnalyticsCalculationError.invalidConfiguration
        }
        return (result, false)
    }

    private static func point(
        _ date: Date,
        _ value: TrendAccumulator
    ) -> LocalAnalyticsTrendPoint {
        LocalAnalyticsTrendPoint(
            bucketStart: date,
            spendingMinor: value.spendingMinor,
            incomeMinor: value.incomeMinor,
            cashFlowMinor: value.cashFlowMinor
        )
    }

    private static func bucketStart(
        for date: Date,
        granularity: AnalyticsTrendGranularity,
        calendar: Calendar
    ) throws -> Date {
        let component = calendarComponent(for: granularity)
        guard let interval = calendar.dateInterval(of: component, for: date) else {
            throw LocalAnalyticsCalculationError.invalidConfiguration
        }
        return interval.start
    }

    private static func calendarComponent(
        for granularity: AnalyticsTrendGranularity
    ) -> Calendar.Component {
        switch granularity {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    private static func sum(_ values: [Int64]) throws -> Int64 {
        try values.reduce(0) { try add($0, $1) }
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw LocalAnalyticsCalculationError.overflow }
        return result.partialValue
    }

    private static func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else { throw LocalAnalyticsCalculationError.overflow }
        return result.partialValue
    }

    private static func multiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw LocalAnalyticsCalculationError.overflow }
        return result.partialValue
    }

    private static func negate(_ value: Int64) throws -> Int64 {
        guard value != Int64.min else { throw LocalAnalyticsCalculationError.overflow }
        return -value
    }

    private static func int64(_ decimal: Decimal) throws -> Int64 {
        let number = NSDecimalNumber(decimal: decimal)
        guard number != .notANumber,
              number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
              number.compare(NSDecimalNumber(value: Int64.min)) != .orderedAscending
        else {
            throw LocalAnalyticsCalculationError.overflow
        }
        return number.int64Value
    }

    private static func magnitude(_ value: Int64) -> UInt64 {
        value == Int64.min ? UInt64(Int64.max) + 1 : UInt64(abs(value))
    }

    private static func validCurrencyCode(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy { (65 ... 90).contains($0) }
    }
}
