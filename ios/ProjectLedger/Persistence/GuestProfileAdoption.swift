import Foundation
import SwiftData

enum GuestProfileAdoptionResult: Equatable {
    case notNeeded
    case discardedDisposableProfile
    case migratedLocalProfile
}

@MainActor
extension LocalLedgerRepository {
    @discardableResult
    func adoptGuestProfileForAuthentication(
        sourceScopeKey: String,
        targetScopeKey: String
    ) throws -> GuestProfileAdoptionResult {
        guard sourceScopeKey != targetScopeKey,
              SessionScope.isLocal(sourceScopeKey),
              !SessionScope.isLocal(targetScopeKey)
        else {
            return .notNeeded
        }

        let profile = try ScopedProfileSnapshot(context: context, scopeKey: sourceScopeKey)
        guard profile.containsData else { return .notNeeded }

        do {
            if profile.isDisposableBootstrapProfile {
                try deleteGuestProfile(profile)
                try context.save()
                return .discardedDisposableProfile
            }

            try moveGuestProfile(profile, targetScopeKey: targetScopeKey)
            try context.save()
            return .migratedLocalProfile
        } catch {
            context.rollback()
            throw error
        }
    }

    private func deleteGuestProfile(_ profile: ScopedProfileSnapshot) throws {
        for item in profile.bootstrapStagedEntities { context.delete(item) }
        for item in profile.attachmentTransfers { context.delete(item) }
        for item in profile.syncConflicts { context.delete(item) }
        for item in profile.outboxMutations { context.delete(item) }
        for item in profile.cursors { context.delete(item) }
        for item in profile.transactionTags { context.delete(item) }
        for item in profile.categoryAllocations { context.delete(item) }
        for item in profile.accountMovements { context.delete(item) }
        for item in profile.attachments { context.delete(item) }
        for item in profile.splitPayments { context.delete(item) }
        for item in profile.splitShares { context.delete(item) }
        for item in profile.settlements { context.delete(item) }
        for item in profile.installmentPayments { context.delete(item) }
        for item in profile.installmentScheduleItems { context.delete(item) }
        for item in profile.installmentPlans { context.delete(item) }
        for item in profile.recurringOccurrences { context.delete(item) }
        for item in profile.recurringRules { context.delete(item) }
        for item in profile.budgetThresholds { context.delete(item) }
        for item in profile.budgetCategories { context.delete(item) }
        for item in profile.budgets { context.delete(item) }
        for item in profile.transactions { context.delete(item) }
        for item in profile.tags { context.delete(item) }
        for item in profile.participants { context.delete(item) }
        for item in profile.memberships { context.delete(item) }
        for item in profile.categories { context.delete(item) }
        for item in profile.accounts { context.delete(item) }
        for item in profile.trackers { context.delete(item) }
    }

    private func moveGuestProfile(
        _ profile: ScopedProfileSnapshot,
        targetScopeKey: String
    ) throws {
        let mutations = profile.outboxMutations.sorted { $0.localSequence < $1.localSequence }
        let targetCursor = try cursor(scopeKey: targetScopeKey)
        var nextSequence = max(
            targetCursor.nextOutboxSequence,
            try nextAvailableSequence(scopeKey: targetScopeKey)
        )

        for item in profile.trackers { item.scopeKey = targetScopeKey }
        for item in profile.memberships { item.scopeKey = targetScopeKey }
        for item in profile.accounts { item.scopeKey = targetScopeKey }
        for item in profile.categories { item.scopeKey = targetScopeKey }
        for item in profile.tags { item.scopeKey = targetScopeKey }
        for item in profile.participants { item.scopeKey = targetScopeKey }
        for item in profile.transactions { item.scopeKey = targetScopeKey }
        for item in profile.categoryAllocations { item.scopeKey = targetScopeKey }
        for item in profile.accountMovements { item.scopeKey = targetScopeKey }
        for item in profile.transactionTags { item.scopeKey = targetScopeKey }
        for item in profile.budgets { item.scopeKey = targetScopeKey }
        for item in profile.budgetCategories { item.scopeKey = targetScopeKey }
        for item in profile.budgetThresholds { item.scopeKey = targetScopeKey }
        for item in profile.recurringRules { item.scopeKey = targetScopeKey }
        for item in profile.recurringOccurrences { item.scopeKey = targetScopeKey }
        for item in profile.installmentPlans { item.scopeKey = targetScopeKey }
        for item in profile.installmentScheduleItems { item.scopeKey = targetScopeKey }
        for item in profile.installmentPayments { item.scopeKey = targetScopeKey }
        for item in profile.settlements { item.scopeKey = targetScopeKey }
        for item in profile.splitPayments { item.scopeKey = targetScopeKey }
        for item in profile.splitShares { item.scopeKey = targetScopeKey }
        for item in profile.attachments { item.scopeKey = targetScopeKey }
        for item in profile.attachmentTransfers { item.scopeKey = targetScopeKey }
        for item in profile.syncConflicts { item.scopeKey = targetScopeKey }

        for mutation in mutations {
            mutation.scopeKey = targetScopeKey
            mutation.localSequence = nextSequence
            if mutation.state == .syncing {
                mutation.stateRaw = LocalSyncState.pending.rawValue
            }
            nextSequence += 1
        }
        targetCursor.nextOutboxSequence = nextSequence
        targetCursor.bootstrapRequired = true
        targetCursor.lastSafeErrorCode = nil

        for item in profile.bootstrapStagedEntities { context.delete(item) }
        for item in profile.cursors { context.delete(item) }
    }

    private func cursor(scopeKey: String) throws -> SyncCursor {
        let descriptor = FetchDescriptor<SyncCursor>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let created = SyncCursor(scopeKey: scopeKey)
        context.insert(created)
        return created
    }

    private func nextAvailableSequence(scopeKey: String) throws -> Int64 {
        let descriptor = FetchDescriptor<OutboxMutation>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )
        let maximum = try context.fetch(descriptor).map(\.localSequence).max() ?? 0
        return maximum + 1
    }
}

@MainActor
private struct ScopedProfileSnapshot {
    let trackers: [LocalTracker]
    let memberships: [LocalTrackerMembership]
    let accounts: [LocalAccount]
    let categories: [LocalCategory]
    let tags: [LocalTag]
    let participants: [LocalParticipant]
    let transactions: [LedgerTransaction]
    let categoryAllocations: [LocalCategoryAllocation]
    let accountMovements: [LocalAccountMovement]
    let transactionTags: [LocalTransactionTag]
    let budgets: [LocalBudget]
    let budgetCategories: [LocalBudgetCategory]
    let budgetThresholds: [LocalBudgetThreshold]
    let recurringRules: [LocalRecurringRule]
    let recurringOccurrences: [LocalRecurringOccurrence]
    let installmentPlans: [LocalInstallmentPlan]
    let installmentScheduleItems: [LocalInstallmentScheduleItem]
    let installmentPayments: [LocalInstallmentPayment]
    let settlements: [LocalSettlement]
    let splitPayments: [LocalSplitPayment]
    let splitShares: [LocalSplitShare]
    let attachments: [LocalAttachment]
    let attachmentTransfers: [AttachmentTransfer]
    let bootstrapStagedEntities: [BootstrapStagedEntity]
    let cursors: [SyncCursor]
    let outboxMutations: [OutboxMutation]
    let syncConflicts: [SyncConflict]

    init(context: ModelContext, scopeKey: String) throws {
        trackers = try context.fetch(FetchDescriptor<LocalTracker>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        memberships = try context.fetch(FetchDescriptor<LocalTrackerMembership>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        accounts = try context.fetch(FetchDescriptor<LocalAccount>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        categories = try context.fetch(FetchDescriptor<LocalCategory>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        tags = try context.fetch(FetchDescriptor<LocalTag>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        participants = try context.fetch(FetchDescriptor<LocalParticipant>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        transactions = try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        categoryAllocations = try context.fetch(FetchDescriptor<LocalCategoryAllocation>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        accountMovements = try context.fetch(FetchDescriptor<LocalAccountMovement>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        transactionTags = try context.fetch(FetchDescriptor<LocalTransactionTag>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        budgets = try context.fetch(FetchDescriptor<LocalBudget>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        budgetCategories = try context.fetch(FetchDescriptor<LocalBudgetCategory>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        budgetThresholds = try context.fetch(FetchDescriptor<LocalBudgetThreshold>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        recurringRules = try context.fetch(FetchDescriptor<LocalRecurringRule>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        recurringOccurrences = try context.fetch(FetchDescriptor<LocalRecurringOccurrence>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        installmentPlans = try context.fetch(FetchDescriptor<LocalInstallmentPlan>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        installmentScheduleItems = try context.fetch(
            FetchDescriptor<LocalInstallmentScheduleItem>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        )
        installmentPayments = try context.fetch(FetchDescriptor<LocalInstallmentPayment>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        settlements = try context.fetch(FetchDescriptor<LocalSettlement>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        splitPayments = try context.fetch(FetchDescriptor<LocalSplitPayment>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        splitShares = try context.fetch(FetchDescriptor<LocalSplitShare>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        attachments = try context.fetch(FetchDescriptor<LocalAttachment>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        attachmentTransfers = try context.fetch(FetchDescriptor<AttachmentTransfer>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        bootstrapStagedEntities = try context.fetch(FetchDescriptor<BootstrapStagedEntity>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        cursors = try context.fetch(FetchDescriptor<SyncCursor>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        outboxMutations = try context.fetch(FetchDescriptor<OutboxMutation>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        syncConflicts = try context.fetch(FetchDescriptor<SyncConflict>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
    }

    var containsData: Bool {
        coreRowCount > 0 ||
            planningRowCount > 0 ||
            sharingRowCount > 0 ||
            transferRowCount > 0 ||
            syncRowCount > 0
    }

    private var coreRowCount: Int {
        trackers.count +
            memberships.count +
            accounts.count +
            categories.count +
            tags.count +
            participants.count +
            transactions.count +
            categoryAllocations.count +
            accountMovements.count +
            transactionTags.count
    }

    private var planningRowCount: Int {
        budgets.count +
            budgetCategories.count +
            budgetThresholds.count +
            recurringRules.count +
            recurringOccurrences.count +
            installmentPlans.count +
            installmentScheduleItems.count +
            installmentPayments.count
    }

    private var sharingRowCount: Int {
        settlements.count +
            splitPayments.count +
            splitShares.count
    }

    private var transferRowCount: Int {
        attachments.count +
            attachmentTransfers.count
    }

    private var syncRowCount: Int {
        bootstrapStagedEntities.count +
            cursors.count +
            outboxMutations.count +
            syncConflicts.count
    }

    var isDisposableBootstrapProfile: Bool {
        guard trackers.count == 1,
              memberships.isEmpty,
              accounts.count == 1,
              categories.count == 1,
              tags.isEmpty,
              participants.isEmpty,
              transactions.isEmpty,
              categoryAllocations.isEmpty,
              accountMovements.isEmpty,
              transactionTags.isEmpty,
              budgets.isEmpty,
              budgetCategories.isEmpty,
              budgetThresholds.isEmpty,
              recurringRules.isEmpty,
              recurringOccurrences.isEmpty,
              installmentPlans.isEmpty,
              installmentScheduleItems.isEmpty,
              installmentPayments.isEmpty,
              settlements.isEmpty,
              splitPayments.isEmpty,
              splitShares.isEmpty,
              attachments.isEmpty,
              attachmentTransfers.isEmpty,
              bootstrapStagedEntities.isEmpty,
              syncConflicts.isEmpty
        else {
            return false
        }
        let tracker = trackers[0]
        let account = accounts[0]
        let category = categories[0]
        guard tracker.serverVersion == nil,
              account.serverVersion == nil,
              category.serverVersion == nil,
              account.trackerID == tracker.id,
              category.trackerID == tracker.id,
              tracker.defaultAccountID == account.id,
              tracker.defaultCategoryID == category.id,
              category.kind == .expense,
              outboxMutations.count == 4
        else {
            return false
        }

        let mutationKeys = outboxMutations.map {
            "\($0.entityType)|\($0.command)|\($0.entityID.uuidString.lowercased())"
        }
        return Set(mutationKeys) == Set([
            "tracker|create|\(tracker.id.uuidString.lowercased())",
            "tracker|update|\(tracker.id.uuidString.lowercased())",
            "account|create|\(account.id.uuidString.lowercased())",
            "category|create|\(category.id.uuidString.lowercased())",
        ])
    }
}
