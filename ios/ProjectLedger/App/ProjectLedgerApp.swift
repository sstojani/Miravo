import SwiftData
import SwiftUI
@preconcurrency import UserNotifications

@main
@MainActor
struct ProjectLedgerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recurringReminderController: RecurringReminderController
    @StateObject private var sessionController: SessionController
    @StateObject private var syncController: SyncController
    private let notificationDelegate: LocalNotificationPresentationDelegate
    private let store: LocalStoreBootstrap

    init() {
        let store = LocalStoreBootstrap.make()
        let recurringReminderController = RecurringReminderController(
            modelContainer: store.container,
            preferences: .standard,
            scheduler: SystemRecurringNotificationScheduler()
        )
        let sessionController = SessionController()
        let syncController = SyncController(modelContainer: store.container)
        let notificationDelegate = LocalNotificationPresentationDelegate()
        self.notificationDelegate = notificationDelegate
        self.store = store
        _recurringReminderController = StateObject(
            wrappedValue: recurringReminderController
        )
        _sessionController = StateObject(wrappedValue: sessionController)
        _syncController = StateObject(wrappedValue: syncController)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        _ = BackgroundSyncScheduler.register(
            syncController: syncController,
            sessionController: sessionController
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeUnavailable: store.persistentStoreUnavailable)
                .environmentObject(recurringReminderController)
                .environmentObject(sessionController)
                .environmentObject(syncController)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            if sessionController.phase == .locked {
                                await sessionController.unlock()
                            }

                            if let scopeKey = sessionController.scopeKey {
                                await recurringReminderController.refresh(
                                    scopeKey: scopeKey
                                )
                            }

                            guard sessionController.hasServerConnection else {
                                return
                            }

                            await syncController.synchronize(
                                session: sessionController
                            )
                            await syncController.startForegroundTriggers(
                                session: sessionController
                            )
                        }
                    } else {
                        if sessionController.hasServerConnection {
                            syncController.scheduleBackgroundRefresh()
                        }
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
                fatalError("Miravo could not initialize a safe local store.")
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
                LocalParticipant.self,
                LocalAccount.self,
                LocalCategory.self,
                LocalTag.self,
                LocalBudget.self,
                LocalBudgetCategory.self,
                LocalBudgetThreshold.self,
                LocalRecurringRule.self,
                LocalRecurringOccurrence.self,
                LocalInstallmentPlan.self,
                LocalInstallmentScheduleItem.self,
                LocalInstallmentPayment.self,
                LedgerTransaction.self,
                LocalAccountMovement.self,
                LocalCategoryAllocation.self,
                LocalTransactionTag.self,
                LocalSplitPayment.self,
                LocalSplitShare.self,
                LocalSettlement.self,
                LocalAttachment.self,
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
            LocalParticipant.self,
            LocalAccount.self,
            LocalCategory.self,
            LocalTag.self,
            LocalBudget.self,
            LocalBudgetCategory.self,
            LocalBudgetThreshold.self,
            LocalRecurringRule.self,
            LocalRecurringOccurrence.self,
            LocalInstallmentPlan.self,
            LocalInstallmentScheduleItem.self,
            LocalInstallmentPayment.self,
            LedgerTransaction.self,
            LocalAccountMovement.self,
            LocalCategoryAllocation.self,
            LocalTransactionTag.self,
            LocalSplitPayment.self,
            LocalSplitShare.self,
            LocalSettlement.self,
            LocalAttachment.self,
            OutboxMutation.self,
            AttachmentTransfer.self,
            SyncCursor.self,
            SyncConflict.self,
            BootstrapStagedEntity.self
        )
    }
}
