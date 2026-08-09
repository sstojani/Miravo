import Foundation
import SwiftData

@Model
final class SyncCursor {
    @Attribute(.unique) var scopeKey: String
    var cursor: String?
    var bootstrapCursor: String?
    var bootstrapTargetCursor: String?
    var bootstrapGenerationID: UUID?
    var lastSuccessfulSyncAt: Date?
    var lastAttemptAt: Date?
    var bootstrapRequired: Bool
    var lastSafeErrorCode: String?
    var consecutiveFailureCount: Int
    var isSyncing: Bool
    var nextOutboxSequence: Int64

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        bootstrapRequired = true
        consecutiveFailureCount = 0
        isSyncing = false
        nextOutboxSequence = 1
    }
}
