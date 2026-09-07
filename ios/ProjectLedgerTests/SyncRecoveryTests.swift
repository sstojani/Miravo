import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct SyncRecoveryTests {
    let fixtures = LedgerSyncActorTests()
    let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"
    let timestamp = "2026-09-07T08:00:00Z"

    @Test func serverDeletionClearsSameEntityQueueAndPreservesDependentWork() async throws {
        let container = try fixtures.makeContainer()
        let context = container.mainContext
        let tracker = LocalTracker(scopeKey: scope, name: "Local edit")
        tracker.serverVersion = 2
        context.insert(tracker)
        let first = try mutation(trackerID: tracker.id, sequence: 1, state: .conflicted)
        let later = try mutation(trackerID: tracker.id, sequence: 2)
        let unrelated = try mutation(trackerID: UUID(), sequence: 4, state: .failed)
        let account = LocalAccount(scopeKey: scope, trackerID: tracker.id, name: "Unsynced account", type: .cash, currencyCode: "ALL", currencyExponent: 2)
        context.insert(account)
        let child = OutboxMutation(scopeKey: scope, localSequence: 3, entityID: account.id, entityType: "account", command: "create", payloadJSON: try JSONEncoder().encode(fixtures.accountRepresentation(id: account.id, trackerID: tracker.id)))
        for row in [first, later, unrelated, child] { context.insert(row) }
        context.insert(try conflict(for: first, current: deletedTracker(tracker.id)))
        try context.save()
        let engine = LedgerSyncActor(modelContainer: container)
        try await engine.resolveKeepServer(scopeKey: scope, operationID: first.operationID)
        let verification = ModelContext(container)
        let remaining = try verification.fetch(FetchDescriptor<OutboxMutation>())
        #expect(Set(remaining.map(\.operationID)) == Set([unrelated.operationID, child.operationID]))
        #expect(remaining.first { $0.operationID == child.operationID }?.lastSafeErrorCode == "parent_unavailable")
        #expect(try verification.fetch(FetchDescriptor<LocalTracker>()).first?.deletedAt != nil)
        #expect(try verification.fetch(FetchDescriptor<LocalAccount>()).first?.deletedAt != nil)
        #expect(try verification.fetch(FetchDescriptor<SyncConflict>()).allSatisfy { $0.resolvedAt != nil })
        #expect(try await engine.diagnostics(scopeKey: scope).bootstrapRequired)
    }

    @Test func keepMineCannotRebaseOntoServerDeletion() async throws {
        let container = try fixtures.makeContainer()
        let row = try mutation(trackerID: UUID(), state: .conflicted)
        container.mainContext.insert(row)
        container.mainContext.insert(try conflict(for: row, current: deletedTracker(row.entityID)))
        try container.mainContext.save()
        let engine = LedgerSyncActor(modelContainer: container)
        await #expect(throws: SyncRecoveryError.serverDeletionCannotBeKept) {
            try await engine.resolveKeepMine(scopeKey: scope, operationID: row.operationID)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<OutboxMutation>()).first?.operationID == row.operationID)
        #expect(try await engine.diagnostics(scopeKey: scope).conflictCount == 1)
    }

    @Test func failedDiscardWaitsForCompleteBootstrapThenServerWins() async throws {
        let container = try fixtures.makeContainer()
        let tracker = LocalTracker(scopeKey: scope, name: "Unsynced edit")
        tracker.serverVersion = 1
        let row = try mutation(trackerID: tracker.id, state: .failed)
        container.mainContext.insert(tracker)
        container.mainContext.insert(row)
        try container.mainContext.save()
        let engine = LedgerSyncActor(modelContainer: container)
        try await engine.requestServerState(scopeKey: scope, operationID: row.operationID)
        #expect(try ModelContext(container).fetch(FetchDescriptor<OutboxMutation>()).count == 1)
        let current = fixtures.trackerRepresentation(id: tracker.id, name: "Server choice", version: 4)
        _ = try await engine.synchronize(authentication: fixtures.authentication(), transport: transport(bootstrap: [current]))
        let verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<OutboxMutation>()).isEmpty)
        #expect(try verification.fetch(FetchDescriptor<LocalTracker>()).first?.name == "Server choice")
        #expect(try await engine.diagnostics(scopeKey: scope).failedCount == 0)
    }

    @Test func interruptedRecoverySurvivesEngineRestartAndNeverPushesDiscardedWork() async throws {
        let container = try fixtures.makeContainer()
        let row = try mutation(trackerID: UUID(), state: .failed)
        let tracker = LocalTracker(id: row.entityID, scopeKey: scope, name: "Local edit")
        container.mainContext.insert(tracker)
        container.mainContext.insert(row)
        try container.mainContext.save()
        let engine = LedgerSyncActor(modelContainer: container)
        try await engine.requestServerState(scopeKey: scope, operationID: row.operationID)
        await #expect(throws: ScriptedTransportError.self) {
            _ = try await engine.synchronize(authentication: fixtures.authentication(), transport: ScriptedSyncTransport(pushResponses: [], pullResponses: [], bootstrapResponses: [], ackResponses: []))
        }
        let restarted = LedgerSyncActor(modelContainer: container)
        let diagnostics = try await restarted.diagnostics(scopeKey: scope)
        #expect(!diagnostics.isSyncing)
        #expect(diagnostics.failedCount == 1)
        #expect(try await restarted.failedOperations(scopeKey: scope).first?.awaitingServerState == true)
        let retry = transport(bootstrap: [])
        _ = try await restarted.synchronize(authentication: fixtures.authentication(), transport: retry)
        #expect(await retry.capturedPushRequests().isEmpty)
        #expect(try await restarted.diagnostics(scopeKey: scope).failedCount == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalTracker>()).first?.deletedAt != nil)
    }

    @Test func editsAddedAfterDiscardConfirmationArePreserved() async throws {
        let container = try fixtures.makeContainer()
        let row = try mutation(trackerID: UUID(), state: .failed)
        container.mainContext.insert(row)
        try container.mainContext.save()
        let engine = LedgerSyncActor(modelContainer: container)
        try await engine.requestServerState(scopeKey: scope, operationID: row.operationID)
        let editContext = ModelContext(container)
        editContext.insert(try mutation(trackerID: row.entityID, sequence: 2))
        try editContext.save()
        let snapshot = fixtures.trackerRepresentation(id: row.entityID, name: "Server", version: 3)
        _ = try await engine.synchronize(authentication: fixtures.authentication(), transport: transport(bootstrap: [snapshot]))
        let rows = try ModelContext(container).fetch(FetchDescriptor<OutboxMutation>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.serverStateRequestedAt == nil })
        #expect(rows.contains { $0.lastSafeErrorCode == "recovery_changed_locally" })
    }

    @Test func permanentFailureDoesNotRetryAndUnrelatedEntityStillPushes() async throws {
        let container = try fixtures.makeContainer()
        let failure = try mutation(trackerID: UUID(), state: .failed)
        failure.lastSafeErrorCode = "validation_error"
        let later = try mutation(trackerID: failure.entityID, sequence: 2)
        let other = try mutation(trackerID: UUID(), sequence: 3)
        for row in [failure, later, other] { container.mainContext.insert(row) }
        try ready(container)
        let engine = LedgerSyncActor(modelContainer: container)
        try await engine.retryFailed(scopeKey: scope)
        await #expect(throws: SyncRecoveryError.retryRequiresRepair) {
            try await engine.retryOperation(scopeKey: scope, operationID: failure.operationID)
        }
        let response = accepted(other, version: 2)
        let script = ScriptedSyncTransport(pushResponses: [response], pullResponses: [fixtures.emptyPull(cursor: "after"), fixtures.emptyPull(cursor: "after")], bootstrapResponses: [], ackResponses: [fixtures.ack(cursor: "after"), fixtures.ack(cursor: "after")])
        _ = try await engine.synchronize(authentication: fixtures.authentication(), transport: script)
        _ = try await engine.synchronize(authentication: fixtures.authentication(), transport: script)
        #expect(await script.capturedPushRequests().flatMap(\.operations).map(\.operationID) == [other.operationID])
        let rows = try ModelContext(container).fetch(FetchDescriptor<OutboxMutation>())
        #expect(rows.count == 2)
        #expect(rows.first { $0.operationID == failure.operationID }?.attemptCount == 0)
    }

    @Test func backoffOnEarlierMutationBlocksLaterSameEntityWork() async throws {
        let container = try fixtures.makeContainer()
        let first = try mutation(trackerID: UUID())
        first.nextAttemptAt = .distantFuture
        container.mainContext.insert(first)
        container.mainContext.insert(try mutation(trackerID: first.entityID, sequence: 2))
        try ready(container)
        let script = ScriptedSyncTransport(pushResponses: [], pullResponses: [fixtures.emptyPull(cursor: "after")], bootstrapResponses: [], ackResponses: [fixtures.ack(cursor: "after")])
        _ = try await LedgerSyncActor(modelContainer: container).synchronize(authentication: fixtures.authentication(), transport: script)
        #expect(await script.capturedPushRequests().isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<OutboxMutation>()).allSatisfy { $0.attemptCount == 0 })
    }

    @Test func missingBaseVersionRepairsWithNewIDAfterKnownRejection() async throws {
        let container = try fixtures.makeContainer()
        let row = try mutation(trackerID: UUID(), state: .failed)
        row.baseServerVersion = nil
        row.attemptCount = 1
        row.lastSafeErrorCode = "invalid_base_server_version"
        row.serverReceiptRecorded = true
        container.mainContext.insert(row)
        let tracker = LocalTracker(id: row.entityID, scopeKey: scope, name: "Local")
        container.mainContext.insert(tracker)
        try container.mainContext.save()
        let oldID = row.operationID
        let current = fixtures.trackerRepresentation(id: tracker.id, name: "Server", version: 3)
        // An interrupted push lets us inspect the repaired, durable request.
        let script = transport(bootstrap: [current])
        let engine = LedgerSyncActor(modelContainer: container)
        await #expect(throws: ScriptedTransportError.self) {
            _ = try await engine.synchronize(authentication: fixtures.authentication(), transport: script)
        }
        let sent = try #require(await script.capturedPushRequests().first?.operations.first)
        #expect(sent.operationID != oldID)
        #expect(sent.baseServerVersion == 3)
        #expect(sent.payload == (try JSONDecoder().decode(JSONValue.self, from: row.payloadJSON)))
        #expect(try await engine.diagnostics(scopeKey: scope).isSyncing == false)
    }

    @Test func bootstrapDoesNotFailTheUpdateWaitingForItsCreate() async throws {
        let container = try fixtures.makeContainer()
        let repository = LocalLedgerRepository(context: container.mainContext)
        _ = try repository.bootstrapDefaults(scopeKey: scope)
        let script = transport(bootstrap: [])
        let engine = LedgerSyncActor(modelContainer: container)
        await #expect(throws: ScriptedTransportError.self) {
            _ = try await engine.synchronize(authentication: fixtures.authentication(), transport: script)
        }
        let rows = try ModelContext(container).fetch(FetchDescriptor<OutboxMutation>())
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.state != .failed })
        let sent = await script.capturedPushRequests().flatMap(\.operations)
        #expect(sent.count == 1)
        #expect(sent.first?.entityType == "tracker")
        #expect(sent.first?.command == "create")
    }

    @Test func identicalConflictReplayStoresOnlyOneConflict() async throws {
        let container = try fixtures.makeContainer()
        let row = try mutation(trackerID: UUID())
        container.mainContext.insert(row)
        try container.mainContext.save()
        let engine = LedgerSyncActor(modelContainer: container)
        let current = deletedTracker(row.entityID)
        try await engine.rememberServerState(scopeKey: scope, key: row.recordKey, value: current)
        try await engine.rememberServerState(scopeKey: scope, key: row.recordKey, value: current)
        try await engine.saveOrRollback()
        #expect(try await engine.diagnostics(scopeKey: scope).conflictCount == 1)
    }

    @Test func repairRefusesUnsyncedWorkAndResetsOnlySyncMetadata() async throws {
        let container = try fixtures.makeContainer()
        let row = try mutation(trackerID: UUID(), state: .failed)
        container.mainContext.insert(row)
        try ready(container)
        let engine = LedgerSyncActor(modelContainer: container)
        await #expect(throws: SyncRecoveryError.unsynchronizedChangesRemain) {
            try await engine.repairSynchronization(scopeKey: scope)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<OutboxMutation>()).count == 1)
        let clean = try fixtures.makeContainer()
        let tracker = LocalTracker(scopeKey: scope, name: "Cached")
        clean.mainContext.insert(tracker)
        try ready(clean)
        let repair = LedgerSyncActor(modelContainer: clean)
        try await repair.repairSynchronization(scopeKey: scope)
        #expect(try ModelContext(clean).fetch(FetchDescriptor<LocalTracker>()).count == 1)
        #expect(try await repair.diagnostics(scopeKey: scope).bootstrapRequired)
    }

    @Test func oldTombstoneCannotOverwriteNewerLocalVersion() async throws {
        let container = try fixtures.makeContainer()
        let tracker = LocalTracker(scopeKey: scope, name: "Current")
        tracker.serverVersion = 8
        container.mainContext.insert(tracker)
        try container.mainContext.save()
        let engine = LedgerSyncActor(modelContainer: container)
        try await engine.applyTombstone(entityType: "tracker", entityID: tracker.id, changedAt: .now, version: 2, scopeKey: scope)
        try await engine.saveOrRollback()
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalTracker>()).first?.deletedAt == nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalTracker>()).first?.serverVersion == 8)
    }

    private func mutation(trackerID: UUID, sequence: Int64 = 1, state: LocalSyncState = .pending) throws -> OutboxMutation {
        let result = OutboxMutation(scopeKey: scope, localSequence: sequence, entityID: trackerID, entityType: "tracker", command: "update", payloadJSON: try JSONEncoder().encode(fixtures.trackerRepresentation(id: trackerID, name: "Local edit", version: 1)), baseServerVersion: 1)
        result.stateRaw = state.rawValue
        return result
    }

    private func conflict(for mutation: OutboxMutation, current: JSONValue) throws -> SyncConflict {
        SyncConflict(operationID: mutation.operationID, scopeKey: scope, entityType: "tracker", entityID: mutation.entityID, baseServerVersion: 1, currentJSON: try JSONEncoder().encode(current), proposedJSON: mutation.payloadJSON, safeErrorCode: "version_conflict")
    }

    private func deletedTracker(_ id: UUID) -> JSONValue {
        var fields = fixtures.trackerRepresentation(id: id, name: "Deleted", version: 4).objectValue ?? [:]
        fields["deleted_at"] = .string(timestamp)
        fields["archived_at"] = .string(timestamp)
        return .object(fields)
    }

    private func ready(_ container: ModelContainer) throws {
        let cursor = SyncCursor(scopeKey: scope)
        cursor.cursor = "before"
        cursor.bootstrapRequired = false
        container.mainContext.insert(cursor)
        try container.mainContext.save()
    }

    private func accepted(_ mutation: OutboxMutation, version: Int64) -> SyncPushResponse {
        SyncPushResponse(protocolVersion: 1, requestID: "test", results: [SyncOperationResult(operationID: mutation.operationID, status: .accepted, originalStatus: nil, replayed: false, entityType: mutation.entityType, entityID: mutation.entityID, serverVersion: version, representation: fixtures.trackerRepresentation(id: mutation.entityID, name: "Server", version: version), error: nil)])
    }

    private func transport(bootstrap: [JSONValue]) -> ScriptedSyncTransport {
        ScriptedSyncTransport(pushResponses: [], pullResponses: [fixtures.emptyPull(cursor: "after")], bootstrapResponses: [SyncBootstrapResponse(protocolVersion: 1, generatedAt: timestamp, cursor: "snapshot", bootstrapCursor: nil, hasMore: false, data: fixtures.bootstrapData(trackers: bootstrap))], ackResponses: [fixtures.ack(cursor: "after")])
    }
}
