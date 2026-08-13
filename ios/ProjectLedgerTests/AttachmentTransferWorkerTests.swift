import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct AttachmentTransferWorkerTests {
    @Test func uploadsVerifiedFileAndPersistsServerMetadata() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let content = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) +
            Data("miravo".utf8)
        let relativePath = "pending/receipt.png"
        try write(content, relativePath: relativePath, rootURL: fixture.rootURL)
        let checksum = sha256(content)
        let attachmentID = UUID()
        let queue = AttachmentTransferQueue(modelContainer: fixture.container)
        try await queue.enqueue(
            makeRequest(
                id: attachmentID,
                scopeKey: fixture.scopeKey,
                transactionID: fixture.transactionID,
                relativePath: relativePath,
                byteCount: Int64(content.count),
                checksum: checksum
            )
        )
        let transport = ScriptedAttachmentTransport(mode: .success)
        let worker = AttachmentTransferWorker(
            modelContainer: fixture.container,
            fileStore: AttachmentFileStore(rootURL: fixture.rootURL)
        )

        let summary = try await worker.process(
            scopeKey: fixture.scopeKey,
            accessToken: "test-access-token",
            transport: transport
        )

        #expect(summary == AttachmentTransferRunSummary(
            uploadedCount: 1,
            quarantinedCount: 0,
            failedCount: 0
        ))
        #expect(await transport.reserveCount == 1)
        #expect(await transport.uploadCount == 1)
        let transfer = try #require(
            fixture.container.mainContext.fetch(FetchDescriptor<AttachmentTransfer>()).first
        )
        #expect(transfer.state == .uploaded)
        #expect(transfer.attemptCount == 1)
        let attachment = try #require(
            fixture.container.mainContext.fetch(FetchDescriptor<LocalAttachment>()).first
        )
        #expect(attachment.id == attachmentID)
        #expect(attachment.uploadState == .ready)
        #expect(attachment.scanStatus == .notConfigured)
        #expect(attachment.serverVersion == 2)
    }

    @Test func transientServerFailureReturnsTransferToDelayedPendingState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let content = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) +
            Data("retry".utf8)
        let relativePath = "pending/retry.png"
        try write(content, relativePath: relativePath, rootURL: fixture.rootURL)
        let queue = AttachmentTransferQueue(modelContainer: fixture.container)
        try await queue.enqueue(
            makeRequest(
                scopeKey: fixture.scopeKey,
                transactionID: fixture.transactionID,
                relativePath: relativePath,
                byteCount: Int64(content.count),
                checksum: sha256(content)
            )
        )
        let transport = ScriptedAttachmentTransport(mode: .serverUnavailable)
        let worker = AttachmentTransferWorker(
            modelContainer: fixture.container,
            fileStore: AttachmentFileStore(rootURL: fixture.rootURL)
        )

        let summary = try await worker.process(
            scopeKey: fixture.scopeKey,
            accessToken: "test-access-token",
            transport: transport
        )

        #expect(summary.failedCount == 1)
        let transfer = try #require(
            fixture.container.mainContext.fetch(FetchDescriptor<AttachmentTransfer>()).first
        )
        #expect(transfer.state == .pending)
        #expect(transfer.nextAttemptAt != nil)
        #expect(transfer.lastSafeErrorCode == "server_unavailable")
        #expect(try await queue.readyBatch(scopeKey: fixture.scopeKey).isEmpty)
    }

    @Test func changedLocalFileFailsBeforeAnyNetworkRequest() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let content = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) +
            Data("changed".utf8)
        let relativePath = "pending/changed.png"
        try write(content, relativePath: relativePath, rootURL: fixture.rootURL)
        let queue = AttachmentTransferQueue(modelContainer: fixture.container)
        try await queue.enqueue(
            makeRequest(
                scopeKey: fixture.scopeKey,
                transactionID: fixture.transactionID,
                relativePath: relativePath,
                byteCount: Int64(content.count),
                checksum: String(repeating: "0", count: 64)
            )
        )
        let transport = ScriptedAttachmentTransport(mode: .success)
        let worker = AttachmentTransferWorker(
            modelContainer: fixture.container,
            fileStore: AttachmentFileStore(rootURL: fixture.rootURL)
        )

        let summary = try await worker.process(
            scopeKey: fixture.scopeKey,
            accessToken: "test-access-token",
            transport: transport
        )

        #expect(summary.failedCount == 1)
        #expect(await transport.reserveCount == 0)
        #expect(await transport.uploadCount == 0)
        let transfer = try #require(
            fixture.container.mainContext.fetch(FetchDescriptor<AttachmentTransfer>()).first
        )
        #expect(transfer.state == .failed)
        #expect(transfer.lastSafeErrorCode == "attachment_local_file_invalid")
    }

    private func makeRequest(
        id: UUID = UUID(),
        scopeKey: String,
        transactionID: UUID,
        relativePath: String,
        byteCount: Int64,
        checksum: String
    ) -> AttachmentTransferRequest {
        AttachmentTransferRequest(
            attachmentID: id,
            scopeKey: scopeKey,
            transactionID: transactionID,
            localRelativePath: relativePath,
            originalFilename: "receipt.png",
            contentType: "image/png",
            byteCount: byteCount,
            checksumSHA256: checksum,
            originalRetained: true
        )
    }

    private func write(_ data: Data, relativePath: String, rootURL: URL) throws {
        let destination = rootURL.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeFixture() throws -> (
        container: ModelContainer,
        scopeKey: String,
        transactionID: UUID,
        rootURL: URL
    ) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
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
        let scopeKey = "https://ledger.example|owner"
        let tracker = LocalTracker(
            scopeKey: scopeKey,
            name: "Everyday",
            baseCurrencyCode: "ALL",
            baseCurrencyExponent: 2,
            syncState: .synced
        )
        tracker.serverVersion = 1
        let account = LocalAccount(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            name: "Cash",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2,
            syncState: .synced
        )
        account.serverVersion = 1
        let transaction = LedgerTransaction(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            accountID: account.id,
            kind: .expense,
            money: try Money(minorUnits: 1_000, currencyCode: "ALL", exponent: 2),
            syncState: .synced
        )
        transaction.serverVersion = 1
        container.mainContext.insert(tracker)
        container.mainContext.insert(account)
        container.mainContext.insert(transaction)
        try container.mainContext.save()
        return (
            container,
            scopeKey,
            transaction.id,
            FileManager.default.temporaryDirectory
                .appending(path: "miravo-attachment-worker-\(UUID().uuidString)")
        )
    }
}

private actor ScriptedAttachmentTransport: AttachmentTransport {
    enum Mode: Sendable, Equatable {
        case success
        case serverUnavailable
    }

    private(set) var reserveCount = 0
    private(set) var uploadCount = 0
    private let mode: Mode
    private var reservation: AttachmentReservationRequest?

    init(mode: Mode) {
        self.mode = mode
    }

    func reserveAttachment(
        _ request: AttachmentReservationRequest,
        accessToken: String
    ) async throws -> AttachmentSnapshot {
        #expect(accessToken == "test-access-token")
        reserveCount += 1
        if mode == .serverUnavailable {
            throw APIClientError(
                code: "server_unavailable",
                message: "Unavailable",
                requestID: "request-id",
                statusCode: 503
            )
        }
        reservation = request
        return snapshot(request: request, uploadState: "pending", version: 1)
    }

    func uploadAttachmentContent(
        id: UUID,
        fileURL: URL,
        contentType: String,
        accessToken: String
    ) async throws -> AttachmentSnapshot {
        #expect(accessToken == "test-access-token")
        #expect(contentType == "image/png")
        uploadCount += 1
        let request = try #require(reservation)
        #expect(id == request.id)
        #expect((try? Data(contentsOf: fileURL))?.isEmpty == false)
        return snapshot(request: request, uploadState: "ready", version: 2)
    }

    private func snapshot(
        request: AttachmentReservationRequest,
        uploadState: String,
        version: Int64
    ) -> AttachmentSnapshot {
        AttachmentSnapshot(
            id: request.id,
            trackerID: request.trackerID,
            transactionID: request.transactionID,
            createdByID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            lastEditorID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            originalFilename: request.originalFilename,
            contentType: request.contentType,
            byteCount: request.byteCount,
            checksumSHA256: request.checksumSHA256,
            uploadState: uploadState,
            scanStatus: uploadState == "ready" ? "not_configured" : "pending",
            originalRetained: request.originalRetained,
            uploadedAt: uploadState == "ready" ? "2026-08-13T12:31:00Z" : nil,
            version: version,
            createdAt: "2026-08-13T12:30:00Z",
            updatedAt: "2026-08-13T12:31:00Z",
            deletedAt: nil
        )
    }
}
