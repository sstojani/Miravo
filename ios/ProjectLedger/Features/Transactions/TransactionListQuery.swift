import Foundation

enum TransactionDateWindow: String, CaseIterable, Identifiable, Sendable {
    case all
    case thisMonth
    case sevenDays
    case thirtyDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: String(localized: "All dates")
        case .thisMonth: String(localized: "This month")
        case .sevenDays: String(localized: "Last 7 days")
        case .thirtyDays: String(localized: "Last 30 days")
        }
    }

    func contains(_ date: Date, relativeTo now: Date, calendar: Calendar) -> Bool {
        guard self != .all else { return true }
        let startOfToday = calendar.startOfDay(for: now)
        let bounds: DateInterval?
        switch self {
        case .all:
            bounds = nil
        case .thisMonth:
            bounds = calendar.dateInterval(of: .month, for: now)
        case .sevenDays:
            bounds = rollingBounds(days: 7, startOfToday: startOfToday, calendar: calendar)
        case .thirtyDays:
            bounds = rollingBounds(days: 30, startOfToday: startOfToday, calendar: calendar)
        }
        guard let bounds else { return false }
        return date >= bounds.start && date < bounds.end
    }

    private func rollingBounds(
        days: Int,
        startOfToday: Date,
        calendar: Calendar
    ) -> DateInterval? {
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday),
              let end = calendar.date(byAdding: .day, value: 1, to: startOfToday)
        else { return nil }
        return DateInterval(start: start, end: end)
    }
}

struct TransactionSearchContext: Sendable {
    var trackerNames: [UUID: String] = [:]
    var accountNames: [UUID: String] = [:]
    var categoryNames: [UUID: String] = [:]
    var tagNamesByTransaction: [UUID: [String]] = [:]
    var tagIDsByTransaction: [UUID: Set<UUID>] = [:]
}

struct TransactionListCriteria: Equatable, Sendable {
    var query = ""
    var trackerID: UUID?
    var accountID: UUID?
    var categoryID: UUID?
    var tagID: UUID?
    var kind: TransactionKind?
    var source: TransactionSource?
    var status: TransactionStatus?
    var currencyCode: String?
    var syncState: LocalSyncState?
    var dateWindow = TransactionDateWindow.all

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            trackerID != nil || accountID != nil || categoryID != nil || tagID != nil || kind != nil ||
            source != nil || status != nil || currencyCode != nil || syncState != nil ||
            dateWindow != .all
    }

    var activeFacetCount: Int {
        [
            trackerID != nil,
            accountID != nil,
            categoryID != nil,
            tagID != nil,
            kind != nil,
            source != nil,
            status != nil,
            currencyCode != nil,
            syncState != nil,
            dateWindow != .all,
        ].filter { $0 }.count
    }

    func matches(
        _ transaction: LedgerTransaction,
        context: TransactionSearchContext,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> Bool {
        let tagMatches = tagID.map {
            context.tagIDsByTransaction[transaction.id]?.contains($0) == true
        } ?? true
        guard trackerID == nil || transaction.trackerID == trackerID,
              accountID == nil ||
              transaction.accountID == accountID ||
              transaction.destinationAccountID == accountID,
              categoryID == nil || transaction.categoryID == categoryID,
              tagMatches,
              kind == nil || transaction.kind == kind,
              source == nil || transaction.source == source,
              status == nil || transaction.status == status,
              currencyCode == nil || transaction.currencyCode == currencyCode,
              syncState == nil || transaction.syncState == syncState,
              dateWindow.contains(transaction.occurredAt, relativeTo: now, calendar: calendar)
        else {
            return false
        }

        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return true }
        var searchableValues = [
            transaction.merchant,
            transaction.note,
            transaction.currencyCode,
            transaction.kind.displayName,
            transaction.source.displayName,
            transaction.status.displayName,
            context.trackerNames[transaction.trackerID] ?? "",
            context.accountNames[transaction.accountID] ?? "",
            transaction.destinationAccountID.flatMap { context.accountNames[$0] } ?? "",
            transaction.categoryID.flatMap { context.categoryNames[$0] } ?? "",
            amountSearchText(for: transaction, locale: locale),
            String(transaction.amountMinor),
        ]
        searchableValues.append(contentsOf: context.tagNamesByTransaction[transaction.id] ?? [])
        return searchableValues.contains { value in
            value.range(
                of: cleanQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: locale
            ) != nil
        }
    }

    private func amountSearchText(for transaction: LedgerTransaction, locale: Locale) -> String {
        let exponent = transaction.currencyExponent
        guard exponent > 0 else { return String(transaction.amountMinor) }
        let magnitude = transaction.amountMinor == Int64.min
            ? UInt64(Int64.max) + 1
            : UInt64(abs(transaction.amountMinor))
        var digits = String(magnitude)
        if digits.count <= exponent {
            digits = String(repeating: "0", count: exponent - digits.count + 1) + digits
        }
        let split = digits.index(digits.endIndex, offsetBy: -exponent)
        let sign = transaction.amountMinor < 0 ? "-" : ""
        let separator = locale.decimalSeparator ?? "."
        return sign + String(digits[..<split]) + separator + String(digits[split...])
    }
}
