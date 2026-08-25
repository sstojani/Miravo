import SwiftData
import SwiftUI

struct RootView: View {
    let storeUnavailable: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController

    var body: some View {
        Group {
            if storeUnavailable {
                LocalStoreRecoveryView()
            } else {
                sessionContent
            }
        }
        .tint(LedgerTheme.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: session.phase)
        .onChange(of: session.phase) { _, phase in
            if phase != .authenticated {
                Task { await sync.stopForegroundTriggers() }
            }
        }
        .onChange(of: session.scopeKey) { previous, current in
            if previous != nil && current == nil {
                Task { await reminders.deactivate() }
            }
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        switch session.phase {
            case .loading:
                ProgressView("Opening local data…")
            case .onboarding:
                OnboardingView()
            case .signIn:
                LoginView()
            case .locked:
                LockedView()
            case .authenticated:
                if let scopeKey = session.scopeKey {
                    MainTabView(scopeKey: scopeKey)
                        .task(id: scopeKey) {
                            if !session.hasServerConnection {
                                try? LocalLedgerRepository(context: modelContext)
                                    .bootstrapDefaults(scopeKey: scopeKey)
                                return
                            }

                            await sync.refreshDiagnostics(scopeKey: scopeKey)
                            let needsInitialProvisioning = sync.diagnostics.bootstrapRequired
                            let synchronized = await sync.synchronize(session: session)
                            let hasTrackers = await sync.hasAvailableTrackers(scopeKey: scopeKey)

                            if synchronized &&
                                needsInitialProvisioning &&
                                !sync.diagnostics.bootstrapRequired &&
                                !hasTrackers {
                                try? LocalLedgerRepository(context: modelContext)
                                    .bootstrapDefaults(scopeKey: scopeKey)
                                await sync.synchronize(session: session)
                            }

                            await sync.startForegroundTriggers(session: session)
                        }
                } else {
                    ProgressView("Opening local data…")
                }
        }
    }
}

private struct LocalStoreRecoveryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Local data needs attention", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Miravo did not erase or replace the persistent store. Do not delete the app if it may contain unsynchronized records. Restart once, then use the documented recovery steps if this message returns.")
        } actions: {
            Text("Support code: local_store_unavailable")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding()
    }
}

private struct MainTabView: View {
    let scopeKey: String

    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @EnvironmentObject private var reminders: RecurringReminderController

    var body: some View {
        TabView {
            NavigationStack {
                OverviewView(scopeKey: scopeKey)
            }
            .tabItem {
                Label("Overview", systemImage: "chart.pie")
            }

            NavigationStack {
                TransactionsView(scopeKey: scopeKey)
            }
            .tabItem {
                Label("Transactions", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                QuickAddView(scopeKey: scopeKey)
            }
            .tabItem {
                Label("Add", systemImage: "plus.circle.fill")
            }

            NavigationStack {
                PlansView(scopeKey: scopeKey)
            }
            .tabItem {
                Label("Plans", systemImage: "calendar.badge.clock")
            }

            NavigationStack {
                InsightsView(scopeKey: scopeKey)
            }
            .tabItem {
                Label("Insights", systemImage: "chart.xyaxis.line")
            }

            NavigationStack {
                SettingsView(scopeKey: scopeKey)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .task(id: scopeKey) {
            await reminders.configure(scopeKey: scopeKey)
            await reminders.activateAfterSystemPrompt(scopeKey: scopeKey)

            guard session.hasServerConnection else {
                return
            }

            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(60))
                } catch {
                    return
                }
                await sync.synchronize(session: session)
            }
        }
        .onChange(of: sync.diagnostics.lastSuccessfulSyncAt) { _, _ in
            Task { await reminders.refresh(scopeKey: scopeKey) }
        }
    }
}
