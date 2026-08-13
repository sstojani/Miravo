import Foundation
import SwiftData

enum LocalSplitMethod: String, Codable, CaseIterable, Sendable {
    case equal
    case exact
    case percentage
}

@Model
final class LocalParticipant {
    #Unique<LocalParticipant>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var linkedUserID: UUID?
    var linkedEmail: String?
    var displayName: String
    var archivedAt: Date?
    var serverVersion: Int64?
    var syncStateRaw: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        scopeKey: String,
        trackerID: UUID,
        linkedUserID: UUID? = nil,
        linkedEmail: String? = nil,
        displayName: String,
        serverVersion: Int64? = nil,
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.linkedUserID = linkedUserID
        self.linkedEmail = linkedEmail
        self.displayName = displayName
        self.serverVersion = serverVersion
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var isRegistered: Bool {
        linkedUserID != nil
    }

    var syncState: LocalSyncState {
        LocalSyncState(rawValue: syncStateRaw) ?? .failed
    }
}

@Model
final class LocalSplitPayment {
    #Unique<LocalSplitPayment>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var transactionID: UUID
    var participantID: UUID
    var amountMinor: Int64
    var serverVersion: Int64?

    init(
        id: UUID = UUID(),
        scopeKey: String,
        transactionID: UUID,
        participantID: UUID,
        amountMinor: Int64,
        serverVersion: Int64? = nil
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.transactionID = transactionID
        self.participantID = participantID
        self.amountMinor = amountMinor
        self.serverVersion = serverVersion
    }
}

@Model
final class LocalSplitShare {
    #Unique<LocalSplitShare>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var transactionID: UUID
    var participantID: UUID
    var amountMinor: Int64
    var methodRaw: String
    var percentageBasisPoints: Int?
    var serverVersion: Int64?

    init(
        id: UUID = UUID(),
        scopeKey: String,
        transactionID: UUID,
        participantID: UUID,
        amountMinor: Int64,
        method: LocalSplitMethod,
        percentageBasisPoints: Int? = nil,
        serverVersion: Int64? = nil
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.transactionID = transactionID
        self.participantID = participantID
        self.amountMinor = amountMinor
        methodRaw = method.rawValue
        self.percentageBasisPoints = percentageBasisPoints
        self.serverVersion = serverVersion
    }

    var method: LocalSplitMethod {
        LocalSplitMethod(rawValue: methodRaw) ?? .exact
    }
}

@Model
final class LocalSettlement {
    #Unique<LocalSettlement>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var fromParticipantID: UUID
    var toParticipantID: UUID
    var amountMinor: Int64
    var currencyCode: String
    var currencyExponent: Int
    var occurredAt: Date
    var note: String
    var transactionID: UUID?
    var serverVersion: Int64?
    var syncStateRaw: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        scopeKey: String,
        trackerID: UUID,
        fromParticipantID: UUID,
        toParticipantID: UUID,
        money: Money,
        occurredAt: Date,
        note: String = "",
        transactionID: UUID? = nil,
        serverVersion: Int64? = nil,
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.fromParticipantID = fromParticipantID
        self.toParticipantID = toParticipantID
        amountMinor = money.minorUnits
        currencyCode = money.currencyCode
        currencyExponent = money.exponent
        self.occurredAt = occurredAt
        self.note = note
        self.transactionID = transactionID
        self.serverVersion = serverVersion
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var money: Money? {
        try? Money(
            minorUnits: amountMinor,
            currencyCode: currencyCode,
            exponent: currencyExponent
        )
    }

    var syncState: LocalSyncState {
        LocalSyncState(rawValue: syncStateRaw) ?? .failed
    }
}
