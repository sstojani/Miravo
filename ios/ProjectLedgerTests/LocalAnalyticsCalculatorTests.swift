import Foundation
import Testing
@testable import ProjectLedger

struct LocalAnalyticsCalculatorTests {
    private let trackerID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let accountID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let firstCategoryID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let secondCategoryID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!

    @Test func convertedRefundsCategoriesTrendsMerchantsAndSourcesStayExact() throws {
        let expenseID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let expense = transaction(
            id: expenseID,
            kind: .expense,
            source: .shortcut,
            amountMinor: 1_000,
            baseAmountMinor: 1_100,
            merchant: "Café",
            occurredAt: date(2026, 1, 10)
        )
        let income = transaction(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            kind: .income,
            amountMinor: 500,
            baseAmountMinor: 550,
            occurredAt: date(2026, 1, 12)
        )
        let refund = transaction(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!,
            kind: .refund,
            amountMinor: 200,
            baseAmountMinor: 220,
            occurredAt: date(2026, 1, 12),
            refundOfID: expenseID
        )
        let transfer = transaction(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            kind: .transfer,
            amountMinor: 9_999,
            baseAmountMinor: 9_999,
            occurredAt: date(2026, 1, 13)
        )

        let snapshot = try LocalAnalyticsCalculator.calculate(
            configuration: configuration(range: .thisMonth),
            transactions: [transfer, refund, income, expense],
            allocations: [
                LocalAnalyticsAllocationInput(
                    transactionID: expenseID,
                    categoryID: firstCategoryID,
                    amountMinor: 333
                ),
                LocalAnalyticsAllocationInput(
                    transactionID: expenseID,
                    categoryID: secondCategoryID,
                    amountMinor: 667
                ),
            ],
            categoryNames: [firstCategoryID: "Food", secondCategoryID: "Travel"],
            asOf: date(2026, 1, 20),
            calendar: calendar
        )

        #expect(snapshot.recordCount == 3)
        #expect(snapshot.spendingMinor == 880)
        #expect(snapshot.incomeMinor == 550)
        #expect(snapshot.cashFlowMinor == -330)
        #expect(snapshot.categories.map(\.amountMinor).reduce(0, +) == 880)
        #expect(snapshot.categories.first { $0.name == "Food" }?.amountMinor == 293)
        #expect(snapshot.categories.first { $0.name == "Travel" }?.amountMinor == 587)
        #expect(snapshot.merchants == [
            LocalAnalyticsBreakdownItem(
                id: "cafe",
                name: "Café",
                amountMinor: 880,
                transactionCount: 2
            ),
        ])
        #expect(snapshot.sources.first?.id == TransactionSource.shortcut.rawValue)
        #expect(snapshot.sources.first?.amountMinor == 1_100)
        #expect(snapshot.trend.count == 31)
        #expect(snapshot.trend.map(\.spendingMinor).reduce(0, +) == 880)
        #expect(snapshot.trend.map(\.incomeMinor).reduce(0, +) == 550)
        #expect(snapshot.unconverted.isEmpty)
    }

    @Test func filtersRangeAccountStatusAndReportsMissingConversionWithoutInventingIt() throws {
        let selected = transaction(
            id: UUID(),
            kind: .expense,
            amountMinor: 700,
            currencyCode: "USD",
            baseAmountMinor: 700,
            baseCurrencyCode: "USD",
            occurredAt: date(2026, 4, 3)
        )
        let missingRate = transaction(
            id: UUID(),
            kind: .expense,
            amountMinor: 900,
            baseAmountMinor: 950,
            occurredAt: date(2026, 4, 4)
        )
        let otherAccount = transaction(
            id: UUID(),
            accountID: UUID(),
            kind: .expense,
            amountMinor: 300,
            currencyCode: "USD",
            baseAmountMinor: 300,
            baseCurrencyCode: "USD",
            occurredAt: date(2026, 4, 4)
        )
        let pending = transaction(
            id: UUID(),
            kind: .expense,
            status: .pending,
            amountMinor: 400,
            currencyCode: "USD",
            baseAmountMinor: 400,
            baseCurrencyCode: "USD",
            occurredAt: date(2026, 4, 5)
        )
        let outsideRange = transaction(
            id: UUID(),
            kind: .expense,
            amountMinor: 500,
            currencyCode: "USD",
            baseAmountMinor: 500,
            baseCurrencyCode: "USD",
            occurredAt: date(2025, 4, 5)
        )

        let snapshot = try LocalAnalyticsCalculator.calculate(
            configuration: LocalAnalyticsConfiguration(
                trackerID: trackerID,
                accountID: accountID,
                reportingCurrencyCode: "USD",
                reportingCurrencyExponent: 2,
                range: .thisYear
            ),
            transactions: [selected, missingRate, otherAccount, pending, outsideRange],
            allocations: [],
            categoryNames: [:],
            asOf: date(2026, 5, 1),
            calendar: calendar
        )

        #expect(snapshot.recordCount == 1)
        #expect(snapshot.spendingMinor == 700)
        #expect(snapshot.isPartial)
        #expect(snapshot.unconverted.count == 1)
        #expect(snapshot.unconverted.first?.currencyCode == "EUR")
        #expect(snapshot.unconverted.first?.amountMinor == 900)
        #expect(snapshot.unconverted.first?.transactionCount == 1)
    }

    @Test func proportionalRoundingUsesStableCategoryOrderAndRejectsBrokenAllocations() throws {
        let expenseID = UUID()
        let expense = transaction(
            id: expenseID,
            kind: .expense,
            amountMinor: 2,
            baseAmountMinor: 3,
            occurredAt: date(2026, 2, 1)
        )
        let allocations = [
            LocalAnalyticsAllocationInput(
                transactionID: expenseID,
                categoryID: secondCategoryID,
                amountMinor: 1
            ),
            LocalAnalyticsAllocationInput(
                transactionID: expenseID,
                categoryID: firstCategoryID,
                amountMinor: 1
            ),
        ]
        let snapshot = try LocalAnalyticsCalculator.calculate(
            configuration: configuration(range: .allTime),
            transactions: [expense],
            allocations: allocations,
            categoryNames: [firstCategoryID: "First", secondCategoryID: "Second"],
            calendar: calendar
        )
        #expect(snapshot.categories.first { $0.name == "First" }?.amountMinor == 2)
        #expect(snapshot.categories.first { $0.name == "Second" }?.amountMinor == 1)

        #expect(throws: LocalAnalyticsCalculationError.invalidAllocations) {
            try LocalAnalyticsCalculator.calculate(
                configuration: configuration(range: .allTime),
                transactions: [expense],
                allocations: [
                    LocalAnalyticsAllocationInput(
                        transactionID: expenseID,
                        categoryID: firstCategoryID,
                        amountMinor: 1
                    ),
                ],
                categoryNames: [:],
                calendar: calendar
            )
        }
    }

    @Test func threeMonthTrendUsesStableISOMondayWeekBoundaries() throws {
        let sunday = transaction(
            id: UUID(),
            kind: .expense,
            amountMinor: 100,
            baseAmountMinor: 100,
            occurredAt: date(2026, 1, 4)
        )
        let monday = transaction(
            id: UUID(),
            kind: .income,
            amountMinor: 50,
            baseAmountMinor: 50,
            occurredAt: date(2026, 1, 5)
        )

        let snapshot = try LocalAnalyticsCalculator.calculate(
            configuration: configuration(range: .threeMonths),
            transactions: [sunday, monday],
            allocations: [],
            categoryNames: [:],
            asOf: date(2026, 1, 20),
            calendar: calendar
        )
        let nonempty = snapshot.trend.filter {
            $0.spendingMinor != 0 || $0.incomeMinor != 0
        }

        #expect(nonempty.map(\.bucketStart) == [date(2025, 12, 29), date(2026, 1, 5)])
        #expect(nonempty.map(\.spendingMinor) == [100, 0])
        #expect(nonempty.map(\.incomeMinor) == [0, 50])
    }

    @Test func allTimeTrendIsBoundedWithoutChangingFinancialTotals() throws {
        let start = date(2000, 1, 1)
        let transactions = try (0 ... LocalAnalyticsCalculator.maximumTrendPointCount).map {
            index in
            let occurredAt = try #require(
                calendar.date(byAdding: .month, value: index, to: start)
            )
            return transaction(
                id: UUID(),
                kind: .expense,
                amountMinor: 1,
                baseAmountMinor: 1,
                occurredAt: occurredAt
            )
        }
        let snapshot = try LocalAnalyticsCalculator.calculate(
            configuration: configuration(range: .allTime),
            transactions: transactions,
            allocations: [],
            categoryNames: [:],
            calendar: calendar
        )

        #expect(
            snapshot.spendingMinor == Int64(LocalAnalyticsCalculator.maximumTrendPointCount + 1)
        )
        #expect(snapshot.recordCount == LocalAnalyticsCalculator.maximumTrendPointCount + 1)
        #expect(snapshot.trend.count == LocalAnalyticsCalculator.maximumTrendPointCount)
        #expect(snapshot.trendWasTruncated)
    }

    private func configuration(range: AnalyticsRangePreset) -> LocalAnalyticsConfiguration {
        LocalAnalyticsConfiguration(
            trackerID: trackerID,
            accountID: nil,
            reportingCurrencyCode: "ALL",
            reportingCurrencyExponent: 2,
            range: range
        )
    }

    private func transaction(
        id: UUID,
        accountID: UUID? = nil,
        kind: TransactionKind,
        source: TransactionSource = .manual,
        status: TransactionStatus = .posted,
        amountMinor: Int64,
        currencyCode: String = "EUR",
        baseAmountMinor: Int64,
        baseCurrencyCode: String = "ALL",
        merchant: String = "",
        occurredAt: Date,
        refundOfID: UUID? = nil
    ) -> LocalAnalyticsTransactionInput {
        LocalAnalyticsTransactionInput(
            id: id,
            trackerID: trackerID,
            accountID: accountID ?? self.accountID,
            destinationAccountID: nil,
            categoryID: nil,
            kind: kind,
            source: source,
            status: status,
            amountMinor: amountMinor,
            currencyCode: currencyCode,
            currencyExponent: 2,
            baseAmountMinor: baseAmountMinor,
            baseCurrencyCode: baseCurrencyCode,
            baseCurrencyExponent: 2,
            rateSource: currencyCode == baseCurrencyCode ? "identity" : "manual",
            merchant: merchant,
            occurredAt: occurredAt,
            refundOfID: refundOfID,
            deleted: false
        )
    }

    private var calendar: Calendar {
        AnalyticsReportingCalendar.make(timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
