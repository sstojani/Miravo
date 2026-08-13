import Foundation
import SwiftData

enum RecurringRuleKind: String, Codable, CaseIterable, Sendable {
    case expense
    case income

    var displayName: String {
        switch self {
        case .expense: String(localized: "Expense")
        case .income: String(localized: "Income")
        }
    }
}

enum RecurringCadence: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly
    case custom

    var displayName: String {
        switch self {
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        case .monthly: String(localized: "Monthly")
        case .yearly: String(localized: "Yearly")
        case .custom: String(localized: "Custom interval")
        }
    }
}

enum RecurringIntervalUnit: String, Codable, CaseIterable, Sendable {
    case day
    case week
    case month
    case year

    var displayName: String {
        switch self {
        case .day: String(localized: "Days")
        case .week: String(localized: "Weeks")
        case .month: String(localized: "Months")
        case .year: String(localized: "Years")
        }
    }
}

enum RecurringRuleState: String, Codable, CaseIterable, Sendable {
    case active
    case paused
    case ended

    var displayName: String {
        switch self {
        case .active: String(localized: "Active")
        case .paused: String(localized: "Paused")
        case .ended: String(localized: "Ended")
        }
    }
}

enum RecurringOccurrenceState: String, Codable, CaseIterable, Sendable {
    case posted
    case skipped
    case failed
}

@Model
final class LocalRecurringRule {
    #Unique<LocalRecurringRule>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var name: String
    var kindRaw: String
    var isSubscription: Bool
    var amountMinor: Int64
    var currencyCode: String
    var currencyExponent: Int
    var accountID: UUID
    var accountAmountMinor: Int64
    var categoryID: UUID?
    var merchant: String
    var note: String
    var baseAmountMinor: Int64
    var baseCurrencyCode: String
    var rateSnapshot: String
    var rateSource: String
    var rateEffectiveAt: Date
    var cadenceRaw: String
    var customIntervalUnitRaw: String
    var customIntervalCount: Int
    var timeZoneIdentifier: String
    var startsOn: Date
    var endsOn: Date?
    var localTimeSeconds: Int
    var nextDueOn: Date
    var nextDueAt: Date
    var stateRaw: String
    var pausedAt: Date?
    var endedAt: Date?
    var subscriptionProvider: String
    var trialEndsOn: Date?
    var cancellationURL: String
    var subscriptionNote: String
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
        kind: RecurringRuleKind,
        isSubscription: Bool,
        money: Money,
        accountID: UUID,
        accountAmountMinor: Int64,
        categoryID: UUID?,
        merchant: String,
        note: String,
        conversion: ReportingConversionSnapshot,
        cadence: RecurringCadence,
        customIntervalUnit: RecurringIntervalUnit?,
        customIntervalCount: Int,
        timeZoneIdentifier: String,
        startsOn: Date,
        endsOn: Date?,
        localTimeSeconds: Int,
        nextDueOn: Date,
        nextDueAt: Date,
        subscriptionProvider: String = "",
        trialEndsOn: Date? = nil,
        cancellationURL: String = "",
        subscriptionNote: String = "",
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.name = name
        kindRaw = kind.rawValue
        self.isSubscription = isSubscription
        amountMinor = money.minorUnits
        currencyCode = money.currencyCode
        currencyExponent = money.exponent
        self.accountID = accountID
        self.accountAmountMinor = accountAmountMinor
        self.categoryID = categoryID
        self.merchant = merchant
        self.note = note
        baseAmountMinor = conversion.baseAmountMinor
        baseCurrencyCode = conversion.baseCurrencyCode
        rateSnapshot = conversion.rateSnapshot
        rateSource = conversion.rateSource
        rateEffectiveAt = conversion.effectiveAt
        cadenceRaw = cadence.rawValue
        customIntervalUnitRaw = customIntervalUnit?.rawValue ?? ""
        self.customIntervalCount = customIntervalCount
        self.timeZoneIdentifier = timeZoneIdentifier
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.localTimeSeconds = localTimeSeconds
        self.nextDueOn = nextDueOn
        self.nextDueAt = nextDueAt
        stateRaw = RecurringRuleState.active.rawValue
        self.subscriptionProvider = subscriptionProvider
        self.trialEndsOn = trialEndsOn
        self.cancellationURL = cancellationURL
        self.subscriptionNote = subscriptionNote
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var kind: RecurringRuleKind {
        RecurringRuleKind(rawValue: kindRaw) ?? .expense
    }

    var cadence: RecurringCadence {
        RecurringCadence(rawValue: cadenceRaw) ?? .monthly
    }

    var customIntervalUnit: RecurringIntervalUnit? {
        customIntervalUnitRaw.isEmpty
            ? nil : RecurringIntervalUnit(rawValue: customIntervalUnitRaw)
    }

    var state: RecurringRuleState {
        RecurringRuleState(rawValue: stateRaw) ?? .ended
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

@Model
final class LocalRecurringOccurrence {
    #Unique<LocalRecurringOccurrence>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var ruleID: UUID
    var occurrenceKey: String
    var dueOn: Date
    var scheduledFor: Date
    var ruleVersion: Int64
    var stateRaw: String
    var transactionID: UUID?
    var materializedAt: Date?
    var skippedAt: Date?
    var errorCode: String
    var serverVersion: Int64
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID,
        scopeKey: String,
        trackerID: UUID,
        ruleID: UUID,
        occurrenceKey: String,
        dueOn: Date,
        scheduledFor: Date,
        ruleVersion: Int64,
        state: RecurringOccurrenceState,
        transactionID: UUID?,
        serverVersion: Int64,
        createdAt: Date
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.ruleID = ruleID
        self.occurrenceKey = occurrenceKey
        self.dueOn = dueOn
        self.scheduledFor = scheduledFor
        self.ruleVersion = ruleVersion
        stateRaw = state.rawValue
        self.transactionID = transactionID
        self.serverVersion = serverVersion
        self.createdAt = createdAt
        updatedAt = createdAt
        errorCode = ""
    }

    var state: RecurringOccurrenceState {
        RecurringOccurrenceState(rawValue: stateRaw) ?? .failed
    }
}

enum RecurringTimeCodec {
    static func string(from seconds: Int) -> String {
        let bounded = min(max(seconds, 0), 86_399)
        return String(
            format: "%02d:%02d:%02d",
            bounded / 3_600,
            (bounded % 3_600) / 60,
            bounded % 60
        )
    }

    static func seconds(from value: String) -> Int? {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        let secondText = pieces.count == 3 ? String(pieces[2].prefix(2)) : "0"
        guard (2 ... 3).contains(pieces.count),
              let hours = Int(pieces[0]),
              let minutes = Int(pieces[1]),
              let seconds = Int(secondText),
              (0 ... 23).contains(hours),
              (0 ... 59).contains(minutes),
              (0 ... 59).contains(seconds)
        else {
            return nil
        }
        return hours * 3_600 + minutes * 60 + seconds
    }

    static func date(from seconds: Int, calendar: Calendar = .current) -> Date {
        let bounded = min(max(seconds, 0), 86_399)
        return calendar.date(
            bySettingHour: bounded / 3_600,
            minute: (bounded % 3_600) / 60,
            second: bounded % 60,
            of: .now
        ) ?? .now
    }

    static func seconds(from date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (components.hour ?? 0) * 3_600 +
            (components.minute ?? 0) * 60 +
            (components.second ?? 0)
    }
}
