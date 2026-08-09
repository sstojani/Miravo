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
        #expect(money.editableMajorUnits(locale: Locale(identifier: "sq_AL")) == "12,50")
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

    @Test func rejectsPartialOrGroupedInputInsteadOfSilentlyTruncating() {
        for value in ["12abc", "1,000.00", "12."] {
            #expect(throws: MoneyError.invalidAmount) {
                try Money.positive(
                    majorUnits: value,
                    currencyCode: "USD",
                    exponent: 2,
                    locale: Locale(identifier: "en_US")
                )
            }
        }
    }

    @Test func rejectsNonASCIICurrencyLookalikesAndIntegerOverflow() {
        #expect(throws: MoneyError.invalidAmount) {
            try Money(minorUnits: 100, currencyCode: "ËUR", exponent: 2)
        }
        #expect(throws: MoneyError.outOfRange) {
            try Money.positive(
                majorUnits: "999999999999999999999999999999",
                currencyCode: "EUR",
                exponent: 2,
                locale: Locale(identifier: "en_US")
            )
        }
    }
}
