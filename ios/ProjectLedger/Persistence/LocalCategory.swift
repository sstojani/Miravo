import Foundation
import SwiftData

enum LocalCategoryKind: String, Codable, CaseIterable, Sendable {
    case expense
    case income
}

@Model
final class LocalCategory {
    @Attribute(.unique) var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var parentID: UUID?
    var kindRaw: String
    var name: String
    var icon: String
    var colorHex: String
    var sortOrder: Int
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
        parentID: UUID? = nil,
        kind: LocalCategoryKind,
        name: String,
        icon: String = "square.grid.2x2",
        colorHex: String = "#73819B",
        sortOrder: Int = 0,
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.parentID = parentID
        kindRaw = kind.rawValue
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var kind: LocalCategoryKind {
        LocalCategoryKind(rawValue: kindRaw) ?? .expense
    }

    var syncState: LocalSyncState {
        LocalSyncState(rawValue: syncStateRaw) ?? .failed
    }
}
