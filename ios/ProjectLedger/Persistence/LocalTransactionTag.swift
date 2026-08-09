import Foundation
import SwiftData

@Model
final class LocalTransactionTag {
    #Unique<LocalTransactionTag>([\.scopeKey, \.transactionID, \.tagID])

    var id: UUID
    var scopeKey: String
    var transactionID: UUID
    var tagID: UUID

    init(
        id: UUID = UUID(),
        scopeKey: String,
        transactionID: UUID,
        tagID: UUID
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.transactionID = transactionID
        self.tagID = tagID
    }
}
