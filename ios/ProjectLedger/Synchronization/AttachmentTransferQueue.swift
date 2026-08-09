import Foundation
import SwiftData

enum AttachmentTransferQueueError: Error, Equatable, Sendable {
    case invalidRelativePath
    case invalidContentType
    case invalidByteCount
    case fileTooLarge
    case invalidChecksum
    case invalidTransaction
    case duplicateAttachment
    case invalidStateTransition
}

struct AttachmentTransferRequest: Equatable, Sendable {
    let attachmentID: UUID
    let scopeKey: String
    let transactionID: UUID
    let localRelativePath: String
    let contentType: String
    let byteCount: Int64
    let checksumSHA256: String
}

struct PendingAttachmentTransfer: Equatable, Sendable {
    let attachmentID: UUID
    let transactionID: UUID
    let localRelativePath: String
    let contentType: String
    let byteCount: Int64
    let checksumSHA256: String
    let attemptCount: Int
}

enum AttachmentTransferQueuePolicy {
    static let defaultMaximumByteCount: Int64 = 20 * 1_024 * 1_024
    static let maximumBatchSize = 10
}

@ModelActor
actor AttachmentTransferQueue {
    func enqueue(
        _ request: AttachmentTransferRequest,
        maximumByteCount: Int64 = AttachmentTransferQueuePolicy.defaultMaximumByteCount
    ) throws {
        try validate(request, maximumByteCount: maximumByteCount)
        guard try transactionExists(
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
                  existing.contentType == request.contentType,
                  existing.byteCount == request.byteCount,
                  existing.checksumSHA256 == request.checksumSHA256
            else {
                throw AttachmentTransferQueueError.duplicateAttachment
            }
            return
        }

        modelContext.insert(
            AttachmentTransfer(
                attachmentID: request.attachmentID,
                scopeKey: request.scopeKey,
                transactionID: request.transactionID,
                localRelativePath: request.localRelativePath,
                contentType: request.contentType,
                byteCount: request.byteCount,
                checksumSHA256: request.checksumSHA256
            )
        )
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
        return try modelContext.fetch(descriptor)
            .lazy
            .filter {
                $0.state == .pending && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
            }
            .prefix(min(max(limit, 1), AttachmentTransferQueuePolicy.maximumBatchSize))
            .map {
                PendingAttachmentTransfer(
                    attachmentID: $0.attachmentID,
                    transactionID: $0.transactionID,
                    localRelativePath: $0.localRelativePath,
                    contentType: $0.contentType,
                    byteCount: $0.byteCount,
                    checksumSHA256: $0.checksumSHA256,
                    attemptCount: $0.attemptCount
                )
            }
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

    func markUploaded(scopeKey: String, attachmentID: UUID, at date: Date = .now) throws {
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
        item.stateRaw = AttachmentTransferState.failed.rawValue
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

    func cancel(scopeKey: String, attachmentID: UUID) throws {
        guard let item = try transfer(scopeKey: scopeKey, attachmentID: attachmentID),
              item.state != .uploaded,
              item.state != .cancelled
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
        let pathParts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              pathParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw AttachmentTransferQueueError.invalidRelativePath
        }
        let contentType = request.contentType.lowercased()
        let allowedContentTypes = [
            "application/pdf",
            "image/heic",
            "image/heif",
            "image/jpeg",
            "image/png",
        ]
        guard request.contentType == contentType,
              allowedContentTypes.contains(contentType)
        else {
            throw AttachmentTransferQueueError.invalidContentType
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

    private func transactionExists(scopeKey: String, transactionID: UUID) throws -> Bool {
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.scopeKey == scopeKey &&
                    $0.id == transactionID &&
                    $0.deletedAt == nil
            }
        )
        return try modelContext.fetchCount(descriptor) == 1
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
