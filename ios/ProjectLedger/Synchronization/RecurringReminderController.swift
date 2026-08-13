import Combine
import Foundation
import SwiftData
@preconcurrency import UserNotifications

enum RecurringReminderAuthorizationState: Equatable, Sendable {
    case unknown
    case notDetermined
    case authorized
    case denied

    var displayName: String {
        switch self {
        case .unknown: String(localized: "Unavailable")
        case .notDetermined: String(localized: "Not requested")
        case .authorized: String(localized: "Allowed")
        case .denied: String(localized: "Denied")
        }
    }
}

@MainActor
protocol RecurringNotificationScheduling: AnyObject {
    func authorizationState() async -> RecurringReminderAuthorizationState
    func requestAuthorization() async throws -> Bool
    func pendingIdentifiers() async -> [String]
    func schedule(_ plan: RecurringReminderPlan, title: String, body: String) async throws
    func removePending(identifiers: [String])
}

@MainActor
final class SystemRecurringNotificationScheduler: RecurringNotificationScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationState() async -> RecurringReminderAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func schedule(
        _ plan: RecurringReminderPlan,
        title: String,
        body: String
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: plan.fireAt
        )
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: plan.identifier,
                content: content,
                trigger: trigger
            )
        )
    }

    func removePending(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

@MainActor
final class RecurringReminderController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var leadTime = RecurringReminderLeadTime.oneDay
    @Published private(set) var authorizationState = RecurringReminderAuthorizationState.unknown
    @Published private(set) var scheduledCount = 0
    @Published private(set) var isUpdating = false
    @Published var message: String?

    private let modelContainer: ModelContainer
    private let preferences: AppPreferences
    private let scheduler: any RecurringNotificationScheduling
    private var currentScopeKey: String?
    private var deferredRefreshScopeKey: String?
    private var operationGeneration: UInt64 = 0

    init(
        modelContainer: ModelContainer,
        preferences: AppPreferences,
        scheduler: any RecurringNotificationScheduling
    ) {
        self.modelContainer = modelContainer
        self.preferences = preferences
        self.scheduler = scheduler
    }

    func configure(scopeKey: String) async {
        guard !isUpdating else {
            deferredRefreshScopeKey = scopeKey
            return
        }
        isUpdating = true
        guard let generation = await prepareScope(scopeKey) else { return }
        defer { finishOperation(generation: generation, scopeKey: scopeKey) }
        await refreshConfiguredScope(scopeKey: scopeKey, generation: generation)
    }

    func refresh(scopeKey: String) async {
        guard !isUpdating else {
            deferredRefreshScopeKey = scopeKey
            return
        }
        isUpdating = true
        guard let generation = await prepareScope(scopeKey) else { return }
        defer { finishOperation(generation: generation, scopeKey: scopeKey) }
        await refreshConfiguredScope(scopeKey: scopeKey, generation: generation)
    }

    func setEnabled(_ enabled: Bool, scopeKey: String) async {
        guard !isUpdating else { return }
        isUpdating = true
        guard let generation = await prepareScope(scopeKey) else { return }
        message = nil
        defer { finishOperation(generation: generation, scopeKey: scopeKey) }

        guard enabled else {
            preferences.setRecurringRemindersEnabled(false, scopeKey: scopeKey)
            isEnabled = false
            await removePending(scopeKey: scopeKey)
            return
        }

        var state = await scheduler.authorizationState()
        guard isCurrent(generation, scopeKey: scopeKey) else { return }
        if state == .notDetermined {
            do {
                _ = try await scheduler.requestAuthorization()
                guard isCurrent(generation, scopeKey: scopeKey) else { return }
                state = await scheduler.authorizationState()
            } catch {
                guard isCurrent(generation, scopeKey: scopeKey) else { return }
                state = await scheduler.authorizationState()
                message = String(
                    localized: "Reminder settings could not be updated. Try again."
                )
            }
            guard isCurrent(generation, scopeKey: scopeKey) else { return }
        }
        authorizationState = state

        guard state == .authorized else {
            preferences.setRecurringRemindersEnabled(false, scopeKey: scopeKey)
            isEnabled = false
            await removePending(scopeKey: scopeKey)
            guard isCurrent(generation, scopeKey: scopeKey) else { return }
            if state == .denied {
                message = String(
                    localized: "iOS notification permission is off. Enable it in Settings to use reminders."
                )
            }
            return
        }

        preferences.setRecurringRemindersEnabled(true, scopeKey: scopeKey)
        isEnabled = true
        await reconcile(scopeKey: scopeKey, generation: generation)
    }

    func setLeadTime(_ value: RecurringReminderLeadTime, scopeKey: String) async {
        guard !isUpdating else { return }
        isUpdating = true
        guard let generation = await prepareScope(scopeKey) else { return }
        preferences.setRecurringReminderLeadTime(value, scopeKey: scopeKey)
        leadTime = value
        message = nil
        defer { finishOperation(generation: generation, scopeKey: scopeKey) }
        guard isEnabled else { return }
        await refreshConfiguredScope(scopeKey: scopeKey, generation: generation)
    }

    func deactivate() async {
        guard let scopeKey = currentScopeKey else { return }
        operationGeneration &+= 1
        currentScopeKey = nil
        isEnabled = false
        isUpdating = false
        scheduledCount = 0
        message = nil
        deferredRefreshScopeKey = nil
        await removePending(scopeKey: scopeKey)
    }

    private func prepareScope(_ scopeKey: String) async -> UInt64? {
        let previous = currentScopeKey
        operationGeneration &+= 1
        let generation = operationGeneration
        currentScopeKey = scopeKey
        loadPreferences(scopeKey: scopeKey)
        if let previous, previous != scopeKey {
            await removePending(scopeKey: previous)
        }
        guard isCurrent(generation, scopeKey: scopeKey) else { return nil }
        return generation
    }

    private func loadPreferences(scopeKey: String) {
        isEnabled = preferences.recurringRemindersEnabled(scopeKey: scopeKey)
        leadTime = preferences.recurringReminderLeadTime(scopeKey: scopeKey)
    }

    private func refreshConfiguredScope(scopeKey: String, generation: UInt64) async {
        guard isCurrent(generation, scopeKey: scopeKey) else { return }
        message = nil
        authorizationState = await scheduler.authorizationState()
        guard isCurrent(generation, scopeKey: scopeKey) else { return }

        guard isEnabled else {
            await removePending(scopeKey: scopeKey)
            return
        }
        guard authorizationState == .authorized else {
            preferences.setRecurringRemindersEnabled(false, scopeKey: scopeKey)
            isEnabled = false
            await removePending(scopeKey: scopeKey)
            guard isCurrent(generation, scopeKey: scopeKey) else { return }
            if authorizationState == .denied {
                message = String(
                    localized: "iOS notification permission is off. Enable it in Settings to use reminders."
                )
            }
            return
        }
        await reconcile(scopeKey: scopeKey, generation: generation)
    }

    private func reconcile(scopeKey: String, generation: UInt64) async {
        await removePending(scopeKey: scopeKey)
        guard isCurrent(generation, scopeKey: scopeKey) else { return }
        do {
            let descriptor = FetchDescriptor<LocalRecurringRule>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
            let candidates = try modelContainer.mainContext.fetch(descriptor).map {
                RecurringReminderCandidate(
                    ruleID: $0.id,
                    nextDueAt: $0.nextDueAt,
                    state: $0.state,
                    archivedAt: $0.archivedAt,
                    deletedAt: $0.deletedAt
                )
            }
            let installmentDescriptor = FetchDescriptor<LocalInstallmentPlan>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
            let scheduleDescriptor = FetchDescriptor<LocalInstallmentScheduleItem>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil }
            )
            let installmentPlans = try modelContainer.mainContext.fetch(
                installmentDescriptor
            )
            let scheduleItems = try modelContainer.mainContext.fetch(scheduleDescriptor)
            let scheduleByPlan = Dictionary(grouping: scheduleItems, by: \.planID)
            let installmentCandidates = try installmentPlans.compactMap {
                plan -> InstallmentReminderCandidate? in
                let next = scheduleByPlan[plan.id, default: []]
                    .filter {
                        $0.supersededAt == nil &&
                            $0.state != .paid &&
                            $0.state != .skipped
                    }
                    .min {
                        $0.dueOn == $1.dueOn
                            ? $0.sequence < $1.sequence : $0.dueOn < $1.dueOn
                    }
                guard let next else { return nil }
                let dueAt = try LocalRecurrenceCalculator.scheduledDate(
                    civilDate: next.dueOn,
                    localTimeSeconds: 9 * 3_600,
                    timeZoneIdentifier: plan.timeZoneIdentifier
                )
                return InstallmentReminderCandidate(
                    planID: plan.id,
                    nextDueAt: dueAt,
                    state: plan.state,
                    archivedAt: plan.archivedAt,
                    deletedAt: plan.deletedAt
                )
            }
            let plans = RecurringReminderPlanner.combinedPlans(
                recurringCandidates: candidates,
                installmentCandidates: installmentCandidates,
                scopeKey: scopeKey,
                leadTime: leadTime,
                now: .now
            )
            var accepted = 0
            for plan in plans {
                guard isCurrent(generation, scopeKey: scopeKey) else {
                    await removePending(scopeKey: scopeKey)
                    return
                }
                do {
                    try await scheduler.schedule(
                        plan,
                        title: String(localized: "Upcoming planned transaction"),
                        body: String(
                            localized: "A scheduled transaction is due soon. Open Miravo to review it."
                        )
                    )
                    guard isCurrent(generation, scopeKey: scopeKey) else {
                        await removePending(scopeKey: scopeKey)
                        return
                    }
                    accepted += 1
                } catch {
                    message = String(
                        localized: "Some plan reminders could not be scheduled. Try again."
                    )
                }
            }
            scheduledCount = accepted
        } catch {
            guard isCurrent(generation, scopeKey: scopeKey) else { return }
            scheduledCount = 0
            message = String(localized: "Plan reminders could not read local schedules.")
        }
    }

    private func isCurrent(_ generation: UInt64, scopeKey: String) -> Bool {
        operationGeneration == generation && currentScopeKey == scopeKey
    }

    private func finishOperation(generation: UInt64, scopeKey: String) {
        guard isCurrent(generation, scopeKey: scopeKey) else { return }
        isUpdating = false
        guard let deferredScope = deferredRefreshScopeKey else { return }
        deferredRefreshScopeKey = nil
        Task { await refresh(scopeKey: deferredScope) }
    }

    private func removePending(scopeKey: String) async {
        let prefix = RecurringReminderPlanner.identifierPrefix(scopeKey: scopeKey)
        let identifiers = await scheduler.pendingIdentifiers().filter {
            $0.hasPrefix(prefix)
        }
        scheduler.removePending(identifiers: identifiers)
        if currentScopeKey == scopeKey {
            scheduledCount = 0
        }
    }
}
