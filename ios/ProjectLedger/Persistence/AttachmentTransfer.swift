import Foundation
import SwiftData

enum AttachmentTransferState: String, Codable, Sendable {
    case pending
    case uploading
    case uploaded
    case failed
    case cancelled
}

@Model
final class AttachmentTransfer {
    #Unique<AttachmentTransfer>([\.scopeKey, \.attachmentID])

    var attachmentID: UUID
    var scopeKey: String
    var transactionID: UUID
    var localRelativePath: String
    var originalFilename: String = "attachment"
    var contentType: String
    var byteCount: Int64
    var checksumSHA256: String
    var originalRetained: Bool = true
    var stateRaw: String
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastSafeErrorCode: String?
    var createdAt: Date
    var updatedAt: Date
    var uploadedAt: Date?

    init(
        attachmentID: UUID = UUID(),
        scopeKey: String,
        transactionID: UUID,
        localRelativePath: String,
        originalFilename: String,
        contentType: String,
        byteCount: Int64,
        checksumSHA256: String,
        originalRetained: Bool = true,
        createdAt: Date = .now
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
        stateRaw = AttachmentTransferState.pending.rawValue
        attemptCount = 0
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var state: AttachmentTransferState {
        AttachmentTransferState(rawValue: stateRaw) ?? .failed
    }
}
