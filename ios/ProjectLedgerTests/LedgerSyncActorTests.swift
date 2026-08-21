import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct LedgerSyncActorTests {
    private let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"

    @Test func acceptedPushClearsOnlyAcknowledgedOutboxOperationAndAdvancesCursor() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let trackerID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let operationID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let tracker = LocalTracker(id: trackerID, scopeKey: scope, name: "Offline tracker")
        context.insert(tracker)
        context.insert(
            OutboxMutation(
                operationID: operationID,
                scopeKey: scope,
                localSequence: 1,
                entityID: trackerID,
                entityType: "tracker",
                command: "create",
                payloadJSON: try JSONEncoder().encode(trackerRepresentation(
                    id: trackerID,
                    name: "Offline tracker",
                    version: 1
                ))
            )
        )
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before"
        cursor.bootstrapRequired = false
        context.insert(cursor)
        try context.save()

        let transport = ScriptedSyncTransport(
            pushResponses: [
                SyncPushResponse(
                    protocolVersion: 1,
                    requestID: "request-1",
                    results: [
                        SyncOperationResult(
                            operationID: operationID,
                            status: .accepted,
                            originalStatus: nil,
                            replayed: false,
                            entityType: "tracker",
                            entityID: trackerID,
                            serverVersion: 1,
                            representation: trackerRepresentation(
                                id: trackerID,
                                name: "Offline tracker",
                                version: 1
                            ),
                            error: nil
                        ),
                    ]
                ),
            ],
            pullResponses: [emptyPull(cursor: "after")],
            bootstrapResponses: [],
            ackResponses: [ack(cursor: "after")]
        )
        let engine = LedgerSyncActor(modelContainer: container)
        let summary = try await engine.synchronize(
            authentication: try authentication(),
            transport: transport
        )

        let verification = ModelContext(container)
        let trackers = try verification.fetch(FetchDescriptor<LocalTracker>())
        let outbox = try verification.fetch(FetchDescriptor<OutboxMutation>())
        let cursors = try verification.fetch(FetchDescriptor<SyncCursor>())
        let requests = await transport.capturedPushRequests()
        #expect(summary.pushedCount == 1)
        #expect(summary.acknowledged)
        #expect(outbox.isEmpty)
        #expect(trackers.first?.serverVersion == 1)
        #expect(trackers.first?.syncState == .synced)
        #expect(cursors.first?.cursor == "after")
        #expect(requests.first?.operations.first?.operationID == operationID)
        #expect(requests.first?.operations.first?.localSequence == 1)
    }

    @Test func versionConflictPreservesProposalAndKeepMineRebasesWithNewOperationID() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let trackerID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let operationID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        let tracker = LocalTracker(id: trackerID, scopeKey: scope, name: "My edit")
        tracker.serverVersion = 1
        context.insert(tracker)
        context.insert(
            OutboxMutation(
                operationID: operationID,
                scopeKey: scope,
                localSequence: 1,
                entityID: trackerID,
                entityType: "tracker",
                command: "update",
                payloadJSON: try JSONEncoder().encode(trackerRepresentation(
                    id: trackerID,
                    name: "My edit",
                    version: 1
                )),
                baseServerVersion: 1
            )
        )
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before"
        cursor.bootstrapRequired = false
        context.insert(cursor)
        try context.save()

        let current = trackerRepresentation(id: trackerID, name: "Server edit", version: 2)
        let transport = ScriptedSyncTransport(
            pushResponses: [
                SyncPushResponse(
                    protocolVersion: 1,
                    requestID: "request-2",
                    results: [
                        SyncOperationResult(
                            operationID: operationID,
                            status: .conflict,
                            originalStatus: nil,
                            replayed: false,
                            entityType: "tracker",
                            entityID: trackerID,
                            serverVersion: 2,
                            representation: current,
                            error: SyncWireError(
                                code: "version_conflict",
                                message: "Conflict",
                                details: nil
                            )
                        ),
                    ]
                ),
            ],
            pullResponses: [emptyPull(cursor: "after")],
            bootstrapResponses: [],
            ackResponses: [ack(cursor: "after")]
        )
        let engine = LedgerSyncActor(modelContainer: container)
        let summary = try await engine.synchronize(
            authentication: try authentication(),
            transport: transport
        )
        #expect(summary.conflictCount == 1)

        try await engine.resolveKeepMine(scopeKey: scope, operationID: operationID)

        let verification = ModelContext(container)
        let mutations = try verification.fetch(FetchDescriptor<OutboxMutation>())
        let conflicts = try verification.fetch(FetchDescriptor<SyncConflict>())
        let rebased = try #require(mutations.first)
        #expect(rebased.operationID != operationID)
        #expect(rebased.baseServerVersion == 2)
        #expect(rebased.state == .pending)
        #expect(conflicts.first?.resolvedAt != nil)
    }

    @Test func failedInstallmentMutationBlocksOnlyLaterCommandsForThatPlan() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let planID = UUID(uuidString: "51000000-0000-0000-0000-000000000005")!
        let failedID = UUID(uuidString: "52000000-0000-0000-0000-000000000005")!
        let blockedID = UUID(uuidString: "53000000-0000-0000-0000-000000000005")!
        let trackerID = UUID(uuidString: "54000000-0000-0000-0000-000000000005")!
        let trackerOperationID = UUID(
            uuidString: "55000000-0000-0000-0000-000000000005"
        )!
        let inertPayload = try JSONEncoder().encode(
            JSONValue.object(["id": .string(planID.uuidString.lowercased())])
        )
        let failed = OutboxMutation(
            operationID: failedID,
            scopeKey: scope,
            localSequence: 1,
            entityID: planID,
            entityType: LocalMutationEntity.installmentPlan.rawValue,
            command: LocalMutationCommand.recordPayment.rawValue,
            payloadJSON: inertPayload,
            baseServerVersion: 1
        )
        failed.stateRaw = LocalSyncState.failed.rawValue
        context.insert(failed)
        context.insert(
            OutboxMutation(
                operationID: blockedID,
                scopeKey: scope,
                localSequence: 2,
                entityID: planID,
                entityType: LocalMutationEntity.installmentPlan.rawValue,
                command: LocalMutationCommand.payoff.rawValue,
                payloadJSON: inertPayload,
                baseServerVersion: 1
            )
        )
        let tracker = LocalTracker(id: trackerID, scopeKey: scope, name: "Independent")
        context.insert(tracker)
        context.insert(
            OutboxMutation(
                operationID: trackerOperationID,
                scopeKey: scope,
                localSequence: 3,
                entityID: trackerID,
                entityType: LocalMutationEntity.tracker.rawValue,
                command: LocalMutationCommand.create.rawValue,
                payloadJSON: try JSONEncoder().encode(
                    trackerRepresentation(id: trackerID, name: "Independent", version: 1)
                )
            )
        )
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before"
        cursor.bootstrapRequired = false
        context.insert(cursor)
        try context.save()

        let trackerResult = trackerRepresentation(
            id: trackerID,
            name: "Independent",
            version: 1
        )
        let transport = ScriptedSyncTransport(
            pushResponses: [
                SyncPushResponse(
                    protocolVersion: 1,
                    requestID: "request-blocked-dependency",
                    results: [
                        SyncOperationResult(
                            operationID: trackerOperationID,
                            status: .accepted,
                            originalStatus: nil,
                            replayed: false,
                            entityType: LocalMutationEntity.tracker.rawValue,
                            entityID: trackerID,
                            serverVersion: 1,
                            representation: trackerResult,
                            error: nil
                        ),
                    ]
                ),
            ],
            pullResponses: [emptyPull(cursor: "after")],
            bootstrapResponses: [],
            ackResponses: [ack(cursor: "after")]
        )

        let summary = try await LedgerSyncActor(modelContainer: container).synchronize(
            authentication: try authentication(),
            transport: transport
        )

        let requests = await transport.capturedPushRequests()
        let remaining = try ModelContext(container).fetch(FetchDescriptor<OutboxMutation>())
        #expect(summary.pushedCount == 1)
        #expect(requests.count == 1)
        #expect(requests.first?.operations.map(\.operationID) == [trackerOperationID])
        #expect(remaining.first { $0.operationID == failedID }?.state == .failed)
        #expect(remaining.first { $0.operationID == blockedID }?.state == .pending)
    }

    @Test func rejectedInstallmentPaymentMarksItsLocalLedgerProjectionFailed() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let planID = UUID(uuidString: "56000000-0000-0000-0000-000000000005")!
        let trackerID = UUID(uuidString: "57000000-0000-0000-0000-000000000005")!
        let accountID = UUID(uuidString: "58000000-0000-0000-0000-000000000005")!
        let transactionID = UUID(uuidString: "59000000-0000-0000-0000-000000000005")!
        let operationID = UUID(uuidString: "5a000000-0000-0000-0000-000000000005")!
        let plan = LocalInstallmentPlan(
            id: planID,
            scopeKey: scope,
            trackerID: trackerID,
            name: "Laptop",
            accountID: accountID,
            categoryID: nil,
            principalMinor: 1_000,
            interestMinor: 0,
            feesMinor: 0,
            plannedTotalMinor: 1_000,
            currencyCode: "ALL",
            currencyExponent: 2,
            installmentCount: 2,
            plannedInstallmentMinor: 500,
            cadence: .monthly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: try #require(dateOnly("2026-08-31")),
            anchorDay: 31
        )
        plan.serverVersion = 1
        let transaction = LedgerTransaction(
            id: transactionID,
            scopeKey: scope,
            trackerID: trackerID,
            accountID: accountID,
            kind: .expense,
            money: try Money(minorUnits: 500, currencyCode: "ALL", exponent: 2),
            source: .installment,
            merchant: plan.name
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = InstallmentPlanMutationPayload(
            plan: plan,
            paymentID: UUID(),
            transactionID: transactionID,
            paymentAmountMinor: 500,
            occurredAt: transaction.occurredAt,
            extraPayment: true,
            confirmOverpayment: false,
            accountAmountMinor: 500,
            baseAmountMinor: 500,
            baseCurrency: "ALL",
            rateSnapshot: "1",
            rateSource: "identity",
            rateEffectiveAt: transaction.occurredAt
        )
        context.insert(plan)
        context.insert(transaction)
        context.insert(
            OutboxMutation(
                operationID: operationID,
                scopeKey: scope,
                localSequence: 1,
                entityID: planID,
                entityType: LocalMutationEntity.installmentPlan.rawValue,
                command: LocalMutationCommand.recordPayment.rawValue,
                payloadJSON: try encoder.encode(payload),
                baseServerVersion: 1
            )
        )
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before"
        cursor.bootstrapRequired = false
        context.insert(cursor)
        try context.save()

        let transport = ScriptedSyncTransport(
            pushResponses: [
                SyncPushResponse(
                    protocolVersion: 1,
                    requestID: "request-payment-rejected",
                    results: [
                        SyncOperationResult(
                            operationID: operationID,
                            status: .rejected,
                            originalStatus: nil,
                            replayed: false,
                            entityType: LocalMutationEntity.installmentPlan.rawValue,
                            entityID: planID,
                            serverVersion: nil,
                            representation: nil,
                            error: SyncWireError(
                                code: "overpayment_requires_confirmation",
                                message: "Confirmation required",
                                details: nil
                            )
                        ),
                    ]
                ),
            ],
            pullResponses: [emptyPull(cursor: "after")],
            bootstrapResponses: [],
            ackResponses: [ack(cursor: "after")]
        )

        _ = try await LedgerSyncActor(modelContainer: container).synchronize(
            authentication: try authentication(),
            transport: transport
        )

        let verification = ModelContext(container)
        let savedPlan = try #require(
            verification.fetch(FetchDescriptor<LocalInstallmentPlan>()).first
        )
        let savedTransaction = try #require(
            verification.fetch(FetchDescriptor<LedgerTransaction>()).first
        )
        let mutation = try #require(
            verification.fetch(FetchDescriptor<OutboxMutation>()).first
        )
        #expect(savedPlan.syncState == .failed)
        #expect(savedTransaction.syncState == .failed)
        #expect(mutation.state == .failed)
        #expect(mutation.lastSafeErrorCode == "overpayment_requires_confirmation")
    }

    @Test func fullBootstrapPreservesAnUnsentInstallmentProjectionAndItsSchedule() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let trackerID = UUID(uuidString: "5b000000-0000-0000-0000-000000000005")!
        let accountID = UUID(uuidString: "5c000000-0000-0000-0000-000000000005")!
        let planID = UUID(uuidString: "5d000000-0000-0000-0000-000000000005")!
        let itemID = UUID(uuidString: "5e000000-0000-0000-0000-000000000005")!
        let transactionID = UUID(uuidString: "5f000000-0000-0000-0000-000000000005")!
        let operationID = UUID(uuidString: "5f100000-0000-0000-0000-000000000005")!
        let startsOn = try #require(dateOnly("2026-08-31"))
        let tracker = LocalTracker(
            id: trackerID,
            scopeKey: scope,
            name: "Local tracker",
            syncState: .synced
        )
        tracker.serverVersion = 1
        let account = LocalAccount(
            id: accountID,
            scopeKey: scope,
            trackerID: trackerID,
            name: "Cash",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2,
            syncState: .synced
        )
        account.serverVersion = 1
        let plan = LocalInstallmentPlan(
            id: planID,
            scopeKey: scope,
            trackerID: trackerID,
            name: "Local laptop edit",
            accountID: accountID,
            categoryID: nil,
            principalMinor: 1_000,
            interestMinor: 0,
            feesMinor: 0,
            plannedTotalMinor: 1_000,
            currencyCode: "ALL",
            currencyExponent: 2,
            installmentCount: 2,
            plannedInstallmentMinor: 500,
            cadence: .monthly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: startsOn,
            anchorDay: 31
        )
        plan.serverVersion = 1
        let item = LocalInstallmentScheduleItem(
            id: itemID,
            scopeKey: scope,
            trackerID: trackerID,
            planID: planID,
            revisionNumber: 1,
            sequence: 1,
            originalDueOn: startsOn,
            dueOn: startsOn,
            plannedPrincipalMinor: 500,
            plannedInterestMinor: 0,
            plannedFeesMinor: 0,
            plannedTotalMinor: 500,
            paidMinor: 400,
            state: .partiallyPaid,
            serverVersion: 1
        )
        let projection = LedgerTransaction(
            id: transactionID,
            scopeKey: scope,
            trackerID: trackerID,
            accountID: accountID,
            kind: .expense,
            money: try Money(minorUnits: 400, currencyCode: "ALL", exponent: 2),
            source: .installment,
            merchant: plan.name
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = InstallmentPlanMutationPayload(
            plan: plan,
            paymentID: UUID(),
            transactionID: transactionID,
            scheduleItemID: itemID,
            paymentAmountMinor: 400,
            occurredAt: projection.occurredAt,
            extraPayment: false,
            confirmOverpayment: false,
            accountAmountMinor: 400,
            baseAmountMinor: 400,
            baseCurrency: "ALL",
            rateSnapshot: "1",
            rateSource: "identity",
            rateEffectiveAt: projection.occurredAt
        )
        let mutation = OutboxMutation(
            operationID: operationID,
            scopeKey: scope,
            localSequence: 1,
            entityID: planID,
            entityType: LocalMutationEntity.installmentPlan.rawValue,
            command: LocalMutationCommand.recordPayment.rawValue,
            payloadJSON: try encoder.encode(payload),
            baseServerVersion: 1
        )
        mutation.nextAttemptAt = .now.addingTimeInterval(3_600)
        context.insert(tracker)
        context.insert(account)
        context.insert(plan)
        context.insert(item)
        context.insert(projection)
        context.insert(mutation)
        try context.save()

        let transport = ScriptedSyncTransport(
            pushResponses: [],
            pullResponses: [emptyPull(cursor: "after-bootstrap")],
            bootstrapResponses: [
                SyncBootstrapResponse(
                    protocolVersion: 1,
                    generatedAt: timestamp,
                    cursor: "bootstrap-target",
                    bootstrapCursor: nil,
                    hasMore: false,
                    data: bootstrapData(
                        trackers: [trackerRepresentation(
                            id: trackerID,
                            name: "Server tracker",
                            version: 2
                        )],
                        accounts: [accountRepresentation(id: accountID, trackerID: trackerID)],
                        installmentPlans: [installmentPlanRepresentation(
                            id: planID,
                            trackerID: trackerID,
                            accountID: accountID,
                            paidMinor: 0
                        )],
                        installmentScheduleItems: [installmentItemRepresentation(
                            id: itemID,
                            trackerID: trackerID,
                            planID: planID,
                            paidMinor: 0,
                            state: "planned"
                        )]
                    )
                ),
            ],
            ackResponses: [ack(cursor: "after-bootstrap")]
        )

        _ = try await LedgerSyncActor(modelContainer: container).synchronize(
            authentication: try authentication(),
            transport: transport
        )

        let verification = ModelContext(container)
        let savedPlan = try #require(
            verification.fetch(FetchDescriptor<LocalInstallmentPlan>()).first
        )
        let savedItem = try #require(
            verification.fetch(FetchDescriptor<LocalInstallmentScheduleItem>()).first
        )
        #expect(savedPlan.name == "Local laptop edit")
        #expect(savedItem.paidMinor == 400)
        #expect(savedItem.state == .partiallyPaid)
        let macroSafeExpectation1: Bool = try evaluateExpectation {
            try verification.fetch(FetchDescriptor<LedgerTransaction>()).first?.id == transactionID
        }
        #expect(macroSafeExpectation1)
        let macroSafeExpectation2: Bool = try evaluateExpectation {
            try verification.fetch(FetchDescriptor<OutboxMutation>()).first?.operationID == operationID
        }
        #expect(macroSafeExpectation2)
    }

    @Test func bootstrapRejectsInvalidInstallmentSnapshotEvenWhenLocalPlanIsPreserved() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let trackerID = UUID(uuidString: "5b200000-0000-0000-0000-000000000005")!
        let accountID = UUID(uuidString: "5c200000-0000-0000-0000-000000000005")!
        let planID = UUID(uuidString: "5d200000-0000-0000-0000-000000000005")!
        let startsOn = try #require(dateOnly("2026-08-31"))
        let tracker = LocalTracker(
            id: trackerID,
            scopeKey: scope,
            name: "Local tracker",
            syncState: .synced
        )
        tracker.serverVersion = 1
        let account = LocalAccount(
            id: accountID,
            scopeKey: scope,
            trackerID: trackerID,
            name: "Cash",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2,
            syncState: .synced
        )
        account.serverVersion = 1
        let plan = LocalInstallmentPlan(
            id: planID,
            scopeKey: scope,
            trackerID: trackerID,
            name: "Pending local plan",
            accountID: accountID,
            categoryID: nil,
            principalMinor: 1_000,
            interestMinor: 0,
            feesMinor: 0,
            plannedTotalMinor: 1_000,
            currencyCode: "ALL",
            currencyExponent: 2,
            installmentCount: 2,
            plannedInstallmentMinor: 500,
            cadence: .monthly,
            timeZoneIdentifier: "Europe/Tirane",
            startsOn: startsOn,
            anchorDay: 31
        )
        plan.serverVersion = 1
        let mutation = OutboxMutation(
            operationID: UUID(),
            scopeKey: scope,
            localSequence: 1,
            entityID: planID,
            entityType: LocalMutationEntity.installmentPlan.rawValue,
            command: LocalMutationCommand.update.rawValue,
            payloadJSON: Data("{}".utf8),
            baseServerVersion: 1
        )
        mutation.nextAttemptAt = .now.addingTimeInterval(3_600)
        context.insert(tracker)
        context.insert(account)
        context.insert(plan)
        context.insert(mutation)
        try context.save()

        var invalidPlan = try #require(
            installmentPlanRepresentation(
                id: planID,
                trackerID: trackerID,
                accountID: accountID,
                paidMinor: 0
            ).objectValue
        )
        invalidPlan["planned_total_minor"] = .integer(999)
        let transport = ScriptedSyncTransport(
            pushResponses: [],
            pullResponses: [],
            bootstrapResponses: [
                SyncBootstrapResponse(
                    protocolVersion: 1,
                    generatedAt: timestamp,
                    cursor: "must-not-advance",
                    bootstrapCursor: nil,
                    hasMore: false,
                    data: bootstrapData(
                        trackers: [trackerRepresentation(
                            id: trackerID,
                            name: "Server tracker",
                            version: 2
                        )],
                        accounts: [accountRepresentation(id: accountID, trackerID: trackerID)],
                        installmentPlans: [.object(invalidPlan)]
                    )
                ),
            ],
            ackResponses: []
        )

        var didThrow = false
        do {
            _ = try await LedgerSyncActor(modelContainer: container).synchronize(
                authentication: try authentication(),
                transport: transport
            )
        } catch {
            didThrow = true
        }

        let verification = ModelContext(container)
        let savedPlan = try #require(
            verification.fetch(FetchDescriptor<LocalInstallmentPlan>()).first
        )
        let cursor = try #require(verification.fetch(FetchDescriptor<SyncCursor>()).first)
        #expect(didThrow)
        #expect(savedPlan.name == "Pending local plan")
        #expect(cursor.cursor == nil)
        #expect(cursor.bootstrapRequired)
    }

    @Test func paginatedBootstrapStagesThenAtomicallyPublishesAndPullsFromTargetCursor() async throws {
        let container = try makeContainer()
        let trackerID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        let accountID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
        let tagID = UUID(uuidString: "71000000-0000-0000-0000-000000000007")!
        let membershipID = UUID(uuidString: "72000000-0000-0000-0000-000000000007")!
        let transactionID = UUID(uuidString: "73000000-0000-0000-0000-000000000007")!
        let budgetID = UUID(uuidString: "74000000-0000-0000-0000-000000000007")!
        let recurringRuleID = UUID(uuidString: "75000000-0000-0000-0000-000000000007")!
        let occurrenceID = UUID(uuidString: "76000000-0000-0000-0000-000000000007")!
        let installmentPlanID = UUID(uuidString: "77000000-0000-0000-0000-000000000007")!
        let installmentItemID = UUID(uuidString: "78000000-0000-0000-0000-000000000007")!
        let installmentPaymentID = UUID(uuidString: "79000000-0000-0000-0000-000000000007")!
        let installmentTransactionID = UUID(
            uuidString: "7a000000-0000-0000-0000-000000000007"
        )!
        let transport = ScriptedSyncTransport(
            pushResponses: [],
            pullResponses: [emptyPull(cursor: "after-bootstrap")],
            bootstrapResponses: [
                SyncBootstrapResponse(
                    protocolVersion: 1,
                    generatedAt: timestamp,
                    cursor: "bootstrap-target",
                    bootstrapCursor: "page-2",
                    hasMore: true,
                    data: bootstrapData(trackers: [trackerRepresentation(
                        id: trackerID,
                        name: "Server tracker",
                        version: 3,
                        role: "editor"
                    )])
                ),
                SyncBootstrapResponse(
                    protocolVersion: 1,
                    generatedAt: timestamp,
                    cursor: "bootstrap-target",
                    bootstrapCursor: nil,
                    hasMore: false,
                    data: bootstrapData(
                        memberships: [membershipRepresentation(
                            id: membershipID,
                            trackerID: trackerID,
                            role: "editor"
                        )],
                        accounts: [accountRepresentation(
                            id: accountID,
                            trackerID: trackerID
                        )],
                        tags: [tagRepresentation(id: tagID, trackerID: trackerID)],
                        budgets: [budgetRepresentation(id: budgetID, trackerID: trackerID)],
                        recurringRules: [recurringRuleRepresentation(
                            id: recurringRuleID,
                            trackerID: trackerID,
                            accountID: accountID
                        )],
                        installmentPlans: [installmentPlanRepresentation(
                            id: installmentPlanID,
                            trackerID: trackerID,
                            accountID: accountID
                        )],
                        installmentScheduleItems: [installmentItemRepresentation(
                            id: installmentItemID,
                            trackerID: trackerID,
                            planID: installmentPlanID
                        )],
                        transactions: [
                            transactionRepresentation(
                                id: transactionID,
                                trackerID: trackerID,
                                accountID: accountID,
                                tagID: tagID
                            ),
                            installmentTransactionRepresentation(
                                id: installmentTransactionID,
                                trackerID: trackerID,
                                accountID: accountID
                            ),
                        ],
                        recurringOccurrences: [recurringOccurrenceRepresentation(
                            id: occurrenceID,
                            trackerID: trackerID,
                            ruleID: recurringRuleID
                        )],
                        installmentPayments: [installmentPaymentRepresentation(
                            id: installmentPaymentID,
                            trackerID: trackerID,
                            planID: installmentPlanID,
                            itemID: installmentItemID,
                            transactionID: installmentTransactionID
                        )]
                    )
                ),
            ],
            ackResponses: [ack(cursor: "after-bootstrap")]
        )
        let engine = LedgerSyncActor(modelContainer: container)
        let summary = try await engine.synchronize(
            authentication: try authentication(),
            transport: transport
        )

        let verification = ModelContext(container)
        let trackers = try verification.fetch(FetchDescriptor<LocalTracker>())
        let accounts = try verification.fetch(FetchDescriptor<LocalAccount>())
        let tags = try verification.fetch(FetchDescriptor<LocalTag>())
        let memberships = try verification.fetch(FetchDescriptor<LocalTrackerMembership>())
        let budgets = try verification.fetch(FetchDescriptor<LocalBudget>())
        let recurringRules = try verification.fetch(FetchDescriptor<LocalRecurringRule>())
        let occurrences = try verification.fetch(
            FetchDescriptor<LocalRecurringOccurrence>()
        )
        let installmentPlans = try verification.fetch(
            FetchDescriptor<LocalInstallmentPlan>()
        )
        let installmentItems = try verification.fetch(
            FetchDescriptor<LocalInstallmentScheduleItem>()
        )
        let installmentPayments = try verification.fetch(
            FetchDescriptor<LocalInstallmentPayment>()
        )
        let budgetThresholds = try verification.fetch(FetchDescriptor<LocalBudgetThreshold>())
        let tagLinks = try verification.fetch(FetchDescriptor<LocalTransactionTag>())
        let staged = try verification.fetch(FetchDescriptor<BootstrapStagedEntity>())
        let cursors = try verification.fetch(FetchDescriptor<SyncCursor>())
        let requestedCursors = await transport.capturedBootstrapCursors()
        #expect(summary.pulledCount == 0)
        #expect(trackers.first?.id == trackerID)
        #expect(accounts.first?.id == accountID)
        #expect(tags.first?.id == tagID)
        #expect(memberships.first?.role == .editor)
        #expect(budgets.first?.id == budgetID)
        #expect(budgets.first?.serverVersion == 1)
        #expect(budgetThresholds.map(\.percent).sorted() == [50, 80, 100])
        #expect(recurringRules.first?.id == recurringRuleID)
        #expect(recurringRules.first?.nextDueOn == dateOnly("2026-09-30"))
        #expect(occurrences.first?.id == occurrenceID)
        #expect(occurrences.first?.state == .skipped)
        #expect(installmentPlans.first?.id == installmentPlanID)
        #expect(installmentPlans.first?.plannedTotalMinor == 1_000)
        #expect(installmentItems.first?.id == installmentItemID)
        #expect(installmentItems.first?.state == .paid)
        #expect(installmentPayments.first?.id == installmentPaymentID)
        #expect(installmentPayments.first?.transactionID == installmentTransactionID)
        #expect(tagLinks.first?.transactionID == transactionID)
        #expect(tagLinks.first?.tagID == tagID)
        #expect(staged.isEmpty)
        #expect(cursors.first?.cursor == "after-bootstrap")
        #expect(cursors.first?.bootstrapRequired == false)
        #expect(requestedCursors == [nil, "page-2"])
    }

    @Test func invalidSecondPullChangeRollsBackFirstChangeAndCursorTogether() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let trackerID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        let accountID = UUID(uuidString: "91000000-0000-0000-0000-000000000009")!
        let tracker = LocalTracker(id: trackerID, scopeKey: scope, name: "Before")
        tracker.serverVersion = 1
        context.insert(tracker)
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before"
        cursor.bootstrapRequired = false
        context.insert(cursor)
        try context.save()

        var invalidAccount = try #require(
            accountRepresentation(id: accountID, trackerID: trackerID).objectValue
        )
        invalidAccount["type"] = .string("not-a-real-account-type")
        let transport = ScriptedSyncTransport(
            pushResponses: [],
            pullResponses: [
                SyncPullResponse(
                    protocolVersion: 1,
                    cursor: "must-not-commit",
                    hasMore: false,
                    changes: [
                        SyncChangeResponse(
                            sequence: 1,
                            entityType: "tracker",
                            entityID: trackerID,
                            trackerID: trackerID,
                            operation: "upsert",
                            version: 2,
                            changedAt: timestamp,
                            data: trackerRepresentation(
                                id: trackerID,
                                name: "Must roll back",
                                version: 2
                            )
                        ),
                        SyncChangeResponse(
                            sequence: 2,
                            entityType: "account",
                            entityID: accountID,
                            trackerID: trackerID,
                            operation: "upsert",
                            version: 1,
                            changedAt: timestamp,
                            data: .object(invalidAccount)
                        ),
                    ]
                ),
            ],
            bootstrapResponses: [],
            ackResponses: []
        )
        let engine = LedgerSyncActor(modelContainer: container)
        var didThrow = false
        do {
            _ = try await engine.synchronize(
                authentication: try authentication(),
                transport: transport
            )
        } catch {
            didThrow = true
        }

        let verification = ModelContext(container)
        let trackers = try verification.fetch(FetchDescriptor<LocalTracker>())
        let cursors = try verification.fetch(FetchDescriptor<SyncCursor>())
        #expect(didThrow)
        #expect(trackers.first?.name == "Before")
        #expect(trackers.first?.serverVersion == 1)
        #expect(cursors.first?.cursor == "before")
    }

    @Test func inconsistentRecurringScheduleIsRejectedWithoutAdvancingCursor() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let trackerID = UUID(uuidString: "93000000-0000-0000-0000-000000000009")!
        let accountID = UUID(uuidString: "94000000-0000-0000-0000-000000000009")!
        let ruleID = UUID(uuidString: "95000000-0000-0000-0000-000000000009")!
        let tracker = LocalTracker(id: trackerID, scopeKey: scope, name: "Recurring")
        tracker.serverVersion = 1
        let account = LocalAccount(
            id: accountID,
            scopeKey: scope,
            trackerID: trackerID,
            name: "Cash",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2,
            syncState: .synced
        )
        account.serverVersion = 1
        context.insert(tracker)
        context.insert(account)
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before"
        cursor.bootstrapRequired = false
        context.insert(cursor)
        try context.save()

        var invalidRule = try #require(
            recurringRuleRepresentation(
                id: ruleID,
                trackerID: trackerID,
                accountID: accountID
            ).objectValue
        )
        invalidRule["next_due_at"] = .string("2026-09-30T08:15:00Z")
        let transport = ScriptedSyncTransport(
            pushResponses: [],
            pullResponses: [
                SyncPullResponse(
                    protocolVersion: 1,
                    cursor: "must-not-commit",
                    hasMore: false,
                    changes: [
                        SyncChangeResponse(
                            sequence: 1,
                            entityType: "recurring_rule",
                            entityID: ruleID,
                            trackerID: trackerID,
                            operation: "upsert",
                            version: 2,
                            changedAt: timestamp,
                            data: .object(invalidRule)
                        ),
                    ]
                ),
            ],
            bootstrapResponses: [],
            ackResponses: []
        )
        let engine = LedgerSyncActor(modelContainer: container)

        var didThrow = false
        do {
            _ = try await engine.synchronize(
                authentication: try authentication(),
                transport: transport
            )
        } catch {
            didThrow = true
        }

        let verification = ModelContext(container)
        #expect(didThrow)
        let macroSafeExpectation3: Bool = try evaluateExpectation {
            try verification.fetch(FetchDescriptor<LocalRecurringRule>()).isEmpty
        }
        #expect(macroSafeExpectation3)
        let macroSafeExpectation4: Bool = try evaluateExpectation {
            try verification.fetch(FetchDescriptor<SyncCursor>()).first?.cursor == "before"
        }
        #expect(macroSafeExpectation4)
    }

    @Test func participantSplitAndSettlementPullApplyAtomically() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let trackerID = UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!
        let accountID = UUID(uuidString: "a2000000-0000-0000-0000-000000000002")!
        let payerID = UUID(uuidString: "a3000000-0000-0000-0000-000000000003")!
        let guestID = UUID(uuidString: "a4000000-0000-0000-0000-000000000004")!
        let transactionID = UUID(uuidString: "a5000000-0000-0000-0000-000000000005")!
        let settlementID = UUID(uuidString: "a6000000-0000-0000-0000-000000000006")!
        let tracker = LocalTracker(id: trackerID, scopeKey: scope, name: "Shared")
        tracker.serverVersion = 1
        let account = LocalAccount(
            id: accountID,
            scopeKey: scope,
            trackerID: trackerID,
            name: "Cash",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2,
            syncState: .synced
        )
        account.serverVersion = 1
        context.insert(tracker)
        context.insert(account)
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before"
        cursor.bootstrapRequired = false
        context.insert(cursor)
        try context.save()

        let changes = [
            SyncChangeResponse(
                sequence: 1,
                entityType: "participant",
                entityID: payerID,
                trackerID: trackerID,
                operation: "upsert",
                version: 1,
                changedAt: timestamp,
                data: participantRepresentation(
                    id: payerID,
                    trackerID: trackerID,
                    displayName: "Owner",
                    linked: true
                )
            ),
            SyncChangeResponse(
                sequence: 2,
                entityType: "participant",
                entityID: guestID,
                trackerID: trackerID,
                operation: "upsert",
                version: 1,
                changedAt: timestamp,
                data: participantRepresentation(
                    id: guestID,
                    trackerID: trackerID,
                    displayName: "Guest"
                )
            ),
            SyncChangeResponse(
                sequence: 3,
                entityType: "transaction",
                entityID: transactionID,
                trackerID: trackerID,
                operation: "upsert",
                version: 1,
                changedAt: timestamp,
                data: splitTransactionRepresentation(
                    id: transactionID,
                    trackerID: trackerID,
                    accountID: accountID,
                    payerID: payerID,
                    shareIDs: [payerID, guestID]
                )
            ),
            SyncChangeResponse(
                sequence: 4,
                entityType: "settlement",
                entityID: settlementID,
                trackerID: trackerID,
                operation: "upsert",
                version: 1,
                changedAt: timestamp,
                data: settlementRepresentation(
                    id: settlementID,
                    trackerID: trackerID,
                    fromID: guestID,
                    toID: payerID,
                    amountMinor: 100
                )
            ),
        ]
        let transport = ScriptedSyncTransport(
            pushResponses: [],
            pullResponses: [
                SyncPullResponse(
                    protocolVersion: 1,
                    cursor: "after-collaboration",
                    hasMore: false,
                    changes: changes
                ),
            ],
            bootstrapResponses: [],
            ackResponses: [ack(cursor: "after-collaboration")]
        )

        let summary = try await LedgerSyncActor(modelContainer: container).synchronize(
            authentication: try authentication(),
            transport: transport
        )

        let verification = ModelContext(container)
        #expect(summary.pulledCount == 4)
        let macroSafeExpectation5: Bool = try evaluateExpectation {
            try verification.fetch(FetchDescriptor<LocalParticipant>()).count == 2
        }
        #expect(macroSafeExpectation5)
        let macroSafeExpectation6: Bool = try evaluateExpectation {
            try verification.fetch(FetchDescriptor<LocalSplitPayment>()).count == 1
        }
        #expect(macroSafeExpectation6)
        let macroSafeExpectation7: Bool = try evaluateExpectation {
            try verification.fetch(FetchDescriptor<LocalSplitShare>()).count == 2
        }
        #expect(macroSafeExpectation7)
        let macroSafeExpectation8: Bool = try evaluateExpectation {
            try verification.fetch(FetchDescriptor<LocalSettlement>()).count == 1
        }
        #expect(macroSafeExpectation8)
        let macroSafeExpectation9: Bool = try evaluateExpectation {
            try verification.fetch(FetchDescriptor<SyncCursor>()).first?.cursor ==
                "after-collaboration"
        }
        #expect(macroSafeExpectation9)
    }

    @Test func attachmentMetadataPullNeverRequiresOrStoresServerStorageKey() async throws {
        let container = try makeContainer()
        let tracker = LocalTracker(
            scopeKey: scope,
            name: "Receipts",
            baseCurrencyCode: "ALL",
            baseCurrencyExponent: 2,
            syncState: .synced
        )
        tracker.serverVersion = 1
        let account = LocalAccount(
            scopeKey: scope,
            trackerID: tracker.id,
            name: "Cash",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2,
            syncState: .synced
        )
        account.serverVersion = 1
        let transaction = LedgerTransaction(
            scopeKey: scope,
            trackerID: tracker.id,
            accountID: account.id,
            kind: .expense,
            money: try Money(minorUnits: 1_250, currencyCode: "ALL", exponent: 2),
            syncState: .synced
        )
        transaction.serverVersion = 1
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before-attachment"
        cursor.bootstrapRequired = false
        container.mainContext.insert(tracker)
        container.mainContext.insert(account)
        container.mainContext.insert(transaction)
        container.mainContext.insert(cursor)
        try container.mainContext.save()
        let attachmentID = UUID()
        let change = SyncChangeResponse(
            sequence: 1,
            entityType: "attachment",
            entityID: attachmentID,
            trackerID: tracker.id,
            operation: "upsert",
            version: 2,
            changedAt: timestamp,
            data: attachmentRepresentation(
                id: attachmentID,
                trackerID: tracker.id,
                transactionID: transaction.id
            )
        )
        let transport = ScriptedSyncTransport(
            pushResponses: [],
            pullResponses: [
                SyncPullResponse(
                    protocolVersion: 1,
                    cursor: "after-attachment",
                    hasMore: false,
                    changes: [change]
                ),
            ],
            bootstrapResponses: [],
            ackResponses: [ack(cursor: "after-attachment")]
        )

        let summary = try await LedgerSyncActor(modelContainer: container).synchronize(
            authentication: try authentication(),
            transport: transport
        )

        let attachment = try #require(
            ModelContext(container).fetch(FetchDescriptor<LocalAttachment>()).first
        )
        #expect(summary.pulledCount == 1)
        #expect(attachment.id == attachmentID)
        #expect(attachment.transactionID == transaction.id)
        #expect(attachment.uploadState == .ready)
        #expect(attachment.serverVersion == 2)
    }

    @Test func authorizationFailureRotatesKeychainTokensOnceThenRetries() async throws {
        let container = try makeContainer()
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before"
        cursor.bootstrapRequired = false
        container.mainContext.insert(cursor)
        try container.mainContext.save()
        let store = KeychainSessionTokenStore(
            service: "ProjectLedgerTests.\(UUID().uuidString)"
        )
        let refreshed = SessionTokenBundle(
            accessToken: "new-access",
            accessTokenExpiresAt: timestamp,
            refreshToken: "new-refresh",
            refreshTokenExpiresAt: timestamp,
            tokenType: "Bearer",
            sessionID: UUID(uuidString: "92000000-0000-0000-0000-000000000009")!
        )
        let transport = RefreshingSyncTransport(refreshed: refreshed, timestamp: timestamp)
        let engine = LedgerSyncActor(modelContainer: container)

        let summary = try await engine.synchronize(
            authentication: try authentication(tokenStore: store),
            transport: transport
        )

        #expect(summary.acknowledged)
        let macroSafeExpectation10: Bool = try await evaluateExpectation {
            try await store.load(scopeKey: scope) == refreshed
        }
        #expect(macroSafeExpectation10)
        #expect(await transport.refreshCount() == 1)
        #expect(await transport.pullCount() == 2)
        try await store.delete(scopeKey: scope)
    }

    private var timestamp: String { "2026-08-09T12:30:00Z" }

    private func authentication(
        tokenStore: KeychainSessionTokenStore? = nil
    ) throws -> SyncAuthenticationContext {
        SyncAuthenticationContext(
            scopeKey: scope,
            baseURL: try #require(URL(string: "https://ledger.example")),
            tokens: SessionTokenBundle(
                accessToken: "access",
                accessTokenExpiresAt: timestamp,
                refreshToken: "refresh",
                refreshTokenExpiresAt: timestamp,
                tokenType: "Bearer",
                sessionID: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!
            ),
            tokenStore: tokenStore ?? KeychainSessionTokenStore(
                service: "ProjectLedgerTests.\(UUID().uuidString)"
            )
        )
    }

    private func trackerRepresentation(
        id: UUID,
        name: String,
        version: Int64,
        role: String = "owner"
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "role": .string(role),
            "name": .string(name),
            "description": .string(""),
            "icon": .string("wallet.pass"),
            "color": .string("#3663F5"),
            "base_currency": .string("ALL"),
            "base_currency_exponent": .integer(2),
            "sort_order": .integer(0),
            "default_account_id": .null,
            "default_category_id": .null,
            "archived_at": .null,
            "version": .integer(version),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func accountRepresentation(id: UUID, trackerID: UUID) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "name": .string("Cash"),
            "type": .string("cash"),
            "currency": .string("ALL"),
            "currency_exponent": .integer(2),
            "opening_balance_minor": .integer(0),
            "opening_date": .string("2026-08-09"),
            "color": .string("#3663F5"),
            "icon": .string("banknote"),
            "include_in_net_worth": .bool(true),
            "credit_limit_minor": .null,
            "archived_at": .null,
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func membershipRepresentation(
        id: UUID,
        trackerID: UUID,
        role: String
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "user_id": .string("10000000-0000-0000-0000-000000000001"),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "email": .string("owner@example.com"),
            "role": .string(role),
            "state": .string("active"),
            "joined_at": .string(timestamp),
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func participantRepresentation(
        id: UUID,
        trackerID: UUID,
        displayName: String,
        linked: Bool = false
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "linked_user_id": linked
                ? .string("10000000-0000-0000-0000-000000000001") : .null,
            "linked_email": linked ? .string("owner@example.com") : .null,
            "display_name": .string(displayName),
            "archived_at": .null,
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func tagRepresentation(id: UUID, trackerID: UUID) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "name": .string("Trip"),
            "color": .string("#73819B"),
            "archived_at": .null,
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func budgetRepresentation(id: UUID, trackerID: UUID) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "name": .string("Monthly spending"),
            "scope": .string("tracker"),
            "period": .string("monthly"),
            "amount_minor": .integer(25_000),
            "currency": .string("ALL"),
            "currency_exponent": .integer(2),
            "time_zone": .string("Europe/Tirane"),
            "starts_on": .string("2026-08-01"),
            "ends_on": .null,
            "rollover": .bool(true),
            "category_ids": .array([]),
            "category_snapshots": .array([]),
            "threshold_percentages": .array([.integer(50), .integer(80), .integer(100)]),
            "archived_at": .null,
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func recurringRuleRepresentation(
        id: UUID,
        trackerID: UUID,
        accountID: UUID
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "name": .string("Music"),
            "kind": .string("expense"),
            "is_subscription": .bool(true),
            "amount_minor": .integer(999),
            "currency": .string("ALL"),
            "currency_exponent": .integer(2),
            "account_id": .string(accountID.uuidString.lowercased()),
            "account_amount_minor": .integer(999),
            "category_id": .null,
            "merchant": .string(""),
            "note": .string(""),
            "base_amount_minor": .integer(999),
            "base_currency": .string("ALL"),
            "rate_snapshot": .string("1.000000000000"),
            "rate_source": .string("identity"),
            "rate_effective_at": .string(timestamp),
            "cadence": .string("monthly"),
            "custom_interval_unit": .string(""),
            "custom_interval_count": .integer(1),
            "time_zone": .string("Europe/Tirane"),
            "starts_on": .string("2026-08-31"),
            "ends_on": .null,
            "local_time": .string("09:15:00"),
            "next_due_on": .string("2026-09-30"),
            "next_due_at": .string("2026-09-30T07:15:00Z"),
            "state": .string("active"),
            "paused_at": .null,
            "ended_at": .null,
            "subscription_provider": .string("Example Music"),
            "trial_ends_on": .null,
            "cancellation_url": .string("https://example.com/cancel"),
            "subscription_note": .string(""),
            "archived_at": .null,
            "version": .integer(2),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func recurringOccurrenceRepresentation(
        id: UUID,
        trackerID: UUID,
        ruleID: UUID
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "rule_id": .string(ruleID.uuidString.lowercased()),
            "occurrence_key": .string(
                "be775a3d4e64436b4a1240088e5cbcf4b5e18d46360ee1fcd77ae39ba93fe735"
            ),
            "due_on": .string("2026-08-31"),
            "scheduled_for": .string("2026-08-31T07:15:00Z"),
            "rule_version": .integer(1),
            "state": .string("skipped"),
            "transaction_id": .null,
            "materialized_at": .null,
            "skipped_at": .string(timestamp),
            "error_code": .string(""),
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
        ])
    }

    private func installmentPlanRepresentation(
        id: UUID,
        trackerID: UUID,
        accountID: UUID,
        paidMinor: Int64 = 500
    ) -> JSONValue {
        let remainingMinor = 1_000 - paidMinor
        return .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "name": .string("Laptop"),
            "account_id": .string(accountID.uuidString.lowercased()),
            "category_id": .null,
            "principal_minor": .integer(1_000),
            "interest_minor": .integer(0),
            "fees_minor": .integer(0),
            "planned_total_minor": .integer(1_000),
            "currency": .string("ALL"),
            "currency_exponent": .integer(2),
            "installment_count": .integer(2),
            "planned_installment_minor": .integer(500),
            "cadence": .string("monthly"),
            "time_zone": .string("Europe/Tirane"),
            "starts_on": .string("2026-08-31"),
            "anchor_day": .integer(31),
            "state": .string("active"),
            "revision_number": .integer(1),
            "paid_off_at": .null,
            "cancelled_at": .null,
            "archived_at": .null,
            "progress": .object([
                "planned_total_minor": .integer(1_000),
                "paid_minor": .integer(paidMinor),
                "remaining_minor": .integer(remainingMinor),
                "next_due_on": remainingMinor > 0
                    ? .string(paidMinor == 0 ? "2026-08-31" : "2026-09-30") : .null,
                "estimated_payoff_on": remainingMinor > 0
                    ? .string("2026-09-30") : .null,
            ]),
            "version": .integer(2),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func installmentItemRepresentation(
        id: UUID,
        trackerID: UUID,
        planID: UUID,
        paidMinor: Int64 = 500,
        state: String = "paid"
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "plan_id": .string(planID.uuidString.lowercased()),
            "revision_number": .integer(1),
            "sequence": .integer(1),
            "original_due_on": .string("2026-08-31"),
            "due_on": .string("2026-08-31"),
            "planned_principal_minor": .integer(500),
            "planned_interest_minor": .integer(0),
            "planned_fees_minor": .integer(0),
            "planned_total_minor": .integer(500),
            "paid_minor": .integer(paidMinor),
            "state": .string(state),
            "skipped_at": .null,
            "superseded_at": .null,
            "version": .integer(2),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func installmentPaymentRepresentation(
        id: UUID,
        trackerID: UUID,
        planID: UUID,
        itemID: UUID,
        transactionID: UUID
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "plan_id": .string(planID.uuidString.lowercased()),
            "schedule_item_id": .string(itemID.uuidString.lowercased()),
            "transaction_id": .string(transactionID.uuidString.lowercased()),
            "amount_minor": .integer(500),
            "applied_amount_minor": .integer(500),
            "overpayment_minor": .integer(0),
            "extra_payment": .bool(false),
            "applied_at": .string(timestamp),
            "created_by_id": .string("10000000-0000-0000-0000-000000000001"),
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func installmentTransactionRepresentation(
        id: UUID,
        trackerID: UUID,
        accountID: UUID
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "kind": .string("expense"),
            "source": .string("installment"),
            "status": .string("posted"),
            "amount_minor": .integer(500),
            "currency": .string("ALL"),
            "currency_exponent": .integer(2),
            "base_amount_minor": .integer(500),
            "base_currency": .string("ALL"),
            "rate_snapshot": .string("1.000000000000"),
            "rate_source": .string("identity"),
            "rate_effective_at": .string(timestamp),
            "merchant": .string("Laptop"),
            "payee": .string(""),
            "note": .string(""),
            "occurred_at": .string(timestamp),
            "captured_at": .string(timestamp),
            "external_event_id": .null,
            "refund_of_id": .null,
            "movements": .array([.object([
                "id": .string(UUID().uuidString.lowercased()),
                "account_id": .string(accountID.uuidString.lowercased()),
                "signed_amount_minor": .integer(-500),
                "currency": .string("ALL"),
                "currency_exponent": .integer(2),
                "conversion_rate": .null,
            ])]),
            "allocations": .array([]),
            "tag_ids": .array([]),
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func transactionRepresentation(
        id: UUID,
        trackerID: UUID,
        accountID: UUID,
        tagID: UUID
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "kind": .string("expense"),
            "source": .string("manual"),
            "status": .string("posted"),
            "amount_minor": .integer(500),
            "currency": .string("ALL"),
            "currency_exponent": .integer(2),
            "base_amount_minor": .integer(500),
            "base_currency": .string("ALL"),
            "rate_snapshot": .string("1.000000000000"),
            "rate_source": .string("identity"),
            "rate_effective_at": .string(timestamp),
            "merchant": .string("Train"),
            "payee": .string(""),
            "note": .string(""),
            "occurred_at": .string(timestamp),
            "captured_at": .string(timestamp),
            "external_event_id": .null,
            "refund_of_id": .null,
            "movements": .array([.object([
                "id": .string(UUID().uuidString.lowercased()),
                "account_id": .string(accountID.uuidString.lowercased()),
                "signed_amount_minor": .integer(-500),
                "currency": .string("ALL"),
                "currency_exponent": .integer(2),
                "conversion_rate": .null,
            ])]),
            "allocations": .array([]),
            "tag_ids": .array([.string(tagID.uuidString.lowercased())]),
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func splitTransactionRepresentation(
        id: UUID,
        trackerID: UUID,
        accountID: UUID,
        payerID: UUID,
        shareIDs: [UUID]
    ) -> JSONValue {
        let paymentID = UUID(uuidString: "b1000000-0000-0000-0000-000000000001")!
        let shareAID = UUID(uuidString: "b2000000-0000-0000-0000-000000000002")!
        let shareBID = UUID(uuidString: "b3000000-0000-0000-0000-000000000003")!
        return .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "kind": .string("expense"),
            "source": .string("manual"),
            "status": .string("posted"),
            "amount_minor": .integer(500),
            "currency": .string("ALL"),
            "currency_exponent": .integer(2),
            "base_amount_minor": .integer(500),
            "base_currency": .string("ALL"),
            "rate_snapshot": .string("1.000000000000"),
            "rate_source": .string("identity"),
            "rate_effective_at": .string(timestamp),
            "merchant": .string("Dinner"),
            "payee": .string(""),
            "note": .string(""),
            "occurred_at": .string(timestamp),
            "captured_at": .string(timestamp),
            "external_event_id": .null,
            "refund_of_id": .null,
            "movements": .array([.object([
                "id": .string(UUID().uuidString.lowercased()),
                "account_id": .string(accountID.uuidString.lowercased()),
                "signed_amount_minor": .integer(-500),
                "currency": .string("ALL"),
                "currency_exponent": .integer(2),
                "conversion_rate": .null,
            ])]),
            "allocations": .array([]),
            "tag_ids": .array([]),
            "split": .object([
                "method": .string("equal"),
                "payments": .array([.object([
                    "id": .string(paymentID.uuidString.lowercased()),
                    "participant_id": .string(payerID.uuidString.lowercased()),
                    "amount_minor": .integer(500),
                    "version": .integer(1),
                ])]),
                "shares": .array([
                    .object([
                        "id": .string(shareAID.uuidString.lowercased()),
                        "participant_id": .string(shareIDs[0].uuidString.lowercased()),
                        "amount_minor": .integer(250),
                        "method": .string("equal"),
                        "percentage_basis_points": .null,
                        "version": .integer(1),
                    ]),
                    .object([
                        "id": .string(shareBID.uuidString.lowercased()),
                        "participant_id": .string(shareIDs[1].uuidString.lowercased()),
                        "amount_minor": .integer(250),
                        "method": .string("equal"),
                        "percentage_basis_points": .null,
                        "version": .integer(1),
                    ]),
                ]),
                "total_paid_minor": .integer(500),
                "total_owed_minor": .integer(500),
            ]),
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func settlementRepresentation(
        id: UUID,
        trackerID: UUID,
        fromID: UUID,
        toID: UUID,
        amountMinor: Int64
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "from_participant_id": .string(fromID.uuidString.lowercased()),
            "to_participant_id": .string(toID.uuidString.lowercased()),
            "amount_minor": .integer(amountMinor),
            "currency": .string("ALL"),
            "currency_exponent": .integer(2),
            "occurred_at": .string(timestamp),
            "note": .string("Partial"),
            "transaction_id": .null,
            "created_by_id": .string("10000000-0000-0000-0000-000000000001"),
            "last_editor_id": .string("10000000-0000-0000-0000-000000000001"),
            "version": .integer(1),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func attachmentRepresentation(
        id: UUID,
        trackerID: UUID,
        transactionID: UUID
    ) -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "tracker_id": .string(trackerID.uuidString.lowercased()),
            "transaction_id": .string(transactionID.uuidString.lowercased()),
            "created_by_id": .string("10000000-0000-0000-0000-000000000001"),
            "last_editor_id": .string("10000000-0000-0000-0000-000000000001"),
            "original_filename": .string("receipt.png"),
            "content_type": .string("image/png"),
            "byte_count": .integer(28),
            "checksum_sha256": .string(String(repeating: "a", count: 64)),
            "upload_state": .string("ready"),
            "scan_status": .string("not_configured"),
            "original_retained": .bool(true),
            "uploaded_at": .string(timestamp),
            "version": .integer(2),
            "created_at": .string(timestamp),
            "updated_at": .string(timestamp),
            "deleted_at": .null,
        ])
    }

    private func bootstrapData(
        trackers: [JSONValue] = [],
        memberships: [JSONValue] = [],
        participants: [JSONValue] = [],
        accounts: [JSONValue] = [],
        tags: [JSONValue] = [],
        budgets: [JSONValue] = [],
        recurringRules: [JSONValue] = [],
        installmentPlans: [JSONValue] = [],
        installmentScheduleItems: [JSONValue] = [],
        transactions: [JSONValue] = [],
        attachments: [JSONValue] = [],
        settlements: [JSONValue] = [],
        recurringOccurrences: [JSONValue] = [],
        installmentPayments: [JSONValue] = []
    ) -> JSONValue {
        .object([
            "trackers": .array(trackers),
            "memberships": .array(memberships),
            "participants": .array(participants),
            "accounts": .array(accounts),
            "categories": .array([]),
            "tags": .array(tags),
            "merchants": .array([]),
            "budgets": .array(budgets),
            "recurring_rules": .array(recurringRules),
            "installment_plans": .array(installmentPlans),
            "installment_schedule_items": .array(installmentScheduleItems),
            "transactions": .array(transactions),
            "attachments": .array(attachments),
            "settlements": .array(settlements),
            "recurring_occurrences": .array(recurringOccurrences),
            "installment_payments": .array(installmentPayments),
        ])
    }

    private func dateOnly(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func emptyPull(cursor: String) -> SyncPullResponse {
        SyncPullResponse(protocolVersion: 1, cursor: cursor, hasMore: false, changes: [])
    }

    private func ack(cursor: String) -> SyncAckResponse {
        SyncAckResponse(protocolVersion: 1, cursor: cursor, acknowledgedAt: timestamp)
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
            LocalAttachment.self,
            OutboxMutation.self,
            AttachmentTransfer.self,
            SyncCursor.self,
            SyncConflict.self,
            BootstrapStagedEntity.self,
            configurations: configuration
        )
    }
}

private enum ScriptedTransportError: Error {
    case unexpectedCall
}

private actor ScriptedSyncTransport: SyncTransport {
    private var pushResponses: [SyncPushResponse]
    private var pullResponses: [SyncPullResponse]
    private var bootstrapResponses: [SyncBootstrapResponse]
    private var ackResponses: [SyncAckResponse]
    private var pushes: [SyncPushRequest] = []
    private var bootstrapCursors: [String?] = []

    init(
        pushResponses: [SyncPushResponse],
        pullResponses: [SyncPullResponse],
        bootstrapResponses: [SyncBootstrapResponse],
        ackResponses: [SyncAckResponse]
    ) {
        self.pushResponses = pushResponses
        self.pullResponses = pullResponses
        self.bootstrapResponses = bootstrapResponses
        self.ackResponses = ackResponses
    }

    func refresh(refreshToken: String) async throws -> SessionTokenBundle {
        throw ScriptedTransportError.unexpectedCall
    }

    func push(
        _ payload: SyncPushRequest,
        accessToken: String
    ) async throws -> SyncPushResponse {
        pushes.append(payload)
        guard !pushResponses.isEmpty else { throw ScriptedTransportError.unexpectedCall }
        return pushResponses.removeFirst()
    }

    func pull(
        cursor: String?,
        limit: Int,
        accessToken: String
    ) async throws -> SyncPullResponse {
        guard !pullResponses.isEmpty else { throw ScriptedTransportError.unexpectedCall }
        return pullResponses.removeFirst()
    }

    func bootstrap(
        cursor: String?,
        limit: Int,
        accessToken: String
    ) async throws -> SyncBootstrapResponse {
        bootstrapCursors.append(cursor)
        guard !bootstrapResponses.isEmpty else { throw ScriptedTransportError.unexpectedCall }
        return bootstrapResponses.removeFirst()
    }

    func acknowledge(cursor: String, accessToken: String) async throws -> SyncAckResponse {
        guard !ackResponses.isEmpty else { throw ScriptedTransportError.unexpectedCall }
        return ackResponses.removeFirst()
    }

    func capturedPushRequests() -> [SyncPushRequest] { pushes }
    func capturedBootstrapCursors() -> [String?] { bootstrapCursors }
}

private actor RefreshingSyncTransport: SyncTransport {
    private let refreshed: SessionTokenBundle
    private let timestamp: String
    private var refreshCalls = 0
    private var pullCalls = 0

    init(refreshed: SessionTokenBundle, timestamp: String) {
        self.refreshed = refreshed
        self.timestamp = timestamp
    }

    func refresh(refreshToken: String) async throws -> SessionTokenBundle {
        refreshCalls += 1
        return refreshed
    }

    func push(
        _ payload: SyncPushRequest,
        accessToken: String
    ) async throws -> SyncPushResponse {
        throw ScriptedTransportError.unexpectedCall
    }

    func pull(
        cursor: String?,
        limit: Int,
        accessToken: String
    ) async throws -> SyncPullResponse {
        pullCalls += 1
        if pullCalls == 1 {
            throw APIClientError(
                code: "invalid_access_token",
                message: "Expired",
                requestID: "request-refresh",
                statusCode: 401
            )
        }
        return SyncPullResponse(
            protocolVersion: 1,
            cursor: "after-refresh",
            hasMore: false,
            changes: []
        )
    }

    func bootstrap(
        cursor: String?,
        limit: Int,
        accessToken: String
    ) async throws -> SyncBootstrapResponse {
        throw ScriptedTransportError.unexpectedCall
    }

    func acknowledge(cursor: String, accessToken: String) async throws -> SyncAckResponse {
        SyncAckResponse(
            protocolVersion: 1,
            cursor: cursor,
            acknowledgedAt: timestamp
        )
    }

    func refreshCount() -> Int { refreshCalls }
    func pullCount() -> Int { pullCalls }
}
