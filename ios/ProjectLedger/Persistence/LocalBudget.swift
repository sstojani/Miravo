import Foundation
import SwiftData

enum BudgetScope: String, Codable, CaseIterable, Sendable {
    case tracker
    case categories

    var displayName: String {
        switch self {
        case .tracker: String(localized: "Entire tracker")
        case .categories: String(localized: "Selected categories")
        }
    }
}

enum BudgetPeriod: String, Codable, CaseIterable, Sendable {
    case monthly
    case weekly
    case custom

    var displayName: String {
        switch self {
        case .monthly: String(localized: "Monthly")
        case .weekly: String(localized: "Weekly")
        case .custom: String(localized: "Custom range")
        }
    }
}

@Model
final class LocalBudget {
    #Unique<LocalBudget>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var name: String
    var budgetScopeRaw: String
    var periodRaw: String
    var amountMinor: Int64
    var currencyCode: String
    var currencyExponent: Int
    var timeZoneIdentifier: String
    var startsOn: Date
    var endsOn: Date?
    var rollover: Bool
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
        budgetScope: BudgetScope,
        period: BudgetPeriod,
        money: Money,
        timeZoneIdentifier: String,
        startsOn: Date,
        endsOn: Date? = nil,
        rollover: Bool = false,
        syncState: LocalSyncState = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.name = name
        budgetScopeRaw = budgetScope.rawValue
        periodRaw = period.rawValue
        amountMinor = money.minorUnits
        currencyCode = money.currencyCode
        currencyExponent = money.exponent
        self.timeZoneIdentifier = timeZoneIdentifier
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.rollover = rollover
        syncStateRaw = syncState.rawValue
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var budgetScope: BudgetScope {
        BudgetScope(rawValue: budgetScopeRaw) ?? .tracker
    }

    var period: BudgetPeriod {
        BudgetPeriod(rawValue: periodRaw) ?? .monthly
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
final class LocalBudgetCategory {
    #Unique<LocalBudgetCategory>([\.scopeKey, \.budgetID, \.categoryID])

    var id: UUID
    var scopeKey: String
    var budgetID: UUID
    var categoryID: UUID
    var categoryNameSnapshot: String
    var categoryVersionSnapshot: Int64

    init(
        id: UUID = UUID(),
        scopeKey: String,
        budgetID: UUID,
        categoryID: UUID,
        categoryNameSnapshot: String,
        categoryVersionSnapshot: Int64
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.budgetID = budgetID
        self.categoryID = categoryID
        self.categoryNameSnapshot = categoryNameSnapshot
        self.categoryVersionSnapshot = categoryVersionSnapshot
    }
}

@Model
final class LocalBudgetThreshold {
    #Unique<LocalBudgetThreshold>([\.scopeKey, \.budgetID, \.percent])

    var id: UUID
    var scopeKey: String
    var budgetID: UUID
    var percent: Int

    init(
        id: UUID = UUID(),
        scopeKey: String,
        budgetID: UUID,
        percent: Int
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.budgetID = budgetID
        self.percent = percent
    }
}

enum BudgetDateCodec {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func canonicalDate(from date: Date, calendar source: Calendar = .current) -> Date? {
        let components = source.dateComponents([.year, .month, .day], from: date)
        var storageCalendar = Calendar(identifier: .gregorian)
        storageCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return storageCalendar.date(from: components)
    }

    static func presentationDate(from stored: Date, calendar target: Calendar = .current) -> Date? {
        var storageCalendar = Calendar(identifier: .gregorian)
        storageCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = storageCalendar.dateComponents([.year, .month, .day], from: stored)
        return target.date(from: components)
    }
}
