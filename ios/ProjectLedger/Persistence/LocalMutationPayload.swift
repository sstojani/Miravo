import Foundation

enum LocalMutationEntity: String, Codable, Sendable {
    case tracker
    case account
    case category
    case tag
    case transaction
}

enum LocalMutationCommand: String, Codable, Sendable {
    case create
    case update
    case archive
    case restore
    case delete
}

struct TrackerMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
    let id: UUID
    let name: String
    let description: String
    let icon: String
    let color: String
    let baseCurrency: String
    let baseCurrencyExponent: Int
    let sortOrder: Int
    let defaultAccountID: UUID?
    let defaultCategoryID: UUID?
    let archivedAt: Date?
    let deletedAt: Date?
}

struct AccountMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
    let id: UUID
    let trackerID: UUID
    let name: String
    let type: String
    let currency: String
    let currencyExponent: Int
    let openingBalanceMinor: Int64
    let openingDate: Date
    let color: String
    let icon: String
    let includeInNetWorth: Bool
    let creditLimitMinor: Int64?
    let archivedAt: Date?
    let deletedAt: Date?
}

struct CategoryMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
    let id: UUID
    let trackerID: UUID
    let parentID: UUID?
    let kind: String
    let name: String
    let icon: String
    let color: String
    let sortOrder: Int
    let archivedAt: Date?
    let deletedAt: Date?
}

struct TagMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
    let id: UUID
    let trackerID: UUID
    let name: String
    let color: String
    let archivedAt: Date?
    let deletedAt: Date?
}

struct TransactionMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
    let id: UUID
    let trackerID: UUID
    let accountID: UUID
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let kind: String
    let source: String
    let status: String
    let amountMinor: Int64
    let accountAmountMinor: Int64
    let destinationAmountMinor: Int64?
    let currency: String
    let currencyExponent: Int
    let baseAmountMinor: Int64
    let baseCurrency: String
    let rateSnapshot: String
    let rateSource: String
    let rateEffectiveAt: Date
    let merchant: String
    let note: String
    let occurredAt: Date
    let refundOfID: UUID?
    let tagIDs: [UUID]
    let deletedAt: Date?
}
