import Foundation
import XCTest
@testable import ProjectLedger

@MainActor
final class TransactionListPerformanceTests: XCTestCase {
    func testCombinedLocalSearchAcrossFiftyThousandTransactions() throws {
        let trackerID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let accountID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let categoryID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let occurredAt = Date(timeIntervalSince1970: 1_786_273_200)
        let transactions = try (0 ..< 50_000).map { index in
            LedgerTransaction(
                scopeKey: "performance-scope",
                trackerID: trackerID,
                accountID: accountID,
                categoryID: categoryID,
                kind: .expense,
                money: try Money(
                    minorUnits: Int64(index + 1),
                    currencyCode: "EUR",
                    exponent: 2
                ),
                merchant: index.isMultiple(of: 10) ? "Coffee" : "Market",
                note: "Fixture \(index)",
                occurredAt: occurredAt
            )
        }
        let criteria = TransactionListCriteria(
            query: "coffee",
            trackerID: trackerID,
            categoryID: categoryID,
            kind: .expense,
            currencyCode: "EUR"
        )
        let context = TransactionSearchContext(
            trackerNames: [trackerID: "Everyday"],
            accountNames: [accountID: "Wallet"],
            categoryNames: [categoryID: "Food"]
        )
        let calendar = Calendar(identifier: .gregorian)
        let clock = ContinuousClock()
        let start = clock.now

        let matches = transactions.filter {
            criteria.matches(
                $0,
                context: context,
                now: occurredAt,
                calendar: calendar,
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(matches.count, 5_000)
        XCTAssertLessThan(
            elapsed,
            .seconds(3),
            "In-memory combined filtering exceeded the three-second regression ceiling."
        )
    }
}
