import Combine
import Foundation

@MainActor
final class ExportController: ObservableObject {
    typealias TransportFactory = @Sendable (URL) -> any ExportTransport

    @Published private(set) var jobs = [ExportJobSummary]()
    @Published private(set) var isWorking = false
    @Published private(set) var downloadingID: UUID?
    @Published var downloadedExport: DownloadedExport?
    @Published var errorMessage: String?
    @Published var requestID: String?

    private let transportFactory: TransportFactory

    init(transportFactory: @escaping TransportFactory = { APIClient(baseURL: $0) }) {
        self.transportFactory = transportFactory
    }

    func load(authentication: SyncAuthenticationContext) async {
        guard !isWorking else { return }
        isWorking = true
        clearError()
        defer { isWorking = false }
        do {
            jobs = try await transportFactory(authentication.baseURL)
                .listExportJobs(accessToken: authentication.tokens.accessToken)
        } catch {
            present(error)
        }
    }

    @discardableResult
    func create(
        trackerID: UUID,
        format: ExportFormat,
        accountID: UUID?,
        includeNotes: Bool,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        clearError()
        defer { isWorking = false }
        do {
            let created = try await transportFactory(authentication.baseURL)
                .createExportJob(
                    ExportJobCreateRequest(
                        trackerID: trackerID,
                        format: format,
                        dateFrom: nil,
                        dateTo: nil,
                        accountID: accountID,
                        includeNotes: includeNotes
                    ),
                    accessToken: authentication.tokens.accessToken
                )
            jobs.removeAll { $0.id == created.id }
            jobs.insert(created, at: 0)
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func download(
        job: ExportJobSummary,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard downloadingID == nil else { return false }
        downloadingID = job.id
        clearError()
        defer { downloadingID = nil }
        do {
            downloadedExport = try await transportFactory(authentication.baseURL)
                .downloadExport(job: job, accessToken: authentication.tokens.accessToken)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func clearDownloadedExport() {
        downloadedExport = nil
    }

    func presentAuthenticationUnavailable() {
        errorMessage = String(
            localized: "Server sign-in is required to create and download exports."
        )
        requestID = nil
    }

    private func clearError() {
        errorMessage = nil
        requestID = nil
    }

    private func present(_ error: Error) {
        switch error {
        case let apiError as APIClientError:
            errorMessage = apiError.message
            requestID = apiError.requestID
        default:
            errorMessage = String(localized: "The request could not be completed.")
            requestID = nil
        }
    }
}
