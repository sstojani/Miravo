import Foundation

enum MoneyError: Error, Equatable {
    case invalidAmount
    case nonPositiveAmount
    case tooManyFractionDigits
    case outOfRange
    case conversionRequired
}

struct ReportingConversionSnapshot: Equatable, Sendable {
    let baseAmountMinor: Int64
    let baseCurrencyCode: String
    let rateSnapshot: String
    let rateSource: String
    let effectiveAt: Date

    static func resolved(
        original: Money,
        baseCurrencyCode: String,
        baseCurrencyExponent: Int,
        manualBaseMoney: Money?,
        effectiveAt: Date
    ) throws -> ReportingConversionSnapshot {
        let normalizedBase = baseCurrencyCode.uppercased()
        if original.currencyCode == normalizedBase {
            guard original.exponent == baseCurrencyExponent,
                  manualBaseMoney == nil || manualBaseMoney == original
            else {
                throw MoneyError.invalidAmount
            }
            return ReportingConversionSnapshot(
                baseAmountMinor: original.minorUnits,
                baseCurrencyCode: normalizedBase,
                rateSnapshot: "1",
                rateSource: "identity",
                effectiveAt: effectiveAt
            )
        }

        guard let manualBaseMoney,
              manualBaseMoney.minorUnits > 0,
              manualBaseMoney.currencyCode == normalizedBase,
              manualBaseMoney.exponent == baseCurrencyExponent,
              original.minorUnits > 0
        else {
            throw MoneyError.conversionRequired
        }
        let originalMajor = NSDecimalNumber(
            mantissa: UInt64(original.minorUnits),
            exponent: Int16(-original.exponent),
            isNegative: false
        )
        let baseMajor = NSDecimalNumber(
            mantissa: UInt64(manualBaseMoney.minorUnits),
            exponent: Int16(-manualBaseMoney.exponent),
            isNegative: false
        )
        let rounding = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 12,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: true
        )
        let rate = baseMajor.dividing(by: originalMajor, withBehavior: rounding)
        guard rate != .notANumber,
              rate.compare(NSDecimalNumber(value: 0)) == .orderedDescending
        else {
            throw MoneyError.invalidAmount
        }
        return ReportingConversionSnapshot(
            baseAmountMinor: manualBaseMoney.minorUnits,
            baseCurrencyCode: normalizedBase,
            rateSnapshot: rate.stringValue,
            rateSource: "manual",
            effectiveAt: effectiveAt
        )
    }
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
        guard normalizedCurrency.utf8.count == 3,
              normalizedCurrency.utf8.allSatisfy({ (65 ... 90).contains($0) })
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
        guard exponent >= 0, exponent <= 4 else { throw MoneyError.invalidAmount }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw MoneyError.invalidAmount }
        let separator = locale.decimalSeparator ?? "."
        let components = input.components(separatedBy: separator)
        guard components.count <= 2,
              let integerPart = components.first,
              !integerPart.isEmpty,
              integerPart.utf8.allSatisfy({ (48 ... 57).contains($0) })
        else {
            throw MoneyError.invalidAmount
        }
        let fractionPart = components.count == 2 ? components[1] : ""
        guard fractionPart.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            throw MoneyError.invalidAmount
        }
        guard fractionPart.count <= exponent else {
            throw MoneyError.tooManyFractionDigits
        }
        if components.count == 2, fractionPart.isEmpty {
            throw MoneyError.invalidAmount
        }

        let paddedFraction = fractionPart + String(
            repeating: "0",
            count: exponent - fractionPart.count
        )
        var minorUnits: Int64 = 0
        for byte in (integerPart + paddedFraction).utf8 {
            let (scaled, multiplicationOverflow) = minorUnits.multipliedReportingOverflow(by: 10)
            let (next, additionOverflow) = scaled.addingReportingOverflow(Int64(byte - 48))
            guard !multiplicationOverflow, !additionOverflow else {
                throw MoneyError.outOfRange
            }
            minorUnits = next
        }
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

    func editableMajorUnits(locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = exponent
        formatter.maximumFractionDigits = exponent
        let magnitude = minorUnits == Int64.min ? UInt64(Int64.max) + 1 : UInt64(abs(minorUnits))
        let number = NSDecimalNumber(
            mantissa: magnitude,
            exponent: Int16(-exponent),
            isNegative: minorUnits < 0
        )
        return formatter.string(from: number) ?? String(minorUnits)
    }
}
