import SwiftData
import SwiftUI

@main
struct ProjectLedgerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sessionController: SessionController
    @StateObject private var syncController: SyncController
    private let store: LocalStoreBootstrap

    init() {
        let store = LocalStoreBootstrap.make()
        self.store = store
        _sessionController = StateObject(wrappedValue: SessionController())
        _syncController = StateObject(
            wrappedValue: SyncController(modelContainer: store.container)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeUnavailable: store.persistentStoreUnavailable)
                .environmentObject(sessionController)
                .environmentObject(syncController)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await syncController.synchronize(session: sessionController) }
                    } else {
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
                LocalAccount.self,
                LocalCategory.self,
                LedgerTransaction.self,
                LocalAccountMovement.self,
                LocalCategoryAllocation.self,
                OutboxMutation.self,
                SyncCursor.self,
                SyncConflict.self,
                BootstrapStagedEntity.self,
                configurations: configuration
            )
        }
        return try ModelContainer(
            for: LocalTracker.self,
            LocalAccount.self,
            LocalCategory.self,
            LedgerTransaction.self,
            LocalAccountMovement.self,
            LocalCategoryAllocation.self,
            OutboxMutation.self,
            SyncCursor.self,
            SyncConflict.self,
            BootstrapStagedEntity.self
        )
    }
}
