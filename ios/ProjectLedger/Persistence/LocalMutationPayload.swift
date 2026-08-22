import Foundation

enum LocalMutationEntity: String, Codable, Sendable {
    case tracker
    case account
    case category
    case tag
    case participant
    case budget
    case recurringRule = "recurring_rule"
    case installmentPlan = "installment_plan"
    case transaction
    case settlement
}

enum LocalMutationCommand: String, Codable, Sendable {
    case create
    case update
    case archive
    case restore
    case delete
    case pause
    case resume
    case end
    case skipNext = "skip_next"
    case cancel
    case recordPayment = "record_payment"
    case payoff
    case skipPayment = "skip_payment"
    case reschedulePayment = "reschedule_payment"
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

struct ParticipantMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
    let id: UUID
    let trackerID: UUID
    let displayName: String
    let archivedAt: Date?
    let deletedAt: Date?
}

struct BudgetMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
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
    let thresholdPercentages: [Int]
    let archivedAt: Date?
    let deletedAt: Date?
}

struct RecurringRuleMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
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
    let rateEffectiveAt: Date
    let cadence: String
    let customIntervalUnit: String
    let customIntervalCount: Int
    let timeZone: String
    let startsOn: String
    let endsOn: String?
    let localTime: String
    let nextDueOn: String
    let subscriptionProvider: String
    let trialEndsOn: String?
    let cancellationURL: String
    let subscriptionNote: String
    let archivedAt: Date?
    let deletedAt: Date?
}

struct InstallmentPlanMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
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
    let archivedAt: Date?
    let deletedAt: Date?
    let paymentID: UUID?
    let transactionID: UUID?
    let scheduleItemID: UUID?
    let paymentAmountMinor: Int64?
    let occurredAt: Date?
    let extraPayment: Bool?
    let confirmOverpayment: Bool?
    let accountAmountMinor: Int64?
    let baseAmountMinor: Int64?
    let baseCurrency: String?
    let rateSnapshot: String?
    let rateSource: String?
    let rateEffectiveAt: Date?
    let rescheduledDueOn: String?

    init(
        plan: LocalInstallmentPlan,
        paymentID: UUID? = nil,
        transactionID: UUID? = nil,
        scheduleItemID: UUID? = nil,
        paymentAmountMinor: Int64? = nil,
        occurredAt: Date? = nil,
        extraPayment: Bool? = nil,
        confirmOverpayment: Bool? = nil,
        accountAmountMinor: Int64? = nil,
        baseAmountMinor: Int64? = nil,
        baseCurrency: String? = nil,
        rateSnapshot: String? = nil,
        rateSource: String? = nil,
        rateEffectiveAt: Date? = nil,
        rescheduledDueOn: String? = nil
    ) {
        id = plan.id
        trackerID = plan.trackerID
        name = plan.name
        accountID = plan.accountID
        categoryID = plan.categoryID
        principalMinor = plan.principalMinor
        interestMinor = plan.interestMinor
        feesMinor = plan.feesMinor
        plannedTotalMinor = plan.plannedTotalMinor
        currency = plan.currencyCode
        currencyExponent = plan.currencyExponent
        installmentCount = plan.installmentCount
        plannedInstallmentMinor = plan.plannedInstallmentMinor
        cadence = plan.cadenceRaw
        timeZone = plan.timeZoneIdentifier
        startsOn = BudgetDateCodec.string(from: plan.startsOn)
        anchorDay = plan.anchorDay
        archivedAt = plan.archivedAt
        deletedAt = plan.deletedAt
        self.paymentID = paymentID
        self.transactionID = transactionID
        self.scheduleItemID = scheduleItemID
        self.paymentAmountMinor = paymentAmountMinor
        self.occurredAt = occurredAt
        self.extraPayment = extraPayment
        self.confirmOverpayment = confirmOverpayment
        self.accountAmountMinor = accountAmountMinor
        self.baseAmountMinor = baseAmountMinor
        self.baseCurrency = baseCurrency
        self.rateSnapshot = rateSnapshot
        self.rateSource = rateSource
        self.rateEffectiveAt = rateEffectiveAt
        self.rescheduledDueOn = rescheduledDueOn
    }
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
    let split: TransactionSplitMutationValue?
    let deletedAt: Date?
}

struct SplitPaymentMutationPayload: Codable, Sendable {
    let id: UUID
    let participantID: UUID
    let amountMinor: Int64
}

struct SplitShareMutationPayload: Codable, Sendable {
    let id: UUID
    let participantID: UUID
    let amountMinor: Int64?
    let percentageBasisPoints: Int?
}

struct TransactionSplitMutationPayload: Codable, Sendable {
    let method: String
    let payments: [SplitPaymentMutationPayload]
    let shares: [SplitShareMutationPayload]
}

enum TransactionSplitMutationValue: Codable, Sendable {
    case none
    case value(TransactionSplitMutationPayload)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .value(try container.decode(TransactionSplitMutationPayload.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encodeNil()
        case let .value(payload):
            try container.encode(payload)
        }
    }
}

struct SettlementMutationPayload: Codable, Sendable {
    let clientPayloadVersion = 1
    let id: UUID
    let trackerID: UUID
    let fromParticipantID: UUID
    let toParticipantID: UUID
    let amountMinor: Int64
    let currency: String
    let currencyExponent: Int
    let occurredAt: Date
    let note: String
    let accountID: UUID?
    let accountAmountMinor: Int64?
    let baseAmountMinor: Int64?
    let baseCurrency: String?
    let rateSnapshot: String?
    let rateSource: String?
    let rateEffectiveAt: Date?
    let transactionID: UUID?
    let deletedAt: Date?
}

private struct LocalMutationPayloadCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

func localMutationPayloadDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .custom { codingPath in
        let rawKey = codingPath.last?.stringValue ?? ""
        let components = rawKey.split(
            separator: "_",
            omittingEmptySubsequences: true
        )

        let converted = components.enumerated().map {
            index, component -> String in

            let value = String(component)

            if index == 0 {
                return value
            }

            switch value.lowercased() {
            case "id":
                return "ID"
            case "ids":
                return "IDs"
            case "url":
                return "URL"
            default:
                return value.prefix(1).uppercased() + value.dropFirst()
            }
        }
        .joined()

        return LocalMutationPayloadCodingKey(
            stringValue: converted
        )!
    }

    return decoder
}
