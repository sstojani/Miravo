import Foundation

enum MoneyError: Error, Equatable {
    case invalidAmount
    case nonPositiveAmount
    case tooManyFractionDigits
    case outOfRange
}

struct Money: Equatable, Sendable {
    let minorUnits: Int64
    let currencyCode: String
    let exponent: Int

    init(minorUnits: Int64, currencyCode: String, exponent: Int) throws {
        guard exponent >= 0, exponent <= 4 else {
            throw MoneyError.invalidAmount
        }
        let normalizedCurrency = currencyCode.uppercased()
        guard normalizedCurrency.count == 3,
              normalizedCurrency.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) })
        else {
            throw MoneyError.invalidAmount
        }
        self.minorUnits = minorUnits
        self.currencyCode = normalizedCurrency
        self.exponent = exponent
    }

    static func positive(
        majorUnits text: String,
        currencyCode: String,
        exponent: Int,
        locale: Locale
    ) throws -> Money {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        guard let number = formatter.number(from: text) else {
            throw MoneyError.invalidAmount
        }

        var major = number.decimalValue
        var scaled = Decimal()
        guard NSDecimalMultiplyByPowerOf10(&scaled, &major, Int16(exponent), .plain) == .noError else {
            throw MoneyError.outOfRange
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard scaled == rounded else {
            throw MoneyError.tooManyFractionDigits
        }

        let decimalNumber = NSDecimalNumber(decimal: rounded)
        let maximum = NSDecimalNumber(value: Int64.max)
        guard decimalNumber.compare(maximum) != .orderedDescending else {
            throw MoneyError.outOfRange
        }
        let minorUnits = decimalNumber.int64Value
        guard minorUnits > 0 else {
            throw MoneyError.nonPositiveAmount
        }
        return try Money(
            minorUnits: minorUnits,
            currencyCode: currencyCode,
            exponent: exponent
        )
    }

    func formatted(locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.minimumFractionDigits = exponent
        formatter.maximumFractionDigits = exponent
        let magnitude = minorUnits == Int64.min ? UInt64(Int64.max) + 1 : UInt64(abs(minorUnits))
        let number = NSDecimalNumber(
            mantissa: magnitude,
            exponent: Int16(-exponent),
            isNegative: minorUnits < 0
        )
        return formatter.string(from: number) ?? "\(minorUnits) \(currencyCode)"
    }
}

