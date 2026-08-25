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
        case participant(ParticipantSnapshot)
        case account(AccountSnapshot)
        case category(CategorySnapshot)
        case tag(TagSnapshot)
        case budget(BudgetSnapshot)
        case recurringRule(RecurringRuleSnapshot)
        case recurringOccurrence(RecurringOccurrenceSnapshot)
        case installmentPlan(InstallmentPlanSnapshot)
        case installmentScheduleItem(InstallmentScheduleItemSnapshot)
        case installmentPayment(InstallmentPaymentSnapshot)
        case transaction(TransactionSnapshot)
        case attachment(AttachmentSnapshot)
        case settlement(SettlementSnapshot)
        case tombstone(entityType: String, entityID: UUID, changedAt: Date, version: Int64)
        case ignored
    }

    private struct PreparedBatch {
        let request: SyncPushRequest
        let operationIDs: [UUID]
    }

    private struct ValidatedInstallmentPlanSnapshot {
        let cadence: InstallmentCadence
        let state: InstallmentPlanState
        let money: Money
        let startsOn: Date
        let paidOffAt: Date?
        let cancelledAt: Date?
        let createdAt: Date
        let updatedAt: Date
        let archivedAt: Date?
        let deletedAt: Date?
    }

    private struct ValidatedInstallmentScheduleSnapshot {
        let state: InstallmentScheduleState
        let originalDueOn: Date
        let dueOn: Date
        let skippedAt: Date?
        let supersededAt: Date?
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    private struct ValidatedInstallmentPaymentSnapshot {
        let appliedAt: Date
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    private struct ValidatedSettlementSnapshot {
        let money: Money
        let occurredAt: Date
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
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

    func hasAvailableTrackers(scopeKey: String) throws -> Bool {
        let descriptor = FetchDescriptor<LocalTracker>(
            predicate: #Predicate<LocalTracker> { $0.scopeKey == scopeKey }
        )
        return try modelContext.fetch(descriptor).contains {
            $0.deletedAt == nil &&
                $0.archivedAt == nil &&
                $0.accessRevokedAt == nil
        }
    }

    func retryFailed(scopeKey: String) throws {
        for mutation in try fetchOutbox(scopeKey: scopeKey) where mutation.state == .failed {
            mutation.stateRaw = LocalSyncState.pending.rawValue
            mutation.nextAttemptAt = nil
            mutation.lastSafeErrorCode = nil
            mutation.updatedAt = .now
            try markInstallmentProjection(
                scopeKey: scopeKey,
                mutation: mutation,
                state: .pending
            )
            try markSettlementProjection(
                scopeKey: scopeKey,
                mutation: mutation,
                state: .pending
            )
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
            let outbox = try fetchOutbox(scopeKey: scopeKey)
            let resolvedMutation = outbox.first { $0.operationID == operationID }
            try applyRepresentation(
                entityType: conflict.entityType,
                value: current,
                scopeKey: scopeKey,
                respectPending: false
            )
            if let resolvedMutation,
               resolvedMutation.entityType == LocalMutationEntity.installmentPlan.rawValue {
                try discardInstallmentProjection(
                    scopeKey: scopeKey,
                    mutation: resolvedMutation
                )
                let state = try cursorState(scopeKey: scopeKey)
                state.bootstrapRequired = true
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
            if let resolvedMutation,
               resolvedMutation.entityType == LocalMutationEntity.installmentPlan.rawValue {
                try preserveDependentInstallmentMutations(
                    scopeKey: scopeKey,
                    resolvedMutation: resolvedMutation,
                    current: current,
                    outbox: outbox
                )
            }
            for mutation in outbox where mutation.operationID == operationID {
                modelContext.delete(mutation)
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
        let blockedEntitySequences = Dictionary(
            grouping: outbox.filter { $0.state == .failed || $0.state == .conflicted },
            by: { "\($0.entityType)|\($0.entityID.uuidString)" }
        ).mapValues { mutations in
            mutations.map(\.localSequence).min() ?? Int64.max
        }
        var seenEntities = Set<String>()
        var operations = [SyncPushOperation]()
        var operationIDs = [UUID]()
        for mutation in eligible {
            let entityKey = "\(mutation.entityType)|\(mutation.entityID.uuidString)"
            if let blockedSequence = blockedEntitySequences[entityKey],
               mutation.localSequence > blockedSequence {
                continue
            }
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
                try markSettlementProjection(
                    scopeKey: scopeKey,
                    mutation: mutation,
                    state: .synced
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
                try markInstallmentProjection(
                    scopeKey: scopeKey,
                    mutation: mutation,
                    state: .failed
                )
                try markSettlementProjection(
                    scopeKey: scopeKey,
                    mutation: mutation,
                    state: .failed
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
                    try markInstallmentProjection(
                        scopeKey: scopeKey,
                        mutation: mutation,
                        state: .failed
                    )
                    try markSettlementProjection(
                        scopeKey: scopeKey,
                        mutation: mutation,
                        state: .failed
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
                try markInstallmentProjection(
                    scopeKey: scopeKey,
                    mutation: mutation,
                    state: .conflicted
                )
                try markSettlementProjection(
                    scopeKey: scopeKey,
                    mutation: mutation,
                    state: .conflicted
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

    private func pullApplyPriority(entityType: String) -> Int {
        switch entityType {
        case "tracker": return 0
        case "tracker_membership": return 1
        case "participant": return 2
        case "account": return 3
        case "category": return 4
        case "tag": return 5
        case "budget": return 6
        case "recurring_rule": return 7
        case "installment_plan": return 8
        case "installment_schedule_item": return 9
        case "transaction": return 10
        case "attachment": return 11
        case "settlement": return 12
        case "recurring_occurrence": return 13
        case "installment_payment": return 14
        case "merchant": return 15
        default: return 100
        }
    }

    private func applyPullPageTransaction(
        _ response: SyncPullResponse,
        scopeKey: String
    ) throws {
        let decoded = try response.changes.enumerated().map { index, change in
            (
                index: index,
                change: change,
                remote: try decodeRemoteChange(change)
            )
        }

        let ordered = decoded.sorted { lhs, rhs in
            let lhsPriority = pullApplyPriority(
                entityType: lhs.change.entityType
            )
            let rhsPriority = pullApplyPriority(
                entityType: rhs.change.entityType
            )

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            // Keep original server order between changes of the same type.
            return lhs.index < rhs.index
        }

        for item in ordered {
            let change = item.change
            let remote = item.remote
            if try hasBlockingInstallmentParentMutation(
                remote: remote,
                scopeKey: scopeKey
            ) {
                continue
            }
            if try hasBlockingSettlementProjectionMutation(
                remote: remote,
                scopeKey: scopeKey
            ) {
                continue
            }
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
            "participants": "participant",
            "accounts": "account",
            "categories": "category",
            "tags": "tag",
            "merchants": "merchant",
            "budgets": "budget",
            "recurring_rules": "recurring_rule",
            "installment_plans": "installment_plan",
            "installment_schedule_items": "installment_schedule_item",
            "transactions": "transaction",
            "attachments": "attachment",
            "settlements": "settlement",
            "recurring_occurrences": "recurring_occurrence",
            "installment_payments": "installment_payment",
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
        let preservingOutbox = outbox.filter { $0.state != .conflicted }
        let pendingKeys = Set(
            preservingOutbox.map { "\($0.entityType)|\($0.entityID.uuidString)" }
        )
        var remoteIDs = [String: Set<UUID>]()
        let bootstrapPriority = [
            "tracker": 0,
            "tracker_membership": 1,
            "participant": 2,
            "account": 3,
            "category": 4,
            "tag": 5,
            "budget": 6,
            "recurring_rule": 7,
            "installment_plan": 8,
            "installment_schedule_item": 9,
            "transaction": 10,
            "attachment": 11,
            "settlement": 12,
            "recurring_occurrence": 13,
            "installment_payment": 14,
            "merchant": 15,
        ]
        for (row, remote) in decoded.sorted(by: {
            (bootstrapPriority[$0.0.entityType] ?? 100) <
                (bootstrapPriority[$1.0.entityType] ?? 100)
        }) {
            remoteIDs[row.entityType, default: []].insert(row.entityID)
            let key = "\(row.entityType)|\(row.entityID.uuidString)"
            let parentKey: String?
            switch remote {
            case let .installmentScheduleItem(snapshot):
                parentKey = "installment_plan|\(snapshot.planID.uuidString)"
            case let .attachment(snapshot):
                parentKey = "transaction|\(snapshot.transactionID.uuidString)"
            case let .settlement(snapshot):
                parentKey = snapshot.transactionID.map {
                    "transaction|\($0.uuidString)"
                }
            default:
                parentKey = nil
            }
            let parentBlocked = parentKey.map { pendingKeys.contains($0) } ?? false
            let projectionBlocked = try settlementProjectionBlocked(
                remote: remote,
                scopeKey: scopeKey,
                pendingKeys: pendingKeys
            )
            if !pendingKeys.contains(key) &&
                !parentBlocked &&
                !projectionBlocked {
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
        var participantTrackers = [UUID: UUID]()
        var accountTrackers = [UUID: UUID]()
        var categoryIDs = Set<UUID>()
        var categoryTrackers = [UUID: UUID]()
        var categoryKinds = [UUID: String]()
        var tagTrackers = [UUID: UUID]()
        var recurringRuleTrackers = [UUID: UUID]()
        var recurringOccurrenceKeys = Set<String>()
        var installmentPlanTrackers = [UUID: UUID]()
        var installmentPlans = [UUID: InstallmentPlanSnapshot]()
        var validatedInstallmentPlans = [UUID: ValidatedInstallmentPlanSnapshot]()
        var installmentSchedulePlans = [UUID: UUID]()
        var installmentScheduleTrackers = [UUID: UUID]()
        var validatedInstallmentSchedules = [UUID: ValidatedInstallmentScheduleSnapshot]()
        var installmentScheduleKeys = Set<String>()
        var transactionTrackers = [UUID: UUID]()
        var transactions = [UUID: TransactionSnapshot]()
        for item in decoded {
            switch item {
            case let .tracker(snapshot): trackerIDs.insert(snapshot.id)
            case let .participant(snapshot):
                guard participantTrackers[snapshot.id] == nil else {
                    throw SyncEngineError.invalidServerResponse
                }
                participantTrackers[snapshot.id] = snapshot.trackerID
            case let .account(snapshot):
                accountTrackers[snapshot.id] = snapshot.trackerID
            case let .category(snapshot):
                categoryIDs.insert(snapshot.id)
                categoryKinds[snapshot.id] = snapshot.kind
                if let trackerID = snapshot.trackerID {
                    categoryTrackers[snapshot.id] = trackerID
                }
            case let .tag(snapshot): tagTrackers[snapshot.id] = snapshot.trackerID
            case let .recurringRule(snapshot):
                recurringRuleTrackers[snapshot.id] = snapshot.trackerID
            case let .recurringOccurrence(snapshot):
                guard recurringOccurrenceKeys.insert(snapshot.occurrenceKey).inserted else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .installmentPlan(snapshot):
                guard installmentPlans[snapshot.id] == nil else {
                    throw SyncEngineError.invalidServerResponse
                }
                installmentPlanTrackers[snapshot.id] = snapshot.trackerID
                installmentPlans[snapshot.id] = snapshot
                validatedInstallmentPlans[snapshot.id] = try validatedInstallmentPlanSnapshot(
                    snapshot
                )
            case let .installmentScheduleItem(snapshot):
                installmentSchedulePlans[snapshot.id] = snapshot.planID
                installmentScheduleTrackers[snapshot.id] = snapshot.trackerID
                validatedInstallmentSchedules[snapshot.id] =
                    try validatedInstallmentScheduleSnapshot(snapshot)
                let key = "\(snapshot.planID)|\(snapshot.revisionNumber)|\(snapshot.sequence)"
                guard installmentScheduleKeys.insert(key).inserted else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .installmentPayment(snapshot):
                _ = try validatedInstallmentPaymentSnapshot(snapshot)
            case let .transaction(snapshot):
                transactionTrackers[snapshot.id] = snapshot.trackerID
                transactions[snapshot.id] = snapshot
            default: break
            }
        }
        for item in decoded {
            switch item {
            case let .membership(snapshot):
                guard trackerIDs.contains(snapshot.trackerID) else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .participant(snapshot):
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
            case let .budget(snapshot):
                guard trackerIDs.contains(snapshot.trackerID),
                      snapshot.categoryIDs.allSatisfy({
                          categoryTrackers[$0] == snapshot.trackerID
                      })
                else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .recurringRule(snapshot):
                guard trackerIDs.contains(snapshot.trackerID),
                      accountTrackers[snapshot.accountID] == snapshot.trackerID,
                      snapshot.categoryID.map({
                          categoryTrackers[$0] == snapshot.trackerID
                      }) ?? true
                else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .installmentPlan(snapshot):
                guard trackerIDs.contains(snapshot.trackerID),
                      accountTrackers[snapshot.accountID] == snapshot.trackerID,
                      snapshot.categoryID.map({
                          categoryTrackers[$0] == snapshot.trackerID &&
                              categoryKinds[$0] == LocalCategoryKind.expense.rawValue
                      }) ?? true
                else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .installmentScheduleItem(snapshot):
                guard let plan = installmentPlans[snapshot.planID],
                      let validatedPlan = validatedInstallmentPlans[snapshot.planID],
                      let validatedSchedule = validatedInstallmentSchedules[snapshot.id],
                      trackerIDs.contains(snapshot.trackerID),
                      installmentPlanTrackers[snapshot.planID] == snapshot.trackerID,
                      snapshot.revisionNumber <= plan.revisionNumber,
                      validatedSchedule.originalDueOn >= validatedPlan.startsOn,
                      validatedSchedule.dueOn >= validatedPlan.startsOn
                else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .transaction(snapshot):
                try validateSplitSnapshot(
                    snapshot,
                    participantTrackers: participantTrackers
                )
                guard trackerIDs.contains(snapshot.trackerID),
                      snapshot.movements.allSatisfy({
                          accountTrackers[$0.accountID] == snapshot.trackerID
                      }),
                      snapshot.allocations.allSatisfy({
                          categoryIDs.contains($0.categoryID) &&
                              categoryTrackers[$0.categoryID] == snapshot.trackerID
                      }),
                      snapshot.tagIDs.allSatisfy({ tagTrackers[$0] == snapshot.trackerID })
                else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .attachment(snapshot):
                guard trackerIDs.contains(snapshot.trackerID),
                      transactionTrackers[snapshot.transactionID] == snapshot.trackerID
                else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .settlement(snapshot):
                guard trackerIDs.contains(snapshot.trackerID),
                      snapshot.fromParticipantID != snapshot.toParticipantID,
                      participantTrackers[snapshot.fromParticipantID] == snapshot.trackerID,
                      participantTrackers[snapshot.toParticipantID] == snapshot.trackerID,
                      snapshot.transactionID.map({ transactionID in
                          guard let transaction = transactions[transactionID] else {
                              return false
                          }
                          return transaction.trackerID == snapshot.trackerID &&
                              transaction.kind == TransactionKind.settlement.rawValue &&
                              transaction.amountMinor == snapshot.amountMinor &&
                              transaction.currency == snapshot.currency &&
                              transaction.currencyExponent == snapshot.currencyExponent
                      }) ?? true
                else {
                    throw SyncEngineError.invalidServerResponse
                }
                _ = try validatedSettlementSnapshot(snapshot)
            case let .recurringOccurrence(snapshot):
                guard trackerIDs.contains(snapshot.trackerID),
                      recurringRuleTrackers[snapshot.ruleID] == snapshot.trackerID,
                      snapshot.transactionID.map({
                          transactionTrackers[$0] == snapshot.trackerID
                      }) ?? true
                else {
                    throw SyncEngineError.invalidServerResponse
                }
            case let .installmentPayment(snapshot):
                guard let plan = installmentPlans[snapshot.planID],
                      let transaction = transactions[snapshot.transactionID],
                      let kind = TransactionKind(rawValue: transaction.kind),
                      let source = TransactionSource(rawValue: transaction.source),
                      let primary = primaryMovement(transaction.movements, kind: kind),
                      trackerIDs.contains(snapshot.trackerID),
                      installmentPlanTrackers[snapshot.planID] == snapshot.trackerID,
                      transactionTrackers[snapshot.transactionID] == snapshot.trackerID,
                      primary.accountID == plan.accountID,
                      primary.signedAmountMinor < 0,
                      kind == .expense,
                      source == .installment,
                      transaction.status == TransactionStatus.posted.rawValue,
                      transaction.amountMinor == snapshot.amountMinor,
                      transaction.currency == plan.currency,
                      transaction.currencyExponent == plan.currencyExponent,
                      snapshot.appliedAmountMinor <= plan.plannedTotalMinor,
                      snapshot.scheduleItemID.map({
                          installmentSchedulePlans[$0] == snapshot.planID &&
                              installmentScheduleTrackers[$0] == snapshot.trackerID
                      }) ?? true
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
        case "participant":
            .participant(try SyncSnapshotDecoder.decode(ParticipantSnapshot.self, from: data))
        case "account":
            .account(try SyncSnapshotDecoder.decode(AccountSnapshot.self, from: data))
        case "category":
            .category(try SyncSnapshotDecoder.decode(CategorySnapshot.self, from: data))
        case "tag":
            .tag(try SyncSnapshotDecoder.decode(TagSnapshot.self, from: data))
        case "budget":
            .budget(try SyncSnapshotDecoder.decode(BudgetSnapshot.self, from: data))
        case "recurring_rule":
            .recurringRule(
                try SyncSnapshotDecoder.decode(RecurringRuleSnapshot.self, from: data)
            )
        case "recurring_occurrence":
            .recurringOccurrence(
                try SyncSnapshotDecoder.decode(RecurringOccurrenceSnapshot.self, from: data)
            )
        case "installment_plan":
            .installmentPlan(
                try SyncSnapshotDecoder.decode(InstallmentPlanSnapshot.self, from: data)
            )
        case "installment_schedule_item":
            .installmentScheduleItem(
                try SyncSnapshotDecoder.decode(InstallmentScheduleItemSnapshot.self, from: data)
            )
        case "installment_payment":
            .installmentPayment(
                try SyncSnapshotDecoder.decode(InstallmentPaymentSnapshot.self, from: data)
            )
        case "transaction":
            .transaction(try SyncSnapshotDecoder.decode(TransactionSnapshot.self, from: data))
        case "attachment":
            .attachment(try SyncSnapshotDecoder.decode(AttachmentSnapshot.self, from: data))
        case "settlement":
            .settlement(try SyncSnapshotDecoder.decode(SettlementSnapshot.self, from: data))
        default:
            .ignored
        }
    }

    private func applyDecoded(_ remote: DecodedRemote, scopeKey: String) throws {
        switch remote {
        case let .tracker(snapshot): try upsertTracker(snapshot, scopeKey: scopeKey)
        case let .membership(snapshot): try upsertMembership(snapshot, scopeKey: scopeKey)
        case let .participant(snapshot): try upsertParticipant(snapshot, scopeKey: scopeKey)
        case let .account(snapshot): try upsertAccount(snapshot, scopeKey: scopeKey)
        case let .category(snapshot): try upsertCategory(snapshot, scopeKey: scopeKey)
        case let .tag(snapshot): try upsertTag(snapshot, scopeKey: scopeKey)
        case let .budget(snapshot): try upsertBudget(snapshot, scopeKey: scopeKey)
        case let .recurringRule(snapshot): try upsertRecurringRule(snapshot, scopeKey: scopeKey)
        case let .recurringOccurrence(snapshot):
            try upsertRecurringOccurrence(snapshot, scopeKey: scopeKey)
        case let .installmentPlan(snapshot):
            try upsertInstallmentPlan(snapshot, scopeKey: scopeKey)
        case let .installmentScheduleItem(snapshot):
            try upsertInstallmentScheduleItem(snapshot, scopeKey: scopeKey)
        case let .installmentPayment(snapshot):
            try upsertInstallmentPayment(snapshot, scopeKey: scopeKey)
        case let .transaction(snapshot): try upsertTransaction(snapshot, scopeKey: scopeKey)
        case let .attachment(snapshot): try upsertAttachment(snapshot, scopeKey: scopeKey)
        case let .settlement(snapshot): try upsertSettlement(snapshot, scopeKey: scopeKey)
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
        if respectPending {
            guard try !hasLocalMutation(
                scopeKey: scopeKey,
                entityType: entityType,
                entityID: entityID
            ) else { return }
        }
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
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let tracker = existing ?? LocalTracker(
            id: snapshot.id,
            scopeKey: scopeKey,
            name: snapshot.name,
            baseCurrencyCode: snapshot.baseCurrency,
            baseCurrencyExponent: exponent,
            syncState: .synced,
            createdAt: createdAt
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
        tracker.createdAt = createdAt
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
        let joinedAt = try parseTimestamp(snapshot.joinedAt)
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let membership = existing ?? LocalTrackerMembership(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            userID: snapshot.userID,
            email: snapshot.email,
            role: role,
            state: snapshot.state,
            serverVersion: snapshot.version,
            joinedAt: joinedAt,
            createdAt: createdAt
        )
        if existing == nil { modelContext.insert(membership) }
        membership.trackerID = snapshot.trackerID
        membership.userID = snapshot.userID
        membership.email = snapshot.email
        membership.roleRaw = role.rawValue
        membership.stateRaw = snapshot.state
        membership.serverVersion = snapshot.version
        membership.joinedAt = joinedAt
        membership.createdAt = createdAt
        membership.updatedAt = try parseTimestamp(snapshot.updatedAt)
        membership.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
    }

    private func upsertParticipant(
        _ snapshot: ParticipantSnapshot,
        scopeKey: String
    ) throws {
        let name = snapshot.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trackerID = snapshot.trackerID
        guard snapshot.version > 0,
              !name.isEmpty,
              (snapshot.linkedUserID == nil) == (snapshot.linkedEmail == nil),
              try modelContext.fetch(
                  FetchDescriptor<LocalTracker>(
                      predicate: #Predicate {
                          $0.scopeKey == scopeKey && $0.id == trackerID
                      }
                  )
              ).first != nil
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let updatedAt = try parseTimestamp(snapshot.updatedAt)
        guard updatedAt >= createdAt else { throw SyncEngineError.invalidServerResponse }
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalParticipant>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let participant = existing ?? LocalParticipant(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            linkedUserID: snapshot.linkedUserID,
            linkedEmail: snapshot.linkedEmail,
            displayName: name,
            serverVersion: snapshot.version,
            syncState: .synced,
            createdAt: createdAt
        )
        if existing == nil { modelContext.insert(participant) }
        participant.trackerID = snapshot.trackerID
        participant.linkedUserID = snapshot.linkedUserID
        participant.linkedEmail = snapshot.linkedEmail
        participant.displayName = name
        participant.archivedAt = try parseOptionalTimestamp(snapshot.archivedAt)
        participant.serverVersion = snapshot.version
        participant.syncStateRaw = LocalSyncState.synced.rawValue
        participant.createdAt = createdAt
        participant.updatedAt = updatedAt
        participant.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
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
        let openingDate = try parseDate(snapshot.openingDate)
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let account = existing ?? LocalAccount(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            name: snapshot.name,
            type: type,
            currencyCode: snapshot.currency,
            currencyExponent: snapshot.currencyExponent,
            openingBalanceMinor: snapshot.openingBalanceMinor,
            openingDate: openingDate,
            syncState: .synced,
            createdAt: createdAt
        )
        if existing == nil { modelContext.insert(account) }
        account.trackerID = snapshot.trackerID
        account.name = snapshot.name
        account.typeRaw = snapshot.type
        account.currencyCode = snapshot.currency
        account.currencyExponent = snapshot.currencyExponent
        account.openingBalanceMinor = snapshot.openingBalanceMinor
        account.openingDate = openingDate
        account.colorHex = snapshot.color
        account.icon = snapshot.icon
        account.includeInNetWorth = snapshot.includeInNetWorth
        account.creditLimitMinor = snapshot.creditLimitMinor
        account.serverVersion = snapshot.version
        account.syncStateRaw = LocalSyncState.synced.rawValue
        account.createdAt = createdAt
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
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let category = existing ?? LocalCategory(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: trackerID,
            parentID: snapshot.parentID,
            kind: kind,
            name: snapshot.name,
            syncState: .synced,
            createdAt: createdAt
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
        category.createdAt = createdAt
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
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let tag = existing ?? LocalTag(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            name: snapshot.name,
            colorHex: snapshot.color,
            syncState: .synced,
            createdAt: createdAt
        )
        if existing == nil { modelContext.insert(tag) }
        tag.trackerID = snapshot.trackerID
        tag.name = snapshot.name
        tag.colorHex = snapshot.color
        tag.serverVersion = snapshot.version
        tag.syncStateRaw = LocalSyncState.synced.rawValue
        tag.createdAt = createdAt
        tag.updatedAt = try parseTimestamp(snapshot.updatedAt)
        tag.archivedAt = try parseOptionalTimestamp(snapshot.archivedAt)
        tag.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
    }

    private func upsertBudget(_ snapshot: BudgetSnapshot, scopeKey: String) throws {
        guard let budgetScope = BudgetScope(rawValue: snapshot.scope),
              let period = BudgetPeriod(rawValue: snapshot.period),
              TimeZone(identifier: snapshot.timeZone) != nil,
              snapshot.amountMinor > 0,
              Set(snapshot.categoryIDs) == Set(snapshot.categorySnapshots.map(\.categoryID)),
              Set(snapshot.thresholdPercentages).count == snapshot.thresholdPercentages.count,
              !snapshot.thresholdPercentages.isEmpty,
              snapshot.thresholdPercentages.allSatisfy({ (1 ... 1000).contains($0) }),
              (budgetScope == .tracker && snapshot.categoryIDs.isEmpty) ||
                (budgetScope == .categories && !snapshot.categoryIDs.isEmpty)
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let money = try Money(
            minorUnits: snapshot.amountMinor,
            currencyCode: snapshot.currency,
            exponent: snapshot.currencyExponent
        )
        let startsOn = try parseDate(snapshot.startsOn)
        let endsOn = try snapshot.endsOn.map { try parseDate($0) }
        guard (endsOn == nil || endsOn! >= startsOn), period != .custom || endsOn != nil else {
            throw SyncEngineError.invalidServerResponse
        }
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalBudget>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let budget = existing ?? LocalBudget(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            name: snapshot.name,
            budgetScope: budgetScope,
            period: period,
            money: money,
            timeZoneIdentifier: snapshot.timeZone,
            startsOn: startsOn,
            endsOn: endsOn,
            rollover: snapshot.rollover,
            syncState: .synced,
            createdAt: createdAt
        )
        if existing == nil { modelContext.insert(budget) }
        budget.trackerID = snapshot.trackerID
        budget.name = snapshot.name
        budget.budgetScopeRaw = snapshot.scope
        budget.periodRaw = snapshot.period
        budget.amountMinor = snapshot.amountMinor
        budget.currencyCode = snapshot.currency
        budget.currencyExponent = snapshot.currencyExponent
        budget.timeZoneIdentifier = snapshot.timeZone
        budget.startsOn = startsOn
        budget.endsOn = endsOn
        budget.rollover = snapshot.rollover
        budget.serverVersion = snapshot.version
        budget.syncStateRaw = LocalSyncState.synced.rawValue
        budget.createdAt = createdAt
        budget.updatedAt = try parseTimestamp(snapshot.updatedAt)
        budget.archivedAt = try parseOptionalTimestamp(snapshot.archivedAt)
        budget.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
        try replaceBudgetChildren(snapshot, scopeKey: scopeKey)
    }

    private func replaceBudgetChildren(_ snapshot: BudgetSnapshot, scopeKey: String) throws {
        let budgetID = snapshot.id
        for value in try modelContext.fetch(
            FetchDescriptor<LocalBudgetCategory>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.budgetID == budgetID
                }
            )
        ) {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalBudgetThreshold>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.budgetID == budgetID
                }
            )
        ) {
            modelContext.delete(value)
        }
        for category in snapshot.categorySnapshots {
            modelContext.insert(
                LocalBudgetCategory(
                    scopeKey: scopeKey,
                    budgetID: budgetID,
                    categoryID: category.categoryID,
                    categoryNameSnapshot: category.name,
                    categoryVersionSnapshot: category.version
                )
            )
        }
        for threshold in snapshot.thresholdPercentages {
            modelContext.insert(
                LocalBudgetThreshold(
                    scopeKey: scopeKey,
                    budgetID: budgetID,
                    percent: threshold
                )
            )
        }
    }

    private func upsertRecurringRule(
        _ snapshot: RecurringRuleSnapshot,
        scopeKey: String
    ) throws {
        guard let kind = RecurringRuleKind(rawValue: snapshot.kind),
              let cadence = RecurringCadence(rawValue: snapshot.cadence),
              let state = RecurringRuleState(rawValue: snapshot.state),
              let localTimeSeconds = RecurringTimeCodec.seconds(from: snapshot.localTime),
              TimeZone(identifier: snapshot.timeZone) != nil,
              snapshot.version > 0,
              snapshot.amountMinor > 0,
              snapshot.accountAmountMinor > 0,
              snapshot.baseAmountMinor > 0,
              let rate = Decimal(
                  string: snapshot.rateSnapshot,
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              rate > 0
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let customUnit = snapshot.customIntervalUnit.isEmpty
            ? nil : RecurringIntervalUnit(rawValue: snapshot.customIntervalUnit)
        guard (cadence == .custom && customUnit != nil &&
                (2 ... 365).contains(snapshot.customIntervalCount)) ||
            (cadence != .custom && customUnit == nil && snapshot.customIntervalCount == 1)
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let money = try Money(
            minorUnits: snapshot.amountMinor,
            currencyCode: snapshot.currency,
            exponent: snapshot.currencyExponent
        )
        let trackerID = snapshot.trackerID
        let accountID = snapshot.accountID
        guard let tracker = try modelContext.fetch(
            FetchDescriptor<LocalTracker>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == trackerID }
            )
        ).first,
        let account = try modelContext.fetch(
            FetchDescriptor<LocalAccount>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == accountID }
            )
        ).first,
        account.trackerID == trackerID,
        snapshot.baseCurrency == tracker.baseCurrencyCode
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let baseMoney = try Money(
            minorUnits: snapshot.baseAmountMinor,
            currencyCode: snapshot.baseCurrency,
            exponent: tracker.baseCurrencyExponent
        )
        guard money.currencyCode != account.currencyCode ||
            (money.exponent == account.currencyExponent &&
                snapshot.accountAmountMinor == money.minorUnits)
        else {
            throw SyncEngineError.invalidServerResponse
        }
        if let categoryID = snapshot.categoryID {
            guard let category = try modelContext.fetch(
                FetchDescriptor<LocalCategory>(
                    predicate: #Predicate {
                        $0.scopeKey == scopeKey && $0.id == categoryID
                    }
                )
            ).first,
            category.trackerID == trackerID,
            category.kind == (kind == .income ? .income : .expense)
            else {
                throw SyncEngineError.invalidServerResponse
            }
        }
        let startsOn = try parseDate(snapshot.startsOn)
        let endsOn = try snapshot.endsOn.map { try parseDate($0) }
        let nextDueOn = try parseDate(snapshot.nextDueOn)
        let trialEndsOn = try snapshot.trialEndsOn.map { try parseDate($0) }
        let pausedAt = try parseOptionalTimestamp(snapshot.pausedAt)
        let endedAt = try parseOptionalTimestamp(snapshot.endedAt)
        let nextDueAt = try parseTimestamp(snapshot.nextDueAt)
        let rateEffectiveAt = try parseTimestamp(snapshot.rateEffectiveAt)
        let calculatedDueAt = try LocalRecurrenceCalculator.scheduledDate(
            civilDate: nextDueOn,
            localTimeSeconds: localTimeSeconds,
            timeZoneIdentifier: snapshot.timeZone
        )
        let expectedConversion = try ReportingConversionSnapshot.resolved(
            original: money,
            baseCurrencyCode: tracker.baseCurrencyCode,
            baseCurrencyExponent: tracker.baseCurrencyExponent,
            manualBaseMoney: money.currencyCode == tracker.baseCurrencyCode ? nil : baseMoney,
            effectiveAt: rateEffectiveAt
        )
        guard let expectedRate = Decimal(
            string: expectedConversion.rateSnapshot,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            throw SyncEngineError.invalidServerResponse
        }
        guard (endsOn == nil || endsOn! >= startsOn),
              nextDueOn >= startsOn,
              endsOn == nil || nextDueOn <= endsOn!,
              nextDueAt == calculatedDueAt,
              snapshot.baseAmountMinor == expectedConversion.baseAmountMinor,
              snapshot.baseCurrency == expectedConversion.baseCurrencyCode,
              rate == expectedRate,
              snapshot.rateSource == expectedConversion.rateSource ||
                (money.currencyCode != tracker.baseCurrencyCode &&
                    !snapshot.rateSource.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty),
              (state == .active && pausedAt == nil && endedAt == nil) ||
                (state == .paused && pausedAt != nil && endedAt == nil) ||
                (state == .ended && pausedAt == nil && endedAt != nil),
              (snapshot.isSubscription &&
                  !snapshot.subscriptionProvider.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty) ||
                (!snapshot.isSubscription &&
                    snapshot.subscriptionProvider.isEmpty &&
                    trialEndsOn == nil &&
                    snapshot.cancellationURL.isEmpty &&
                    snapshot.subscriptionNote.isEmpty),
              snapshot.cancellationURL.isEmpty ||
                URL(string: snapshot.cancellationURL)?.scheme?.lowercased() == "https"
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let conversion = ReportingConversionSnapshot(
            baseAmountMinor: snapshot.baseAmountMinor,
            baseCurrencyCode: snapshot.baseCurrency,
            rateSnapshot: snapshot.rateSnapshot,
            rateSource: snapshot.rateSource,
            effectiveAt: rateEffectiveAt
        )
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalRecurringRule>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let rule = existing ?? LocalRecurringRule(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            name: snapshot.name,
            kind: kind,
            isSubscription: snapshot.isSubscription,
            money: money,
            accountID: snapshot.accountID,
            accountAmountMinor: snapshot.accountAmountMinor,
            categoryID: snapshot.categoryID,
            merchant: snapshot.merchant,
            note: snapshot.note,
            conversion: conversion,
            cadence: cadence,
            customIntervalUnit: customUnit,
            customIntervalCount: snapshot.customIntervalCount,
            timeZoneIdentifier: snapshot.timeZone,
            startsOn: startsOn,
            endsOn: endsOn,
            localTimeSeconds: localTimeSeconds,
            nextDueOn: nextDueOn,
            nextDueAt: nextDueAt,
            subscriptionProvider: snapshot.subscriptionProvider,
            trialEndsOn: trialEndsOn,
            cancellationURL: snapshot.cancellationURL,
            subscriptionNote: snapshot.subscriptionNote,
            syncState: .synced,
            createdAt: createdAt
        )
        if existing == nil { modelContext.insert(rule) }
        rule.trackerID = snapshot.trackerID
        rule.name = snapshot.name
        rule.kindRaw = snapshot.kind
        rule.isSubscription = snapshot.isSubscription
        rule.amountMinor = snapshot.amountMinor
        rule.currencyCode = snapshot.currency
        rule.currencyExponent = snapshot.currencyExponent
        rule.accountID = snapshot.accountID
        rule.accountAmountMinor = snapshot.accountAmountMinor
        rule.categoryID = snapshot.categoryID
        rule.merchant = snapshot.merchant
        rule.note = snapshot.note
        rule.baseAmountMinor = snapshot.baseAmountMinor
        rule.baseCurrencyCode = snapshot.baseCurrency
        rule.rateSnapshot = snapshot.rateSnapshot
        rule.rateSource = snapshot.rateSource
        rule.rateEffectiveAt = conversion.effectiveAt
        rule.cadenceRaw = snapshot.cadence
        rule.customIntervalUnitRaw = snapshot.customIntervalUnit
        rule.customIntervalCount = snapshot.customIntervalCount
        rule.timeZoneIdentifier = snapshot.timeZone
        rule.startsOn = startsOn
        rule.endsOn = endsOn
        rule.localTimeSeconds = localTimeSeconds
        rule.nextDueOn = nextDueOn
        rule.nextDueAt = nextDueAt
        rule.stateRaw = snapshot.state
        rule.pausedAt = pausedAt
        rule.endedAt = endedAt
        rule.subscriptionProvider = snapshot.subscriptionProvider
        rule.trialEndsOn = trialEndsOn
        rule.cancellationURL = snapshot.cancellationURL
        rule.subscriptionNote = snapshot.subscriptionNote
        rule.serverVersion = snapshot.version
        rule.syncStateRaw = LocalSyncState.synced.rawValue
        rule.createdAt = createdAt
        rule.updatedAt = try parseTimestamp(snapshot.updatedAt)
        rule.archivedAt = try parseOptionalTimestamp(snapshot.archivedAt)
        rule.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
    }

    private func upsertRecurringOccurrence(
        _ snapshot: RecurringOccurrenceSnapshot,
        scopeKey: String
    ) throws {
        guard let state = RecurringOccurrenceState(rawValue: snapshot.state),
              snapshot.occurrenceKey.count == 64,
              snapshot.occurrenceKey.allSatisfy({ $0.isHexDigit }),
              snapshot.version > 0,
              snapshot.ruleVersion > 0,
              (state == .posted && snapshot.transactionID != nil &&
                  snapshot.materializedAt != nil && snapshot.skippedAt == nil &&
                  snapshot.errorCode.isEmpty) ||
                (state == .skipped && snapshot.transactionID == nil &&
                    snapshot.materializedAt == nil && snapshot.skippedAt != nil &&
                    snapshot.errorCode.isEmpty) ||
                (state == .failed && snapshot.transactionID == nil &&
                    snapshot.materializedAt == nil && snapshot.skippedAt == nil &&
                    !snapshot.errorCode.isEmpty)
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let ruleID = snapshot.ruleID
        let dueOn = try parseDate(snapshot.dueOn)
        guard let rule = try modelContext.fetch(
            FetchDescriptor<LocalRecurringRule>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == ruleID }
            )
        ).first,
        rule.trackerID == snapshot.trackerID,
        snapshot.occurrenceKey == LocalRecurrenceCalculator.occurrenceKey(
            ruleID: snapshot.ruleID,
            dueOn: dueOn
        )
        else {
            throw SyncEngineError.invalidServerResponse
        }
        if let transactionID = snapshot.transactionID {
            guard let transaction = try modelContext.fetch(
                FetchDescriptor<LedgerTransaction>(
                    predicate: #Predicate {
                        $0.scopeKey == scopeKey && $0.id == transactionID
                    }
                )
            ).first,
            transaction.trackerID == snapshot.trackerID
            else {
                throw SyncEngineError.invalidServerResponse
            }
        }
        let snapshotID = snapshot.id
        let occurrenceKey = snapshot.occurrenceKey
        if let duplicate = try modelContext.fetch(
            FetchDescriptor<LocalRecurringOccurrence>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.occurrenceKey == occurrenceKey
                }
            )
        ).first, duplicate.id != snapshotID {
            throw SyncEngineError.invalidServerResponse
        }
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalRecurringOccurrence>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let existing, existing.serverVersion > snapshot.version { return }
        let scheduledFor = try parseTimestamp(snapshot.scheduledFor)
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let occurrence = existing ?? LocalRecurringOccurrence(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            ruleID: snapshot.ruleID,
            occurrenceKey: snapshot.occurrenceKey,
            dueOn: dueOn,
            scheduledFor: scheduledFor,
            ruleVersion: snapshot.ruleVersion,
            state: state,
            transactionID: snapshot.transactionID,
            serverVersion: snapshot.version,
            createdAt: createdAt
        )
        if existing == nil { modelContext.insert(occurrence) }
        occurrence.trackerID = snapshot.trackerID
        occurrence.ruleID = snapshot.ruleID
        occurrence.occurrenceKey = snapshot.occurrenceKey
        occurrence.dueOn = dueOn
        occurrence.scheduledFor = scheduledFor
        occurrence.ruleVersion = snapshot.ruleVersion
        occurrence.stateRaw = snapshot.state
        occurrence.transactionID = snapshot.transactionID
        occurrence.materializedAt = try parseOptionalTimestamp(snapshot.materializedAt)
        occurrence.skippedAt = try parseOptionalTimestamp(snapshot.skippedAt)
        occurrence.errorCode = snapshot.errorCode
        occurrence.serverVersion = snapshot.version
        occurrence.createdAt = createdAt
        occurrence.updatedAt = try parseTimestamp(snapshot.updatedAt)
        occurrence.deletedAt = nil
    }

    private func validatedInstallmentPlanSnapshot(
        _ snapshot: InstallmentPlanSnapshot
    ) throws -> ValidatedInstallmentPlanSnapshot {
        guard let cadence = InstallmentCadence(rawValue: snapshot.cadence),
              let state = InstallmentPlanState(rawValue: snapshot.state),
              TimeZone(identifier: snapshot.timeZone) != nil,
              snapshot.version > 0,
              snapshot.revisionNumber > 0,
              !snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let money = try Money(
            minorUnits: snapshot.plannedTotalMinor,
            currencyCode: snapshot.currency,
            exponent: snapshot.currencyExponent
        )
        let startsOn = try parseDate(snapshot.startsOn)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expectedTotal = try LocalInstallmentCalculator.plannedTotal(
            principalMinor: snapshot.principalMinor,
            interestMinor: snapshot.interestMinor,
            feesMinor: snapshot.feesMinor
        )
        guard snapshot.anchorDay == calendar.component(.day, from: startsOn),
              snapshot.plannedTotalMinor == expectedTotal,
              snapshot.currency == money.currencyCode
        else {
            throw SyncEngineError.invalidServerResponse
        }
        _ = try LocalInstallmentCalculator.buildSchedule(
            principalMinor: snapshot.principalMinor,
            interestMinor: snapshot.interestMinor,
            feesMinor: snapshot.feesMinor,
            installmentCount: snapshot.installmentCount,
            plannedInstallmentMinor: snapshot.plannedInstallmentMinor,
            cadence: cadence,
            startsOn: startsOn,
            anchorDay: snapshot.anchorDay
        )
        let paidOffAt = try parseOptionalTimestamp(snapshot.paidOffAt)
        let cancelledAt = try parseOptionalTimestamp(snapshot.cancelledAt)
        guard (state == .active && paidOffAt == nil && cancelledAt == nil) ||
            (state == .paidOff && paidOffAt != nil && cancelledAt == nil) ||
            (state == .cancelled && paidOffAt == nil && cancelledAt != nil),
            snapshot.progress.plannedTotalMinor == snapshot.plannedTotalMinor,
            snapshot.progress.paidMinor >= 0,
            snapshot.progress.paidMinor <= snapshot.plannedTotalMinor,
            snapshot.progress.remainingMinor ==
                snapshot.plannedTotalMinor - snapshot.progress.paidMinor,
            state != .paidOff || snapshot.progress.remainingMinor == 0,
            state != .active || snapshot.progress.remainingMinor > 0
        else {
            throw SyncEngineError.invalidServerResponse
        }
        _ = try snapshot.progress.nextDueOn.map { try parseDate($0) }
        _ = try snapshot.progress.estimatedPayoffOn.map { try parseDate($0) }
        return try ValidatedInstallmentPlanSnapshot(
            cadence: cadence,
            state: state,
            money: money,
            startsOn: startsOn,
            paidOffAt: paidOffAt,
            cancelledAt: cancelledAt,
            createdAt: parseTimestamp(snapshot.createdAt),
            updatedAt: parseTimestamp(snapshot.updatedAt),
            archivedAt: parseOptionalTimestamp(snapshot.archivedAt),
            deletedAt: parseOptionalTimestamp(snapshot.deletedAt)
        )
    }

    private func validatedInstallmentScheduleSnapshot(
        _ snapshot: InstallmentScheduleItemSnapshot
    ) throws -> ValidatedInstallmentScheduleSnapshot {
        guard let state = InstallmentScheduleState(rawValue: snapshot.state),
              snapshot.version > 0,
              snapshot.revisionNumber > 0,
              snapshot.sequence > 0,
              snapshot.plannedPrincipalMinor >= 0,
              snapshot.plannedInterestMinor >= 0,
              snapshot.plannedFeesMinor >= 0,
              snapshot.plannedTotalMinor > 0,
              snapshot.paidMinor >= 0,
              snapshot.paidMinor <= snapshot.plannedTotalMinor
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let first = snapshot.plannedPrincipalMinor.addingReportingOverflow(
            snapshot.plannedInterestMinor
        )
        let total = first.partialValue.addingReportingOverflow(snapshot.plannedFeesMinor)
        guard !first.overflow, !total.overflow,
              total.partialValue == snapshot.plannedTotalMinor
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let skippedAt = try parseOptionalTimestamp(snapshot.skippedAt)
        guard (state == .planned && snapshot.paidMinor == 0 && skippedAt == nil) ||
            (state == .partiallyPaid && snapshot.paidMinor > 0 &&
                snapshot.paidMinor < snapshot.plannedTotalMinor && skippedAt == nil) ||
            (state == .paid && snapshot.paidMinor == snapshot.plannedTotalMinor &&
                skippedAt == nil) ||
            (state == .skipped && snapshot.paidMinor == 0 && skippedAt != nil)
        else {
            throw SyncEngineError.invalidServerResponse
        }
        return try ValidatedInstallmentScheduleSnapshot(
            state: state,
            originalDueOn: parseDate(snapshot.originalDueOn),
            dueOn: parseDate(snapshot.dueOn),
            skippedAt: skippedAt,
            supersededAt: parseOptionalTimestamp(snapshot.supersededAt),
            createdAt: parseTimestamp(snapshot.createdAt),
            updatedAt: parseTimestamp(snapshot.updatedAt),
            deletedAt: parseOptionalTimestamp(snapshot.deletedAt)
        )
    }

    private func validatedInstallmentPaymentSnapshot(
        _ snapshot: InstallmentPaymentSnapshot
    ) throws -> ValidatedInstallmentPaymentSnapshot {
        let sum = snapshot.appliedAmountMinor.addingReportingOverflow(
            snapshot.overpaymentMinor
        )
        guard snapshot.version > 0,
              snapshot.amountMinor > 0,
              snapshot.appliedAmountMinor > 0,
              snapshot.overpaymentMinor >= 0,
              !sum.overflow,
              sum.partialValue == snapshot.amountMinor,
              snapshot.extraPayment || snapshot.scheduleItemID != nil
        else {
            throw SyncEngineError.invalidServerResponse
        }
        return try ValidatedInstallmentPaymentSnapshot(
            appliedAt: parseTimestamp(snapshot.appliedAt),
            createdAt: parseTimestamp(snapshot.createdAt),
            updatedAt: parseTimestamp(snapshot.updatedAt),
            deletedAt: parseOptionalTimestamp(snapshot.deletedAt)
        )
    }

    private func upsertInstallmentPlan(
        _ snapshot: InstallmentPlanSnapshot,
        scopeKey: String
    ) throws {
        let validated = try validatedInstallmentPlanSnapshot(snapshot)
        let cadence = validated.cadence
        let state = validated.state
        let money = validated.money
        let startsOn = validated.startsOn
        let trackerID = snapshot.trackerID
        let accountID = snapshot.accountID
        guard try modelContext.fetch(
            FetchDescriptor<LocalTracker>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == trackerID }
            )
        ).first != nil,
        let account = try modelContext.fetch(
            FetchDescriptor<LocalAccount>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == accountID }
            )
        ).first,
        account.trackerID == trackerID
        else {
            throw SyncEngineError.invalidServerResponse
        }
        if let categoryID = snapshot.categoryID {
            guard let category = try modelContext.fetch(
                FetchDescriptor<LocalCategory>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == categoryID }
                )
            ).first,
            category.trackerID == trackerID,
            category.kind == .expense
            else {
                throw SyncEngineError.invalidServerResponse
            }
        }
        let paidOffAt = validated.paidOffAt
        let cancelledAt = validated.cancelledAt
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalInstallmentPlan>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let plan = existing ?? LocalInstallmentPlan(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            name: snapshot.name,
            accountID: snapshot.accountID,
            categoryID: snapshot.categoryID,
            principalMinor: snapshot.principalMinor,
            interestMinor: snapshot.interestMinor,
            feesMinor: snapshot.feesMinor,
            plannedTotalMinor: money.minorUnits,
            currencyCode: money.currencyCode,
            currencyExponent: money.exponent,
            installmentCount: snapshot.installmentCount,
            plannedInstallmentMinor: snapshot.plannedInstallmentMinor,
            cadence: cadence,
            timeZoneIdentifier: snapshot.timeZone,
            startsOn: startsOn,
            anchorDay: snapshot.anchorDay,
            state: state,
            revisionNumber: snapshot.revisionNumber,
            syncState: .synced,
            createdAt: validated.createdAt
        )
        if existing == nil { modelContext.insert(plan) }
        plan.trackerID = snapshot.trackerID
        plan.name = snapshot.name
        plan.accountID = snapshot.accountID
        plan.categoryID = snapshot.categoryID
        plan.principalMinor = snapshot.principalMinor
        plan.interestMinor = snapshot.interestMinor
        plan.feesMinor = snapshot.feesMinor
        plan.plannedTotalMinor = snapshot.plannedTotalMinor
        plan.currencyCode = snapshot.currency
        plan.currencyExponent = snapshot.currencyExponent
        plan.installmentCount = snapshot.installmentCount
        plan.plannedInstallmentMinor = snapshot.plannedInstallmentMinor
        plan.cadenceRaw = snapshot.cadence
        plan.timeZoneIdentifier = snapshot.timeZone
        plan.startsOn = startsOn
        plan.anchorDay = snapshot.anchorDay
        plan.stateRaw = snapshot.state
        plan.revisionNumber = snapshot.revisionNumber
        plan.paidOffAt = paidOffAt
        plan.cancelledAt = cancelledAt
        plan.serverVersion = snapshot.version
        plan.syncStateRaw = LocalSyncState.synced.rawValue
        plan.createdAt = validated.createdAt
        plan.updatedAt = validated.updatedAt
        plan.archivedAt = validated.archivedAt
        plan.deletedAt = validated.deletedAt
    }

    private func upsertInstallmentScheduleItem(
        _ snapshot: InstallmentScheduleItemSnapshot,
        scopeKey: String
    ) throws {
        let validated = try validatedInstallmentScheduleSnapshot(snapshot)
        let state = validated.state
        let skippedAt = validated.skippedAt
        let planID = snapshot.planID
        let originalDueOn = validated.originalDueOn
        let dueOn = validated.dueOn
        guard let plan = try modelContext.fetch(
            FetchDescriptor<LocalInstallmentPlan>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == planID }
            )
        ).first,
        plan.trackerID == snapshot.trackerID,
        snapshot.revisionNumber <= plan.revisionNumber,
        originalDueOn >= plan.startsOn,
        dueOn >= plan.startsOn
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let snapshotID = snapshot.id
        let revisionNumber = snapshot.revisionNumber
        let sequence = snapshot.sequence
        let matching = try modelContext.fetch(
            FetchDescriptor<LocalInstallmentScheduleItem>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.planID == planID &&
                        $0.revisionNumber == revisionNumber &&
                        $0.sequence == sequence
                }
            )
        )
        for preview in matching where preview.id != snapshotID {
            guard preview.serverVersion == 0 else {
                throw SyncEngineError.invalidServerResponse
            }
            modelContext.delete(preview)
        }
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalInstallmentScheduleItem>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let existing, existing.serverVersion > snapshot.version { return }
        let item = existing ?? LocalInstallmentScheduleItem(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            planID: snapshot.planID,
            revisionNumber: snapshot.revisionNumber,
            sequence: snapshot.sequence,
            originalDueOn: originalDueOn,
            dueOn: dueOn,
            plannedPrincipalMinor: snapshot.plannedPrincipalMinor,
            plannedInterestMinor: snapshot.plannedInterestMinor,
            plannedFeesMinor: snapshot.plannedFeesMinor,
            plannedTotalMinor: snapshot.plannedTotalMinor,
            paidMinor: snapshot.paidMinor,
            state: state,
            serverVersion: snapshot.version,
            createdAt: validated.createdAt
        )
        if existing == nil { modelContext.insert(item) }
        item.trackerID = snapshot.trackerID
        item.planID = snapshot.planID
        item.revisionNumber = snapshot.revisionNumber
        item.sequence = snapshot.sequence
        item.originalDueOn = originalDueOn
        item.dueOn = dueOn
        item.plannedPrincipalMinor = snapshot.plannedPrincipalMinor
        item.plannedInterestMinor = snapshot.plannedInterestMinor
        item.plannedFeesMinor = snapshot.plannedFeesMinor
        item.plannedTotalMinor = snapshot.plannedTotalMinor
        item.paidMinor = snapshot.paidMinor
        item.stateRaw = snapshot.state
        item.skippedAt = skippedAt
        item.supersededAt = validated.supersededAt
        item.serverVersion = snapshot.version
        item.createdAt = validated.createdAt
        item.updatedAt = validated.updatedAt
        item.deletedAt = validated.deletedAt
    }

    private func upsertInstallmentPayment(
        _ snapshot: InstallmentPaymentSnapshot,
        scopeKey: String
    ) throws {
        let validated = try validatedInstallmentPaymentSnapshot(snapshot)
        let planID = snapshot.planID
        let transactionID = snapshot.transactionID
        guard let plan = try modelContext.fetch(
            FetchDescriptor<LocalInstallmentPlan>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == planID }
            )
        ).first,
        let transaction = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == transactionID }
            )
        ).first,
        plan.trackerID == snapshot.trackerID,
        transaction.trackerID == snapshot.trackerID,
        transaction.accountID == plan.accountID,
        transaction.kind == .expense,
        transaction.source == .installment,
        transaction.status == .posted,
        transaction.amountMinor == snapshot.amountMinor,
        transaction.currencyCode == plan.currencyCode,
        transaction.currencyExponent == plan.currencyExponent,
        snapshot.appliedAmountMinor <= plan.plannedTotalMinor
        else {
            throw SyncEngineError.invalidServerResponse
        }
        if let scheduleItemID = snapshot.scheduleItemID {
            guard let item = try modelContext.fetch(
                FetchDescriptor<LocalInstallmentScheduleItem>(
                    predicate: #Predicate {
                        $0.scopeKey == scopeKey && $0.id == scheduleItemID
                    }
                )
            ).first,
            item.planID == snapshot.planID,
            item.trackerID == snapshot.trackerID
            else {
                throw SyncEngineError.invalidServerResponse
            }
        }
        let snapshotID = snapshot.id
        if let duplicate = try modelContext.fetch(
            FetchDescriptor<LocalInstallmentPayment>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ).first, duplicate.id != snapshotID {
            throw SyncEngineError.invalidServerResponse
        }
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalInstallmentPayment>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let existing, existing.serverVersion > snapshot.version { return }
        let payment = existing ?? LocalInstallmentPayment(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            planID: snapshot.planID,
            scheduleItemID: snapshot.scheduleItemID,
            transactionID: snapshot.transactionID,
            amountMinor: snapshot.amountMinor,
            appliedAmountMinor: snapshot.appliedAmountMinor,
            overpaymentMinor: snapshot.overpaymentMinor,
            extraPayment: snapshot.extraPayment,
            appliedAt: validated.appliedAt,
            createdByID: snapshot.createdByID,
            serverVersion: snapshot.version,
            createdAt: validated.createdAt
        )
        if existing == nil { modelContext.insert(payment) }
        payment.trackerID = snapshot.trackerID
        payment.planID = snapshot.planID
        payment.scheduleItemID = snapshot.scheduleItemID
        payment.transactionID = snapshot.transactionID
        payment.amountMinor = snapshot.amountMinor
        payment.appliedAmountMinor = snapshot.appliedAmountMinor
        payment.overpaymentMinor = snapshot.overpaymentMinor
        payment.extraPayment = snapshot.extraPayment
        payment.appliedAt = validated.appliedAt
        payment.createdByID = snapshot.createdByID
        payment.serverVersion = snapshot.version
        payment.createdAt = validated.createdAt
        payment.updatedAt = validated.updatedAt
        payment.deletedAt = validated.deletedAt
    }

    private func upsertTransaction(_ snapshot: TransactionSnapshot, scopeKey: String) throws {
        let participantTrackers = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(
                FetchDescriptor<LocalParticipant>(
                    predicate: #Predicate { $0.scopeKey == scopeKey }
                )
            ).map { ($0.id, $0.trackerID) }
        )
        try validateSplitSnapshot(snapshot, participantTrackers: participantTrackers)
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
        let occurredAt = try parseTimestamp(snapshot.occurredAt)
        let createdAt = try parseTimestamp(snapshot.createdAt)
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
            occurredAt: occurredAt,
            syncState: .synced,
            createdAt: createdAt
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
        transaction.occurredAt = occurredAt
        transaction.capturedAt = try parseTimestamp(snapshot.capturedAt)
        transaction.externalEventID = snapshot.externalEventID
        transaction.refundOfID = snapshot.refundOfID
        transaction.serverVersion = snapshot.version
        transaction.syncStateRaw = LocalSyncState.synced.rawValue
        transaction.createdAt = createdAt
        transaction.updatedAt = try parseTimestamp(snapshot.updatedAt)
        transaction.deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
        try replaceChildren(snapshot, scopeKey: scopeKey)
    }

    private func upsertAttachment(
        _ snapshot: AttachmentSnapshot,
        scopeKey: String
    ) throws {
        guard AttachmentContentType(rawValue: snapshot.contentType) != nil,
              LocalAttachmentUploadState(rawValue: snapshot.uploadState) != nil,
              LocalAttachmentScanStatus(rawValue: snapshot.scanStatus) != nil,
              snapshot.byteCount > 0,
              snapshot.checksumSHA256.count == 64,
              snapshot.checksumSHA256.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }),
              !snapshot.originalFilename.isEmpty,
              snapshot.originalFilename.count <= 180,
              let tracker = try modelContext.fetch(
                  FetchDescriptor<LocalTracker>(
                      predicate: #Predicate {
                          $0.scopeKey == scopeKey && $0.id == snapshot.trackerID
                      }
                  )
              ).first,
              tracker.deletedAt == nil,
              let financialTransaction = try modelContext.fetch(
                  FetchDescriptor<LedgerTransaction>(
                      predicate: #Predicate {
                          $0.scopeKey == scopeKey && $0.id == snapshot.transactionID
                      }
                  )
              ).first,
              financialTransaction.trackerID == snapshot.trackerID,
              let createdAt = try? parseTimestamp(snapshot.createdAt),
              let updatedAt = try? parseTimestamp(snapshot.updatedAt)
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let uploadedAt = try parseOptionalTimestamp(snapshot.uploadedAt)
        let deletedAt = try parseOptionalTimestamp(snapshot.deletedAt)
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalAttachment>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        if let existing, existing.serverVersion == nil {
            guard existing.trackerID == snapshot.trackerID,
                  existing.transactionID == snapshot.transactionID,
                  existing.originalFilename == snapshot.originalFilename,
                  existing.contentType == snapshot.contentType,
                  existing.byteCount == snapshot.byteCount,
                  existing.checksumSHA256 == snapshot.checksumSHA256,
                  existing.originalRetained == snapshot.originalRetained
            else {
                throw SyncEngineError.invalidServerResponse
            }
        }
        let attachment = existing ?? LocalAttachment(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            transactionID: snapshot.transactionID,
            originalFilename: snapshot.originalFilename,
            contentType: snapshot.contentType,
            byteCount: snapshot.byteCount,
            checksumSHA256: snapshot.checksumSHA256,
            uploadState: LocalAttachmentUploadState(rawValue: snapshot.uploadState) ?? .pending,
            scanStatus: LocalAttachmentScanStatus(rawValue: snapshot.scanStatus) ?? .error,
            originalRetained: snapshot.originalRetained,
            createdAt: createdAt
        )
        if existing == nil { modelContext.insert(attachment) }
        attachment.trackerID = snapshot.trackerID
        attachment.transactionID = snapshot.transactionID
        attachment.createdByID = snapshot.createdByID
        attachment.lastEditorID = snapshot.lastEditorID
        attachment.originalFilename = snapshot.originalFilename
        attachment.contentType = snapshot.contentType
        attachment.byteCount = snapshot.byteCount
        attachment.checksumSHA256 = snapshot.checksumSHA256
        attachment.uploadStateRaw = snapshot.uploadState
        attachment.scanStatusRaw = snapshot.scanStatus
        attachment.originalRetained = snapshot.originalRetained
        attachment.uploadedAt = uploadedAt
        attachment.serverVersion = snapshot.version
        attachment.createdAt = createdAt
        attachment.updatedAt = updatedAt
        attachment.deletedAt = deletedAt
    }

    private func upsertSettlement(
        _ snapshot: SettlementSnapshot,
        scopeKey: String
    ) throws {
        let validated = try validatedSettlementSnapshot(snapshot)
        let fromID = snapshot.fromParticipantID
        let toID = snapshot.toParticipantID
        guard let from = try modelContext.fetch(
            FetchDescriptor<LocalParticipant>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == fromID }
            )
        ).first,
        let to = try modelContext.fetch(
            FetchDescriptor<LocalParticipant>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == toID }
            )
        ).first,
        from.trackerID == snapshot.trackerID,
        to.trackerID == snapshot.trackerID
        else {
            throw SyncEngineError.invalidServerResponse
        }
        if let transactionID = snapshot.transactionID {
            guard let transaction = try modelContext.fetch(
                FetchDescriptor<LedgerTransaction>(
                    predicate: #Predicate {
                        $0.scopeKey == scopeKey && $0.id == transactionID
                    }
                )
            ).first,
            transaction.trackerID == snapshot.trackerID,
            transaction.kind == .settlement,
            transaction.amountMinor == snapshot.amountMinor,
            transaction.currencyCode == snapshot.currency,
            transaction.currencyExponent == snapshot.currencyExponent
            else {
                throw SyncEngineError.invalidServerResponse
            }
        }
        let snapshotID = snapshot.id
        let existing = try modelContext.fetch(
            FetchDescriptor<LocalSettlement>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == snapshotID }
            )
        ).first
        if let version = existing?.serverVersion, version > snapshot.version { return }
        let settlement = existing ?? LocalSettlement(
            id: snapshot.id,
            scopeKey: scopeKey,
            trackerID: snapshot.trackerID,
            fromParticipantID: snapshot.fromParticipantID,
            toParticipantID: snapshot.toParticipantID,
            money: validated.money,
            occurredAt: validated.occurredAt,
            note: snapshot.note,
            transactionID: snapshot.transactionID,
            serverVersion: snapshot.version,
            syncState: .synced,
            createdAt: validated.createdAt
        )
        if existing == nil { modelContext.insert(settlement) }
        settlement.trackerID = snapshot.trackerID
        settlement.fromParticipantID = snapshot.fromParticipantID
        settlement.toParticipantID = snapshot.toParticipantID
        settlement.amountMinor = snapshot.amountMinor
        settlement.currencyCode = snapshot.currency
        settlement.currencyExponent = snapshot.currencyExponent
        settlement.occurredAt = validated.occurredAt
        settlement.note = snapshot.note
        settlement.transactionID = snapshot.transactionID
        settlement.serverVersion = snapshot.version
        settlement.syncStateRaw = LocalSyncState.synced.rawValue
        settlement.createdAt = validated.createdAt
        settlement.updatedAt = validated.updatedAt
        settlement.deletedAt = validated.deletedAt
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
        for payment in try modelContext.fetch(
            FetchDescriptor<LocalSplitPayment>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) {
            modelContext.delete(payment)
        }
        for share in try modelContext.fetch(
            FetchDescriptor<LocalSplitShare>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) {
            modelContext.delete(share)
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
        for payment in snapshot.split?.payments ?? [] {
            modelContext.insert(
                LocalSplitPayment(
                    id: payment.id,
                    scopeKey: scopeKey,
                    transactionID: transactionID,
                    participantID: payment.participantID,
                    amountMinor: payment.amountMinor,
                    serverVersion: payment.version
                )
            )
        }
        for share in snapshot.split?.shares ?? [] {
            guard let method = LocalSplitMethod(rawValue: share.method) else {
                throw SyncEngineError.invalidServerResponse
            }
            modelContext.insert(
                LocalSplitShare(
                    id: share.id,
                    scopeKey: scopeKey,
                    transactionID: transactionID,
                    participantID: share.participantID,
                    amountMinor: share.amountMinor,
                    method: method,
                    percentageBasisPoints: share.percentageBasisPoints,
                    serverVersion: share.version
                )
            )
        }
    }

    private func validateSplitSnapshot(
        _ snapshot: TransactionSnapshot,
        participantTrackers: [UUID: UUID]
    ) throws {
        guard let split = snapshot.split else { return }
        guard snapshot.kind == TransactionKind.expense.rawValue,
              snapshot.status != TransactionStatus.voided.rawValue,
              snapshot.amountMinor > 0,
              let method = LocalSplitMethod(rawValue: split.method),
              !split.payments.isEmpty,
              !split.shares.isEmpty,
              split.totalPaidMinor == snapshot.amountMinor,
              split.totalOwedMinor == snapshot.amountMinor,
              Set(split.payments.map(\.id)).count == split.payments.count,
              Set(split.shares.map(\.id)).count == split.shares.count,
              Set(split.payments.map(\.participantID)).count == split.payments.count,
              Set(split.shares.map(\.participantID)).count == split.shares.count,
              split.payments.allSatisfy({
                  $0.amountMinor > 0 &&
                      participantTrackers[$0.participantID] == snapshot.trackerID
              }),
              split.shares.allSatisfy({
                  $0.amountMinor > 0 &&
                      $0.method == split.method &&
                      participantTrackers[$0.participantID] == snapshot.trackerID
              }),
              try sumMinorUnits(split.payments.map(\.amountMinor)) == snapshot.amountMinor,
              try sumMinorUnits(split.shares.map(\.amountMinor)) == snapshot.amountMinor
        else {
            throw SyncEngineError.invalidServerResponse
        }

        switch method {
        case .exact:
            guard split.shares.allSatisfy({ $0.percentageBasisPoints == nil }) else {
                throw SyncEngineError.invalidServerResponse
            }
        case .equal:
            guard split.shares.allSatisfy({ $0.percentageBasisPoints == nil }) else {
                throw SyncEngineError.invalidServerResponse
            }
            let ordered = split.shares.sorted {
                $0.participantID.uuidString < $1.participantID.uuidString
            }
            let divisor = Int64(ordered.count)
            let quotient = snapshot.amountMinor / divisor
            let remainder = snapshot.amountMinor % divisor
            guard quotient > 0,
                  ordered.enumerated().allSatisfy({ row in
                      let (index, share) = row
                      return share.amountMinor ==
                          quotient + (Int64(index) < remainder ? 1 : 0)
                  })
            else {
                throw SyncEngineError.invalidServerResponse
            }
        case .percentage:
            let basisPoints = split.shares.compactMap(\.percentageBasisPoints)
            guard basisPoints.count == split.shares.count,
                  basisPoints.allSatisfy({ (1 ... 10_000).contains($0) }),
                  basisPoints.reduce(0, +) == 10_000
            else {
                throw SyncEngineError.invalidServerResponse
            }
            var expected = [UUID: Int64]()
            var remainders = [(remainder: Int64, participantID: UUID)]()
            for share in split.shares {
                guard let rawBasisPoints = share.percentageBasisPoints else {
                    throw SyncEngineError.invalidServerResponse
                }
                let points = Int64(rawBasisPoints)
                let whole = snapshot.amountMinor / 10_000
                let fraction = snapshot.amountMinor % 10_000
                expected[share.participantID] = whole * points + fraction * points / 10_000
                remainders.append((fraction * points % 10_000, share.participantID))
            }
            let allocated = try sumMinorUnits(Array(expected.values))
            let remaining = snapshot.amountMinor - allocated
            guard remaining >= 0, remaining <= Int64(split.shares.count) else {
                throw SyncEngineError.invalidServerResponse
            }
            let ranked = remainders.sorted {
                if $0.remainder != $1.remainder { return $0.remainder > $1.remainder }
                return $0.participantID.uuidString < $1.participantID.uuidString
            }
            for row in ranked.prefix(Int(remaining)) {
                expected[row.participantID, default: 0] += 1
            }
            guard split.shares.allSatisfy({
                expected[$0.participantID] == $0.amountMinor
            }) else {
                throw SyncEngineError.invalidServerResponse
            }
        }
    }

    private func sumMinorUnits(_ values: [Int64]) throws -> Int64 {
        var total: Int64 = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { throw SyncEngineError.invalidServerResponse }
            total = result.partialValue
        }
        return total
    }

    private func validatedSettlementSnapshot(
        _ snapshot: SettlementSnapshot
    ) throws -> ValidatedSettlementSnapshot {
        guard snapshot.version > 0,
              snapshot.amountMinor > 0,
              snapshot.fromParticipantID != snapshot.toParticipantID
        else {
            throw SyncEngineError.invalidServerResponse
        }
        let money = try Money(
            minorUnits: snapshot.amountMinor,
            currencyCode: snapshot.currency,
            exponent: snapshot.currencyExponent
        )
        let occurredAt = try parseTimestamp(snapshot.occurredAt)
        let createdAt = try parseTimestamp(snapshot.createdAt)
        let updatedAt = try parseTimestamp(snapshot.updatedAt)
        guard updatedAt >= createdAt else { throw SyncEngineError.invalidServerResponse }
        return ValidatedSettlementSnapshot(
            money: money,
            occurredAt: occurredAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: try parseOptionalTimestamp(snapshot.deletedAt)
        )
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
        case "participant":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalParticipant>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.archivedAt = changedAt
                value.serverVersion = version
                value.syncStateRaw = LocalSyncState.synced.rawValue
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
        case "budget":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalBudget>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
                value.syncStateRaw = LocalSyncState.synced.rawValue
            }
        case "recurring_rule":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalRecurringRule>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.archivedAt = changedAt
                value.stateRaw = RecurringRuleState.ended.rawValue
                value.pausedAt = nil
                value.endedAt = changedAt
                value.serverVersion = version
                value.syncStateRaw = LocalSyncState.synced.rawValue
            }
        case "recurring_occurrence":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalRecurringOccurrence>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
            }
        case "installment_plan":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalInstallmentPlan>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.archivedAt = changedAt
                value.stateRaw = InstallmentPlanState.cancelled.rawValue
                value.paidOffAt = nil
                value.cancelledAt = changedAt
                value.serverVersion = version
                value.syncStateRaw = LocalSyncState.synced.rawValue
            }
        case "installment_schedule_item":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalInstallmentScheduleItem>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
            }
        case "installment_payment":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalInstallmentPayment>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
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
        case "attachment":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalAttachment>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.deletedAt = changedAt
                value.serverVersion = version
            }
        case "settlement":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalSettlement>(
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
            FetchDescriptor<LocalInstallmentPayment>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ) where !(remoteIDs["installment_payment"] ?? []).contains(value.id) {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalInstallmentScheduleItem>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ) where !(remoteIDs["installment_schedule_item"] ?? []).contains(value.id) &&
            (value.serverVersion > 0 ||
                !pendingKeys.contains("installment_plan|\(value.planID.uuidString)")) {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalRecurringOccurrence>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ) where !(remoteIDs["recurring_occurrence"] ?? []).contains(value.id) {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalSettlement>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["settlement"] ?? []).contains(value.id) &&
            !pendingKeys.contains("settlement|\(value.id.uuidString)") {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalAttachment>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["attachment"] ?? []).contains(value.id) {
            modelContext.delete(value)
        }
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
            FetchDescriptor<LocalBudget>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["budget"] ?? []).contains(value.id) &&
            !pendingKeys.contains("budget|\(value.id.uuidString)") {
            try deleteBudgetAndChildren(value, scopeKey: scopeKey)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalRecurringRule>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["recurring_rule"] ?? []).contains(value.id) &&
            !pendingKeys.contains("recurring_rule|\(value.id.uuidString)") {
            try deleteRecurringRuleAndOccurrences(value, scopeKey: scopeKey)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalInstallmentPlan>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["installment_plan"] ?? []).contains(value.id) &&
            !pendingKeys.contains("installment_plan|\(value.id.uuidString)") {
            try deleteInstallmentPlanAndChildren(value, scopeKey: scopeKey)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalTrackerMembership>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ) where !(remoteIDs["tracker_membership"] ?? []).contains(value.id) {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalParticipant>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.serverVersion != nil }
            )
        ) where !(remoteIDs["participant"] ?? []).contains(value.id) &&
            !pendingKeys.contains("participant|\(value.id.uuidString)") {
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
        for value in try modelContext.fetch(
            FetchDescriptor<LocalSplitPayment>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) { modelContext.delete(value) }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalSplitShare>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ) { modelContext.delete(value) }
        modelContext.delete(transaction)
    }

    private func deleteBudgetAndChildren(_ budget: LocalBudget, scopeKey: String) throws {
        let budgetID = budget.id
        for value in try modelContext.fetch(
            FetchDescriptor<LocalBudgetCategory>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.budgetID == budgetID
                }
            )
        ) { modelContext.delete(value) }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalBudgetThreshold>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.budgetID == budgetID
                }
            )
        ) { modelContext.delete(value) }
        modelContext.delete(budget)
    }

    private func deleteRecurringRuleAndOccurrences(
        _ rule: LocalRecurringRule,
        scopeKey: String
    ) throws {
        let ruleID = rule.id
        for value in try modelContext.fetch(
            FetchDescriptor<LocalRecurringOccurrence>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.ruleID == ruleID
                }
            )
        ) {
            modelContext.delete(value)
        }
        modelContext.delete(rule)
    }

    private func deleteInstallmentPlanAndChildren(
        _ plan: LocalInstallmentPlan,
        scopeKey: String
    ) throws {
        let planID = plan.id
        for value in try modelContext.fetch(
            FetchDescriptor<LocalInstallmentPayment>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.planID == planID
                }
            )
        ) {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(
            FetchDescriptor<LocalInstallmentScheduleItem>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.planID == planID
                }
            )
        ) {
            modelContext.delete(value)
        }
        modelContext.delete(plan)
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

    private func installmentPayload(
        for mutation: OutboxMutation
    ) -> InstallmentPlanMutationPayload? {
        let isPayment = mutation.command == LocalMutationCommand.recordPayment.rawValue ||
            mutation.command == LocalMutationCommand.payoff.rawValue
        guard mutation.entityType == LocalMutationEntity.installmentPlan.rawValue,
              isPayment
        else {
            return nil
        }
        let decoder = localMutationPayloadDecoder()
        return try? decoder.decode(
            InstallmentPlanMutationPayload.self,
            from: mutation.payloadJSON
        )
    }

    private func settlementPayload(
        for mutation: OutboxMutation
    ) -> SettlementMutationPayload? {
        guard mutation.entityType == LocalMutationEntity.settlement.rawValue else {
            return nil
        }
        let decoder = localMutationPayloadDecoder()
        return try? decoder.decode(SettlementMutationPayload.self, from: mutation.payloadJSON)
    }

    private func markSettlementProjection(
        scopeKey: String,
        mutation: OutboxMutation,
        state: LocalSyncState
    ) throws {
        guard mutation.entityType == LocalMutationEntity.settlement.rawValue else {
            return
        }
        let settlementID = mutation.entityID
        let storedTransactionID = try modelContext.fetch(
            FetchDescriptor<LocalSettlement>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.id == settlementID
                }
            )
        ).first?.transactionID
        guard let transactionID = settlementPayload(for: mutation)?.transactionID ??
            storedTransactionID
        else { return }
        if let record = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.id == transactionID
                }
            )
        ).first, record.kind == .settlement {
            record.syncStateRaw = state.rawValue
        }
    }

    private func hasBlockingInstallmentParentMutation(
        remote: DecodedRemote,
        scopeKey: String
    ) throws -> Bool {
        let planID: UUID?
        switch remote {
        case let .installmentScheduleItem(snapshot):
            planID = snapshot.planID
        case let .tombstone(entityType, entityID, _, _)
            where entityType == "installment_schedule_item":
            planID = try modelContext.fetch(
                FetchDescriptor<LocalInstallmentScheduleItem>(
                    predicate: #Predicate {
                        $0.scopeKey == scopeKey && $0.id == entityID
                    }
                )
            ).first?.planID
        default:
            planID = nil
        }
        guard let planID else { return false }
        return try hasLocalMutation(
            scopeKey: scopeKey,
            entityType: LocalMutationEntity.installmentPlan.rawValue,
            entityID: planID
        )
    }

    private func settlementProjectionIDs(
        remote: DecodedRemote,
        scopeKey: String
    ) throws -> [UUID] {
        let transactionID: UUID?
        switch remote {
        case let .transaction(snapshot):
            transactionID = snapshot.id
        case let .tombstone(entityType, entityID, _, _) where entityType == "transaction":
            transactionID = entityID
        default:
            transactionID = nil
        }
        guard let transactionID else { return [] }
        return try modelContext.fetch(
            FetchDescriptor<LocalSettlement>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        ).map(\.id)
    }

    private func hasBlockingSettlementProjectionMutation(
        remote: DecodedRemote,
        scopeKey: String
    ) throws -> Bool {
        for settlementID in try settlementProjectionIDs(remote: remote, scopeKey: scopeKey) {
            if try hasLocalMutation(
                scopeKey: scopeKey,
                entityType: LocalMutationEntity.settlement.rawValue,
                entityID: settlementID
            ) {
                return true
            }
        }
        return false
    }

    private func settlementProjectionBlocked(
        remote: DecodedRemote,
        scopeKey: String,
        pendingKeys: Set<String>
    ) throws -> Bool {
        try settlementProjectionIDs(remote: remote, scopeKey: scopeKey).contains {
            pendingKeys.contains("settlement|\($0.uuidString)")
        }
    }

    private func markInstallmentProjection(
        scopeKey: String,
        mutation: OutboxMutation,
        state: LocalSyncState
    ) throws {
        guard let transactionID = installmentPayload(for: mutation)?.transactionID else {
            return
        }
        if let record = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.id == transactionID
                }
            )
        ).first, record.source == .installment, record.serverVersion == nil {
            record.syncStateRaw = state.rawValue
        }
    }

    private func discardInstallmentProjection(
        scopeKey: String,
        mutation: OutboxMutation
    ) throws {
        guard let transactionID = installmentPayload(for: mutation)?.transactionID else {
            return
        }
        if let record = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.id == transactionID
                }
            )
        ).first, record.source == .installment, record.serverVersion == nil {
            try deleteTransactionAndChildren(record, scopeKey: scopeKey)
        }
    }

    private func preserveDependentInstallmentMutations(
        scopeKey: String,
        resolvedMutation: OutboxMutation,
        current: JSONValue,
        outbox: [OutboxMutation]
    ) throws {
        let encoder = JSONEncoder()
        let currentJSON = try encoder.encode(current)
        for mutation in outbox where
            mutation.operationID != resolvedMutation.operationID &&
            mutation.entityType == resolvedMutation.entityType &&
            mutation.entityID == resolvedMutation.entityID &&
            mutation.localSequence > resolvedMutation.localSequence &&
            mutation.state != .conflicted {
            mutation.stateRaw = LocalSyncState.conflicted.rawValue
            mutation.lastSafeErrorCode = "dependency_conflict"
            mutation.nextAttemptAt = nil
            mutation.updatedAt = .now
            if try unresolvedConflict(
                scopeKey: scopeKey,
                operationID: mutation.operationID
            ) == nil {
                modelContext.insert(
                    SyncConflict(
                        operationID: mutation.operationID,
                        scopeKey: scopeKey,
                        entityType: mutation.entityType,
                        entityID: mutation.entityID,
                        baseServerVersion: mutation.baseServerVersion,
                        currentJSON: currentJSON,
                        proposedJSON: mutation.payloadJSON,
                        safeErrorCode: "dependency_conflict"
                    )
                )
            }
            try markInstallmentProjection(
                scopeKey: scopeKey,
                mutation: mutation,
                state: .conflicted
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
            let projectionState: LocalSyncState = permanent ? .failed : .pending
            mutation.stateRaw = projectionState.rawValue
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
            try markInstallmentProjection(
                scopeKey: scopeKey,
                mutation: mutation,
                state: projectionState
            )
            try markSettlementProjection(
                scopeKey: scopeKey,
                mutation: mutation,
                state: projectionState
            )
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
        case "participant":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalParticipant>(
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
        case "budget":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalBudget>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.syncStateRaw = state.rawValue
                if let serverVersion { value.serverVersion = serverVersion }
            }
        case "recurring_rule":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalRecurringRule>(
                    predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == entityID }
                )
            ).first {
                value.syncStateRaw = state.rawValue
                if let serverVersion { value.serverVersion = serverVersion }
            }
        case "installment_plan":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalInstallmentPlan>(
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
        case "settlement":
            if let value = try modelContext.fetch(
                FetchDescriptor<LocalSettlement>(
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
        formatter.isLenient = false
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
