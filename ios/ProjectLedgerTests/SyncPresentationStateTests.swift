import Foundation
import Testing
@testable import ProjectLedger

struct SyncPresentationStateTests {
    @Test func statePriorityIsDeterministic() {
        #expect(resolve(running: true, pending: 2, failed: 1, conflicts: 1) == .syncing)
        #expect(resolve(pending: 2, failed: 1, conflicts: 1) == .conflict(1))
        #expect(resolve(pending: 2, failed: 1) == .failed(1))
        #expect(resolve(pending: 2, code: "network_unavailable") == .offline)
        #expect(resolve(pending: 2) == .pending(2))
        #expect(resolve(synced: true) == .synced)
        #expect(resolve() == .notSynchronized)
    }

    private func resolve(
        running: Bool = false,
        pending: Int = 0,
        failed: Int = 0,
        conflicts: Int = 0,
        synced: Bool = false,
        code: String? = nil
    ) -> SyncPresentationState {
        SyncPresentationState.resolve(
            isRunning: running,
            pendingCount: pending,
            failedCount: failed,
            conflictCount: conflicts,
            lastSuccessfulSyncAt: synced ? Date(timeIntervalSince1970: 1) : nil,
            lastSafeErrorCode: code
        )
    }
}
