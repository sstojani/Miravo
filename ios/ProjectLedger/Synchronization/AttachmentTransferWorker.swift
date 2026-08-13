import Foundation
import SwiftData

struct AttachmentTransferRunSummary: Equatable, Sendable {
    let uploadedCount: Int
    let quarantinedCount: Int
    let failedCount: Int
}

actor AttachmentTransferWorker {
    private let queue: AttachmentTransferQueue
    private let fileStore: AttachmentFileStore

    init(
        modelContainer: ModelContainer,
        fileStore: AttachmentFileStore = AttachmentFileStore()
    ) {
        queue = AttachmentTransferQueue(modelContainer: modelContainer)
        self.fileStore = fileStore
    }

    func retryFailed(scopeKey: String) async throws {
        try await queue.retryFailed(scopeKey: scopeKey)
    }

    func process(authentication: SyncAuthenticationContext) async throws -> AttachmentTransferRunSummary {
        let latestTokens = try await authentication.tokenStore.load(
            scopeKey: authentication.scopeKey
        ) ?? authentication.tokens
        return try await process(
            scopeKey: authentication.scopeKey,
            accessToken: latestTokens.accessToken,
            transport: APIClient(baseURL: authentication.baseURL)
        )
    }

    func process(
        scopeKey: String,
        accessToken: String,
        transport: any AttachmentTransport
    ) async throws -> AttachmentTransferRunSummary {
        try await queue.recoverInterruptedTransfers(scopeKey: scopeKey)
        let pending = try await queue.readyBatch(scopeKey: scopeKey)
        var uploadedCount = 0
        var quarantinedCount = 0
        var failedCount = 0

        for transfer in pending {
            try Task.checkCancellation()
            try await queue.markUploading(
                scopeKey: scopeKey,
                attachmentID: transfer.attachmentID
            )
            do {
                let verified = try fileStore.verify(
                    relativePath: transfer.localRelativePath,
                    expectedByteCount: transfer.byteCount,
                    expectedChecksumSHA256: transfer.checksumSHA256
                )
                let reservation = try await transport.reserveAttachment(
                    AttachmentReservationRequest(
                        id: transfer.attachmentID,
                        trackerID: transfer.trackerID,
                        transactionID: transfer.transactionID,
                        originalFilename: transfer.originalFilename,
                        contentType: transfer.contentType,
                        byteCount: transfer.byteCount,
                        checksumSHA256: transfer.checksumSHA256,
                        originalRetained: transfer.originalRetained
                    ),
                    accessToken: accessToken
                )
                try validate(reservation, against: transfer)
                try await queue.recordServerSnapshot(scopeKey: scopeKey, snapshot: reservation)
                if reservation.uploadState == LocalAttachmentUploadState.quarantined.rawValue {
                    try await queue.markFailed(
                        scopeKey: scopeKey,
                        attachmentID: transfer.attachmentID,
                        safeErrorCode: "attachment_quarantined",
                        retryAt: nil
                    )
                    quarantinedCount += 1
                    continue
                }

                let uploaded = try await transport.uploadAttachmentContent(
                    id: transfer.attachmentID,
                    fileURL: verified.url,
                    contentType: transfer.contentType,
                    accessToken: accessToken
                )
                try validate(uploaded, against: transfer)
                if uploaded.uploadState == LocalAttachmentUploadState.ready.rawValue {
                    try await queue.markUploaded(scopeKey: scopeKey, snapshot: uploaded)
                    uploadedCount += 1
                } else {
                    try await queue.recordServerSnapshot(scopeKey: scopeKey, snapshot: uploaded)
                    try await queue.markFailed(
                        scopeKey: scopeKey,
                        attachmentID: transfer.attachmentID,
                        safeErrorCode: "attachment_quarantined",
                        retryAt: nil
                    )
                    quarantinedCount += 1
                }
            } catch is CancellationError {
                try? await queue.markFailed(
                    scopeKey: scopeKey,
                    attachmentID: transfer.attachmentID,
                    safeErrorCode: "upload_cancelled",
                    retryAt: .now
                )
                throw CancellationError()
            } catch {
                let retryable = isRetryable(error)
                let retryAt = retryable
                    ? Date.now.addingTimeInterval(
                        SyncRetryPolicy.delay(attempt: transfer.attemptCount + 1, jitter: 1)
                    )
                    : nil
                try await queue.markFailed(
                    scopeKey: scopeKey,
                    attachmentID: transfer.attachmentID,
                    safeErrorCode: safeErrorCode(error),
                    retryAt: retryAt
                )
                failedCount += 1
                if retryable { break }
            }
        }
        return AttachmentTransferRunSummary(
            uploadedCount: uploadedCount,
            quarantinedCount: quarantinedCount,
            failedCount: failedCount
        )
    }

    private func validate(
        _ snapshot: AttachmentSnapshot,
        against transfer: PendingAttachmentTransfer
    ) throws {
        guard snapshot.id == transfer.attachmentID,
              snapshot.trackerID == transfer.trackerID,
              snapshot.transactionID == transfer.transactionID,
              snapshot.originalFilename == transfer.originalFilename,
              snapshot.contentType == transfer.contentType,
              snapshot.byteCount == transfer.byteCount,
              snapshot.checksumSHA256 == transfer.checksumSHA256,
              snapshot.originalRetained == transfer.originalRetained,
              LocalAttachmentUploadState(rawValue: snapshot.uploadState) != nil,
              LocalAttachmentScanStatus(rawValue: snapshot.scanStatus) != nil
        else {
            throw AttachmentTransferQueueError.invalidServerResponse
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let apiError = error as? APIClientError else { return false }
        guard let statusCode = apiError.statusCode else { return true }
        return statusCode == 401 || statusCode == 408 || statusCode == 425 ||
            statusCode == 429 || statusCode >= 500
    }

    private func safeErrorCode(_ error: Error) -> String {
        if let apiError = error as? APIClientError { return apiError.code }
        if error is URLError { return "network_unavailable" }
        if error is AttachmentLocalFileError { return "attachment_local_file_invalid" }
        if error is AttachmentTransferQueueError { return "invalid_server_response" }
        return "attachment_transfer_failed"
    }
}
