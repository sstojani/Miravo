import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct LocalLedgerRepositoryTests {
    private let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"

    @Test func bootstrapCreatesCoherentDefaultsAndOutbox() throws {
        let container = try makeContainer()
        let repository = LocalLedgerRepository(context: container.mainContext)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)

        let trackers = try container.mainContext.fetch(FetchDescriptor<LocalTracker>())
        let accounts = try container.mainContext.fetch(FetchDescriptor<LocalAccount>())
        let categories = try container.mainContext.fetch(FetchDescriptor<LocalCategory>())
        let outbox = try container.mainContext.fetch(FetchDescriptor<OutboxMutation>())

        #expect(trackers.map(\.id) == [tracker.id])
        #expect(accounts.first?.id == tracker.defaultAccountID)
        #expect(categories.first?.id == tracker.defaultCategoryID)
        #expect(outbox.count == 4)
        #expect(outbox.allSatisfy { !$0.payloadJSON.isEmpty })
        #expect(outbox.map(\.localSequence).sorted() == [1, 2, 3, 4])
    }

    @Test func createEditDeleteAndRestoreEachAppendDurableMutation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let money = try Money(minorUnits: 500, currencyCode: "ALL", exponent: 2)

        let transaction = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: category,
            kind: .expense,
            money: money,
            merchant: "Test merchant"
        )
        let revisedMoney = try Money(minorUnits: 725, currencyCode: "ALL", exponent: 2)
        try repository.updateTransaction(
            transaction,
            tracker: tracker,
            account: account,
            category: category,
            money: revisedMoney,
            merchant: "Updated merchant",
            note: "local edit",
            occurredAt: transaction.occurredAt,
            tags: []
        )
        try repository.setTransactionDeleted(transaction, deleted: true)
        try repository.setTransactionDeleted(transaction, deleted: false)

        let persisted = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let movements = try context.fetch(FetchDescriptor<LocalAccountMovement>())
        let allocations = try context.fetch(FetchDescriptor<LocalCategoryAllocation>())
        let mutations = try context.fetch(FetchDescriptor<OutboxMutation>())
            .filter { $0.entityID == transaction.id }
            .sorted { $0.localSequence < $1.localSequence }
        #expect(persisted.map(\.id) == [transaction.id])
        #expect(transaction.amountMinor == 725)
        #expect(transaction.deletedAt == nil)
        #expect(movements.count == 1)
        #expect(movements.first?.signedAmountMinor == -725)
        #expect(allocations.count == 1)
        #expect(allocations.first?.amountMinor == 725)
        #expect(mutations.map(\.command) == ["create", "update", "delete", "restore"])
    }

    @Test func transactionPayloadUsesIntegerMinorUnitsAndStableIdentifiers() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let money = try Money(minorUnits: 1_250, currencyCode: "ALL", exponent: 2)
        let transaction = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: nil,
            kind: .expense,
            money: money,
            merchant: "Merchant"
        )
        let mutation = try #require(
            context.fetch(FetchDescriptor<OutboxMutation>())
                .first { $0.entityID == transaction.id }
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(TransactionMutationPayload.self, from: mutation.payloadJSON)
        let rawPayload = try #require(
            JSONSerialization.jsonObject(with: mutation.payloadJSON) as? [String: Any]
        )

        #expect(payload.id == transaction.id)
        #expect(payload.amountMinor == 1_250)
        #expect(payload.currency == "ALL")
        #expect(payload.trackerID == tracker.id)
        #expect(mutation.scopeKey == scope)
        #expect(rawPayload["amount_minor"] as? Int == 1_250)
        #expect(rawPayload["amountMinor"] == nil)
    }

    @Test func compoundIdentityAllowsSharedUUIDInSeparateUserScopes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sharedID = UUID()
        let secondScope = "https://ledger.example|20000000-0000-0000-0000-000000000002"
        context.insert(LocalTracker(id: sharedID, scopeKey: scope, name: "First user"))
        context.insert(LocalTracker(id: sharedID, scopeKey: secondScope, name: "Second user"))
        try context.save()

        let trackers = try context.fetch(FetchDescriptor<LocalTracker>())
        #expect(trackers.count == 2)
        #expect(Set(trackers.map(\.scopeKey)) == Set([scope, secondScope]))
    }

    @Test func revokedTrackerRejectsNewLocalFinancialMutations() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        tracker.accessRevokedAt = .now
        try context.save()
        let before = try context.fetch(FetchDescriptor<OutboxMutation>()).count

        #expect(throws: LocalLedgerError.invalidReference) {
            try repository.createTransaction(
                scopeKey: scope,
                tracker: tracker,
                account: account,
                category: nil,
                kind: .expense,
                money: Money(minorUnits: 100, currencyCode: "ALL", exponent: 2),
                merchant: "Rejected"
            )
        }
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<OutboxMutation>()).count == before)
    }

    @Test func crossScopeReferenceIsRejectedWithoutPartialMutation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let foreign = LocalAccount(
            scopeKey: "https://other.example|20000000-0000-0000-0000-000000000002",
            trackerID: tracker.id,
            name: "Foreign",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2
        )
        context.insert(foreign)
        try context.save()
        let before = try context.fetch(FetchDescriptor<OutboxMutation>()).count

        #expect(throws: LocalLedgerError.invalidReference) {
            try repository.createTransaction(
                scopeKey: scope,
                tracker: tracker,
                account: foreign,
                category: nil,
                kind: .expense,
                money: Money(minorUnits: 100, currencyCode: "ALL", exponent: 2),
                merchant: "Rejected"
            )
        }
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<OutboxMutation>()).count == before)
    }

    @Test func outboxFailureRollsBackTransactionAndFinancialChildrenTogether() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let cursor = try #require(context.fetch(FetchDescriptor<SyncCursor>()).first)
        cursor.nextOutboxSequence = Int64.max
        try context.save()

        #expect(throws: MoneyError.outOfRange) {
            try repository.createTransaction(
                scopeKey: scope,
                tracker: tracker,
                account: account,
                category: category,
                kind: .expense,
                money: Money(minorUnits: 100, currencyCode: "ALL", exponent: 2),
                merchant: "Must roll back"
            )
        }
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalAccountMovement>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalCategoryAllocation>()).isEmpty)
    }

    @Test func sameCurrencyTransferCreatesBalancedLinkedMovementsAndDuplicatesSafely() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let source = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let destination = try repository.createAccount(
            scopeKey: scope,
            tracker: tracker,
            name: "Savings",
            type: .savings,
            currencyCode: "ALL",
            currencyExponent: 2
        )
        let money = try Money(minorUnits: 2_500, currencyCode: "ALL", exponent: 2)

        let transfer = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: source,
            category: nil,
            kind: .transfer,
            money: money,
            merchant: "Move to savings",
            destinationAccount: destination,
            destinationMoney: money
        )
        let duplicate = try repository.duplicate(transfer)
        let movements = try context.fetch(FetchDescriptor<LocalAccountMovement>())
        let originalMovements = movements.filter { $0.transactionID == transfer.id }
        let duplicateMovements = movements.filter { $0.transactionID == duplicate.id }

        #expect(transfer.destinationAccountID == destination.id)
        #expect(transfer.destinationAmountMinor == 2_500)
        #expect(Set(originalMovements.map(\.signedAmountMinor)) == Set([-2_500, 2_500]))
        #expect(Set(duplicateMovements.map(\.signedAmountMinor)) == Set([-2_500, 2_500]))
        #expect(try context.fetch(FetchDescriptor<LocalCategoryAllocation>()).isEmpty)
    }

    @Test func crossCurrencyTransferStoresBothAmountsAndExplicitBaseSnapshot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let destination = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let source = try repository.createAccount(
            scopeKey: scope,
            tracker: tracker,
            name: "Euro account",
            type: .checking,
            currencyCode: "EUR",
            currencyExponent: 2
        )
        let sourceMoney = try Money(minorUnits: 1_000, currencyCode: "EUR", exponent: 2)
        let destinationMoney = try Money(
            minorUnits: 100_000,
            currencyCode: "ALL",
            exponent: 2
        )

        let transfer = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: source,
            category: nil,
            kind: .transfer,
            money: sourceMoney,
            merchant: "Convert to cash",
            destinationAccount: destination,
            destinationMoney: destinationMoney,
            baseMoney: destinationMoney
        )
        let movements = try context.fetch(FetchDescriptor<LocalAccountMovement>())
            .filter { $0.transactionID == transfer.id }
        let mutation = try #require(
            context.fetch(FetchDescriptor<OutboxMutation>())
                .first { $0.entityID == transfer.id }
        )
        let rawPayload = try #require(
            JSONSerialization.jsonObject(with: mutation.payloadJSON) as? [String: Any]
        )

        #expect(transfer.amountMinor == 1_000)
        #expect(transfer.destinationAmountMinor == 100_000)
        #expect(transfer.baseAmountMinor == 100_000)
        #expect(transfer.rateSnapshot == "100")
        #expect(Set(movements.map(\.signedAmountMinor)) == Set([-1_000, 100_000]))
        #expect(rawPayload["base_amount_minor"] as? Int == 100_000)
        #expect(rawPayload["rate_snapshot"] as? String == "100")
    }

    @Test func linkedPartialRefundAddsMoneyAndCarriesOriginalID() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let expense = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: category,
            kind: .expense,
            money: Money(minorUnits: 500, currencyCode: "ALL", exponent: 2),
            merchant: "Shop"
        )

        let refund = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: category,
            kind: .refund,
            money: Money(minorUnits: 200, currencyCode: "ALL", exponent: 2),
            merchant: "Shop refund",
            refundOf: expense
        )
        let movement = try #require(
            context.fetch(FetchDescriptor<LocalAccountMovement>())
                .first { $0.transactionID == refund.id }
        )
        let mutation = try #require(
            context.fetch(FetchDescriptor<OutboxMutation>())
                .first { $0.entityID == refund.id }
        )
        let rawPayload = try #require(
            JSONSerialization.jsonObject(with: mutation.payloadJSON) as? [String: Any]
        )

        #expect(refund.refundOfID == expense.id)
        #expect(movement.signedAmountMinor == 200)
        #expect(rawPayload["refund_of_id"] as? String == expense.id.uuidString)
    }

    @Test func tagsAreSyncableAssignedAtomicallyAndPreservedByDuplicate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let tag = try repository.createTag(scopeKey: scope, tracker: tracker, name: "Trip")

        let transaction = try repository.createTransaction(
            scopeKey: scope,
            tracker: tracker,
            account: account,
            category: nil,
            kind: .expense,
            money: Money(minorUnits: 900, currencyCode: "ALL", exponent: 2),
            merchant: "Train",
            tags: [tag]
        )
        let duplicate = try repository.duplicate(transaction)
        let links = try context.fetch(FetchDescriptor<LocalTransactionTag>())
        let mutation = try #require(
            context.fetch(FetchDescriptor<OutboxMutation>())
                .first { $0.entityID == transaction.id }
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(TransactionMutationPayload.self, from: mutation.payloadJSON)

        #expect(payload.tagIDs == [tag.id])
        #expect(Set(links.map(\.transactionID)) == Set([transaction.id, duplicate.id]))
        #expect(links.allSatisfy { $0.tagID == tag.id })

        try repository.renameTag(tag, name: "Summer trip")
        try repository.setTagArchived(tag, archived: true)
        try repository.updateTransaction(
            transaction,
            tracker: tracker,
            account: account,
            category: nil,
            money: Money(minorUnits: 950, currencyCode: "ALL", exponent: 2),
            merchant: "Train updated",
            note: "Archived tag retained",
            occurredAt: transaction.occurredAt,
            tags: [tag]
        )
        try repository.setTagArchived(tag, archived: false)
        let tagMutations = try context.fetch(FetchDescriptor<OutboxMutation>())
            .filter { $0.entityID == tag.id }
            .sorted { $0.localSequence < $1.localSequence }
        #expect(tagMutations.map(\.command) == ["create", "update", "archive", "restore"])
    }

    @Test func viewerRoleRejectsOfflineWritesWithoutAppendingOutbox() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        tracker.roleRaw = TrackerRole.viewer.rawValue
        try context.save()
        let before = try context.fetch(FetchDescriptor<OutboxMutation>()).count

        #expect(throws: LocalLedgerError.permissionDenied) {
            try repository.createTransaction(
                scopeKey: scope,
                tracker: tracker,
                account: account,
                category: nil,
                kind: .expense,
                money: Money(minorUnits: 100, currencyCode: "ALL", exponent: 2),
                merchant: "Blocked"
            )
        }
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<OutboxMutation>()).count == before)
    }

    @Test func trackerPresentationDefaultsAndOrderingAreAtomicAndSyncable() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let everyday = try repository.bootstrapDefaults(scopeKey: scope)
        let account = try #require(context.fetch(FetchDescriptor<LocalAccount>()).first)
        let category = try #require(context.fetch(FetchDescriptor<LocalCategory>()).first)
        let trip = try repository.createTracker(
            scopeKey: scope,
            name: "Trip",
            currencyCode: "EUR",
            currencyExponent: 2
        )

        #expect(everyday.sortOrder == 0)
        #expect(trip.sortOrder == 1)

        let beforeInvalidUpdate = try context.fetch(FetchDescriptor<OutboxMutation>()).count
        #expect(throws: LocalLedgerError.invalidReference) {
            try repository.updateTracker(
                everyday,
                name: "Must not persist",
                description: "",
                icon: "house",
                colorHex: "not-a-color",
                defaultAccount: account,
                defaultCategory: category
            )
        }
        #expect(everyday.name == "Everyday")
        #expect(
            try context.fetch(FetchDescriptor<OutboxMutation>()).count == beforeInvalidUpdate
        )

        try repository.updateTracker(
            everyday,
            name: "Daily life",
            description: "Shared household spending",
            icon: "house",
            colorHex: "#138a72",
            defaultAccount: account,
            defaultCategory: category
        )
        try repository.reorderTrackers([trip, everyday], scopeKey: scope)

        #expect(everyday.name == "Daily life")
        #expect(everyday.trackerDescription == "Shared household spending")
        #expect(everyday.icon == "house")
        #expect(everyday.colorHex == "#138A72")
        #expect(everyday.defaultAccountID == account.id)
        #expect(everyday.defaultCategoryID == category.id)
        #expect(trip.sortOrder == 0)
        #expect(everyday.sortOrder == 1)

        let trackerMutations = try context.fetch(FetchDescriptor<OutboxMutation>())
            .filter { $0.entityType == LocalMutationEntity.tracker.rawValue }
        #expect(trackerMutations.filter { $0.entityID == trip.id }.count == 2)
        #expect(trackerMutations.filter { $0.entityID == everyday.id }.count == 4)

        let latestEveryday = try #require(
            trackerMutations
                .filter { $0.entityID == everyday.id }
                .max { $0.localSequence < $1.localSequence }
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(
            TrackerMutationPayload.self,
            from: latestEveryday.payloadJSON
        )
        #expect(payload.sortOrder == 1)
        #expect(payload.defaultAccountID == account.id)
        #expect(payload.defaultCategoryID == category.id)
    }

    @Test func editorCannotChangeTrackerSettingsOrOrdering() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = LocalLedgerRepository(context: context)
        let tracker = try repository.bootstrapDefaults(scopeKey: scope)
        tracker.roleRaw = TrackerRole.editor.rawValue
        try context.save()
        let before = try context.fetch(FetchDescriptor<OutboxMutation>()).count

        #expect(throws: LocalLedgerError.permissionDenied) {
            try repository.updateTracker(
                tracker,
                name: "Blocked",
                description: "",
                icon: "house",
                colorHex: "#138A72",
                defaultAccount: nil,
                defaultCategory: nil
            )
        }
        #expect(throws: LocalLedgerError.permissionDenied) {
            try repository.reorderTrackers([tracker], scopeKey: scope)
        }
        #expect(tracker.name == "Everyday")
        #expect(try context.fetch(FetchDescriptor<OutboxMutation>()).count == before)
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: LocalTracker.self,
            LocalTrackerMembership.self,
            LocalAccount.self,
            LocalCategory.self,
            LocalTag.self,
            LocalParticipant.self,
            LocalBudget.self,
            LocalBudgetCategory.self,
            LocalBudgetThreshold.self,
            LocalRecurringRule.self,
            LocalRecurringOccurrence.self,
            LocalInstallmentPlan.self,
            LocalInstallmentScheduleItem.self,
            LocalInstallmentPayment.self,
            LedgerTransaction.self,
            LocalAccountMovement.self,
            LocalCategoryAllocation.self,
            LocalTransactionTag.self,
            LocalSplitPayment.self,
            LocalSplitShare.self,
            LocalSettlement.self,
            OutboxMutation.self,
            AttachmentTransfer.self,
            SyncCursor.self,
            SyncConflict.self,
            BootstrapStagedEntity.self,
            configurations: configuration
        )
    }
}
