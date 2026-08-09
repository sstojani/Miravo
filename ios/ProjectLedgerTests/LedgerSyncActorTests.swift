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

    @Test func paginatedBootstrapStagesThenAtomicallyPublishesAndPullsFromTargetCursor() async throws {
        let container = try makeContainer()
        let trackerID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        let accountID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
        let tagID = UUID(uuidString: "71000000-0000-0000-0000-000000000007")!
        let membershipID = UUID(uuidString: "72000000-0000-0000-0000-000000000007")!
        let transactionID = UUID(uuidString: "73000000-0000-0000-0000-000000000007")!
        let budgetID = UUID(uuidString: "74000000-0000-0000-0000-000000000007")!
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
                        transactions: [transactionRepresentation(
                            id: transactionID,
                            trackerID: trackerID,
                            accountID: accountID,
                            tagID: tagID
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
        #expect(try await store.load(scopeKey: scope) == refreshed)
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

    private func bootstrapData(
        trackers: [JSONValue] = [],
        memberships: [JSONValue] = [],
        accounts: [JSONValue] = [],
        tags: [JSONValue] = [],
        budgets: [JSONValue] = [],
        transactions: [JSONValue] = []
    ) -> JSONValue {
        .object([
            "trackers": .array(trackers),
            "memberships": .array(memberships),
            "accounts": .array(accounts),
            "categories": .array([]),
            "tags": .array(tags),
            "merchants": .array([]),
            "budgets": .array(budgets),
            "transactions": .array(transactions),
        ])
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
            LocalBudget.self,
            LocalBudgetCategory.self,
            LocalBudgetThreshold.self,
            LedgerTransaction.self,
            LocalAccountMovement.self,
            LocalCategoryAllocation.self,
            LocalTransactionTag.self,
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
