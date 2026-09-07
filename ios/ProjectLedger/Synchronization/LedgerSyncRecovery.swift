import Foundation
import SwiftData

extension LedgerSyncActor {
    func failedOperations(scopeKey: String) throws -> [FailedOperationSnapshot] {
        let outbox = try fetchOutbox(scopeKey: scopeKey)
        let inventory = try SyncLocalInventory(context: modelContext, scopeKey: scopeKey)
        var sameEntityCounts: [SyncRecordKey: Int] = [:]
        for mutation in outbox {
            sameEntityCounts[mutation.recordKey, default: 0] += 1
        }
        return outbox.filter { $0.state == .failed || $0.serverStateRequestedAt != nil }.map { mutation in
            let current = mutation.serverSnapshotJSON.flatMap {
                try? JSONDecoder().decode(JSONValue.self, from: $0)
            }
            let deleted = current.map(SyncRecoveryPolicy.isDeleted) ?? false
            return FailedOperationSnapshot(
                id: mutation.operationID,
                entityType: SyncRecoveryPolicy.safeCode(mutation.entityType),
                entityID: mutation.entityID,
                command: SyncRecoveryPolicy.safeCode(mutation.command),
                localSequence: mutation.localSequence,
                state: SyncRecoveryPolicy.safeCode(mutation.stateRaw),
                safeErrorCode: SyncRecoveryPolicy.safeCode(mutation.lastSafeErrorCode),
                baseServerVersion: mutation.baseServerVersion,
                attemptCount: mutation.attemptCount,
                createdAt: mutation.createdAt,
                updatedAt: mutation.updatedAt,
                existsLocally: inventory.records[mutation.recordKey] != nil,
                serverDeleted: deleted,
                serverMissing: mutation.serverSnapshotMissing,
                canRetry: canRetry(mutation),
                awaitingServerState: mutation.serverStateRequestedAt != nil,
                sameEntityOperationCount: sameEntityCounts[mutation.recordKey, default: 0]
            )
        }
    }

    func canRetry(_ mutation: OutboxMutation) -> Bool {
        guard mutation.state == .failed,
              mutation.serverStateRequestedAt == nil,
              !mutation.serverSnapshotMissing,
              SyncRecoveryPolicy.canRetry(code: mutation.lastSafeErrorCode),
              (mutation.command == "create") == (mutation.baseServerVersion == nil),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: mutation.payloadJSON),
              payload.objectValue != nil
        else { return false }
        if let data = mutation.serverSnapshotJSON,
           let current = try? JSONDecoder().decode(JSONValue.self, from: data),
           SyncRecoveryPolicy.isDeleted(current) { return false }
        return true
    }

    func retryOperation(scopeKey: String, operationID: UUID) throws {
        try requireIdle(scopeKey: scopeKey)
        guard let mutation = try fetchOutbox(scopeKey: scopeKey).first(where: { $0.operationID == operationID }),
              canRetry(mutation)
        else { throw SyncRecoveryError.retryRequiresRepair }
        try prepareRetry(mutation, scopeKey: scopeKey)
        try saveOrRollback()
    }

    func prepareRetry(_ mutation: OutboxMutation, scopeKey: String) throws {
        // A definitive rejected receipt would replay forever. Unknown transport outcomes retain their ID.
        if mutation.serverReceiptRecorded { mutation.operationID = UUID() }
        mutation.serverReceiptRecorded = false
        mutation.stateRaw = LocalSyncState.pending.rawValue
        mutation.nextAttemptAt = nil
        mutation.lastSafeErrorCode = nil
        mutation.updatedAt = .now
        try markEntityState(scopeKey: scopeKey, entityType: mutation.entityType, entityID: mutation.entityID, state: .pending, serverVersion: nil)
        try markInstallmentProjection(scopeKey: scopeKey, mutation: mutation, state: .pending)
        try markSettlementProjection(scopeKey: scopeKey, mutation: mutation, state: .pending)
    }

    func requireIdle(scopeKey: String) throws {
        if try cursorState(scopeKey: scopeKey).isSyncing { throw SyncRecoveryError.syncInProgress }
    }

    func requestServerState(scopeKey: String, operationID: UUID) throws {
        try requireIdle(scopeKey: scopeKey)
        let outbox = try fetchOutbox(scopeKey: scopeKey)
        guard let selected = outbox.first(where: { $0.operationID == operationID }),
              selected.state == .failed || selected.state == .conflicted
        else { throw SyncRecoveryError.operationChanged }
        do {
            // Confirmed scope is this entity's existing queue, never future edits or other entities.
            for mutation in outbox where mutation.recordKey == selected.recordKey {
                mutation.serverStateRequestedAt = .now
            }
            try resetBootstrap(scopeKey: scopeKey)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func repairSynchronization(scopeKey: String) throws {
        try requireIdle(scopeKey: scopeKey)
        guard try fetchOutbox(scopeKey: scopeKey).isEmpty else {
            throw SyncRecoveryError.unsynchronizedChangesRemain
        }
        let transfers = try modelContext.fetch(FetchDescriptor<AttachmentTransfer>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        guard transfers.allSatisfy({ $0.state == .uploaded || $0.state == .cancelled }) else {
            throw SyncRecoveryError.unsynchronizedChangesRemain
        }
        let conflicts = try modelContext.fetch(FetchDescriptor<SyncConflict>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        guard conflicts.allSatisfy({ $0.resolvedAt != nil }) else {
            throw SyncRecoveryError.unsynchronizedChangesRemain
        }
        do {
            let state = try cursorState(scopeKey: scopeKey)
            state.cursor = nil
            state.lastSafeErrorCode = nil
            for conflict in try modelContext.fetch(FetchDescriptor<SyncConflict>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )) where conflict.resolvedAt != nil {
                modelContext.delete(conflict)
            }
            try resetBootstrap(scopeKey: scopeKey)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func completeRequestedRecoveries(
        scopeKey: String,
        staged: [BootstrapStagedEntity]
    ) throws {
        let outbox = try fetchOutbox(scopeKey: scopeKey)
        let inventory = try SyncLocalInventory(context: modelContext, scopeKey: scopeKey)
        let remote = Dictionary(grouping: staged) {
            SyncRecordKey(entityType: $0.entityType, entityID: $0.entityID)
        }
        let groups = Dictionary(grouping: outbox.filter { $0.serverStateRequestedAt != nil }, by: \.recordKey)
        for (key, mutations) in groups {
            let sameEntity = outbox.filter { $0.recordKey == key }
            guard sameEntity.allSatisfy({ $0.serverStateRequestedAt != nil }) else {
                for mutation in mutations {
                    mutation.serverStateRequestedAt = nil
                    mutation.lastSafeErrorCode = "recovery_changed_locally"
                }
                continue
            }
            for mutation in mutations {
                try discardInstallmentProjection(scopeKey: scopeKey, mutation: mutation)
                modelContext.delete(mutation)
            }
            try resolveEntityConflicts(scopeKey: scopeKey, key: key)
            if remote[key] == nil {
                // Absence is not proof of deletion. The user explicitly chose the current
                // authorized server copy, which has no visible record; retain local bytes as unavailable.
                inventory.records[key]?.markUnavailable(.now)
                try markEntityState(scopeKey: scopeKey, entityType: key.entityType, entityID: key.entityID, state: .synced, serverVersion: nil)
                try quarantineDependents(scopeKey: scopeKey, key: key, changedAt: .now)
            }
        }
    }

    func resolveEntityConflicts(scopeKey: String, key: SyncRecordKey) throws {
        for conflict in try modelContext.fetch(FetchDescriptor<SyncConflict>(
            predicate: #Predicate { $0.scopeKey == scopeKey && $0.resolvedAt == nil }
        )) where conflict.entityType == key.entityType && conflict.entityID == key.entityID {
            conflict.resolvedAt = .now
        }
    }

    func acceptServerDeletion(scopeKey: String, key: SyncRecordKey, current: JSONValue) throws {
        guard SyncRecoveryPolicy.isDeleted(current),
              let rawID = current.objectValue?["id"]?.stringValue,
              UUID(uuidString: rawID) == key.entityID,
              let version = current.objectValue?["version"]?.integerValue,
              version > 0
        else { throw SyncEngineError.invalidServerResponse }
        let date = current.objectValue?["deleted_at"]?.stringValue.flatMap { APIDate.date(from: $0) } ?? .now
        for mutation in try fetchOutbox(scopeKey: scopeKey) where mutation.recordKey == key {
            try discardInstallmentProjection(scopeKey: scopeKey, mutation: mutation)
            modelContext.delete(mutation)
        }
        try applyTombstone(entityType: key.entityType, entityID: key.entityID, changedAt: date, version: version, scopeKey: scopeKey)
        try resolveEntityConflicts(scopeKey: scopeKey, key: key)
        try quarantineDependents(scopeKey: scopeKey, key: key, changedAt: date)
        let state = try cursorState(scopeKey: scopeKey)
        state.bootstrapRequired = true
    }

    func quarantineDependents(scopeKey: String, key: SyncRecordKey, changedAt: Date) throws {
        let inventory = try SyncLocalInventory(context: modelContext, scopeKey: scopeKey)
        let outbox = try fetchOutbox(scopeKey: scopeKey)
        var blocked = Set([key])
        if key.entityType == "tracker" {
            for (child, record) in inventory.records where record.trackerID == key.entityID {
                record.markUnavailable(changedAt)
                blocked.insert(child)
            }
        }
        var changed = true
        while changed {
            changed = false
            for mutation in outbox {
                let payload = try? JSONDecoder().decode(JSONValue.self, from: mutation.payloadJSON)
                let dependencies = payload.map(SyncRecoveryPolicy.references) ?? []
                if blocked.contains(mutation.recordKey) || !dependencies.isDisjoint(with: blocked) {
                    if blocked.insert(mutation.recordKey).inserted { changed = true }
                    mutation.stateRaw = LocalSyncState.failed.rawValue
                    mutation.nextAttemptAt = nil
                    mutation.lastSafeErrorCode = "parent_unavailable"
                    mutation.updatedAt = .now
                    try markEntityState(scopeKey: scopeKey, entityType: mutation.entityType, entityID: mutation.entityID, state: .failed, serverVersion: nil)
                }
            }
        }
        // Upload work and receipt files remain local for explicit recovery.
        for transfer in try modelContext.fetch(FetchDescriptor<AttachmentTransfer>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )) where blocked.contains(SyncRecordKey(entityType: "transaction", entityID: transfer.transactionID)) && transfer.state != .uploaded {
            transfer.stateRaw = AttachmentTransferState.failed.rawValue
            transfer.lastSafeErrorCode = "parent_unavailable"
            transfer.nextAttemptAt = nil
        }
    }

    func rememberServerState(scopeKey: String, key: SyncRecordKey, value: JSONValue) throws {
        let data = try JSONEncoder().encode(value)
        for mutation in try fetchOutbox(scopeKey: scopeKey) where mutation.recordKey == key {
            mutation.serverSnapshotJSON = data
            mutation.serverSnapshotMissing = false
            if SyncRecoveryPolicy.isDeleted(value) {
                mutation.stateRaw = LocalSyncState.conflicted.rawValue
                mutation.nextAttemptAt = nil
                mutation.lastSafeErrorCode = "server_deleted"
                try storeConflict(scopeKey: scopeKey, mutation: mutation, result: SyncOperationResult(
                    operationID: mutation.operationID, status: .conflict, originalStatus: nil,
                    replayed: false, entityType: key.entityType, entityID: key.entityID,
                    serverVersion: value.objectValue?["version"]?.integerValue,
                    representation: value, error: nil
                ))
            }
        }
    }
}

extension OutboxMutation {
    var recordKey: SyncRecordKey { SyncRecordKey(entityType: entityType, entityID: entityID) }
}
