import Foundation
import Testing
@testable import ProjectLedger

struct LocalBalanceCalculatorTests {
    @Test func derivesBalanceAndIgnoresDeletedOrVoidedEntries() throws {
        let scope = "https://ledger.example|70000000-0000-0000-0000-000000000007"
        let trackerID = UUID(uuidString: "71000000-0000-0000-0000-000000000007")!
        let account = LocalAccount(
            scopeKey: scope,
            trackerID: trackerID,
            name: "Cash",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2,
            openingBalanceMinor: 10_000
        )
        let expense = LedgerTransaction(
            scopeKey: scope,
            trackerID: trackerID,
            accountID: account.id,
            kind: .expense,
            money: try Money(minorUnits: 500, currencyCode: "ALL", exponent: 2)
        )
        let income = LedgerTransaction(
            scopeKey: scope,
            trackerID: trackerID,
            accountID: account.id,
            kind: .income,
            money: try Money(minorUnits: 200, currencyCode: "ALL", exponent: 2)
        )
        let deleted = LedgerTransaction(
            scopeKey: scope,
            trackerID: trackerID,
            accountID: account.id,
            kind: .expense,
            money: try Money(minorUnits: 9_999, currencyCode: "ALL", exponent: 2)
        )
        deleted.deletedAt = .now
        let voided = LedgerTransaction(
            scopeKey: scope,
            trackerID: trackerID,
            accountID: account.id,
            kind: .expense,
            money: try Money(minorUnits: 9_999, currencyCode: "ALL", exponent: 2),
            status: .voided
        )

        let balance = LocalBalanceCalculator.balance(
            for: account,
            transactions: [expense, income, deleted, voided]
        )
        #expect(balance?.minorUnits == 9_700)
    }
}
