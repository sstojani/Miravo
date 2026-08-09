import Foundation
import SwiftData

@Model
final class SyncConflict {
    @Attribute(.unique) var operationID: UUID
    var scopeKey: String
    var entityType: String
    var entityID: UUID
    var baseServerVersion: Int64?
    var currentJSON: Data
    var proposedJSON: Data
    var safeErrorCode: String
    var createdAt: Date
    var resolvedAt: Date?

    init(
        operationID: UUID,
        scopeKey: String,
        entityType: String,
        entityID: UUID,
        baseServerVersion: Int64?,
        currentJSON: Data,
        proposedJSON: Data,
        safeErrorCode: String,
        createdAt: Date = .now
    ) {
        self.operationID = operationID
        self.scopeKey = scopeKey
        self.entityType = entityType
        self.entityID = entityID
        self.baseServerVersion = baseServerVersion
        self.currentJSON = currentJSON
        self.proposedJSON = proposedJSON
        self.safeErrorCode = safeErrorCode
        self.createdAt = createdAt
    }
}
