import Foundation

enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case csv
    case pdf
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .csv: String(localized: "CSV")
        case .pdf: String(localized: "PDF")
        case .full: String(localized: "Full JSON")
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .pdf: "pdf"
        case .full: "json"
        }
    }

    var expectedContentType: String {
        switch self {
        case .csv: "text/csv"
        case .pdf: "application/pdf"
        case .full: "application/json"
        }
    }
}

enum ExportState: String, Codable, Sendable {
    case ready
    case failed
    case expired
}

struct ExportJobCreateRequest: Encodable, Equatable, Sendable {
    let trackerID: UUID
    let format: ExportFormat
    let dateFrom: String?
    let dateTo: String?
    let accountID: UUID?
    let includeNotes: Bool

    enum CodingKeys: String, CodingKey {
        case trackerID = "tracker_id"
        case format
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case accountID = "account_id"
        case includeNotes = "include_notes"
    }
}

struct ExportJobSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let requesterID: UUID
    let trackerID: UUID
    let format: ExportFormat
    let state: ExportState
    let filters: [String: String]
    let byteCount: Int64
    let checksumSHA256: String
    let contentType: String
    let expiresAt: String
    let errorSummary: String
    let downloadURL: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case requesterID = "requester_id"
        case trackerID = "tracker_id"
        case format
        case state
        case filters
        case byteCount = "byte_count"
        case checksumSHA256 = "checksum_sha256"
        case contentType = "content_type"
        case expiresAt = "expires_at"
        case errorSummary = "error_summary"
        case downloadURL = "download_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var expirationDate: Date? {
        APIDate.date(from: expiresAt)
    }

    func isExpired(at date: Date = .now) -> Bool {
        guard let expirationDate else { return true }
        return expirationDate <= date || state == .expired
    }
}

struct DownloadedExport: Equatable, Identifiable, Sendable {
    let id: UUID
    let format: ExportFormat
    let filename: String
    let checksumSHA256: String
    let data: Data
}

protocol ExportTransport: Sendable {
    func listExportJobs(accessToken: String) async throws -> [ExportJobSummary]
    func createExportJob(
        _ request: ExportJobCreateRequest,
        accessToken: String
    ) async throws -> ExportJobSummary
    func downloadExport(job: ExportJobSummary, accessToken: String) async throws -> DownloadedExport
}
