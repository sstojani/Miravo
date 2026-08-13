import Foundation

indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Decimal)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }
}

struct SyncPushRequest: Encodable, Sendable {
    let protocolVersion: Int
    let operations: [SyncPushOperation]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operations
    }
}

struct SyncPushOperation: Encodable, Sendable {
    let operationID: UUID
    let localSequence: Int64
    let entityType: String
    let entityID: UUID
    let command: String
    let baseServerVersion: Int64?
    let payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case localSequence = "local_sequence"
        case entityType = "entity_type"
        case entityID = "entity_id"
        case command
        case baseServerVersion = "base_server_version"
        case payload
    }
}

enum SyncOperationResultStatus: String, Decodable, Sendable {
    case accepted
    case duplicate
    case rejected
    case unauthorized
    case conflict
}

struct SyncWireError: Decodable, Sendable {
    let code: String
    let message: String
    let details: JSONValue?
}

struct SyncOperationResult: Decodable, Sendable {
    let operationID: UUID
    let status: SyncOperationResultStatus
    let originalStatus: String?
    let replayed: Bool?
    let entityType: String
    let entityID: UUID
    let serverVersion: Int64?
    let representation: JSONValue?
    let error: SyncWireError?

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case status
        case originalStatus = "original_status"
        case replayed
        case entityType = "entity_type"
        case entityID = "entity_id"
        case serverVersion = "server_version"
        case representation
        case error
    }
}

struct SyncPushResponse: Decodable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let results: [SyncOperationResult]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case results
    }
}

struct SyncChangeResponse: Decodable, Sendable {
    let sequence: Int64
    let entityType: String
    let entityID: UUID
    let trackerID: UUID?
    let operation: String
    let version: Int64
    let changedAt: String
    let data: JSONValue

    enum CodingKeys: String, CodingKey {
        case sequence
        case entityType = "entity_type"
        case entityID = "entity_id"
        case trackerID = "tracker_id"
        case operation
        case version
        case changedAt = "changed_at"
        case data
    }
}

struct SyncPullResponse: Decodable, Sendable {
    let protocolVersion: Int
    let cursor: String
    let hasMore: Bool
    let changes: [SyncChangeResponse]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case cursor
        case hasMore = "has_more"
        case changes
    }
}

struct SyncBootstrapResponse: Decodable, Sendable {
    let protocolVersion: Int
    let generatedAt: String
    let cursor: String
    let bootstrapCursor: String?
    let hasMore: Bool
    let data: JSONValue

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case generatedAt = "generated_at"
        case cursor
        case bootstrapCursor = "bootstrap_cursor"
        case hasMore = "has_more"
        case data
    }
}

struct SyncAckResponse: Decodable, Sendable {
    let protocolVersion: Int
    let cursor: String
    let acknowledgedAt: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case cursor
        case acknowledgedAt = "acknowledged_at"
    }
}

struct TrackerSnapshot: Decodable, Sendable {
    let id: UUID
    let role: String?
    let name: String
    let description: String
    let icon: String
    let color: String
    let baseCurrency: String
    let baseCurrencyExponent: Int
    let sortOrder: Int
    let defaultAccountID: UUID?
    let defaultCategoryID: UUID?
    let archivedAt: String?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, role, name, description, icon, color
        case baseCurrency = "base_currency"
        case baseCurrencyExponent = "base_currency_exponent"
        case sortOrder = "sort_order"
        case defaultAccountID = "default_account_id"
        case defaultCategoryID = "default_category_id"
        case archivedAt = "archived_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct AccountSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let name: String
    let type: String
    let currency: String
    let currencyExponent: Int
    let openingBalanceMinor: Int64
    let openingDate: String
    let color: String
    let icon: String
    let includeInNetWorth: Bool
    let creditLimitMinor: Int64?
    let archivedAt: String?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case name, type, currency
        case currencyExponent = "currency_exponent"
        case openingBalanceMinor = "opening_balance_minor"
        case openingDate = "opening_date"
        case color, icon
        case includeInNetWorth = "include_in_net_worth"
        case creditLimitMinor = "credit_limit_minor"
        case archivedAt = "archived_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct CategorySnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID?
    let parentID: UUID?
    let kind: String
    let name: String
    let icon: String
    let color: String
    let sortOrder: Int
    let archivedAt: String?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case parentID = "parent_id"
        case kind, name, icon, color
        case sortOrder = "sort_order"
        case archivedAt = "archived_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct TagSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let name: String
    let color: String
    let archivedAt: String?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case name, color
        case archivedAt = "archived_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct BudgetCategorySnapshot: Decodable, Sendable {
    let categoryID: UUID
    let name: String
    let version: Int64

    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case name, version
    }
}

struct BudgetSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let name: String
    let scope: String
    let period: String
    let amountMinor: Int64
    let currency: String
    let currencyExponent: Int
    let timeZone: String
    let startsOn: String
    let endsOn: String?
    let rollover: Bool
    let categoryIDs: [UUID]
    let categorySnapshots: [BudgetCategorySnapshot]
    let thresholdPercentages: [Int]
    let archivedAt: String?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case name, scope, period
        case amountMinor = "amount_minor"
        case currency
        case currencyExponent = "currency_exponent"
        case timeZone = "time_zone"
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case rollover
        case categoryIDs = "category_ids"
        case categorySnapshots = "category_snapshots"
        case thresholdPercentages = "threshold_percentages"
        case archivedAt = "archived_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct RecurringRuleSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let name: String
    let kind: String
    let isSubscription: Bool
    let amountMinor: Int64
    let currency: String
    let currencyExponent: Int
    let accountID: UUID
    let accountAmountMinor: Int64
    let categoryID: UUID?
    let merchant: String
    let note: String
    let baseAmountMinor: Int64
    let baseCurrency: String
    let rateSnapshot: String
    let rateSource: String
    let rateEffectiveAt: String
    let cadence: String
    let customIntervalUnit: String
    let customIntervalCount: Int
    let timeZone: String
    let startsOn: String
    let endsOn: String?
    let localTime: String
    let nextDueOn: String
    let nextDueAt: String
    let state: String
    let pausedAt: String?
    let endedAt: String?
    let subscriptionProvider: String
    let trialEndsOn: String?
    let cancellationURL: String
    let subscriptionNote: String
    let archivedAt: String?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case name, kind
        case isSubscription = "is_subscription"
        case amountMinor = "amount_minor"
        case currency
        case currencyExponent = "currency_exponent"
        case accountID = "account_id"
        case accountAmountMinor = "account_amount_minor"
        case categoryID = "category_id"
        case merchant, note
        case baseAmountMinor = "base_amount_minor"
        case baseCurrency = "base_currency"
        case rateSnapshot = "rate_snapshot"
        case rateSource = "rate_source"
        case rateEffectiveAt = "rate_effective_at"
        case cadence
        case customIntervalUnit = "custom_interval_unit"
        case customIntervalCount = "custom_interval_count"
        case timeZone = "time_zone"
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case localTime = "local_time"
        case nextDueOn = "next_due_on"
        case nextDueAt = "next_due_at"
        case state
        case pausedAt = "paused_at"
        case endedAt = "ended_at"
        case subscriptionProvider = "subscription_provider"
        case trialEndsOn = "trial_ends_on"
        case cancellationURL = "cancellation_url"
        case subscriptionNote = "subscription_note"
        case archivedAt = "archived_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct RecurringOccurrenceSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let ruleID: UUID
    let occurrenceKey: String
    let dueOn: String
    let scheduledFor: String
    let ruleVersion: Int64
    let state: String
    let transactionID: UUID?
    let materializedAt: String?
    let skippedAt: String?
    let errorCode: String
    let version: Int64
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case ruleID = "rule_id"
        case occurrenceKey = "occurrence_key"
        case dueOn = "due_on"
        case scheduledFor = "scheduled_for"
        case ruleVersion = "rule_version"
        case state
        case transactionID = "transaction_id"
        case materializedAt = "materialized_at"
        case skippedAt = "skipped_at"
        case errorCode = "error_code"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct InstallmentProgressSnapshot: Decodable, Sendable {
    let plannedTotalMinor: Int64
    let paidMinor: Int64
    let remainingMinor: Int64
    let nextDueOn: String?
    let estimatedPayoffOn: String?

    enum CodingKeys: String, CodingKey {
        case plannedTotalMinor = "planned_total_minor"
        case paidMinor = "paid_minor"
        case remainingMinor = "remaining_minor"
        case nextDueOn = "next_due_on"
        case estimatedPayoffOn = "estimated_payoff_on"
    }
}

struct InstallmentPlanSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let name: String
    let accountID: UUID
    let categoryID: UUID?
    let principalMinor: Int64
    let interestMinor: Int64
    let feesMinor: Int64
    let plannedTotalMinor: Int64
    let currency: String
    let currencyExponent: Int
    let installmentCount: Int
    let plannedInstallmentMinor: Int64?
    let cadence: String
    let timeZone: String
    let startsOn: String
    let anchorDay: Int
    let state: String
    let revisionNumber: Int
    let paidOffAt: String?
    let cancelledAt: String?
    let archivedAt: String?
    let progress: InstallmentProgressSnapshot
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case name
        case accountID = "account_id"
        case categoryID = "category_id"
        case principalMinor = "principal_minor"
        case interestMinor = "interest_minor"
        case feesMinor = "fees_minor"
        case plannedTotalMinor = "planned_total_minor"
        case currency
        case currencyExponent = "currency_exponent"
        case installmentCount = "installment_count"
        case plannedInstallmentMinor = "planned_installment_minor"
        case cadence
        case timeZone = "time_zone"
        case startsOn = "starts_on"
        case anchorDay = "anchor_day"
        case state
        case revisionNumber = "revision_number"
        case paidOffAt = "paid_off_at"
        case cancelledAt = "cancelled_at"
        case archivedAt = "archived_at"
        case progress, version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct InstallmentScheduleItemSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let planID: UUID
    let revisionNumber: Int
    let sequence: Int
    let originalDueOn: String
    let dueOn: String
    let plannedPrincipalMinor: Int64
    let plannedInterestMinor: Int64
    let plannedFeesMinor: Int64
    let plannedTotalMinor: Int64
    let paidMinor: Int64
    let state: String
    let skippedAt: String?
    let supersededAt: String?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case planID = "plan_id"
        case revisionNumber = "revision_number"
        case sequence
        case originalDueOn = "original_due_on"
        case dueOn = "due_on"
        case plannedPrincipalMinor = "planned_principal_minor"
        case plannedInterestMinor = "planned_interest_minor"
        case plannedFeesMinor = "planned_fees_minor"
        case plannedTotalMinor = "planned_total_minor"
        case paidMinor = "paid_minor"
        case state
        case skippedAt = "skipped_at"
        case supersededAt = "superseded_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct InstallmentPaymentSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let planID: UUID
    let scheduleItemID: UUID?
    let transactionID: UUID
    let amountMinor: Int64
    let appliedAmountMinor: Int64
    let overpaymentMinor: Int64
    let extraPayment: Bool
    let appliedAt: String
    let createdByID: UUID
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case planID = "plan_id"
        case scheduleItemID = "schedule_item_id"
        case transactionID = "transaction_id"
        case amountMinor = "amount_minor"
        case appliedAmountMinor = "applied_amount_minor"
        case overpaymentMinor = "overpayment_minor"
        case extraPayment = "extra_payment"
        case appliedAt = "applied_at"
        case createdByID = "created_by_id"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct MembershipSnapshot: Decodable, Sendable {
    let id: UUID
    let userID: UUID
    let trackerID: UUID
    let email: String
    let role: String
    let state: String
    let joinedAt: String
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case trackerID = "tracker_id"
        case email, role, state
        case joinedAt = "joined_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct ParticipantSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let linkedUserID: UUID?
    let linkedEmail: String?
    let displayName: String
    let archivedAt: String?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case linkedUserID = "linked_user_id"
        case linkedEmail = "linked_email"
        case displayName = "display_name"
        case archivedAt = "archived_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct MovementSnapshot: Decodable, Sendable {
    let id: UUID
    let accountID: UUID
    let signedAmountMinor: Int64
    let currency: String
    let currencyExponent: Int
    let conversionRate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case signedAmountMinor = "signed_amount_minor"
        case currency
        case currencyExponent = "currency_exponent"
        case conversionRate = "conversion_rate"
    }
}

struct AllocationSnapshot: Decodable, Sendable {
    let id: UUID
    let categoryID: UUID
    let categoryVersion: Int64
    let amountMinor: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case categoryID = "category_id"
        case categoryVersion = "category_version"
        case amountMinor = "amount_minor"
    }
}

struct SplitPaymentSnapshot: Decodable, Sendable {
    let id: UUID
    let participantID: UUID
    let amountMinor: Int64
    let version: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case participantID = "participant_id"
        case amountMinor = "amount_minor"
        case version
    }
}

struct SplitShareSnapshot: Decodable, Sendable {
    let id: UUID
    let participantID: UUID
    let amountMinor: Int64
    let method: String
    let percentageBasisPoints: Int?
    let version: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case participantID = "participant_id"
        case amountMinor = "amount_minor"
        case method
        case percentageBasisPoints = "percentage_basis_points"
        case version
    }
}

struct TransactionSplitSnapshot: Decodable, Sendable {
    let method: String
    let payments: [SplitPaymentSnapshot]
    let shares: [SplitShareSnapshot]
    let totalPaidMinor: Int64
    let totalOwedMinor: Int64

    enum CodingKeys: String, CodingKey {
        case method, payments, shares
        case totalPaidMinor = "total_paid_minor"
        case totalOwedMinor = "total_owed_minor"
    }
}

struct TransactionSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let kind: String
    let source: String
    let status: String
    let amountMinor: Int64
    let currency: String
    let currencyExponent: Int
    let baseAmountMinor: Int64
    let baseCurrency: String
    let rateSnapshot: String
    let rateSource: String
    let rateEffectiveAt: String
    let merchant: String?
    let payee: String
    let note: String
    let occurredAt: String
    let capturedAt: String
    let externalEventID: UUID?
    let refundOfID: UUID?
    let movements: [MovementSnapshot]
    let allocations: [AllocationSnapshot]
    let tagIDs: [UUID]
    let split: TransactionSplitSnapshot?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case kind, source, status
        case amountMinor = "amount_minor"
        case currency
        case currencyExponent = "currency_exponent"
        case baseAmountMinor = "base_amount_minor"
        case baseCurrency = "base_currency"
        case rateSnapshot = "rate_snapshot"
        case rateSource = "rate_source"
        case rateEffectiveAt = "rate_effective_at"
        case merchant, payee, note
        case occurredAt = "occurred_at"
        case capturedAt = "captured_at"
        case externalEventID = "external_event_id"
        case refundOfID = "refund_of_id"
        case movements, allocations
        case tagIDs = "tag_ids"
        case split
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct SettlementSnapshot: Decodable, Sendable {
    let id: UUID
    let trackerID: UUID
    let fromParticipantID: UUID
    let toParticipantID: UUID
    let amountMinor: Int64
    let currency: String
    let currencyExponent: Int
    let occurredAt: String
    let note: String
    let transactionID: UUID?
    let createdByID: UUID
    let lastEditorID: UUID
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case fromParticipantID = "from_participant_id"
        case toParticipantID = "to_participant_id"
        case amountMinor = "amount_minor"
        case currency
        case currencyExponent = "currency_exponent"
        case occurredAt = "occurred_at"
        case note
        case transactionID = "transaction_id"
        case createdByID = "created_by_id"
        case lastEditorID = "last_editor_id"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

enum SyncSnapshotDecoder {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from value: JSONValue
    ) throws -> Value {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: encoder.encode(value))
    }
}
