import Foundation
import SwiftData

enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case expense
    case income
    case transfer
    case settlement
    case adjustment
}

enum LocalSyncState: String, Codable, Sendable {
    case pending
    case syncing
    case synced
    case failed
    case conflicted
}

@Model
final class LedgerTransaction {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var amountMinor: Int64
    var currencyCode: String
    var currencyExponent: Int
    var merchant: String
    var note: String
    var occurredAt: Date
    var syncStateRaw: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        kind: TransactionKind,
        money: Money,
        merchant: String = "",
        note: String = "",
        occurredAt: Date = .now,
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        kindRaw = kind.rawValue
        amountMinor = money.minorUnits
        currencyCode = money.currencyCode
        currencyExponent = money.exponent
        self.merchant = merchant
        self.note = note
        self.occurredAt = occurredAt
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var kind: TransactionKind {
        TransactionKind(rawValue: kindRaw) ?? .expense
    }

    var syncState: LocalSyncState {
        LocalSyncState(rawValue: syncStateRaw) ?? .failed
    }

    var money: Money? {
        try? Money(
            minorUnits: amountMinor,
            currencyCode: currencyCode,
            exponent: currencyExponent
        )
    }
}

