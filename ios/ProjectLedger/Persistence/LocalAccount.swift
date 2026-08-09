import Foundation
import SwiftData

enum LocalAccountType: String, Codable, CaseIterable, Sendable {
    case cash
    case checking
    case savings
    case credit
    case digitalWallet = "digital_wallet"
    case custom
}

@Model
final class LocalAccount {
    @Attribute(.unique) var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var name: String
    var typeRaw: String
    var currencyCode: String
    var currencyExponent: Int
    var openingBalanceMinor: Int64
    var openingDate: Date
    var colorHex: String
    var icon: String
    var includeInNetWorth: Bool
    var creditLimitMinor: Int64?
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
        type: LocalAccountType,
        currencyCode: String,
        currencyExponent: Int,
        openingBalanceMinor: Int64 = 0,
        openingDate: Date = .now,
        colorHex: String = "#3663F5",
        icon: String = "banknote",
        includeInNetWorth: Bool = true,
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.name = name
        typeRaw = type.rawValue
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
        self.openingBalanceMinor = openingBalanceMinor
        self.openingDate = openingDate
        self.colorHex = colorHex
        self.icon = icon
        self.includeInNetWorth = includeInNetWorth
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var type: LocalAccountType {
        LocalAccountType(rawValue: typeRaw) ?? .custom
    }

    var syncState: LocalSyncState {
        LocalSyncState(rawValue: syncStateRaw) ?? .failed
    }
}
