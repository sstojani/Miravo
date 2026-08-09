import SwiftData
import SwiftUI

@main
@MainActor
struct ProjectLedgerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sessionController: SessionController
    @StateObject private var syncController: SyncController
    private let store: LocalStoreBootstrap

    init() {
        let store = LocalStoreBootstrap.make()
        let sessionController = SessionController()
        let syncController = SyncController(modelContainer: store.container)
        self.store = store
        _sessionController = StateObject(wrappedValue: sessionController)
        _syncController = StateObject(wrappedValue: syncController)
        _ = BackgroundSyncScheduler.register(
            syncController: syncController,
            sessionController: sessionController
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeUnavailable: store.persistentStoreUnavailable)
                .environmentObject(sessionController)
                .environmentObject(syncController)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            await syncController.synchronize(session: sessionController)
                            await syncController.startForegroundTriggers(
                                session: sessionController
                            )
                        }
                    } else {
                        syncController.scheduleBackgroundRefresh()
                        Task { await syncController.stopForegroundTriggers() }
                        sessionController.lockIfNeeded()
                    }
                }
        }
        .modelContainer(store.container)
    }
}

private struct LocalStoreBootstrap {
    let container: ModelContainer
    let persistentStoreUnavailable: Bool

    static func make() -> LocalStoreBootstrap {
        do {
            return LocalStoreBootstrap(
                container: try makeContainer(),
                persistentStoreUnavailable: false
            )
        } catch {
            do {
                let temporary = ModelConfiguration(isStoredInMemoryOnly: true)
                return LocalStoreBootstrap(
                    container: try makeContainer(configuration: temporary),
                    persistentStoreUnavailable: true
                )
            } catch {
                fatalError("Project Ledger could not initialize a safe local store.")
            }
        }
    }

    private static func makeContainer(
        configuration: ModelConfiguration? = nil
    ) throws -> ModelContainer {
        if let configuration {
            return try ModelContainer(
                for: LocalTracker.self,
                LocalTrackerMembership.self,
                LocalAccount.self,
                LocalCategory.self,
                LocalTag.self,
                LedgerTransaction.self,
                LocalAccountMovement.self,
                LocalCategoryAllocation.self,
                LocalTransactionTag.self,
                OutboxMutation.self,
                AttachmentTransfer.self,
                SyncCursor.self,
                SyncConflict.self,
                BootstrapStagedEntity.self,
                configurations: configuration
            )
        }
        return try ModelContainer(
            for: LocalTracker.self,
            LocalTrackerMembership.self,
            LocalAccount.self,
            LocalCategory.self,
            LocalTag.self,
            LedgerTransaction.self,
            LocalAccountMovement.self,
            LocalCategoryAllocation.self,
            LocalTransactionTag.self,
            OutboxMutation.self,
            AttachmentTransfer.self,
            SyncCursor.self,
            SyncConflict.self,
            BootstrapStagedEntity.self
        )
    }
}
