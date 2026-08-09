import Foundation
import SwiftData

@Model
final class SyncCursor {
    @Attribute(.unique) var scopeKey: String
    var cursor: String?
    var lastSuccessfulSyncAt: Date?
    var bootstrapRequired: Bool
    var lastSafeErrorCode: String?
    var nextOutboxSequence: Int64

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        bootstrapRequired = true
        nextOutboxSequence = 1
    }
}
