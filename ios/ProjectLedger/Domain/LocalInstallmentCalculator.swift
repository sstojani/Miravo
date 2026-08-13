import CryptoKit
import Foundation

enum InstallmentCalculationError: Error, Equatable {
    case invalidConfiguration
    case overflow
}

struct LocalInstallmentScheduleAmount: Equatable, Sendable {
    let sequence: Int
    let dueOn: Date
    let principalMinor: Int64
    let interestMinor: Int64
    let feesMinor: Int64

    var totalMinor: Int64 {
        principalMinor + interestMinor + feesMinor
    }
}

struct LocalInstallmentProgress: Equatable, Sendable {
    let plannedTotalMinor: Int64
    let paidMinor: Int64
    let remainingMinor: Int64
    let nextDueOn: Date?
    let estimatedPayoffOn: Date?
}

enum LocalInstallmentCalculator {
    static let maximumInstallmentCount = 600
    private static let scheduleNamespace = UUID(
        uuidString: "d8c75720-0d53-4cfa-9f9a-c89a78737760"
    )!

    static func scheduleItemID(
        planID: UUID,
        revisionNumber: Int,
        sequence: Int
    ) throws -> UUID {
        guard revisionNumber > 0, sequence > 0 else {
            throw InstallmentCalculationError.invalidConfiguration
        }
        let name = "project-ledger:installment-schedule:" +
            "\(planID.uuidString.lowercased()):\(revisionNumber):\(sequence)"
        var namespace = scheduleNamespace.uuid
        let namespaceBytes = withUnsafeBytes(of: &namespace) { Array($0) }
        let digest = Insecure.SHA1.hash(data: Data(namespaceBytes + Array(name.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func plannedTotal(
        principalMinor: Int64,
        interestMinor: Int64,
        feesMinor: Int64
    ) throws -> Int64 {
        guard principalMinor > 0, interestMinor >= 0, feesMinor >= 0 else {
            throw InstallmentCalculationError.invalidConfiguration
        }
        return try safeAdd(try safeAdd(principalMinor, interestMinor), feesMinor)
    }

    static func buildSchedule(
        principalMinor: Int64,
        interestMinor: Int64,
        feesMinor: Int64,
        installmentCount: Int,
        plannedInstallmentMinor: Int64?,
        cadence: InstallmentCadence,
        startsOn: Date,
        anchorDay: Int? = nil
    ) throws -> [LocalInstallmentScheduleAmount] {
        let total = try plannedTotal(
            principalMinor: principalMinor,
            interestMinor: interestMinor,
            feesMinor: feesMinor
        )
        guard (1 ... maximumInstallmentCount).contains(installmentCount),
              let canonicalStart = BudgetDateCodec.canonicalDate(
                  from: startsOn,
                  calendar: storageCalendar
              )
        else {
            throw InstallmentCalculationError.invalidConfiguration
        }
        let resolvedAnchor = anchorDay ?? storageCalendar.component(.day, from: canonicalStart)
        guard (1 ... 31).contains(resolvedAnchor) else {
            throw InstallmentCalculationError.invalidConfiguration
        }

        let rowTotals: [Int64]
        if let plannedInstallmentMinor {
            guard plannedInstallmentMinor > 0 else {
                throw InstallmentCalculationError.invalidConfiguration
            }
            let lower = try safeMultiply(plannedInstallmentMinor, installmentCount - 1)
            let upper = try safeMultiply(plannedInstallmentMinor, installmentCount)
            guard lower < total, total <= upper else {
                throw InstallmentCalculationError.invalidConfiguration
            }
            rowTotals = Array(repeating: plannedInstallmentMinor, count: installmentCount - 1) +
                [try safeSubtract(total, lower)]
        } else {
            let quotient = total / Int64(installmentCount)
            let remainder = Int(total % Int64(installmentCount))
            guard quotient > 0 else {
                throw InstallmentCalculationError.invalidConfiguration
            }
            rowTotals = (0 ..< installmentCount).map { index in
                quotient + (index >= installmentCount - remainder ? 1 : 0)
            }
        }

        let componentRows = try allocateComponents(
            rowTotals: rowTotals,
            components: [principalMinor, interestMinor, feesMinor]
        )
        return try rowTotals.indices.map { index in
            let components = componentRows[index]
            let dueOn = try dueDate(
                startsOn: canonicalStart,
                cadence: cadence,
                sequence: index + 1,
                anchorDay: resolvedAnchor
            )
            let row = LocalInstallmentScheduleAmount(
                sequence: index + 1,
                dueOn: dueOn,
                principalMinor: components[0],
                interestMinor: components[1],
                feesMinor: components[2]
            )
            guard row.totalMinor == rowTotals[index] else {
                throw InstallmentCalculationError.invalidConfiguration
            }
            return row
        }
    }

    static func dueDate(
        startsOn: Date,
        cadence: InstallmentCadence,
        sequence: Int,
        anchorDay: Int
    ) throws -> Date {
        guard sequence >= 1, (1 ... 31).contains(anchorDay),
              let canonicalStart = BudgetDateCodec.canonicalDate(
                  from: startsOn,
                  calendar: storageCalendar
              )
        else {
            throw InstallmentCalculationError.invalidConfiguration
        }
        switch cadence {
        case .weekly:
            guard let value = storageCalendar.date(
                byAdding: .day,
                value: try safeIntMultiply(sequence - 1, 7),
                to: canonicalStart
            ) else {
                throw InstallmentCalculationError.invalidConfiguration
            }
            return value
        case .monthly:
            let start = storageCalendar.dateComponents([.year, .month], from: canonicalStart)
            guard let year = start.year, let month = start.month else {
                throw InstallmentCalculationError.invalidConfiguration
            }
            let zeroBased = try safeIntAdd(
                try safeIntAdd(try safeIntMultiply(year, 12), month - 1),
                sequence - 1
            )
            let targetYear = zeroBased / 12
            let targetMonth = zeroBased % 12 + 1
            guard let monthStart = storageCalendar.date(
                from: DateComponents(year: targetYear, month: targetMonth, day: 1)
            ), let range = storageCalendar.range(of: .day, in: .month, for: monthStart),
            let value = storageCalendar.date(
                from: DateComponents(
                    year: targetYear,
                    month: targetMonth,
                    day: min(anchorDay, range.count)
                )
            ) else {
                throw InstallmentCalculationError.invalidConfiguration
            }
            return value
        }
    }

    static func progress(
        plan: LocalInstallmentPlan,
        scheduleItems: [LocalInstallmentScheduleItem],
        payments: [LocalInstallmentPayment]
    ) throws -> LocalInstallmentProgress {
        let paymentPaid = try payments
            .filter { $0.planID == plan.id && $0.deletedAt == nil }
            .reduce(into: Int64(0)) { result, payment in
                result = try safeAdd(result, payment.appliedAmountMinor)
            }
        let schedulePaid = try scheduleItems
            .filter {
                $0.planID == plan.id && $0.deletedAt == nil && $0.supersededAt == nil
            }
            .reduce(into: Int64(0)) { result, item in
                result = try safeAdd(result, item.paidMinor)
            }
        let paid = max(paymentPaid, schedulePaid)
        let remaining = max(try safeSubtract(plan.plannedTotalMinor, paid), 0)
        let unpaid = scheduleItems
            .filter {
                $0.planID == plan.id &&
                    $0.deletedAt == nil &&
                    $0.supersededAt == nil &&
                    $0.state != .paid &&
                    $0.state != .skipped
            }
            .sorted {
                $0.dueOn == $1.dueOn ? $0.sequence < $1.sequence : $0.dueOn < $1.dueOn
            }
        return LocalInstallmentProgress(
            plannedTotalMinor: plan.plannedTotalMinor,
            paidMinor: paid,
            remainingMinor: remaining,
            nextDueOn: unpaid.first?.dueOn,
            estimatedPayoffOn: remaining > 0 ? unpaid.last?.dueOn : nil
        )
    }

    private static func allocateComponents(
        rowTotals: [Int64],
        components: [Int64]
    ) throws -> [[Int64]] {
        guard try checkedSum(rowTotals) == checkedSum(components),
              !rowTotals.isEmpty,
              components.allSatisfy({ $0 >= 0 })
        else {
            throw InstallmentCalculationError.invalidConfiguration
        }
        var remainingComponents = components
        var remainingTotal = try checkedSum(components)
        var rows = [[Int64]]()
        for index in rowTotals.indices {
            if index == rowTotals.index(before: rowTotals.endIndex) {
                rows.append(remainingComponents)
                break
            }
            let rowTotal = rowTotals[index]
            let divisions = try remainingComponents.map {
                try multipliedQuotientAndRemainder(
                    rowTotal,
                    $0,
                    dividedBy: remainingTotal
                )
            }
            var row = divisions.map(\.quotient)
            var unallocated = try safeSubtract(rowTotal, try checkedSum(row))
            let order = divisions.indices.sorted { left, right in
                if divisions[left].remainder != divisions[right].remainder {
                    return divisions[left].remainder > divisions[right].remainder
                }
                if remainingComponents[left] != remainingComponents[right] {
                    return remainingComponents[left] > remainingComponents[right]
                }
                return left < right
            }
            for position in order where unallocated > 0 {
                if row[position] < remainingComponents[position] {
                    row[position] = try safeAdd(row[position], 1)
                    unallocated -= 1
                }
            }
            guard unallocated == 0 else {
                throw InstallmentCalculationError.invalidConfiguration
            }
            rows.append(row)
            remainingComponents = try zip(remainingComponents, row).map {
                try safeSubtract($0.0, $0.1)
            }
            remainingTotal = try safeSubtract(remainingTotal, rowTotal)
        }
        return rows
    }

    private static func multipliedQuotientAndRemainder(
        _ left: Int64,
        _ right: Int64,
        dividedBy divisor: Int64
    ) throws -> (quotient: Int64, remainder: Int64) {
        guard left >= 0, right >= 0, divisor > 0 else {
            throw InstallmentCalculationError.invalidConfiguration
        }
        let product = UInt64(left).multipliedFullWidth(by: UInt64(right))
        let division = UInt64(divisor).dividingFullWidth(product)
        guard division.quotient <= UInt64(Int64.max),
              division.remainder <= UInt64(Int64.max)
        else {
            throw InstallmentCalculationError.overflow
        }
        return (Int64(division.quotient), Int64(division.remainder))
    }

    private static func checkedSum(_ values: [Int64]) throws -> Int64 {
        try values.reduce(into: Int64(0)) { result, value in
            result = try safeAdd(result, value)
        }
    }

    private static func safeAdd(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw InstallmentCalculationError.overflow }
        return result.partialValue
    }

    private static func safeSubtract(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.subtractingReportingOverflow(right)
        guard !result.overflow else { throw InstallmentCalculationError.overflow }
        return result.partialValue
    }

    private static func safeMultiply(_ value: Int64, _ count: Int) throws -> Int64 {
        guard count >= 0 else { throw InstallmentCalculationError.invalidConfiguration }
        let result = value.multipliedReportingOverflow(by: Int64(count))
        guard !result.overflow else { throw InstallmentCalculationError.overflow }
        return result.partialValue
    }

    private static func safeIntAdd(_ left: Int, _ right: Int) throws -> Int {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw InstallmentCalculationError.overflow }
        return result.partialValue
    }

    private static func safeIntMultiply(_ left: Int, _ right: Int) throws -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else { throw InstallmentCalculationError.overflow }
        return result.partialValue
    }

    private static var storageCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
