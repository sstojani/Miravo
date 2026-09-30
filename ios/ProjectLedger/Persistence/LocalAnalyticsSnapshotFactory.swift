import Foundation

enum LocalAnalyticsSnapshotFactory {
    static func calculate(
        tracker: LocalTracker,
        accountID: UUID? = nil,
        reportingCurrencyCode: String,
        reportingCurrencyExponent: Int,
        range: AnalyticsRangePreset,
        transactions: [LedgerTransaction],
        categories: [LocalCategory],
        allocations: [LocalCategoryAllocation],
        asOf: Date = .now,
        calendar: Calendar = AnalyticsReportingCalendar.make()
    ) throws -> LocalAnalyticsSnapshot {
        let trackerCategories = categories.filter {
            $0.scopeKey == tracker.scopeKey && $0.trackerID == tracker.id && $0.deletedAt == nil
        }
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
        let records = transactions.filter {
            $0.scopeKey == tracker.scopeKey && $0.trackerID == tracker.id
        }.map {
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
        let categoryAllocations: [LocalAnalyticsAllocationInput] = allocations.compactMap { allocation in
            guard allocation.scopeKey == tracker.scopeKey,
                  recordIDs.contains(allocation.transactionID)
            else { return nil }
            return LocalAnalyticsAllocationInput(
                transactionID: allocation.transactionID,
                categoryID: allocation.categoryID,
                amountMinor: allocation.amountMinor
            )
        }
        return try LocalAnalyticsCalculator.calculate(
            configuration: LocalAnalyticsConfiguration(
                trackerID: tracker.id,
                accountID: accountID,
                reportingCurrencyCode: reportingCurrencyCode,
                reportingCurrencyExponent: reportingCurrencyExponent,
                range: range
            ),
            transactions: records,
            allocations: categoryAllocations,
            categoryNames: categoryNames,
            asOf: asOf,
            calendar: calendar
        )
    }
}
