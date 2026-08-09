@preconcurrency import BackgroundTasks
import Foundation

@MainActor
enum BackgroundSyncScheduler {
    private static var registered = false

    static var identifier: String {
        "\(Bundle.main.bundleIdentifier ?? "com.example.projectledger").sync.refresh"
    }

    static func register(
        syncController: SyncController,
        sessionController: SessionController
    ) -> Bool {
        guard !registered else { return true }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let operation = Task { @MainActor in
                _ = schedule()
                let success = await syncController.synchronize(session: sessionController)
                refreshTask.setTaskCompleted(success: success && !Task.isCancelled)
            }
            refreshTask.expirationHandler = {
                operation.cancel()
            }
        }
        return registered
    }

    static func schedule(earliestBeginDate: Date = .now.addingTimeInterval(15 * 60)) -> Bool {
        guard registered else { return false }
        let scheduler = BGTaskScheduler.shared
        scheduler.cancel(taskRequestWithIdentifier: identifier)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try scheduler.submit(request)
            return true
        } catch {
            return false
        }
    }
}
