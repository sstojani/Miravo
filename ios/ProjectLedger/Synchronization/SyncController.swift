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
    @Published var message: String?

    private let engine: LedgerSyncActor

    init(modelContainer: ModelContainer) {
        engine = LedgerSyncActor(modelContainer: modelContainer)
    }

    func synchronize(session: SessionController) async {
        guard !isRunning else { return }
        isRunning = true
        message = nil
        defer { isRunning = false }
        do {
            guard let authentication = try await session.synchronizationContext() else {
                return
            }
            _ = try await engine.synchronize(authentication: authentication)
            diagnostics = try await engine.diagnostics(scopeKey: authentication.scopeKey)
        } catch let error as APIClientError {
            message = message(for: error)
            if let scopeKey = session.scopeKey {
                diagnostics = (try? await engine.diagnostics(scopeKey: scopeKey)) ?? diagnostics
            }
        } catch is URLError {
            message = String(localized: "The server is unreachable. Local changes will retry later.")
            if let scopeKey = session.scopeKey {
                diagnostics = (try? await engine.diagnostics(scopeKey: scopeKey)) ?? diagnostics
            }
        } catch {
            message = String(localized: "Synchronization could not be completed. Local changes are safe and will be retried.")
            if let scopeKey = session.scopeKey {
                diagnostics = (try? await engine.diagnostics(scopeKey: scopeKey)) ?? diagnostics
            }
        }
    }

    func refreshDiagnostics(scopeKey: String) async {
        diagnostics = (try? await engine.diagnostics(scopeKey: scopeKey)) ?? diagnostics
    }

    func retryFailed(scopeKey: String, session: SessionController) async {
        do {
            try await engine.retryFailed(scopeKey: scopeKey)
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
