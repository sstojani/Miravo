import CryptoKit
import Foundation

enum RecurringReminderLeadTime: Int, CaseIterable, Codable, Sendable {
    case atDueTime = 0
    case oneDay = 24
    case threeDays = 72
    case oneWeek = 168

    var displayName: String {
        switch self {
        case .atDueTime: String(localized: "At the due time")
        case .oneDay: String(localized: "One day before")
        case .threeDays: String(localized: "Three days before")
        case .oneWeek: String(localized: "One week before")
        }
    }

    var interval: TimeInterval {
        TimeInterval(rawValue) * 3_600
    }
}

struct RecurringReminderCandidate: Equatable, Sendable {
    let ruleID: UUID
    let nextDueAt: Date
    let state: RecurringRuleState
    let archivedAt: Date?
    let deletedAt: Date?
}

struct RecurringReminderPlan: Equatable, Sendable {
    let identifier: String
    let ruleID: UUID
    let fireAt: Date
    let dueAt: Date
}

enum RecurringReminderPlanner {
    static let maximumScheduledCount = 50
    static let minimumSchedulingDelay: TimeInterval = 5

    static func plans(
        candidates: [RecurringReminderCandidate],
        scopeKey: String,
        leadTime: RecurringReminderLeadTime,
        now: Date,
        maximumCount: Int = maximumScheduledCount
    ) -> [RecurringReminderPlan] {
        let earliestFire = now.addingTimeInterval(minimumSchedulingDelay)
        let boundedMaximum = min(max(maximumCount, 0), maximumScheduledCount)
        guard boundedMaximum > 0 else { return [] }

        return candidates.compactMap { candidate -> RecurringReminderPlan? in
            guard candidate.state == .active,
                  candidate.archivedAt == nil,
                  candidate.deletedAt == nil,
                  candidate.nextDueAt > earliestFire
            else {
                return nil
            }
            let preferredFire = candidate.nextDueAt.addingTimeInterval(-leadTime.interval)
            return RecurringReminderPlan(
                identifier: reminderIdentifier(
                    scopeKey: scopeKey,
                    ruleID: candidate.ruleID
                ),
                ruleID: candidate.ruleID,
                fireAt: max(preferredFire, earliestFire),
                dueAt: candidate.nextDueAt
            )
        }
        .sorted {
            if $0.fireAt != $1.fireAt { return $0.fireAt < $1.fireAt }
            if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
            return $0.ruleID.uuidString < $1.ruleID.uuidString
        }
        .prefix(boundedMaximum)
        .map { $0 }
    }

    static func identifierPrefix(scopeKey: String) -> String {
        "projectledger.recurring.\(scopeDigest(scopeKey))."
    }

    static func scopeDigest(_ scopeKey: String) -> String {
        SHA256.hash(data: Data(scopeKey.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func reminderIdentifier(scopeKey: String, ruleID: UUID) -> String {
        let source = "\(scopeKey):\(ruleID.uuidString.lowercased())"
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return identifierPrefix(scopeKey: scopeKey) + digest
    }
}
