import Foundation
import SwiftData

@Model
final class OutboxMutation {
    @Attribute(.unique) var operationID: UUID
    var scopeKey: String
    var localSequence: Int64
    var entityID: UUID
    var entityType: String
    var command: String
    var payloadJSON: Data
    var baseServerVersion: Int64?
    var createdAt: Date
    var updatedAt: Date
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastSafeErrorCode: String?
    var stateRaw: String

    init(
        operationID: UUID = UUID(),
        scopeKey: String,
        localSequence: Int64,
        entityID: UUID,
        entityType: String,
        command: String,
        payloadJSON: Data = Data(),
        baseServerVersion: Int64? = nil,
        createdAt: Date = .now
    ) {
        self.operationID = operationID
        self.scopeKey = scopeKey
        self.localSequence = localSequence
        self.entityID = entityID
        self.entityType = entityType
        self.command = command
        self.payloadJSON = payloadJSON
        self.baseServerVersion = baseServerVersion
        self.createdAt = createdAt
        updatedAt = createdAt
        attemptCount = 0
        stateRaw = LocalSyncState.pending.rawValue
    }

    var state: LocalSyncState {
        LocalSyncState(rawValue: stateRaw) ?? .failed
    }
}
