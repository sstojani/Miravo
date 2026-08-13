import Combine
import Foundation
import SwiftData

@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var diagnostics = SyncDiagnosticsSnapshot(
        pendingCount: 0,
        failedCount: 0,
        conflictCount: 0,
        lastSuccessfulSyncAt: nil,
        lastAttemptAt: nil,
        lastSafeErrorCode: nil,
        bootstrapRequired: true,
        isSyncing: false
    )
    @Published private(set) var isRunning = false
    @Published private(set) var realtimeConnected = false
    @Published private(set) var backgroundRefreshScheduled: Bool?
    @Published var message: String?

    private let engine: LedgerSyncActor
    private let attachmentWorker: AttachmentTransferWorker
    private let realtimeClient = SyncInvalidationClient()
    private let connectivityMonitor = ConnectivitySyncMonitor()
    private var rerunRequested = false
    private var foregroundRealtimeEnabled = false

    init(modelContainer: ModelContainer) {
        engine = LedgerSyncActor(modelContainer: modelContainer)
        attachmentWorker = AttachmentTransferWorker(modelContainer: modelContainer)
    }

    @discardableResult
    func synchronize(session: SessionController) async -> Bool {
        guard !isRunning else {
            rerunRequested = true
            return false
        }
        isRunning = true
        message = nil
        defer {
            isRunning = false
            rerunRequested = false
        }
        var pass = 0
        var succeeded = false
        repeat {
            rerunRequested = false
            pass += 1
            succeeded = await synchronizeOnce(session: session)
        } while rerunRequested && pass < 2

        if foregroundRealtimeEnabled {
            await configureRealtime(session: session)
        }
        return succeeded
    }

    func startForegroundTriggers(session: SessionController) async {
        foregroundRealtimeEnabled = true
        connectivityMonitor.start { [weak self, weak session] in
            guard let self, let session else { return }
            Task { await self.synchronize(session: session) }
        }
        await configureRealtime(session: session)
    }

    func stopForegroundTriggers() async {
        foregroundRealtimeEnabled = false
        realtimeConnected = false
        connectivityMonitor.stop()
        await realtimeClient.stop()
    }

    func scheduleBackgroundRefresh() {
        backgroundRefreshScheduled = BackgroundSyncScheduler.schedule()
    }

    private func synchronizeOnce(session: SessionController) async -> Bool {
        do {
            guard let authentication = try await session.synchronizationContext() else {
                return false
            }
            _ = try await engine.synchronize(authentication: authentication)
            do {
                let transfers = try await attachmentWorker.process(authentication: authentication)
                if transfers.uploadedCount > 0 || transfers.quarantinedCount > 0 {
                    rerunRequested = true
                }
                if transfers.quarantinedCount > 0 {
                    message = String(
                        localized: "A receipt was quarantined by the server and needs review."
                    )
                } else if transfers.failedCount > 0 {
                    message = String(
                        localized: "A receipt upload could not be completed. It remains stored on this iPhone."
                    )
                }
            } catch {
                message = String(
                    localized: "Receipt uploads could not be processed. Local receipt files remain safe."
                )
            }
            diagnostics = try await engine.diagnostics(scopeKey: authentication.scopeKey)
            return true
        } catch let error as APIClientError {
            message = message(for: error)
            if let scopeKey = session.scopeKey {
                diagnostics = (try? await engine.diagnostics(scopeKey: scopeKey)) ?? diagnostics
            }
            return false
        } catch is URLError {
            message = String(localized: "The server is unreachable. Local changes will retry later.")
            if let scopeKey = session.scopeKey {
                diagnostics = (try? await engine.diagnostics(scopeKey: scopeKey)) ?? diagnostics
            }
            return false
        } catch {
            message = String(localized: "Synchronization could not be completed. Local changes are safe and will be retried.")
            if let scopeKey = session.scopeKey {
                diagnostics = (try? await engine.diagnostics(scopeKey: scopeKey)) ?? diagnostics
            }
            return false
        }
    }

    private func configureRealtime(session: SessionController) async {
        guard foregroundRealtimeEnabled,
              let authentication = try? await session.synchronizationContext()
        else {
            realtimeConnected = false
            await realtimeClient.stop()
            return
        }
        await realtimeClient.start(
            baseURL: authentication.baseURL,
            tokens: authentication.tokens
        ) { [weak self, weak session] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .connected:
                    self.realtimeConnected = true
                case .disconnected:
                    self.realtimeConnected = false
                case .invalidation:
                    guard let session else { return }
                    await self.synchronize(session: session)
                }
            }
        }
    }

    func refreshDiagnostics(scopeKey: String) async {
        diagnostics = (try? await engine.diagnostics(scopeKey: scopeKey)) ?? diagnostics
    }

    func retryFailed(scopeKey: String, session: SessionController) async {
        do {
            try await engine.retryFailed(scopeKey: scopeKey)
            try await attachmentWorker.retryFailed(scopeKey: scopeKey)
        } catch {
            message = String(localized: "Failed operations could not be prepared for retry.")
            return
        }
        await synchronize(session: session)
    }

    func keepServer(
        scopeKey: String,
        operationID: UUID,
        session: SessionController
    ) async -> Bool {
        do {
            try await engine.resolveKeepServer(scopeKey: scopeKey, operationID: operationID)
            await synchronize(session: session)
            return true
        } catch {
            message = String(localized: "The conflict could not be resolved safely.")
            return false
        }
    }

    func keepMine(
        scopeKey: String,
        operationID: UUID,
        session: SessionController
    ) async -> Bool {
        do {
            try await engine.resolveKeepMine(scopeKey: scopeKey, operationID: operationID)
            await synchronize(session: session)
            return true
        } catch {
            message = String(localized: "The conflict could not be resolved safely.")
            return false
        }
    }

    private func message(for error: APIClientError) -> String {
        switch error.code {
        case "session_revoked", "refresh_reuse_detected", "invalid_refresh_token":
            String(localized: "Server sign-in is required again. Local data remains available offline.")
        case "network_unavailable", "request_failed":
            String(localized: "The server is unreachable. Local changes will retry later.")
        default:
            error.message
        }
    }
}
