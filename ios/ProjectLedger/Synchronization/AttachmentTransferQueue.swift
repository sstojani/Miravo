import Foundation
import SwiftData

enum AttachmentTransferQueueError: Error, Equatable, Sendable {
    case invalidRelativePath
    case invalidFilename
    case invalidContentType
    case invalidByteCount
    case fileTooLarge
    case invalidChecksum
    case invalidTransaction
    case duplicateAttachment
    case invalidStateTransition
    case invalidServerResponse
}

struct AttachmentTransferRequest: Equatable, Sendable {
    let attachmentID: UUID
    let scopeKey: String
    let transactionID: UUID
    let localRelativePath: String
    let originalFilename: String
    let contentType: String
    let byteCount: Int64
    let checksumSHA256: String
    let originalRetained: Bool
    let thumbnailRelativePath: String?

    init(
        attachmentID: UUID,
        scopeKey: String,
        transactionID: UUID,
        localRelativePath: String,
        originalFilename: String,
        contentType: String,
        byteCount: Int64,
        checksumSHA256: String,
        originalRetained: Bool,
        thumbnailRelativePath: String? = nil
    ) {
        self.attachmentID = attachmentID
        self.scopeKey = scopeKey
        self.transactionID = transactionID
        self.localRelativePath = localRelativePath
        self.originalFilename = originalFilename
        self.contentType = contentType
        self.byteCount = byteCount
        self.checksumSHA256 = checksumSHA256
        self.originalRetained = originalRetained
        self.thumbnailRelativePath = thumbnailRelativePath
    }
}

struct PendingAttachmentTransfer: Equatable, Sendable {
    let attachmentID: UUID
    let trackerID: UUID
    let transactionID: UUID
    let localRelativePath: String
    let originalFilename: String
    let contentType: String
    let byteCount: Int64
    let checksumSHA256: String
    let originalRetained: Bool
    let attemptCount: Int
}

enum AttachmentTransferQueuePolicy {
    static let defaultMaximumByteCount: Int64 = 12 * 1_024 * 1_024
    static let maximumBatchSize = 10
}

@ModelActor
actor AttachmentTransferQueue {
    func enqueue(
        _ request: AttachmentTransferRequest,
        maximumByteCount: Int64 = AttachmentTransferQueuePolicy.defaultMaximumByteCount
    ) throws {
        try validate(request, maximumByteCount: maximumByteCount)
        guard let transaction = try transaction(
            scopeKey: request.scopeKey,
            transactionID: request.transactionID
        ) else {
            throw AttachmentTransferQueueError.invalidTransaction
        }

        if let existing = try transfer(
            scopeKey: request.scopeKey,
            attachmentID: request.attachmentID
        ) {
            guard existing.transactionID == request.transactionID,
                  existing.localRelativePath == request.localRelativePath,
                  existing.originalFilename == request.originalFilename,
                  existing.contentType == request.contentType,
                  existing.byteCount == request.byteCount,
                  existing.checksumSHA256 == request.checksumSHA256,
                  existing.originalRetained == request.originalRetained
            else {
                throw AttachmentTransferQueueError.duplicateAttachment
            }
            try ensureLocalAttachment(request, trackerID: transaction.trackerID)
            try saveOrRollback()
            return
        }

        modelContext.insert(
            AttachmentTransfer(
                attachmentID: request.attachmentID,
                scopeKey: request.scopeKey,
                transactionID: request.transactionID,
                localRelativePath: request.localRelativePath,
                originalFilename: request.originalFilename,
                contentType: request.contentType,
                byteCount: request.byteCount,
                checksumSHA256: request.checksumSHA256,
                originalRetained: request.originalRetained
            )
        )
        try ensureLocalAttachment(request, trackerID: transaction.trackerID)
        try saveOrRollback()
    }

    func readyBatch(
        scopeKey: String,
        limit: Int = AttachmentTransferQueuePolicy.maximumBatchSize,
        now: Date = .now
    ) throws -> [PendingAttachmentTransfer] {
        let descriptor = FetchDescriptor<AttachmentTransfer>(
            predicate: #Predicate { $0.scopeKey == scopeKey },
            sortBy: [SortDescriptor(\AttachmentTransfer.createdAt)]
        )
        let maximum = min(max(limit, 1), AttachmentTransferQueuePolicy.maximumBatchSize)
        var ready: [PendingAttachmentTransfer] = []
        for item in try modelContext.fetch(descriptor) where
            item.state == .pending && (item.nextAttemptAt == nil || item.nextAttemptAt! <= now) {
            guard let transaction = try transaction(
                scopeKey: scopeKey,
                transactionID: item.transactionID
            ), transaction.serverVersion != nil else { continue }
            ready.append(
                PendingAttachmentTransfer(
                    attachmentID: item.attachmentID,
                    trackerID: transaction.trackerID,
                    transactionID: item.transactionID,
                    localRelativePath: item.localRelativePath,
                    originalFilename: item.originalFilename,
                    contentType: item.contentType,
                    byteCount: item.byteCount,
                    checksumSHA256: item.checksumSHA256,
                    originalRetained: item.originalRetained,
                    attemptCount: item.attemptCount
                )
            )
            if ready.count == maximum { break }
        }
        return ready
    }

    func markUploading(scopeKey: String, attachmentID: UUID) throws {
        guard let item = try transfer(scopeKey: scopeKey, attachmentID: attachmentID),
              item.state == .pending
        else {
            throw AttachmentTransferQueueError.invalidStateTransition
        }
        item.stateRaw = AttachmentTransferState.uploading.rawValue
        item.attemptCount += 1
        item.nextAttemptAt = nil
        item.lastSafeErrorCode = nil
        item.updatedAt = .now
        try saveOrRollback()
    }

    func recordServerSnapshot(scopeKey: String, snapshot: AttachmentSnapshot) throws {
        guard let item = try transfer(scopeKey: scopeKey, attachmentID: snapshot.id),
              let local = try localAttachment(scopeKey: scopeKey, attachmentID: snapshot.id),
              item.transactionID == snapshot.transactionID,
              local.trackerID == snapshot.trackerID,
              item.originalFilename == snapshot.originalFilename,
              item.contentType == snapshot.contentType,
              item.byteCount == snapshot.byteCount,
              item.checksumSHA256 == snapshot.checksumSHA256,
              item.originalRetained == snapshot.originalRetained,
              let uploadState = LocalAttachmentUploadState(rawValue: snapshot.uploadState),
              let scanStatus = LocalAttachmentScanStatus(rawValue: snapshot.scanStatus),
              let createdAt = parseServerTimestamp(snapshot.createdAt),
              let updatedAt = parseServerTimestamp(snapshot.updatedAt),
              let uploadedAt = tryParseOptionalTimestamp(snapshot.uploadedAt),
              let deletedAt = tryParseOptionalTimestamp(snapshot.deletedAt)
        else {
            throw AttachmentTransferQueueError.invalidServerResponse
        }
        local.createdByID = snapshot.createdByID
        local.lastEditorID = snapshot.lastEditorID
        local.uploadStateRaw = uploadState.rawValue
        local.scanStatusRaw = scanStatus.rawValue
        local.uploadedAt = uploadedAt
        local.serverVersion = snapshot.version
        local.createdAt = createdAt
        local.updatedAt = updatedAt
        local.deletedAt = deletedAt
        try saveOrRollback()
    }

    func markUploaded(
        scopeKey: String,
        snapshot: AttachmentSnapshot,
        at date: Date = .now
    ) throws {
        try recordServerSnapshot(scopeKey: scopeKey, snapshot: snapshot)
        guard snapshot.uploadState == LocalAttachmentUploadState.ready.rawValue else {
            throw AttachmentTransferQueueError.invalidServerResponse
        }
        let attachmentID = snapshot.id
        guard let item = try transfer(scopeKey: scopeKey, attachmentID: attachmentID),
              item.state == .uploading
        else {
            throw AttachmentTransferQueueError.invalidStateTransition
        }
        item.stateRaw = AttachmentTransferState.uploaded.rawValue
        item.uploadedAt = date
        item.nextAttemptAt = nil
        item.lastSafeErrorCode = nil
        item.updatedAt = date
        try saveOrRollback()
    }

    func markFailed(
        scopeKey: String,
        attachmentID: UUID,
        safeErrorCode: String,
        retryAt: Date?
    ) throws {
        guard let item = try transfer(scopeKey: scopeKey, attachmentID: attachmentID),
              item.state == .uploading || item.state == .pending
        else {
            throw AttachmentTransferQueueError.invalidStateTransition
        }
        item.stateRaw = retryAt == nil
            ? AttachmentTransferState.failed.rawValue
            : AttachmentTransferState.pending.rawValue
        item.nextAttemptAt = retryAt
        item.lastSafeErrorCode = sanitizedSafeErrorCode(safeErrorCode)
        item.updatedAt = .now
        try saveOrRollback()
    }

    func retryFailed(scopeKey: String) throws {
        let descriptor = FetchDescriptor<AttachmentTransfer>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )
        for item in try modelContext.fetch(descriptor) where item.state == .failed {
            item.stateRaw = AttachmentTransferState.pending.rawValue
            item.nextAttemptAt = nil
            item.lastSafeErrorCode = nil
            item.updatedAt = .now
        }
        try saveOrRollback()
    }

    func retry(scopeKey: String, attachmentID: UUID) throws {
        guard let item = try transfer(scopeKey: scopeKey, attachmentID: attachmentID),
              item.state == .failed || item.state == .cancelled
        else {
            throw AttachmentTransferQueueError.invalidStateTransition
        }
        item.stateRaw = AttachmentTransferState.pending.rawValue
        item.nextAttemptAt = nil
        item.lastSafeErrorCode = nil
        item.updatedAt = .now
        try saveOrRollback()
    }

    func cancel(scopeKey: String, attachmentID: UUID) throws {
        guard let item = try transfer(scopeKey: scopeKey, attachmentID: attachmentID),
              item.state == .pending || item.state == .failed
        else {
            throw AttachmentTransferQueueError.invalidStateTransition
        }
        item.stateRaw = AttachmentTransferState.cancelled.rawValue
        item.nextAttemptAt = nil
        item.lastSafeErrorCode = nil
        item.updatedAt = .now
        try saveOrRollback()
    }

    func recoverInterruptedTransfers(scopeKey: String) throws {
        let descriptor = FetchDescriptor<AttachmentTransfer>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )
        for item in try modelContext.fetch(descriptor) where item.state == .uploading {
            item.stateRaw = AttachmentTransferState.pending.rawValue
            item.nextAttemptAt = nil
            item.lastSafeErrorCode = "upload_interrupted"
            item.updatedAt = .now
        }
        try saveOrRollback()
    }

    private func validate(
        _ request: AttachmentTransferRequest,
        maximumByteCount: Int64
    ) throws {
        let path = request.localRelativePath
        guard isValidRelativePath(path) else {
            throw AttachmentTransferQueueError.invalidRelativePath
        }
        if let thumbnailRelativePath = request.thumbnailRelativePath,
           !isValidRelativePath(thumbnailRelativePath) {
            throw AttachmentTransferQueueError.invalidRelativePath
        }
        let contentType = request.contentType.lowercased()
        let allowedContentTypes = [
            "application/pdf",
            "image/heic",
            "image/heif",
            "image/jpeg",
            "image/png",
            "image/webp",
        ]
        guard request.contentType == contentType,
              allowedContentTypes.contains(contentType)
        else {
            throw AttachmentTransferQueueError.invalidContentType
        }
        let filename = request.originalFilename
        guard !filename.isEmpty,
              filename.count <= 180,
              !filename.contains("/"),
              !filename.contains("\\"),
              filename.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
        else {
            throw AttachmentTransferQueueError.invalidFilename
        }
        guard request.byteCount > 0 else {
            throw AttachmentTransferQueueError.invalidByteCount
        }
        guard maximumByteCount > 0, request.byteCount <= maximumByteCount else {
            throw AttachmentTransferQueueError.fileTooLarge
        }
        let checksum = request.checksumSHA256
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard checksum.count == 64,
              checksum == checksum.lowercased(),
              checksum.unicodeScalars.allSatisfy({ lowercaseHex.contains($0) })
        else {
            throw AttachmentTransferQueueError.invalidChecksum
        }
    }

    private func transaction(
        scopeKey: String,
        transactionID: UUID
    ) throws -> LedgerTransaction? {
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.scopeKey == scopeKey &&
                    $0.id == transactionID &&
                    $0.deletedAt == nil
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func transfer(
        scopeKey: String,
        attachmentID: UUID
    ) throws -> AttachmentTransfer? {
        let descriptor = FetchDescriptor<AttachmentTransfer>(
            predicate: #Predicate {
                $0.scopeKey == scopeKey && $0.attachmentID == attachmentID
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func localAttachment(
        scopeKey: String,
        attachmentID: UUID
    ) throws -> LocalAttachment? {
        let descriptor = FetchDescriptor<LocalAttachment>(
            predicate: #Predicate {
                $0.scopeKey == scopeKey && $0.id == attachmentID
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func ensureLocalAttachment(
        _ request: AttachmentTransferRequest,
        trackerID: UUID
    ) throws {
        if let existing = try localAttachment(
            scopeKey: request.scopeKey,
            attachmentID: request.attachmentID
        ) {
            guard existing.trackerID == trackerID,
                  existing.transactionID == request.transactionID,
                  existing.originalFilename == request.originalFilename,
                  existing.contentType == request.contentType,
                  existing.byteCount == request.byteCount,
                  existing.checksumSHA256 == request.checksumSHA256,
                  existing.originalRetained == request.originalRetained
            else {
                throw AttachmentTransferQueueError.duplicateAttachment
            }
            if let requestedThumbnail = request.thumbnailRelativePath {
                guard existing.thumbnailRelativePath == nil ||
                    existing.thumbnailRelativePath == requestedThumbnail
                else {
                    throw AttachmentTransferQueueError.duplicateAttachment
                }
                existing.thumbnailRelativePath = requestedThumbnail
            }
            guard existing.contentRelativePath == nil ||
                existing.contentRelativePath == request.localRelativePath
            else {
                throw AttachmentTransferQueueError.duplicateAttachment
            }
            existing.contentRelativePath = request.localRelativePath
            return
        }
        modelContext.insert(
            LocalAttachment(
                id: request.attachmentID,
                scopeKey: request.scopeKey,
                trackerID: trackerID,
                transactionID: request.transactionID,
                originalFilename: request.originalFilename,
                contentType: request.contentType,
                byteCount: request.byteCount,
                checksumSHA256: request.checksumSHA256,
                originalRetained: request.originalRetained,
                contentRelativePath: request.localRelativePath,
                thumbnailRelativePath: request.thumbnailRelativePath
            )
        )
    }

    private func isValidRelativePath(_ path: String) -> Bool {
        let pathParts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty &&
            !path.hasPrefix("/") &&
            !path.contains("\\") &&
            pathParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    }

    private func parseServerTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        return ISO8601DateFormatter().date(from: value)
    }

    private func tryParseOptionalTimestamp(_ value: String?) -> Date?? {
        guard let value else { return .some(nil) }
        guard let parsed = parseServerTimestamp(value) else { return nil }
        return .some(parsed)
    }

    private func sanitizedSafeErrorCode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard !value.isEmpty,
              value.count <= 64,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            return "attachment_transfer_failed"
        }
        return value
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
