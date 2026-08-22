import Foundation
import SwiftData
import Testing
@testable import ProjectLedger

@MainActor
struct AttachmentTransferQueueTests {
    @Test func enqueueIsIdempotentAndPersistsBoundedMetadata() async throws {
        let fixture = try makeFixture()
        let queue = AttachmentTransferQueue(modelContainer: fixture.container)
        let request = makeRequest(
            scopeKey: fixture.scopeKey,
            transactionID: fixture.transactionID,
            path: "receipts/2026/receipt.jpg",
            contentType: "image/jpeg",
            byteCount: 1_024,
            checksum: String(repeating: "a", count: 64)
        )

        try await queue.enqueue(request)
        try await queue.enqueue(request)

        let items = try fixture.container.mainContext.fetch(
            FetchDescriptor<AttachmentTransfer>()
        )
        #expect(items.count == 1)
        #expect(items.first?.state == .pending)
        #expect(items.first?.localRelativePath == "receipts/2026/receipt.jpg")
        let attachments = try fixture.container.mainContext.fetch(
            FetchDescriptor<LocalAttachment>()
        )
        #expect(attachments.count == 1)
        #expect(attachments.first?.originalFilename == "receipt.pdf")
        #expect(attachments.first?.contentRelativePath == "receipts/2026/receipt.jpg")
        #expect(attachments.first?.thumbnailRelativePath == "thumbnails/receipt.jpg")
    }

    @Test func rejectsUnsafePathInvalidDigestAndCrossScopeTransaction() async throws {
        let fixture = try makeFixture()
        let queue = AttachmentTransferQueue(modelContainer: fixture.container)

        do {
            try await queue.enqueue(
                makeRequest(
                    scopeKey: fixture.scopeKey,
                    transactionID: fixture.transactionID,
                    path: "../receipt.jpg"
                )
            )
            Issue.record("An unsafe relative path was accepted")
        } catch {
            #expect(error as? AttachmentTransferQueueError == .invalidRelativePath)
        }
        do {
            try await queue.enqueue(
                makeRequest(
                    scopeKey: fixture.scopeKey,
                    transactionID: fixture.transactionID,
                    checksum: "not-a-digest"
                )
            )
            Issue.record("An invalid checksum was accepted")
        } catch {
            #expect(error as? AttachmentTransferQueueError == .invalidChecksum)
        }
        do {
            try await queue.enqueue(
                makeRequest(
                    scopeKey: "https://other.example|someone-else",
                    transactionID: fixture.transactionID
                )
            )
            Issue.record("A cross-scope transaction reference was accepted")
        } catch {
            #expect(error as? AttachmentTransferQueueError == .invalidTransaction)
        }
    }

    @Test func interruptedUploadRecoversAndRetryStateIsDurable() async throws {
        let fixture = try makeFixture()
        let queue = AttachmentTransferQueue(modelContainer: fixture.container)
        let request = makeRequest(
            scopeKey: fixture.scopeKey,
            transactionID: fixture.transactionID
        )
        try await queue.enqueue(request)

        try await queue.markUploading(
            scopeKey: fixture.scopeKey,
            attachmentID: request.attachmentID
        )
        try await queue.recoverInterruptedTransfers(scopeKey: fixture.scopeKey)
        let ready = try await queue.readyBatch(scopeKey: fixture.scopeKey, limit: 100)

        #expect(ready.count == 1)
        #expect(ready.first?.attemptCount == 1)
        let item = try #require(
            fixture.container.mainContext.fetch(FetchDescriptor<AttachmentTransfer>()).first
        )
        #expect(item.state == .pending)
        #expect(item.lastSafeErrorCode == "upload_interrupted")
    }

    @Test func pendingUploadCanBeCancelledWithoutDeletingLocalReceipt() async throws {
        let fixture = try makeFixture()
        let queue = AttachmentTransferQueue(modelContainer: fixture.container)
        let request = makeRequest(
            scopeKey: fixture.scopeKey,
            transactionID: fixture.transactionID
        )
        try await queue.enqueue(request)

        try await queue.cancel(
            scopeKey: fixture.scopeKey,
            attachmentID: request.attachmentID
        )

        let macroSafeExpectation1: Bool = try await queue.readyBatch(scopeKey: fixture.scopeKey).isEmpty
        #expect(macroSafeExpectation1)
        let transfer = try #require(
            fixture.container.mainContext.fetch(FetchDescriptor<AttachmentTransfer>()).first
        )
        #expect(transfer.state == .cancelled)
        let macroSafeExpectation2: Bool = try evaluateExpectation {
            try fixture.container.mainContext.fetch(FetchDescriptor<LocalAttachment>()).count == 1
        }
        #expect(macroSafeExpectation2)

        try await queue.retry(
            scopeKey: fixture.scopeKey,
            attachmentID: request.attachmentID
        )
        let readyAfterRetry = try await queue.readyBatch(
            scopeKey: fixture.scopeKey
        )
        #expect(readyAfterRetry.count == 1)
        #expect(readyAfterRetry.first?.attachmentID == request.attachmentID)

        await #expect(throws: AttachmentTransferQueueError.invalidStateTransition) {
            try await queue.retry(
                scopeKey: fixture.scopeKey,
                attachmentID: request.attachmentID
            )
        }
    }

    private func makeRequest(
        attachmentID: UUID = UUID(),
        scopeKey: String,
        transactionID: UUID,
        path: String = "receipts/receipt.pdf",
        originalFilename: String = "receipt.pdf",
        contentType: String = "application/pdf",
        byteCount: Int64 = 2_048,
        checksum: String = String(repeating: "b", count: 64)
    ) -> AttachmentTransferRequest {
        AttachmentTransferRequest(
            attachmentID: attachmentID,
            scopeKey: scopeKey,
            transactionID: transactionID,
            localRelativePath: path,
            originalFilename: originalFilename,
            contentType: contentType,
            byteCount: byteCount,
            checksumSHA256: checksum,
            originalRetained: true,
            thumbnailRelativePath: "thumbnails/receipt.jpg"
        )
    }

    private func makeFixture() throws -> (
        container: ModelContainer,
        scopeKey: String,
        transactionID: UUID
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
        let account = LocalAccount(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            name: "Cash",
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2,
            syncState: .synced
        )
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
        return (container, scopeKey, transaction.id)
    }
}
