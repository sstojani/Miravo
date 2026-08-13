import Foundation
import SwiftData

enum InstallmentCadence: String, Codable, CaseIterable, Sendable {
    case weekly
    case monthly

    var displayName: String {
        switch self {
        case .weekly: String(localized: "Weekly")
        case .monthly: String(localized: "Monthly")
        }
    }
}

enum InstallmentPlanState: String, Codable, CaseIterable, Sendable {
    case active
    case paidOff = "paid_off"
    case cancelled

    var displayName: String {
        switch self {
        case .active: String(localized: "Active")
        case .paidOff: String(localized: "Paid off")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}

enum InstallmentScheduleState: String, Codable, CaseIterable, Sendable {
    case planned
    case partiallyPaid = "partially_paid"
    case paid
    case skipped

    var displayName: String {
        switch self {
        case .planned: String(localized: "Planned")
        case .partiallyPaid: String(localized: "Partially paid")
        case .paid: String(localized: "Paid")
        case .skipped: String(localized: "Skipped")
        }
    }
}

@Model
final class LocalInstallmentPlan {
    #Unique<LocalInstallmentPlan>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var name: String
    var accountID: UUID
    var categoryID: UUID?
    var principalMinor: Int64
    var interestMinor: Int64
    var feesMinor: Int64
    var plannedTotalMinor: Int64
    var currencyCode: String
    var currencyExponent: Int
    var installmentCount: Int
    var plannedInstallmentMinor: Int64?
    var cadenceRaw: String
    var timeZoneIdentifier: String
    var startsOn: Date
    var anchorDay: Int
    var stateRaw: String
    var revisionNumber: Int
    var paidOffAt: Date?
    var cancelledAt: Date?
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
        accountID: UUID,
        categoryID: UUID?,
        principalMinor: Int64,
        interestMinor: Int64,
        feesMinor: Int64,
        plannedTotalMinor: Int64,
        currencyCode: String,
        currencyExponent: Int,
        installmentCount: Int,
        plannedInstallmentMinor: Int64?,
        cadence: InstallmentCadence,
        timeZoneIdentifier: String,
        startsOn: Date,
        anchorDay: Int,
        state: InstallmentPlanState = .active,
        revisionNumber: Int = 1,
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.name = name
        self.accountID = accountID
        self.categoryID = categoryID
        self.principalMinor = principalMinor
        self.interestMinor = interestMinor
        self.feesMinor = feesMinor
        self.plannedTotalMinor = plannedTotalMinor
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
        self.installmentCount = installmentCount
        self.plannedInstallmentMinor = plannedInstallmentMinor
        cadenceRaw = cadence.rawValue
        self.timeZoneIdentifier = timeZoneIdentifier
        self.startsOn = startsOn
        self.anchorDay = anchorDay
        stateRaw = state.rawValue
        self.revisionNumber = revisionNumber
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var cadence: InstallmentCadence {
        InstallmentCadence(rawValue: cadenceRaw) ?? .monthly
    }

    var state: InstallmentPlanState {
        InstallmentPlanState(rawValue: stateRaw) ?? .cancelled
    }

    var syncState: LocalSyncState {
        LocalSyncState(rawValue: syncStateRaw) ?? .failed
    }

    var money: Money? {
        try? Money(
            minorUnits: plannedTotalMinor,
            currencyCode: currencyCode,
            exponent: currencyExponent
        )
    }
}

@Model
final class LocalInstallmentScheduleItem {
    #Unique<LocalInstallmentScheduleItem>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var planID: UUID
    var revisionNumber: Int
    var sequence: Int
    var originalDueOn: Date
    var dueOn: Date
    var plannedPrincipalMinor: Int64
    var plannedInterestMinor: Int64
    var plannedFeesMinor: Int64
    var plannedTotalMinor: Int64
    var paidMinor: Int64
    var stateRaw: String
    var skippedAt: Date?
    var supersededAt: Date?
    var serverVersion: Int64
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        scopeKey: String,
        trackerID: UUID,
        planID: UUID,
        revisionNumber: Int,
        sequence: Int,
        originalDueOn: Date,
        dueOn: Date,
        plannedPrincipalMinor: Int64,
        plannedInterestMinor: Int64,
        plannedFeesMinor: Int64,
        plannedTotalMinor: Int64,
        paidMinor: Int64 = 0,
        state: InstallmentScheduleState = .planned,
        serverVersion: Int64 = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.planID = planID
        self.revisionNumber = revisionNumber
        self.sequence = sequence
        self.originalDueOn = originalDueOn
        self.dueOn = dueOn
        self.plannedPrincipalMinor = plannedPrincipalMinor
        self.plannedInterestMinor = plannedInterestMinor
        self.plannedFeesMinor = plannedFeesMinor
        self.plannedTotalMinor = plannedTotalMinor
        self.paidMinor = paidMinor
        stateRaw = state.rawValue
        self.serverVersion = serverVersion
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var state: InstallmentScheduleState {
        InstallmentScheduleState(rawValue: stateRaw) ?? .planned
    }
}

@Model
final class LocalInstallmentPayment {
    #Unique<LocalInstallmentPayment>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var planID: UUID
    var scheduleItemID: UUID?
    var transactionID: UUID
    var amountMinor: Int64
    var appliedAmountMinor: Int64
    var overpaymentMinor: Int64
    var extraPayment: Bool
    var appliedAt: Date
    var createdByID: UUID
    var serverVersion: Int64
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID,
        scopeKey: String,
        trackerID: UUID,
        planID: UUID,
        scheduleItemID: UUID?,
        transactionID: UUID,
        amountMinor: Int64,
        appliedAmountMinor: Int64,
        overpaymentMinor: Int64,
        extraPayment: Bool,
        appliedAt: Date,
        createdByID: UUID,
        serverVersion: Int64,
        createdAt: Date
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.planID = planID
        self.scheduleItemID = scheduleItemID
        self.transactionID = transactionID
        self.amountMinor = amountMinor
        self.appliedAmountMinor = appliedAmountMinor
        self.overpaymentMinor = overpaymentMinor
        self.extraPayment = extraPayment
        self.appliedAt = appliedAt
        self.createdByID = createdByID
        self.serverVersion = serverVersion
        self.createdAt = createdAt
        updatedAt = createdAt
    }
}
