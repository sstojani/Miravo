import Foundation

enum SyncPresentationState: Equatable, Sendable {
    case syncing
    case conflict(Int)
    case failed(Int)
    case offline
    case pending(Int)
    case synced
    case notSynchronized

    static func resolve(
        isRunning: Bool,
        pendingCount: Int,
        failedCount: Int,
        conflictCount: Int,
        lastSuccessfulSyncAt: Date?,
        lastSafeErrorCode: String?
    ) -> SyncPresentationState {
        if isRunning { return .syncing }
        if conflictCount > 0 { return .conflict(conflictCount) }
        if failedCount > 0 { return .failed(failedCount) }
        if let lastSafeErrorCode,
           ["network_unavailable", "request_failed"].contains(lastSafeErrorCode) {
            return .offline
        }
        if pendingCount > 0 { return .pending(pendingCount) }
        if lastSuccessfulSyncAt != nil { return .synced }
        return .notSynchronized
    }
}
