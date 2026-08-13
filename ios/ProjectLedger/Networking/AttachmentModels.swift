import Foundation

enum AttachmentContentType: String, Codable, CaseIterable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case heic = "image/heic"
    case heif = "image/heif"
    case webp = "image/webp"
    case pdf = "application/pdf"
}

struct AttachmentReservationRequest: Encodable, Equatable, Sendable {
    let clientPayloadVersion = 1
    let id: UUID
    let trackerID: UUID
    let transactionID: UUID
    let originalFilename: String
    let contentType: String
    let byteCount: Int64
    let checksumSHA256: String
    let originalRetained: Bool

    enum CodingKeys: String, CodingKey {
        case clientPayloadVersion = "client_payload_version"
        case id
        case trackerID = "tracker_id"
        case transactionID = "transaction_id"
        case originalFilename = "original_filename"
        case contentType = "content_type"
        case byteCount = "byte_count"
        case checksumSHA256 = "checksum_sha256"
        case originalRetained = "original_retained"
    }
}

struct AttachmentSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let trackerID: UUID
    let transactionID: UUID
    let createdByID: UUID
    let lastEditorID: UUID
    let originalFilename: String
    let contentType: String
    let byteCount: Int64
    let checksumSHA256: String
    let uploadState: String
    let scanStatus: String
    let originalRetained: Bool
    let uploadedAt: String?
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackerID = "tracker_id"
        case transactionID = "transaction_id"
        case createdByID = "created_by_id"
        case lastEditorID = "last_editor_id"
        case originalFilename = "original_filename"
        case contentType = "content_type"
        case byteCount = "byte_count"
        case checksumSHA256 = "checksum_sha256"
        case uploadState = "upload_state"
        case scanStatus = "scan_status"
        case originalRetained = "original_retained"
        case uploadedAt = "uploaded_at"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

protocol AttachmentTransport: Sendable {
    func reserveAttachment(
        _ request: AttachmentReservationRequest,
        accessToken: String
    ) async throws -> AttachmentSnapshot

    func uploadAttachmentContent(
        id: UUID,
        fileURL: URL,
        contentType: String,
        accessToken: String
    ) async throws -> AttachmentSnapshot
}

protocol AttachmentDownloadTransport: Sendable {
    func downloadAttachmentContent(
        id: UUID,
        expectedContentType: String,
        maximumByteCount: Int64,
        accessToken: String
    ) async throws -> Data
}
