import Foundation
import SwiftData

/// An actor-local inventory: callbacks never cross a suspension or leave the model context.
protocol SyncRecoveryRecord: PersistentModel {
    var id: UUID { get }
    var scopeKey: String { get }
    var deletedAt: Date? { get set }
}

extension LocalTracker: SyncRecoveryRecord {}
extension LocalTrackerMembership: SyncRecoveryRecord {}
extension LocalParticipant: SyncRecoveryRecord {}
extension LocalAccount: SyncRecoveryRecord {}
extension LocalCategory: SyncRecoveryRecord {}
extension LocalTag: SyncRecoveryRecord {}
extension LocalBudget: SyncRecoveryRecord {}
extension LocalRecurringRule: SyncRecoveryRecord {}
extension LocalRecurringOccurrence: SyncRecoveryRecord {}
extension LocalInstallmentPlan: SyncRecoveryRecord {}
extension LocalInstallmentScheduleItem: SyncRecoveryRecord {}
extension LocalInstallmentPayment: SyncRecoveryRecord {}
extension LedgerTransaction: SyncRecoveryRecord {}
extension LocalAttachment: SyncRecoveryRecord {}
extension LocalSettlement: SyncRecoveryRecord {}

struct SyncLocalRecordState {
    let trackerID: UUID?
    let serverVersion: Int64?
    let deletedAt: Date?
    let markUnavailable: (Date) -> Void
}

struct SyncLocalInventory {
    private(set) var records: [SyncRecordKey: SyncLocalRecordState] = [:]

    init(context: ModelContext, scopeKey: String) throws {
        add("tracker", rows: try context.fetch(FetchDescriptor<LocalTracker>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { _ in nil }, version: { $0.serverVersion })
        add("tracker_membership", rows: try context.fetch(FetchDescriptor<LocalTrackerMembership>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("participant", rows: try context.fetch(FetchDescriptor<LocalParticipant>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("account", rows: try context.fetch(FetchDescriptor<LocalAccount>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("category", rows: try context.fetch(FetchDescriptor<LocalCategory>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("tag", rows: try context.fetch(FetchDescriptor<LocalTag>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("budget", rows: try context.fetch(FetchDescriptor<LocalBudget>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("recurring_rule", rows: try context.fetch(FetchDescriptor<LocalRecurringRule>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("recurring_occurrence", rows: try context.fetch(FetchDescriptor<LocalRecurringOccurrence>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("installment_plan", rows: try context.fetch(FetchDescriptor<LocalInstallmentPlan>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("installment_schedule_item", rows: try context.fetch(FetchDescriptor<LocalInstallmentScheduleItem>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("installment_payment", rows: try context.fetch(FetchDescriptor<LocalInstallmentPayment>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("transaction", rows: try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("attachment", rows: try context.fetch(FetchDescriptor<LocalAttachment>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
        add("settlement", rows: try context.fetch(FetchDescriptor<LocalSettlement>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )), trackerID: { $0.trackerID }, version: { $0.serverVersion })
    }

    private mutating func add<Record: SyncRecoveryRecord>(
        _ entityType: String,
        rows: [Record],
        trackerID: (Record) -> UUID?,
        version: (Record) -> Int64?
    ) {
        for row in rows {
            records[SyncRecordKey(entityType: entityType, entityID: row.id)] = SyncLocalRecordState(
                trackerID: trackerID(row),
                serverVersion: version(row),
                deletedAt: row.deletedAt,
                markUnavailable: { row.deletedAt = $0 }
            )
        }
    }
}
