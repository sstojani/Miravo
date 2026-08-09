import Foundation
import SwiftData

@Model
final class LocalTag {
    #Unique<LocalTag>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var name: String
    var colorHex: String
    var serverVersion: Int64?
    var syncStateRaw: String
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        scopeKey: String,
        trackerID: UUID,
        name: String,
        colorHex: String = "#73819B",
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.name = name
        self.colorHex = colorHex
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var syncState: LocalSyncState {
        LocalSyncState(rawValue: syncStateRaw) ?? .failed
    }
}
