import Foundation
import Testing
@testable import ProjectLedger

@MainActor
struct TransactionListQueryTests {
    private let trackerID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let sourceAccountID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let destinationAccountID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let categoryID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!

    @Test func combinedFacetsIncludeDestinationAccountsAndExcludeMismatches() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let transaction = try makeTransaction(occurredAt: now)
        transaction.destinationAccountID = destinationAccountID
        transaction.destinationAmountMinor = 900
        transaction.sourceRaw = TransactionSource.shortcut.rawValue
        transaction.statusRaw = TransactionStatus.pending.rawValue
        transaction.syncStateRaw = LocalSyncState.failed.rawValue
        let context = searchContext()
        var criteria = TransactionListCriteria(
            trackerID: trackerID,
            accountID: destinationAccountID,
            categoryID: categoryID,
            kind: .expense,
            source: .shortcut,
            status: .pending,
            currencyCode: "EUR",
            syncState: .failed,
            dateWindow: .sevenDays
        )

        #expect(criteria.matches(
            transaction,
            context: context,
            now: now,
            calendar: utcCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        ))
        #expect(criteria.activeFacetCount == 9)

        criteria.accountID = UUID()
        #expect(!criteria.matches(
            transaction,
            context: context,
            now: now,
            calendar: utcCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        ))
    }

    @Test func searchCoversNamesDiacriticsAndLocalizedAmountWithoutFormattingEachRow() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let transaction = try makeTransaction(occurredAt: now)
        transaction.destinationAccountID = destinationAccountID
        let context = searchContext()

        for query in ["cafe", "savings", "travel", "food", "12.50", "EUR"] {
            let criteria = TransactionListCriteria(query: query)
            #expect(criteria.matches(
                transaction,
                context: context,
                now: now,
                calendar: utcCalendar(),
                locale: Locale(identifier: "en_US_POSIX")
            ))
        }
        #expect(TransactionListCriteria(query: "12,50").matches(
            transaction,
            context: context,
            now: now,
            calendar: utcCalendar(),
            locale: Locale(identifier: "sq_AL")
        ))
    }

    @Test func rollingDateWindowUsesWholeLocalDaysAndExcludesFutureDates() throws {
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2026-08-09T12:00:00Z"))
        let firstIncluded = try makeTransaction(
            occurredAt: #require(formatter.date(from: "2026-08-03T00:00:00Z"))
        )
        let dayBefore = try makeTransaction(
            occurredAt: #require(formatter.date(from: "2026-08-02T23:59:59Z"))
        )
        let tomorrow = try makeTransaction(
            occurredAt: #require(formatter.date(from: "2026-08-10T00:00:00Z"))
        )
        let criteria = TransactionListCriteria(dateWindow: .sevenDays)
        let context = searchContext()

        #expect(criteria.matches(
            firstIncluded,
            context: context,
            now: now,
            calendar: utcCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        ))
        #expect(!criteria.matches(
            dayBefore,
            context: context,
            now: now,
            calendar: utcCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        ))
        #expect(!criteria.matches(
            tomorrow,
            context: context,
            now: now,
            calendar: utcCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        ))
    }

    private func makeTransaction(occurredAt: Date) throws -> LedgerTransaction {
        LedgerTransaction(
            scopeKey: "scope",
            trackerID: trackerID,
            accountID: sourceAccountID,
            categoryID: categoryID,
            kind: .expense,
            money: try Money(minorUnits: 1_250, currencyCode: "EUR", exponent: 2),
            merchant: "Café Adriatik",
            note: "Summer trip",
            occurredAt: occurredAt
        )
    }

    private func searchContext() -> TransactionSearchContext {
        TransactionSearchContext(
            trackerNames: [trackerID: "Travel"],
            accountNames: [
                sourceAccountID: "Wallet",
                destinationAccountID: "Savings",
            ],
            categoryNames: [categoryID: "Food"]
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
