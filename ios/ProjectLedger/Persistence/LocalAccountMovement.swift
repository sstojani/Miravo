import Foundation
import SwiftData

@Model
final class LocalAccountMovement {
    #Unique<LocalAccountMovement>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var transactionID: UUID
    var accountID: UUID
    var signedAmountMinor: Int64
    var currencyCode: String
    var currencyExponent: Int
    var conversionRate: String?

    init(
        id: UUID = UUID(),
        scopeKey: String,
        transactionID: UUID,
        accountID: UUID,
        signedAmountMinor: Int64,
        currencyCode: String,
        currencyExponent: Int,
        conversionRate: String? = nil
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.transactionID = transactionID
        self.accountID = accountID
        self.signedAmountMinor = signedAmountMinor
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
        self.conversionRate = conversionRate
    }
}
