import Foundation
import SwiftData

enum TrackerRole: String, Codable, CaseIterable, Sendable {
    case owner
    case admin
    case editor
    case viewer

    var canEditFinancialData: Bool {
        self != .viewer
    }

    var canManageTracker: Bool {
        self == .owner || self == .admin
    }

    var canTransferOwnership: Bool {
        self == .owner
    }
}

@Model
final class LocalTracker {
    #Unique<LocalTracker>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var name: String
    var trackerDescription: String
    var icon: String
    var colorHex: String
    var baseCurrencyCode: String
    var baseCurrencyExponent: Int
    var sortOrder: Int
    var defaultAccountID: UUID?
    var defaultCategoryID: UUID?
    var roleRaw: String
    var serverVersion: Int64?
    var syncStateRaw: String
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var deletedAt: Date?
    var accessRevokedAt: Date?

    init(
        id: UUID = UUID(),
        scopeKey: String,
        name: String,
        description: String = "",
        icon: String = "wallet.pass",
        colorHex: String = "#3663F5",
        baseCurrencyCode: String = "ALL",
        baseCurrencyExponent: Int = 2,
        sortOrder: Int = 0,
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.name = name
        trackerDescription = description
        self.icon = icon
        self.colorHex = colorHex
        self.baseCurrencyCode = baseCurrencyCode
        self.baseCurrencyExponent = baseCurrencyExponent
        self.sortOrder = sortOrder
        roleRaw = "owner"
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var syncState: LocalSyncState {
        LocalSyncState(rawValue: syncStateRaw) ?? .failed
    }

    var role: TrackerRole {
        TrackerRole(rawValue: roleRaw) ?? .viewer
    }
}
