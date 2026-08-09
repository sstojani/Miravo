import Foundation
import SwiftData

enum SyncEngineError: Error, Equatable, Sendable {
    case invalidLocalPayload
    case invalidServerResponse
    case unsupportedCurrency
    case missingServerRepresentation
}

struct SyncRunSummary: Equatable, Sendable {
    let pushedCount: Int
    let pulledCount: Int
    let conflictCount: Int
    let acknowledged: Bool
    let completedAt: Date
}

struct SyncDiagnosticsSnapshot: Equatable, Sendable {
    let pendingCount: Int
    let failedCount: Int
    let conflictCount: Int
    let lastSuccessfulSyncAt: Date?
    let lastAttemptAt: Date?
    let lastSafeErrorCode: String?
    let bootstrapRequired: Bool
    let isSyncing: Bool
}

enum SyncRetryPolicy {
    static func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let boundedAttempt = min(max(attempt, 1), 10)
        let base = min(pow(2, Double(boundedAttempt)), 3_600)
        return base * min(max(jitter, 0.8), 1.2)
    }
}

@ModelActor
actor LedgerSyncActor {
    private enum DecodedRemote {
        case tracker(TrackerSnapshot)
        case membership(MembershipSnapshot)
        case account(AccountSnapshot)
        case category(CategorySnapshot)
        case tag(TagSnapshot)
        case transaction(TransactionSnapshot)
        case tombstone(entityType: String, entityID: UUID, changedAt: Date, version: Int64)
        case ignored
    }

    private struct PreparedBatch {
        let request: SyncPushRequest
        let operationIDs: [UUID]
    }

    func synchronize(authentication: SyncAuthenticationContext) async throws -> SyncRunSummary {
        try await synchronize(
            authentication: authentication,
            transport: APIClient(baseURL: authentication.baseURL)
        )
    }

    func synchronize(
        authentication: SyncAuthenticationContext,
        transport: any SyncTransport
    ) async throws -> SyncRunSummary {
        do {
            return try await performSync(
                scopeKey: authentication.scopeKey,
                client: transport,
                accessToken: authentication.tokens.accessToken
            )
        } catch let error as APIClientError where shouldRefresh(after: error) {
            do {
                let refreshed = try await transport.refresh(
                    refreshToken: authentication.tokens.refreshToken
                )
                try await authentication.tokenStore.save(
                    refreshed,
                    scopeKey: authentication.scopeKey
                )
                return try await performSync(
                    scopeKey: authentication.scopeKey,
                    client: transport,
                    accessToken: refreshed.accessToken
                )
            } catch {
                try recordRunFailure(scopeKey: authentication.scopeKey, error: error)
                throw error
            }
        } catch {
            try recordRunFailure(scopeKey: authentication.scopeKey, error: error)
            throw error
        }
    }

    func diagnostics(scopeKey: String) throws -> SyncDiagnosticsSnapshot {
        let outbox = try fetchOutbox(scopeKey: scopeKey)
        let conflicts = try modelContext.fetch(
            FetchDescriptor<SyncConflict>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.resolvedAt == nil }
            )
        )
        let state = try cursorState(scopeKey: scopeKey)
        return SyncDiagnosticsSnapshot(
            pendingCount: outbox.filter {
                $0.state == .pending || $0.state == .syncing
            }.count,
            failedCount: outbox.filter { $0.state == .failed }.count,
            conflictCount: conflicts.count,
            lastSuccessfulSyncAt: state.lastSuccessfulSyncAt,
            lastAttemptAt: state.lastAttemptAt,
            lastSafeErrorCode: state.lastSafeErrorCode,
            bootstrapRequired: state.bootstrapRequired,
            isSyncing: state.isSyncing
        )
    }

    func retryFailed(scopeKey: String) throws {
        for mutation in try fetchOutbox(scopeKey: scopeKey) where mutation.state == .failed {
            mutation.stateRaw = LocalSyncState.pending.rawValue
            mutation.nextAttemptAt = nil
            mutation.lastSafeErrorCode = nil
            mutation.updatedAt = .now
        }
        try saveOrRollback()
    }

    func resolveKeepServer(scopeKey: String, operationID: UUID) throws {
        do {
            guard let conflict = try unresolvedConflict(
                scopeKey: scopeKey,
                operationID: operationID
            ) else { return }
            let current = try JSONDecoder().decode(JSONValue.self, from: conflict.currentJSON)
            try applyRepresentation(
                entityType: conflict.entityType,
                value: current,
                scopeKey: scopeKey,
                respectPending: false
            )
            let outbox = try fetchOutbox(scopeKey: scopeKey)
            for mutation in outbox where mutation.operationID == operationID {
                modelContext.delete(mutation)
            }
            if let currentVersion = current.objectValue?["version"]?.integerValue {
                rebaseRemainingMutations(
                    outbox,
                    entityType: conflict.entityType,
                    entityID: conflict.entityID,
                    from: conflict.baseServerVersion,
                    to: currentVersion,
                    excluding: operationID
                )
            }
            conflict.resolvedAt = .now
            try saveOrRollback()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func resolveKeepMine(scopeKey: String, operationID: UUID) throws {
        do {
            guard let conflict = try unresolvedConflict(
                scopeKey: scopeKey,
                operationID: operationID
            ) else { return }
            let current = try JSONDecoder().decode(JSONValue.self, from: conflict.currentJSON)
            guard let currentVersion = current.objectValue?["version"]?.integerValue else {
                throw SyncEngineError.invalidServerResponse
            }
            guard let mutation = try fetchOutbox(scopeKey: scopeKey).first(where: {
                $0.operationID == operationID
            }) else {
                throw SyncEngineError.invalidLocalPayload
            }
            mutation.operationID = UUID()
            mutation.baseServerVersion = currentVersion
            mutation.stateRaw = LocalSyncState.pending.rawValue
            mutation.attemptCount = 0
            mutation.nextAttemptAt = nil
            mutation.lastSafeErrorCode = nil
            mutation.updatedAt = .now
            conflict.resolvedAt = .now
            try saveOrRollback()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func performSync(
        scopeKey: String,
        client: any SyncTransport,
        accessToken: String
    ) async throws -> SyncRunSummary {
        let state = try cursorState(scopeKey: scopeKey)
        state.isSyncing = true
        state.lastAttemptAt = .now
        state.lastSafeErrorCode = nil
        try saveOrRollback()

        let pushedCount = try await pushAvailable(
            scopeKey: scopeKey,
            client: client,
            accessToken: accessToken
        )
        var pulledCount = 0
        for _ in 0 ..< 3 {
            var currentState = try cursorState(scopeKey: scopeKey)
            if currentState.bootstrapRequired || currentState.cursor == nil {
                try await bootstrapAll(
                    scopeKey: scopeKey,
                    client: client,
                    accessToken: accessToken
                )
            }
            do {
                pulledCount += try await pullAll(
                    scopeKey: scopeKey,
                    client: client,
                    accessToken: accessToken
                )
            } catch let error as APIClientError where error.code == "sync_cursor_expired" {
                currentState = try cursorState(scopeKey: scopeKey)
                currentState.bootstrapRequired = true
                currentState.lastSafeErrorCode = error.code
                try saveOrRollback()
                continue
            }
            if !(try cursorState(scopeKey: scopeKey).bootstrapRequired) { break }
        }
        guard !(try cursorState(scopeKey: scopeKey).bootstrapRequired) else {
            throw SyncEngineError.invalidServerResponse
        }

        let currentState = try cursorState(scopeKey: scopeKey)
        var acknowledged = false
        if let cursor = currentState.cursor {
            acknowledged = (try? await client.acknowledge(
                cursor: cursor,
                accessToken: accessToken
            )) != nil
        }
        let completedAt = Date.now
        currentState.isSyncing = false
        currentState.lastSuccessfulSyncAt = completedAt
        currentState.lastSafeErrorCode = acknowledged ? nil : "ack_pending"
        currentState.consecutiveFailureCount = 0
        try saveOrRollback()
        let conflictCount = try modelContext.fetch(
            FetchDescriptor<SyncConflict>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.resolvedAt == nil }
            )
        ).count
        return SyncRunSummary(
            pushedCount: pushedCount,
            pulledCount: pulledCount,
            conflictCount: conflictCount,
            acknowledged: acknowledged,
            completedAt: completedAt
        )
    }

    private func pushAvailable(
        scopeKey: String,
        client: any SyncTransport,
        accessToken: String
    ) async throws -> Int {
        var processed = 0
        for _ in 0 ..< 25 {
            guard let batch = try preparePushBatch(scopeKey: scopeKey) else { break }
            do {
                let response = try await client.push(batch.request, accessToken: accessToken)
                guard response.protocolVersion == 1,
                      response.results.count == batch.operationIDs.count,
                      Set(response.results.map(\.operationID)) == Set(batch.operationIDs)
                else {
                    throw SyncEngineError.invalidServerResponse
                }
                processed += try applyPushResponse(
                    response,
                    scopeKey: scopeKey
                )
            } catch {
                try markTransportFailure(
                    scopeKey: scopeKey,
                    operationIDs: batch.operationIDs,
                    error: error
                )
                throw error
            }
        }
        return processed
    }

    private func preparePushBatch(scopeKey: String) throws -> PreparedBatch? {
        let now = Date.now
        let outbox = try fetchOutbox(scopeKey: scopeKey)
        for mutation in outbox where mutation.state == .syncing {
            mutation.stateRaw = LocalSyncState.pending.rawValue
        }
        let eligible = outbox
            .filter {
                $0.state == .pending && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
            }
            .sorted { $0.localSequence < $1.localSequence }
        var seenEntities = Set<String>()
        var operations = [SyncPushOperation]()
        var operationIDs = [UUID]()
        for mutation in eligible {
            let entityKey = "\(mutation.entityType)|\(mutation.entityID.uuidString)"
            guard !seenEntities.contains(entityKey), operations.count < 100 else { continue }
            seenEntities.insert(entityKey)
            do {
                let payload = try JSONDecoder().decode(JSONValue.self, from: mutation.payloadJSON)
                guard payload.objectValue != nil else {
                    throw SyncEngineError.invalidLocalPayload
                }
                operations.append(
                    SyncPushOperation(
                        operationID: mutation.operationID,
                        localSequence: mutation.localSequence,
                        entityType: mutation.entityType,
                        entityID: mutation.entityID,
                        command: mutation.command,
                        baseServerVersion: mutation.baseServerVersion,
                        payload: payload
                    )
                )
                operationIDs.append(mutation.operationID)
                mutation.stateRaw = LocalSyncState.syncing.rawValue
                mutation.attemptCount += 1
                mutation.updatedAt = now
            } catch {
                mutation.stateRaw = LocalSyncState.failed.rawValue
                mutation.lastSafeErrorCode = "invalid_local_payload"
                mutation.updatedAt = now
            }
        }
        try saveOrRollback()
        guard !operations.isEmpty else { return nil }
        return PreparedBatch(
            request: SyncPushRequest(protocolVersion: 1, operations: operations),
            operationIDs: operationIDs
        )
    }

    private func applyPushResponse(
        _ response: SyncPushResponse,
        scopeKey: String
    ) throws -> Int {
        do {
            return try applyPushResponseTransaction(response, scopeKey: scopeKey)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func applyPushResponseTransaction(
        _ response: SyncPushResponse,
        scopeKey: String
    ) throws -> Int {
        let outbox = try fetchOutbox(scopeKey: scopeKey)
        var processed = 0
        for result in response.results {
            guard let mutation = outbox.first(where: { $0.operationID == result.operationID }) else {
                throw SyncEngineError.invalidServerResponse
            }
            switch result.status {
            case .accepted, .duplicate:
                guard let representation = result.representation,
                      let serverVersion = result.serverVersion
                else {
                    throw SyncEngineError.missingServerRepresentation
                }
                try applyRepresentation(
                    entityType: result.entityType,
                    value: representation,
                    scopeKey: scopeKey,
                    respectPending: false
                )
                modelContext.delete(mutation)
                rebaseRemainingMutations(
                    outbox,
                    entityType: mutation.entityType,
                    entityID: mutation.entityID,
                    from: mutation.baseServerVersion,
                    to: serverVersion,
                    excluding: mutation.operationID
                )
                try markEntityState(
                    scopeKey: scopeKey,
                    entityType: mutation.entityType,
                    entityID: mutation.entityID,
                    state: outbox.contains(where: {
                        $0.operationID != mutation.operationID &&
                            $0.entityType == mutation.entityType &&
                            $0.entityID == mutation.entityID
                    }) ? .pending : .synced,
                    serverVersion: serverVersion
                )
                processed += 1
            case .rejected, .unauthorized:
                mutation.stateRaw = LocalSyncState.failed.rawValue
                mutation.lastSafeErrorCode = result.error?.code ?? "operation_rejected"
                mutation.nextAttemptAt = nil
                mutation.updatedAt = .now
                try markEntityState(
                    scopeKey: scopeKey,
                    entityType: mutation.entityType,
                    entityID: mutation.entityID,
                    state: .failed,
                    serverVersion: nil
                )
            case .conflict:
                guard result.representation != nil, result.serverVersion != nil else {
                    mutation.stateRaw = LocalSyncState.failed.rawValue
                    mutation.lastSafeErrorCode = result.error?.code ?? "invalid_conflict"
                    mutation.nextAttemptAt = nil
                    mutation.updatedAt = .now
                    try markEntityState(
                        scopeKey: scopeKey,
                        entityType: mutation.entityType,
                        entityID: mutation.entityID,
                        state: .failed,
                        serverVersion: nil
                    )
                    continue
                }
                mutation.stateRaw = LocalSyncState.conflicted.rawValue
                mutation.lastSafeErrorCode = result.error?.code ?? "version_conflict"
                mutation.nextAttemptAt = nil
                mutation.updatedAt = .now
                try storeConflict(
                    scopeKey: scopeKey,
                    mutation: mutation,
                    result: result
                )
                try markEntityState(
                    scopeKey: scopeKey,
                    entityType: mutation.entityType,
                    entityID: mutation.entityID,
                    state: .conflicted,
                    serverVersion: result.serverVersion
                )
            }
        }
        try saveOrRollback()
        return processed
    }

    private func pullAll(
        scopeKey: String,
        client: any SyncTransport,
        accessToken: String
    ) async throws -> Int {
        var total = 0
        for _ in 0 ..< 1_000 {
            let state = try cursorState(scopeKey: scopeKey)
            let response = try await client.pull(
                cursor: state.cursor,
                limit: 100,
                accessToken: accessToken
            )
            guard response.protocolVersion == 1 else {
                throw SyncEngineError.invalidServerResponse
            }
            try applyPullPage(response, scopeKey: scopeKey)
            total += response.changes.count
            if !response.hasMore { return total }
        }
        throw SyncEngineError.invalidServerResponse
    }

    private func applyPullPage(_ response: SyncPullResponse, scopeKey: String) throws {
        do {
            try applyPullPageTransaction(response, scopeKey: scopeKey)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func applyPullPageTransaction(
        _ response: SyncPullResponse,
        scopeKey: String
    ) throws {
        let decoded = try response.changes.map { change in
            (change, try decodeRemoteChange(change))
        }
        for (change, remote) in decoded {
            switch remote {
            case let .membership(snapshot):
                try applyMembership(snapshot, changedAt: change.changedAt, scopeKey: scopeKey)
            case .ignored:
                continue
            default:
                if try hasLocalMutation(
                    scopeKey: scopeKey,
                    entityType: change.entityType,
                    entityID: change.entityID
                ) {
                    continue
                }
                try applyDecoded(remote, scopeKey: scopeKey)
            }
        }
        let state = try cursorState(scopeKey: scopeKey)
        state.cursor = response.cursor
        try saveOrRollback()
    }

    private func bootstrapAll(
        scopeKey: String,
        client: any SyncTransport,
        accessToken: String
    ) async throws {
        do {
            try await continueBootstrap(
                scopeKey: scopeKey,
                client: client,
                accessToken: accessToken
            )
        } catch let error as APIClientError where error.code == "invalid_bootstrap_cursor" {
            try resetBootstrap(scopeKey: scopeKey)
            try await continueBootstrap(
                scopeKey: scopeKey,
                client: client,
                accessToken: accessToken
            )
        }
    }

    private func continueBootstrap(
        scopeKey: String,
        client: any SyncTransport,
        accessToken: String
    ) async throws {
        if try cursorState(scopeKey: scopeKey).bootstrapGenerationID == nil {
            try resetBootstrap(scopeKey: scopeKey)
        }
        for _ in 0 ..< 10_000 {
            let state = try cursorState(scopeKey: scopeKey)
            let response = try await client.bootstrap(
                cursor: state.bootstrapCursor,
                limit: 100,
                accessToken: accessToken
            )
            guard response.protocolVersion == 1,
                  response.hasMore == (response.bootstrapCursor != nil)
            else {
                throw SyncEngineError.invalidServerResponse
            }
            try stageBootstrapPage(response, scopeKey: scopeKey)
            if !response.hasMore {
                try finalizeBootstrap(scopeKey: scopeKey, finalCursor: response.cursor)
                return
            }
        }
        throw SyncEngineError.invalidServerResponse
    }

    private func resetBootstrap(scopeKey: String) throws {
        for row in try modelContext.fetch(
            FetchDescriptor<BootstrapStagedEntity>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ) {
            modelContext.delete(row)
        }
        let state = try cursorState(scopeKey: scopeKey)
        state.bootstrapRequired = true
        state.bootstrapCursor = nil
        state.bootstrapTargetCursor = nil
        state.bootstrapGenerationID = UUID()
        try saveOrRollback()
    }

    private func stageBootstrapPage(
        _ response: SyncBootstrapResponse,
        scopeKey: String
    ) throws {
        do {
            try stageBootstrapPageTransaction(response, scopeKey: scopeKey)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func stageBootstrapPageTransaction(
        _ response: SyncBootstrapResponse,
        scopeKey: String
    ) throws {
        guard let root = response.data.objectValue else {
            throw SyncEngineError.invalidServerResponse
        }
        let state = try cursorState(scopeKey: scopeKey)
        guard let generationID = state.bootstrapGenerationID else {
            throw SyncEngineError.invalidServerResponse
        }
        if let target = state.bootstrapTargetCursor, target != response.cursor {
            throw SyncEngineError.invalidServerResponse
        }
        state.bootstrapTargetCursor = response.cursor
        let entityTypes = [
            "trackers": "tracker",
            "memberships": "tracker_membership",
            "accounts": "account",
            "categories": "category",
            "tags": "tag",
            "merchants": "merchant",
            "transactions": "transaction",
        ]
        let encoder = JSONEncoder()
        for (key, entityType) in entityTypes {
            guard let values = root[key]?.arrayValue else {
                throw SyncEngineError.invalidServerResponse
            }
            for value in values {
                guard let object = value.objectValue,
                      let idString = object["id"]?.stringValue,
                      let entityID = UUID(uuidString: idString),
                      let version = object["version"]?.integerValue
                else {
                    throw SyncEngineError.invalidServerResponse
                }
                modelContext.insert(
                    BootstrapStagedEntity(
                        scopeKey: scopeKey,
                        generationID: generationID,
                        entityType: entityType,
                        entityID: entityID,
                        payloadJSON: try encoder.encode(value),
                        serverVersion: version
                    )
                )
            }
        }
        state.bootstrapCursor = response.bootstrapCursor
        try saveOrRollback()
    }

    private func finalizeBootstrap(scopeKey: String, finalCursor: String) throws {
        do {
            try finalizeBootstrapTransaction(scopeKey: scopeKey, finalCursor: finalCursor)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func finalizeBootstrapTransaction(
        scopeKey: String,
        finalCursor: String
    ) throws {
        let state = try cursorState(scopeKey: scopeKey)
        guard let generationID = state.bootstrapGenerationID,
              state.bootstrapTargetCursor == finalCursor
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let staged = try modelContext.fetch(
            FetchDescriptor<BootstrapStagedEntity>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.generationID == generationID
                }
            )
        )
        let decoder = JSONDecoder()
        let decoded: [(BootstrapStagedEntity, DecodedRemote)] = try staged.map { row in
            let value = try decoder.decode(JSONValue.self, from: row.payloadJSON)
            return (row, try decodeRemote(entityType: row.entityType, data: value))
        }
        try validateBootstrapRelationships(decoded.map(\.1))
        let outbox = try fetchOutbox(scopeKey: scopeKey)
        let pendingKeys = Set(outbox.map { "\($0.entityType)|\($0.entityID.uuidString)" })
        var remoteIDs = [String: Set<UUID>]()
        for (row, remote) in decoded {
            remoteIDs[row.entityType, default: []].insert(row.entityID)
            let key = "\(row.entityType)|\(row.entityID.uuidString)"
            if !pendingKeys.contains(key) {
                try applyDecoded(remote, scopeKey: scopeKey)
            }
        }
        try removeMissingSynchronizedEntities(
            scopeKey: scopeKey,
            remoteIDs: remoteIDs,
            pendingKeys: pendingKeys
        )
        for row in staged { modelContext.delete(row) }
        state.cursor = finalCursor
        state.bootstrapRequired = false
        state.bootstrapCursor = nil
        state.bootstrapTargetCursor = nil
        state.bootstrapGenerationID = nil
        try saveOrRollback()
    }

    private func validateBootstrapRelationships(_ decoded: [DecodedRemote]) throws {
        var trackerIDs = Set<UUID>()
        var accountIDs = Set<UUID>()
        var categoryIDs = Set<UUID>()
        var tagTrackers = [UUID: UUID]()
        for item in decoded {
            switch item {
            case let .tracker(snapshot): trackerIDs.insert(snapshot.id)
            case let .account(snapshot): accountIDs.insert(snapshot.id)
            case let .category(snapshot): categoryIDs.insert(snapshot.id)
            case let .tag(snapshot): tagTrackers[snapshot.id] = snapshot.trackerID
            default: break
            }
        }
        for item in decoded {
            switch item {
            case let .membership(snapshot):
                guard trackerIDs.contains(snapshot.trackerID) else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .account(snapshot):
                guard trackerIDs.contains(snapshot.trackerID) else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .category(snapshot):
                if let trackerID = snapshot.trackerID, !trackerIDs.contains(trackerID) {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .tag(snapshot):
                guard trackerIDs.contains(snapshot.trackerID) else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .transaction(snapshot):
                guard trackerIDs.contains(snapshot.trackerID),
                      snapshot.movements.allSatisfy({ accountIDs.contains($0.accountID) }),
                      snapshot.allocations.allSatisfy({ categoryIDs.contains($0.categoryID) }),
                      snapshot.tagIDs.allSatisfy({ tagTrackers[$0] == snapshot.trackerID })
                else {
                    throw SyncEngineError.invalidServerResponse
                }
            default:
                break
            }
        }
    }

    private func decodeRemoteChange(_ change: SyncChangeResponse) throws -> DecodedRemote {
        do {
            return try decodeRemote(entityType: change.entityType, data: change.data)
        } catch where change.operation == "delete" {
            return .tombstone(
                entityType: change.entityType,
                entityID: change.entityID,
                changedAt: try parseTimestamp(change.changedAt),
                version: change.version
            )
        }
    }

    private func decodeRemote(entityType: String, data: JSONValue) throws -> DecodedRemote {
        switch entityType {
        case "tracker":
            .tracker(try SyncSnapshotDecoder.decode(TrackerSnapshot.self, from: data))
        case "tracker_membership":
            .membership(try SyncSnapshotDecoder.decode(MembershipSnapshot.self, from: data))
        case "account":
            .account(try SyncSnapshotDecoder.decode(AccountSnapshot.self, from: data))
        case "category":
            .category(try SyncSnapshotDecoder.decode(CategorySnapshot.self, from: data))
        case "tag":
            .tag(try SyncSnapshotDecoder.decode(TagSnapshot.self, from: data))
        case "transaction":
            .transaction(try SyncSnapshotDecoder.decode(TransactionSnapshot.self, from: data))
        default:
            .ignored
        }
    }

    private func applyDecoded(_ remote: DecodedRemote, scopeKey: String) throws {
        switch remote {
        case let .tracker(snapshot): try upsertTracker(snapshot, scopeKey: scopeKey)
        case let .membership(snapshot): try upsertMembership(snapshot, scopeKey: scopeKey)
        case let .account(snapshot): try upsertAccount(snapshot, scopeKey: scopeKey)
        case let .category(snapshot): try upsertCategory(snapshot, scopeKey: scopeKey)
        case let .tag(snapshot): try upsertTag(snapshot, scopeKey: scopeKey)
        case let .transaction(snapshot): try upsertTransaction(snapshot, scopeKey: scopeKey)
        case let .tombstone(entityType, entityID, changedAt, version):
            try applyTombstone(
                entityType: entityType,
                entityID: entityID,
                changedAt: changedAt,
                version: version,
                scopeKey: scopeKey
            )
        case .ignored:
            break
        }
    }

    private func applyRepresentation(
        entityType: String,
        value: JSONValue,
        scopeKey: String,
        respectPending: Bool
    ) throws {
        guard let idString = value.objectValue?["id"]?.stringValue,
              let entityID = UUID(uuidString: idString)
        else {
            throw SyncEngineError.invalidServerResponse
        }
        guard !respectPending || !(try hasLocalMutation(
            scopeKey: scopeKey,
            entityType: entityType,
            entityID: entityID
        )) else { return }
        try applyDecoded(
            decodeRemote(entityType: entityType, data: value),
            scopeKey: scopeKey
        )
    }

    private func upsertTracker(_ snapshot: TrackerSnapshot, scopeKey: String) throws {
        _ = try Money(
            minorUnits: 0,
            currencyCode: snapshot.baseCurrency,
            exponent: snapshot.baseCurrencyExponent
        )
        let exponent = snapshot.baseCurrencyExponent
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalTracker>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let tracker = existing ?? LocalTracker(
            id: snapshot.id,
            scopeKey: scopeKey,
            name: snapshot.name,
            baseCurrencyCode: snapshot.baseCurrency,
            baseCurrencyExponent: exponent,
            syncState: .synced,
            createdAt: try parseTimestamp(snapshot.createdAt)
        )
        if existing == nil { modelContext.insert(tracker) }
        tracker.name = snapshot.name
        tracker.trackerDescription = snapshot.description
        tracker.icon = snapshot.icon
        tracker.colorHex = snapshot.color
        tracker.baseCurrencyCode = snapshot.baseCurrency
        tracker.baseCurrencyExponent = exponent
        tracker.sortOrder = snapshot.sortOrder
        tracker.defaultAccountID = snapshot.defaultAccountID
        tracker.defaultCategoryID = snapshot.defaultCategoryID
        if let roleRaw = snapshot.role {
            guard TrackerRole(rawValue: roleRaw) != nil else {
                throw SyncEngineError.invalidServerResponse
            }
            tracker.roleRaw = roleRaw
        }
        tracker.serverVersion = snapshot.version
        tracker.syncStateRaw = LocalSyncState.synced.rawValue
        tracker.createdAt = try parseTimestamp(snapshot.createdAt)
        tracker.updatedAt = try parseTimestamp(snapshot.updatedAt)
        tracker.archivedAt = try parseOptionalTimestamp(snapshot.archivedAt)
        tracker.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
        tracker.accessRevokedAt = nil
    }

    private func upsertMembership(
        _ snapshot: MembershipSnapshot,
        scopeKey: String
    ) throws {
        guard let role = TrackerRole(rawValue: snapshot.role),
              ["active", "removed"].contains(snapshot.state)
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalTrackerMembership>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let existing, existing.serverVersion > snapshot.version { return }
        let membership = existing ?? LocalTrackerMembership(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            userID: snapshot.userID,
            email: snapshot.email,
            role: role,
            state: snapshot.state,
            serverVersion: snapshot.version,
            joinedAt: try parseTimestamp(snapshot.joinedAt),
            createdAt: try parseTimestamp(snapshot.createdAt)
        )
        if existing == nil { modelContext.insert(membership) }
        membership.trackerID = snapshot.trackerID
        membership.userID = snapshot.userID
        membership.email = snapshot.email
        membership.roleRaw = role.rawValue
        membership.stateRaw = snapshot.state
        membership.serverVersion = snapshot.version
        membership.joinedAt = try parseTimestamp(snapshot.joinedAt)
        membership.createdAt = try parseTimestamp(snapshot.createdAt)
        membership.updatedAt = try parseTimestamp(snapshot.updatedAt)
        membership.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
    }

    private func upsertAccount(_ snapshot: AccountSnapshot, scopeKey: String) throws {
        guard let type = LocalAccountType(rawValue: snapshot.type) else {
            throw SyncEngineError.invalidServerResponse
        }
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalAccount>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let account = existing ?? LocalAccount(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            name: snapshot.name,
            type: type,
            currencyCode: snapshot.currency,
            currencyExponent: snapshot.currencyExponent,
            openingBalanceMinor: snapshot.openingBalanceMinor,
            openingDate: try parseDate(snapshot.openingDate),
            syncState: .synced,
            createdAt: try parseTimestamp(snapshot.createdAt)
        )
        if existing == nil { modelContext.insert(account) }
        account.trackerID = snapshot.trackerID
        account.name = snapshot.name
        account.typeRaw = snapshot.type
        account.currencyCode = snapshot.currency
        account.currencyExponent = snapshot.currencyExponent
        account.openingBalanceMinor = snapshot.openingBalanceMinor
        account.openingDate = try parseDate(snapshot.openingDate)
        account.colorHex = snapshot.color
        account.icon = snapshot.icon
        account.includeInNetWorth = snapshot.includeInNetWorth
        account.creditLimitMinor = snapshot.creditLimitMinor
        account.serverVersion = snapshot.version
        account.syncStateRaw = LocalSyncState.synced.rawValue
        account.createdAt = try parseTimestamp(snapshot.createdAt)
        account.updatedAt = try parseTimestamp(snapshot.updatedAt)
        account.archivedAt = try parseOptionalTimestamp(snapshot.archivedAt)
        account.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
    }

    private func upsertCategory(_ snapshot: CategorySnapshot, scopeKey: String) throws {
        guard let trackerID = snapshot.trackerID,
              let kind = LocalCategoryKind(rawValue: snapshot.kind)
        else { return }
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalCategory>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let category = existing ?? LocalCategory(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: trackerID,
            parentID: snapshot.parentID,
            kind: kind,
            name: snapshot.name,
            syncState: .synced,
            createdAt: try parseTimestamp(snapshot.createdAt)
        )
        if existing == nil { modelContext.insert(category) }
        category.trackerID = trackerID
        category.parentID = snapshot.parentID
        category.kindRaw = snapshot.kind
        category.name = snapshot.name
        category.icon = snapshot.icon
        category.colorHex = snapshot.color
        category.sortOrder = snapshot.sortOrder
        category.serverVersion = snapshot.version
        category.syncStateRaw = LocalSyncState.synced.rawValue
        category.createdAt = try parseTimestamp(snapshot.createdAt)
        category.updatedAt = try parseTimestamp(snapshot.updatedAt)
        category.archivedAt = try parseOptionalTimestamp(snapshot.archivedAt)
        category.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
    }

    private func upsertTag(_ snapshot: TagSnapshot, scopeKey: String) throws {
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalTag>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let tag = existing ?? LocalTag(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            name: snapshot.name,
            colorHex: snapshot.color,
            syncState: .synced,
            createdAt: try parseTimestamp(snapshot.createdAt)
        )
        if existing == nil { modelContext.insert(tag) }
        tag.trackerID = snapshot.trackerID
        tag.name = snapshot.name
        tag.colorHex = snapshot.color
        tag.serverVersion = snapshot.version
        tag.syncStateRaw = LocalSyncState.synced.rawValue
        tag.createdAt = try parseTimestamp(snapshot.createdAt)
        tag.updatedAt = try parseTimestamp(snapshot.updatedAt)
        tag.archivedAt = try parseOptionalTimestamp(snapshot.archivedAt)
        tag.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
    }

    private func upsertTransaction(_ snapshot: TransactionSnapshot, scopeKey: String) throws {
        guard let kind = TransactionKind(rawValue: snapshot.kind),
              let source = TransactionSource(rawValue: snapshot.source),
              let status = TransactionStatus(rawValue: snapshot.status),
              let primary = primaryMovement(snapshot.movements, kind: kind)
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let money = try Money(
            minorUnits: snapshot.amountMinor,
            currencyCode: snapshot.currency,
            exponent: snapshot.currencyExponent
        )
        let destination = snapshot.movements.first { $0.id != primary.id }
        let transaction = existing ?? LedgerTransaction(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            accountID: primary.accountID,
            destinationAccountID: destination?.accountID,
            categoryID: snapshot.allocations.count == 1
                ? snapshot.allocations.first?.categoryID : nil,
            kind: kind,
            money: money,
            accountAmountMinor: abs(primary.signedAmountMinor),
            destinationAmountMinor: destination.map { abs($0.signedAmountMinor) },
            source: source,
            status: status,
            merchant: snapshot.merchant ?? snapshot.payee,
            note: snapshot.note,
            occurredAt: try parseTimestamp(snapshot.occurredAt),
            syncState: .synced,
            createdAt: try parseTimestamp(snapshot.createdAt)
        )
        if existing == nil { modelContext.insert(transaction) }
        transaction.trackerID = snapshot.trackerID
        transaction.accountID = primary.accountID
        transaction.destinationAccountID = destination?.accountID
        transaction.categoryID = snapshot.allocations.count == 1
            ? snapshot.allocations.first?.categoryID : nil
        transaction.kindRaw = snapshot.kind
        transaction.sourceRaw = snapshot.source
        transaction.statusRaw = snapshot.status
        transaction.amountMinor = snapshot.amountMinor
        transaction.accountAmountMinor = abs(primary.signedAmountMinor)
        transaction.destinationAmountMinor = destination.map { abs($0.signedAmountMinor) }
        transaction.currencyCode = snapshot.currency
        transaction.currencyExponent = snapshot.currencyExponent
        transaction.baseAmountMinor = snapshot.baseAmountMinor
        transaction.baseCurrencyCode = snapshot.baseCurrency
        transaction.rateSnapshot = snapshot.rateSnapshot
        transaction.rateSource = snapshot.rateSource
        transaction.rateEffectiveAt = try parseTimestamp(snapshot.rateEffectiveAt)
        transaction.merchant = snapshot.merchant ?? snapshot.payee
        transaction.note = snapshot.note
        transaction.occurredAt = try parseTimestamp(snapshot.occurredAt)
        transaction.capturedAt = try parseTimestamp(snapshot.capturedAt)
        transaction.externalEventID = snapshot.externalEventID
        transaction.refundOfID = snapshot.refundOfID
        transaction.serverVersion = snapshot.version
        transaction.syncStateRaw = LocalSyncState.synced.rawValue
        transaction.createdAt = try parseTimestamp(snapshot.createdAt)
        transaction.updatedAt = try parseTimestamp(snapshot.updatedAt)
        transaction.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
        try replaceChildren(snapshot, scopeKey: scopeKey)
    }

    private func replaceChildren(_ snapshot: TransactionSnapshot, scopeKey: String) throws {
        let transactionID = snapshot.id
        for movement in try modelContext.fetch(
            FetchDescriptor<LocalAccountMovement>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) {
            modelContext.delete(movement)
        }
        for allocation in try modelContext.fetch(
            FetchDescriptor<LocalCategoryAllocation>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) {
            modelContext.delete(allocation)
        }
        for tagLink in try modelContext.fetch(
            FetchDescriptor<LocalTransactionTag>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) {
            modelContext.delete(tagLink)
        }
        for movement in snapshot.movements {
            modelContext.insert(
                LocalAccountMovement(
                    id: movement.id,
                    scopeKey: scopeKey,
                    transactionID: transactionID,
                    accountID: movement.accountID,
                    signedAmountMinor: movement.signedAmountMinor,
                    currencyCode: movement.currency,
                    currencyExponent: movement.currencyExponent,
                    conversionRate: movement.conversionRate
                )
            )
        }
        for allocation in snapshot.allocations {
            modelContext.insert(
                LocalCategoryAllocation(
                    id: allocation.id,
                    scopeKey: scopeKey,
                    transactionID: transactionID,
                    categoryID: allocation.categoryID,
                    amountMinor: allocation.amountMinor,
                    categoryVersion: allocation.categoryVersion
                )
            )
        }
        for tagID in snapshot.tagIDs {
            modelContext.insert(
                LocalTransactionTag(
                    scopeKey: scopeKey,
                    transactionID: transactionID,
                    tagID: tagID
                )
            )
        }
    }

    private func primaryMovement(
        _ movements: [MovementSnapshot],
        kind: TransactionKind
    ) -> MovementSnapshot? {
        switch kind {
        case .expense, .transfer, .settlement:
            movements.first { $0.signedAmountMinor < 0 } ?? movements.first
        case .income, .refund:
            movements.first { $0.signedAmountMinor > 0 } ?? movements.first
        }
    }

    private func applyMembership(
        _ snapshot: MembershipSnapshot,
        changedAt: String,
        scopeKey: String
    ) throws {
        try upsertMembership(snapshot, scopeKey: scopeKey)
        guard snapshot.userID == scopeUserID(scopeKey) else { return }
        let state = try cursorState(scopeKey: scopeKey)
        if snapshot.state == "active" && snapshot.deletedAt == nil {
            guard TrackerRole(rawValue: snapshot.role) != nil else {
                throw SyncEngineError.invalidServerResponse
            }
            let trackerID = snapshot.trackerID
            if let tracker = try modelContext.fetch(
                FetchDescriptor<LocalTracker>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == trackerID }
                )
            ).first {
                tracker.roleRaw = snapshot.role
                tracker.accessRevokedAt = nil
                tracker.syncStateRaw = LocalSyncState.synced.rawValue
            } else {
                state.bootstrapRequired = true
            }
            return
        }
        let trackerID = snapshot.trackerID
        if let tracker = try modelContext.fetch(
            FetchDescriptor<LocalTracker>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == trackerID }
            )
        ).first {
            tracker.accessRevokedAt = try parseTimestamp(changedAt)
            tracker.syncStateRaw = LocalSyncState.synced.rawValue
        }
    }

    private func applyTombstone(
        entityType: String,
        entityID: UUID,
        changedAt: Date,
        version: Int64,
        scopeKey: String
    ) throws {
        switch entityType {
        case "tracker":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalTracker>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
                value.syncStateRaw = LocalSyncState.synced.rawValue
            }
        case "account":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalAccount>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
                value.syncStateRaw = LocalSyncState.synced.rawValue
            }
        case "category":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalCategory>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
                value.syncStateRaw = LocalSyncState.synced.rawValue
            }
        case "tracker_membership":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalTrackerMembership>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.stateRaw = "removed"
                value.serverVersion = version
                let trackerID = value.trackerID
                if value.userID == scopeUserID(scopeKey),
                   let tracker = try modelContext.fetch(
                       FetchDescriptor<LocalTracker>(
                           predicate: #Predicate {
                               $0.scopeKey == scopeKey && $0.id == trackerID
                           }
                       )
                   ).first {
                    tracker.accessRevokedAt = changedAt
                    tracker.syncStateRaw = LocalSyncState.synced.rawValue
                }
            }
        case "tag":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalTag>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
                value.syncStateRaw = LocalSyncState.synced.rawValue
            }
        case "transaction":
            if let value = try modelContext.fetch(
                FetchDescriptor<LedgerTransaction>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
                value.syncStateRaw = LocalSyncState.synced.rawValue
            }
        default:
            break
        }
    }

    private func removeMissingSynchronizedEntities(
        scopeKey: String,
        remoteIDs: [String: Set<UUID>],
        pendingKeys: Set<String>
    ) throws {
        for value in try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["transaction"] ?? []).contains(value.id) &&
            !pendingKeys.contains("transaction|\(value.id.uuidString)") {
            try deleteTransactionAndChildren(value, scopeKey: scopeKey)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalAccount>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["account"] ?? []).contains(value.id) &&
            !pendingKeys.contains("account|\(value.id.uuidString)") {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalCategory>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["category"] ?? []).contains(value.id) &&
            !pendingKeys.contains("category|\(value.id.uuidString)") {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalTag>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["tag"] ?? []).contains(value.id) &&
            !pendingKeys.contains("tag|\(value.id.uuidString)") {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalTrackerMembership>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ) where !(remoteIDs["tracker_membership"] ?? []).contains(value.id) {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalTracker>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["tracker"] ?? []).contains(value.id) &&
            !pendingKeys.contains("tracker|\(value.id.uuidString)") {
            modelContext.delete(value)
        }
    }

    private func deleteTransactionAndChildren(
        _ transaction: LedgerTransaction,
        scopeKey: String
    ) throws {
        let transactionID = transaction.id
        for value in try modelContext.fetch(
            FetchDescriptor<LocalAccountMovement>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) { modelContext.delete(value) }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalCategoryAllocation>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) { modelContext.delete(value) }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalTransactionTag>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) { modelContext.delete(value) }
        modelContext.delete(transaction)
    }

    private func storeConflict(
        scopeKey: String,
        mutation: OutboxMutation,
        result: SyncOperationResult
    ) throws {
        let encoder = JSONEncoder()
        let current = try encoder.encode(result.representation ?? .null)
        let existing = try unresolvedConflict(
            scopeKey: scopeKey,
            operationID: mutation.operationID
        )
        if let existing {
            existing.currentJSON = current
            existing.proposedJSON = mutation.payloadJSON
            existing.safeErrorCode = result.error?.code ?? "version_conflict"
        } else {
            modelContext.insert(
                SyncConflict(
                    operationID: mutation.operationID,
                    scopeKey: scopeKey,
                    entityType: mutation.entityType,
                    entityID: mutation.entityID,
                    baseServerVersion: mutation.baseServerVersion,
                    currentJSON: current,
                    proposedJSON: mutation.payloadJSON,
                    safeErrorCode: result.error?.code ?? "version_conflict"
                )
            )
        }
    }

    private func markTransportFailure(
        scopeKey: String,
        operationIDs: [UUID],
        error: Error
    ) throws {
        let code = safeErrorCode(error)
        let permanent = (error as? APIClientError).map {
            ($0.statusCode ?? 0) >= 400 && ($0.statusCode ?? 0) < 500 &&
                !shouldRefresh(after: $0)
        } ?? false
        for mutation in try fetchOutbox(scopeKey: scopeKey)
        where operationIDs.contains(mutation.operationID) {
            mutation.stateRaw = permanent
                ? LocalSyncState.failed.rawValue : LocalSyncState.pending.rawValue
            mutation.lastSafeErrorCode = code
            mutation.nextAttemptAt = permanent || shouldRefresh(after: error as? APIClientError)
                ? nil
                : Date.now.addingTimeInterval(
                    SyncRetryPolicy.delay(
                        attempt: mutation.attemptCount,
                        jitter: Double.random(in: 0.8 ... 1.2)
                    )
                )
            mutation.updatedAt = .now
        }
        try saveOrRollback()
    }

    private func recordRunFailure(scopeKey: String, error: Error) throws {
        let state = try cursorState(scopeKey: scopeKey)
        state.isSyncing = false
        state.lastSafeErrorCode = safeErrorCode(error)
        state.consecutiveFailureCount += 1
        for mutation in try fetchOutbox(scopeKey: scopeKey) where mutation.state == .syncing {
            mutation.stateRaw = LocalSyncState.pending.rawValue
        }
        try saveOrRollback()
    }

    private func rebaseRemainingMutations(
        _ outbox: [OutboxMutation],
        entityType: String,
        entityID: UUID,
        from oldVersion: Int64?,
        to newVersion: Int64,
        excluding operationID: UUID
    ) {
        for mutation in outbox where mutation.operationID != operationID &&
            mutation.entityType == entityType && mutation.entityID == entityID &&
            (mutation.baseServerVersion == nil || mutation.baseServerVersion == oldVersion) {
            mutation.baseServerVersion = newVersion
            mutation.stateRaw = LocalSyncState.pending.rawValue
            mutation.nextAttemptAt = nil
        }
    }

    private func markEntityState(
        scopeKey: String,
        entityType: String,
        entityID: UUID,
        state: LocalSyncState,
        serverVersion: Int64?
    ) throws {
        switch entityType {
        case "tracker":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalTracker>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.syncStateRaw = state.rawValue
                if let serverVersion { value.serverVersion = serverVersion }
            }
        case "account":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalAccount>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.syncStateRaw = state.rawValue
                if let serverVersion { value.serverVersion = serverVersion }
            }
        case "category":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalCategory>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.syncStateRaw = state.rawValue
                if let serverVersion { value.serverVersion = serverVersion }
            }
        case "tag":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalTag>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.syncStateRaw = state.rawValue
                if let serverVersion { value.serverVersion = serverVersion }
            }
        case "transaction":
            if let value = try modelContext.fetch(
                FetchDescriptor<LedgerTransaction>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.syncStateRaw = state.rawValue
                if let serverVersion { value.serverVersion = serverVersion }
            }
        default:
            break
        }
    }

    private func hasLocalMutation(
        scopeKey: String,
        entityType: String,
        entityID: UUID
    ) throws -> Bool {
        try fetchOutbox(scopeKey: scopeKey).contains {
            $0.entityType == entityType && $0.entityID == entityID
        }
    }

    private func unresolvedConflict(
        scopeKey: String,
        operationID: UUID
    ) throws -> SyncConflict? {
        try modelContext.fetch(
            FetchDescriptor<SyncConflict>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.operationID == operationID &&
                        $0.resolvedAt == nil
                }
            )
        ).first
    }

    private func cursorState(scopeKey: String) throws -> SyncCursor {
        if let existing = try modelContext.fetch(
            FetchDescriptor<SyncCursor>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ).first {
            return existing
        }
        let created = SyncCursor(scopeKey: scopeKey)
        modelContext.insert(created)
        return created
    }

    private func fetchOutbox(scopeKey: String) throws -> [OutboxMutation] {
        try modelContext.fetch(
            FetchDescriptor<OutboxMutation>(
                predicate: #Predicate { $0.scopeKey == scopeKey },
                sortBy: [SortDescriptor(\OutboxMutation.localSequence)]
            )
        )
    }

    private func shouldRefresh(after error: APIClientError) -> Bool {
        error.statusCode == 401 || [
            "invalid_access_token",
            "authentication_required",
            "session_revoked",
        ].contains(error.code)
    }

    private func shouldRefresh(after error: APIClientError?) -> Bool {
        guard let error else { return false }
        return shouldRefresh(after: error)
    }

    private func safeErrorCode(_ error: Error) -> String {
        if let apiError = error as? APIClientError { return apiError.code }
        if error is URLError { return "network_unavailable" }
        if let engineError = error as? SyncEngineError {
            switch engineError {
            case .invalidLocalPayload: return "invalid_local_payload"
            case .invalidServerResponse: return "invalid_server_response"
            case .unsupportedCurrency: return "unsupported_currency"
            case .missingServerRepresentation: return "missing_server_representation"
            }
        }
        return "sync_failed"
    }

    private func scopeUserID(_ scopeKey: String) -> UUID? {
        UUID(uuidString: scopeKey.split(separator: "|").last.map(String.init) ?? "")
    }

    private func parseTimestamp(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: value) else {
            throw SyncEngineError.invalidServerResponse
        }
        return date
    }

    private func parseOptionalTimestamp(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        return try parseTimestamp(value)
    }

    private func parseDate(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else {
            throw SyncEngineError.invalidServerResponse
        }
        return date
    }

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
