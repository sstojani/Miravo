import Foundation
import SwiftData

enum LocalAttachmentUploadState: String, Codable, Sendable {
    case pending
    case ready
    case quarantined
}

enum LocalAttachmentScanStatus: String, Codable, Sendable {
    case pending
    case notConfigured = "not_configured"
    case clean
    case blocked
    case error
}

@Model
final class LocalAttachment {
    #Unique<LocalAttachment>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var transactionID: UUID
    var createdByID: UUID?
    var lastEditorID: UUID?
    var originalFilename: String
    var contentType: String
    var byteCount: Int64
    var checksumSHA256: String
    var uploadStateRaw: String
    var scanStatusRaw: String
    var originalRetained: Bool
    var contentRelativePath: String?
    var thumbnailRelativePath: String?
    var uploadedAt: Date?
    var serverVersion: Int64?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID,
        scopeKey: String,
        trackerID: UUID,
        transactionID: UUID,
        originalFilename: String,
        contentType: String,
        byteCount: Int64,
        checksumSHA256: String,
        uploadState: LocalAttachmentUploadState = .pending,
        scanStatus: LocalAttachmentScanStatus = .pending,
        originalRetained: Bool = true,
        contentRelativePath: String? = nil,
        thumbnailRelativePath: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.transactionID = transactionID
        self.originalFilename = originalFilename
        self.contentType = contentType
        self.byteCount = byteCount
        self.checksumSHA256 = checksumSHA256
        uploadStateRaw = uploadState.rawValue
        scanStatusRaw = scanStatus.rawValue
        self.originalRetained = originalRetained
        self.contentRelativePath = contentRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var uploadState: LocalAttachmentUploadState {
        LocalAttachmentUploadState(rawValue: uploadStateRaw) ?? .pending
    }

    var scanStatus: LocalAttachmentScanStatus {
        LocalAttachmentScanStatus(rawValue: scanStatusRaw) ?? .error
    }
}
