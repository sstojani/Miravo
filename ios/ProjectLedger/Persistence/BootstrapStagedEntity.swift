import Foundation
import SwiftData

@Model
final class BootstrapStagedEntity {
    @Attribute(.unique) var stageKey: String
    var scopeKey: String
    var generationID: UUID
    var entityType: String
    var entityID: UUID
    var payloadJSON: Data
    var serverVersion: Int64

    init(
        scopeKey: String,
        generationID: UUID,
        entityType: String,
        entityID: UUID,
        payloadJSON: Data,
        serverVersion: Int64
    ) {
        stageKey = "\(scopeKey)|\(generationID.uuidString)|\(entityType)|\(entityID.uuidString)"
        self.scopeKey = scopeKey
        self.generationID = generationID
        self.entityType = entityType
        self.entityID = entityID
        self.payloadJSON = payloadJSON
        self.serverVersion = serverVersion
    }
}
