import Foundation
import SwiftData

enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case expense
    case income
    case transfer
    case settlement
    case refund

    var displayName: String {
        switch self {
        case .expense: String(localized: "Expense")
        case .income: String(localized: "Income")
        case .transfer: String(localized: "Transfer")
        case .settlement: String(localized: "Settlement")
        case .refund: String(localized: "Refund")
        }
    }
}

enum TransactionSource: String, Codable, CaseIterable, Sendable {
    case manual
    case shortcut
    case recurring
    case installment
    case receiptScan = "receipt_scan"
    case imported = "import"
    case server

    var displayName: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .shortcut: String(localized: "Shortcut")
        case .recurring: String(localized: "Recurring")
        case .installment: String(localized: "Installment")
        case .receiptScan: String(localized: "Receipt scan")
        case .imported: String(localized: "Imported")
        case .server: String(localized: "Server")
        }
    }
}

enum TransactionStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case posted
    case pending
    case voided
    case reconciled

    var displayName: String {
        switch self {
        case .draft: String(localized: "Draft")
        case .posted: String(localized: "Posted")
        case .pending: String(localized: "Pending")
        case .voided: String(localized: "Voided")
        case .reconciled: String(localized: "Reconciled")
        }
    }
}

enum LocalSyncState: String, Codable, CaseIterable, Sendable {
    case pending
    case syncing
    case synced
    case failed
    case conflicted

    var displayName: String {
        switch self {
        case .pending: String(localized: "Pending")
        case .syncing: String(localized: "Syncing")
        case .synced: String(localized: "Synced")
        case .failed: String(localized: "Failed")
        case .conflicted: String(localized: "Conflict")
        }
    }
}

@Model
final class LedgerTransaction {
    #Unique<LedgerTransaction>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var accountID: UUID
    var destinationAccountID: UUID?
    var categoryID: UUID?
    var kindRaw: String
    var sourceRaw: String
    var statusRaw: String
    var amountMinor: Int64
    var accountAmountMinor: Int64
    var destinationAmountMinor: Int64?
    var currencyCode: String
    var currencyExponent: Int
    var baseAmountMinor: Int64
    var baseCurrencyCode: String
    var rateSnapshot: String
    var rateSource: String
    var rateEffectiveAt: Date
    var merchant: String
    var note: String
    var occurredAt: Date
    var capturedAt: Date
    var externalEventID: UUID?
    var refundOfID: UUID?
    var syncStateRaw: String
    var serverVersion: Int64?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        scopeKey: String,
        trackerID: UUID,
        accountID: UUID,
        destinationAccountID: UUID? = nil,
        categoryID: UUID? = nil,
        kind: TransactionKind,
        money: Money,
        accountAmountMinor: Int64? = nil,
        destinationAmountMinor: Int64? = nil,
        source: TransactionSource = .manual,
        status: TransactionStatus = .posted,
        merchant: String = "",
        note: String = "",
        occurredAt: Date = .now,
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.accountID = accountID
        self.destinationAccountID = destinationAccountID
        self.categoryID = categoryID
        kindRaw = kind.rawValue
        sourceRaw = source.rawValue
        statusRaw = status.rawValue
        amountMinor = money.minorUnits
        self.accountAmountMinor = accountAmountMinor ?? money.minorUnits
        self.destinationAmountMinor = destinationAmountMinor
        currencyCode = money.currencyCode
        currencyExponent = money.exponent
        baseAmountMinor = money.minorUnits
        baseCurrencyCode = money.currencyCode
        rateSnapshot = "1"
        rateSource = "identity"
        rateEffectiveAt = occurredAt
        self.merchant = merchant
        self.note = note
        self.occurredAt = occurredAt
        capturedAt = createdAt
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

    var source: TransactionSource {
        TransactionSource(rawValue: sourceRaw) ?? .manual
    }

    var status: TransactionStatus {
        TransactionStatus(rawValue: statusRaw) ?? .posted
    }

    var money: Money? {
        try? Money(
            minorUnits: amountMinor,
            currencyCode: currencyCode,
            exponent: currencyExponent
        )
    }
}
