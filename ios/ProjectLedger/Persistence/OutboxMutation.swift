import Foundation
import SwiftData

@Model
final class OutboxMutation {
    @Attribute(.unique) var operationID: UUID
    var entityID: UUID
    var entityType: String
    var command: String
    var baseServerVersion: Int64?
    var createdAt: Date
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastSafeErrorCode: String?

    init(
        operationID: UUID = UUID(),
        entityID: UUID,
        entityType: String,
        command: String,
        baseServerVersion: Int64? = nil,
        createdAt: Date = .now
    ) {
        self.operationID = operationID
        self.entityID = entityID
        self.entityType = entityType
        self.command = command
        self.baseServerVersion = baseServerVersion
        self.createdAt = createdAt
        attemptCount = 0
    }
}

