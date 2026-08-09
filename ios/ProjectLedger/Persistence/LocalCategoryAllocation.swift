import Foundation
import SwiftData

@Model
final class LocalCategoryAllocation {
    #Unique<LocalCategoryAllocation>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var transactionID: UUID
    var categoryID: UUID
    var amountMinor: Int64
    var categoryVersion: Int64

    init(
        id: UUID = UUID(),
        scopeKey: String,
        transactionID: UUID,
        categoryID: UUID,
        amountMinor: Int64,
        categoryVersion: Int64 = 1
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.transactionID = transactionID
        self.categoryID = categoryID
        self.amountMinor = amountMinor
        self.categoryVersion = categoryVersion
    }
}
