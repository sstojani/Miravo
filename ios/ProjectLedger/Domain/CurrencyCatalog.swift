import Foundation

struct CurrencyDefinition: Identifiable, Equatable, Sendable {
    let code: String
    let exponent: Int

    var id: String { code }
}

enum CurrencyCatalog {
    static let priority: [CurrencyDefinition] = [
        CurrencyDefinition(code: "ALL", exponent: 2),
        CurrencyDefinition(code: "EUR", exponent: 2),
        CurrencyDefinition(code: "USD", exponent: 2),
    ]

    static func exponent(for code: String) -> Int? {
        priority.first { $0.code == code.uppercased() }?.exponent
    }
}
