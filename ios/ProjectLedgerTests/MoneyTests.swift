import Foundation
import Testing
@testable import ProjectLedger

struct MoneyTests {
    @Test func parsesEnglishDecimalWithoutFloatingPoint() throws {
        let money = try Money.positive(
            majorUnits: "12.50",
            currencyCode: "eur",
            exponent: 2,
            locale: Locale(identifier: "en_US")
        )
        #expect(money.minorUnits == 1_250)
        #expect(money.currencyCode == "EUR")
    }

    @Test func parsesAlbanianDecimalSeparator() throws {
        let money = try Money.positive(
            majorUnits: "12,50",
            currencyCode: "ALL",
            exponent: 2,
            locale: Locale(identifier: "sq_AL")
        )
        #expect(money.minorUnits == 1_250)
    }

    @Test func rejectsExcessFractionPrecision() {
        #expect(throws: MoneyError.tooManyFractionDigits) {
            try Money.positive(
                majorUnits: "1.001",
                currencyCode: "USD",
                exponent: 2,
                locale: Locale(identifier: "en_US")
            )
        }
    }

    @Test func rejectsZero() {
        #expect(throws: MoneyError.nonPositiveAmount) {
            try Money.positive(
                majorUnits: "0",
                currencyCode: "USD",
                exponent: 2,
                locale: Locale(identifier: "en_US")
            )
        }
    }
}

