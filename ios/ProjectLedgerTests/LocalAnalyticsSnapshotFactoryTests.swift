import Foundation
import Testing
@testable import ProjectLedger

@MainActor
struct LocalAnalyticsSnapshotFactoryTests {
    @Test func scopedSplitExpensesAndRefundsKeepExactCategoryTotals() throws {
        let scopeKey = "account|current"
        let tracker = LocalTracker(scopeKey: scopeKey, name: "Everyday")
        let food = LocalCategory(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            kind: .expense,
            name: "Food"
        )
        let dining = LocalCategory(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            parentID: food.id,
            kind: .expense,
            name: "Dining"
        )
        let groceries = LocalCategory(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            parentID: food.id,
            kind: .expense,
            name: "Groceries"
        )
        let otherScopeCategory = LocalCategory(
            id: dining.id,
            scopeKey: "account|other",
            trackerID: tracker.id,
            kind: .expense,
            name: "Private"
        )
        let calendar = AnalyticsReportingCalendar.make(timeZone: TimeZone(secondsFromGMT: 0)!)
        let expenseDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 3
        )))
        let asOf = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 15
        )))
        let expense = LedgerTransaction(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            accountID: UUID(),
            kind: .expense,
            money: try Money(minorUnits: 1_000, currencyCode: "ALL", exponent: 2),
            occurredAt: expenseDate
        )
        let refund = LedgerTransaction(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            accountID: expense.accountID,
            kind: .refund,
            money: try Money(minorUnits: 200, currencyCode: "ALL", exponent: 2),
            occurredAt: expenseDate
        )
        refund.refundOfID = expense.id
        let otherScopeExpense = LedgerTransaction(
            scopeKey: "account|other",
            trackerID: tracker.id,
            accountID: UUID(),
            kind: .expense,
            money: try Money(minorUnits: 9_000, currencyCode: "ALL", exponent: 2),
            occurredAt: expenseDate
        )

        let snapshot = try LocalAnalyticsSnapshotFactory.calculate(
            tracker: tracker,
            reportingCurrencyCode: "ALL",
            reportingCurrencyExponent: 2,
            range: .thisMonth,
            transactions: [expense, refund, otherScopeExpense],
            categories: [food, dining, groceries, otherScopeCategory],
            allocations: [
                LocalCategoryAllocation(
                    scopeKey: scopeKey,
                    transactionID: expense.id,
                    categoryID: dining.id,
                    amountMinor: 700
                ),
                LocalCategoryAllocation(
                    scopeKey: scopeKey,
                    transactionID: expense.id,
                    categoryID: groceries.id,
                    amountMinor: 300
                ),
                LocalCategoryAllocation(
                    scopeKey: "account|other",
                    transactionID: expense.id,
                    categoryID: dining.id,
                    amountMinor: 1_000
                ),
            ],
            asOf: asOf,
            calendar: calendar
        )

        #expect(snapshot.spendingMinor == 800)
        #expect(snapshot.categories.first { $0.name == "Food · Dining" }?.amountMinor == 560)
        #expect(snapshot.categories.first { $0.name == "Food · Groceries" }?.amountMinor == 240)
        #expect(snapshot.categories.allSatisfy { $0.name != "Private" })
    }
}
