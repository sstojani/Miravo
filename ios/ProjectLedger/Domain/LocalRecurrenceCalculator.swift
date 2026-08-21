import CryptoKit
import Foundation

enum RecurrenceCalculationError: Error, Equatable {
    case invalidConfiguration
    case overflow
}

struct LocalNormalizedRecurringCost: Equatable, Sendable {
    let monthly: Money
    let annual: Money
}

enum LocalRecurrenceCalculator {
    static func nextDueDate(
        after current: Date,
        cadence: RecurringCadence,
        customIntervalUnit: RecurringIntervalUnit?,
        customIntervalCount: Int,
        anchorDay: Int,
        anchorMonth: Int
    ) throws -> Date {
        guard let canonical = BudgetDateCodec.canonicalDate(from: current),
              (1 ... 31).contains(anchorDay),
              (1 ... 12).contains(anchorMonth)
        else {
            throw RecurrenceCalculationError.invalidConfiguration
        }
        let step: (unit: RecurringIntervalUnit, amount: Int)
        switch cadence {
        case .daily:
            step = (.day, 1)
        case .weekly:
            step = (.week, 1)
        case .monthly:
            step = (.month, 1)
        case .yearly:
            step = (.year, 1)
        case .custom:
            guard let customIntervalUnit, (2 ... 365).contains(customIntervalCount) else {
                throw RecurrenceCalculationError.invalidConfiguration
            }
            step = (customIntervalUnit, customIntervalCount)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        switch step.unit {
        case .day:
            guard let value = calendar.date(
                byAdding: .day,
                value: step.amount,
                to: canonical
            ) else {
                throw RecurrenceCalculationError.invalidConfiguration
            }
            return value
        case .week:
            guard let value = calendar.date(
                byAdding: .day,
                value: step.amount * 7,
                to: canonical
            ) else {
                throw RecurrenceCalculationError.invalidConfiguration
            }
            return value
        case .month:
            return try anchoredMonth(
                from: canonical,
                months: step.amount,
                anchorDay: anchorDay,
                calendar: calendar
            )
        case .year:
            let components = calendar.dateComponents([.year], from: canonical)
            guard let year = components.year else {
                throw RecurrenceCalculationError.invalidConfiguration
            }
            return try civilDate(
                year: year + step.amount,
                month: anchorMonth,
                preferredDay: anchorDay,
                calendar: calendar
            )
        }
    }

    static func scheduledDate(
        civilDate: Date,
        localTimeSeconds: Int,
        timeZoneIdentifier: String
    ) throws -> Date {
        guard let zone = TimeZone(identifier: timeZoneIdentifier),
              (0 ... 86_399).contains(localTimeSeconds)
        else {
            throw RecurrenceCalculationError.invalidConfiguration
        }
        var storageCalendar = Calendar(identifier: .gregorian)
        storageCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = storageCalendar.dateComponents([.year, .month, .day], from: civilDate)
        guard let year = day.year, let month = day.month, let dayValue = day.day else {
            throw RecurrenceCalculationError.invalidConfiguration
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let midnight = calendar.date(
            from: DateComponents(year: year, month: month, day: dayValue)
        ) else {
            throw RecurrenceCalculationError.invalidConfiguration
        }
        let searchStart = midnight.addingTimeInterval(-1)
        let hour = localTimeSeconds / 3_600
        let minute = (localTimeSeconds % 3_600) / 60
        let second = localTimeSeconds % 60

        let rawComponents = DateComponents(
            year: year,
            month: month,
            day: dayValue,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let rawTime = storageCalendar.date(from: rawComponents) else {
            throw RecurrenceCalculationError.invalidConfiguration
        }
        for minuteOffset in 0 ... 180 {
            guard let candidate = storageCalendar.date(
                byAdding: .minute,
                value: minuteOffset,
                to: rawTime
            ) else {
                continue
            }
            let parts = storageCalendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: candidate
            )
            guard let resolved = calendar.nextDate(
                after: searchStart,
                matching: parts,
                matchingPolicy: .strict,
                repeatedTimePolicy: .first,
                direction: .forward
            ) else {
                continue
            }
            let roundTrip = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: resolved
            )
            if roundTrip == parts { return resolved }
        }
        throw RecurrenceCalculationError.invalidConfiguration
    }

    static func normalizedCost(
        for rule: LocalRecurringRule,
        baseCurrencyExponent: Int
    ) throws -> LocalNormalizedRecurringCost {
        let money = try Money(
            minorUnits: rule.baseAmountMinor,
            currencyCode: rule.baseCurrencyCode,
            exponent: baseCurrencyExponent
        )
        guard money.minorUnits > 0 else {
            throw RecurrenceCalculationError.invalidConfiguration
        }
        let interval = rule.cadence == .custom ? rule.customIntervalCount : 1
        guard interval > 0 else { throw RecurrenceCalculationError.invalidConfiguration }
        let unit: RecurringIntervalUnit
        switch rule.cadence {
        case .daily: unit = .day
        case .weekly: unit = .week
        case .monthly: unit = .month
        case .yearly: unit = .year
        case .custom:
            guard let custom = rule.customIntervalUnit else {
                throw RecurrenceCalculationError.invalidConfiguration
            }
            unit = custom
        }
        let monthlyRatio: (Int, Int)
        let annualRatio: (Int, Int)
        switch unit {
        case .day:
            monthlyRatio = (365, 12 * interval)
            annualRatio = (365, interval)
        case .week:
            monthlyRatio = (52, 12 * interval)
            annualRatio = (52, interval)
        case .month:
            monthlyRatio = (1, interval)
            annualRatio = (12, interval)
        case .year:
            monthlyRatio = (1, 12 * interval)
            annualRatio = (1, interval)
        }
        return LocalNormalizedRecurringCost(
            monthly: try scaledMoney(money, ratio: monthlyRatio),
            annual: try scaledMoney(money, ratio: annualRatio)
        )
    }

    static func occurrenceKey(ruleID: UUID, dueOn: Date) -> String {
        let source = "\(ruleID.uuidString.lowercased()):\(BudgetDateCodec.string(from: dueOn))"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func anchoredMonth(
        from current: Date,
        months: Int,
        anchorDay: Int,
        calendar: Calendar
    ) throws -> Date {
        let components = calendar.dateComponents([.year, .month], from: current)
        guard let year = components.year, let month = components.month else {
            throw RecurrenceCalculationError.invalidConfiguration
        }
        let zeroBased = year * 12 + month - 1 + months
        return try civilDate(
            year: zeroBased / 12,
            month: zeroBased % 12 + 1,
            preferredDay: anchorDay,
            calendar: calendar
        )
    }

    private static func civilDate(
        year: Int,
        month: Int,
        preferredDay: Int,
        calendar: Calendar
    ) throws -> Date {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: start),
              let value = calendar.date(
                  from: DateComponents(
                      year: year,
                      month: month,
                      day: min(preferredDay, range.count)
                  )
              )
        else {
            throw RecurrenceCalculationError.invalidConfiguration
        }
        return value
    }

    private static func scaledMoney(_ money: Money, ratio: (Int, Int)) throws -> Money {
        guard ratio.0 > 0, ratio.1 > 0 else {
            throw RecurrenceCalculationError.invalidConfiguration
        }
        var source = Decimal(money.minorUnits) * Decimal(ratio.0) / Decimal(ratio.1)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber,
              number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
              number.compare(NSDecimalNumber(value: 0)) == .orderedDescending
        else {
            throw RecurrenceCalculationError.overflow
        }
        return try Money(
            minorUnits: number.int64Value,
            currencyCode: money.currencyCode,
            exponent: money.exponent
        )
    }
}
