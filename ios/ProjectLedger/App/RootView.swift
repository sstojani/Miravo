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
        .preferredColorScheme(session.appAppearance.colorScheme)
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
                            let repository = LocalLedgerRepository(context: modelContext)
                            if let adoption = session.pendingGuestAdoption(for: scopeKey) {
                                do {
                                    _ = try repository.adoptGuestProfileForAuthentication(
                                        sourceScopeKey: adoption.sourceScopeKey,
                                        targetScopeKey: adoption.targetScopeKey
                                    )
                                    session.clearPendingGuestAdoption(adoption)
                                } catch {
                                    session.reportGuestAdoptionFailure()
                                    return
                                }
                            }

                            if !session.hasServerConnection {
                                _ = try? repository.bootstrapDefaults(scopeKey: scopeKey)
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
                                _ = try? repository.bootstrapDefaults(scopeKey: scopeKey)
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

    @State private var selectedTab: MainTab = .overview
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @EnvironmentObject private var reminders: RecurringReminderController

    var body: some View {
        ZStack {
            selectedContent
        }
        .safeAreaInset(edge: .bottom) {
            FloatingTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 10)
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

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .overview:
            NavigationStack { OverviewView(scopeKey: scopeKey) }
        case .transactions:
            NavigationStack { TransactionsView(scopeKey: scopeKey) }
        case .add:
            NavigationStack { QuickAddView(scopeKey: scopeKey) }
        case .plans:
            NavigationStack { PlansView(scopeKey: scopeKey) }
        case .more:
            NavigationStack { MoreView(scopeKey: scopeKey) }
        }
    }
}

private enum MainTab: String, CaseIterable, Identifiable {
    case overview
    case transactions
    case add
    case plans
    case more

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview:
            "Overview"
        case .transactions:
            "Transactions"
        case .add:
            "Add"
        case .plans:
            "Plans"
        case .more:
            "More"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "chart.pie"
        case .transactions:
            "list.bullet.rectangle"
        case .add:
            "plus"
        case .plans:
            "calendar.badge.clock"
        case .more:
            "ellipsis"
        }
    }
}

private struct FloatingTabBar: View {
    @Binding var selectedTab: MainTab

    var body: some View {
        HStack(spacing: 18) {
            ForEach(MainTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: tab == .add ? 24 : 21, weight: .semibold))
                        .symbolVariant(selectedTab == tab ? .fill : .none)
                        .foregroundStyle(iconColor(for: tab))
                        .frame(width: 52, height: 52)
                        .background {
                            if selectedTab == tab {
                                Circle()
                                    .fill(.white)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : AccessibilityTraits())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.92))
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        )
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private func iconColor(for tab: MainTab) -> Color {
        if selectedTab == tab {
            return .black
        }
        return .white.opacity(0.72)
    }
}

private struct MoreView: View {
    let scopeKey: String

    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var showingSignIn = false
    @State private var disconnecting = false

    var body: some View {
        List {
            Section("Account") {
                if session.hasServerConnection {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.preferences.lastEmail.isEmpty ? String(localized: "Server account") : session.preferences.lastEmail)
                            Text("Signed in and syncing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(LedgerTheme.positive)
                    }

                    Button {
                        disconnecting = true
                        Task {
                            await sync.stopForegroundTriggers()
                            await session.disconnectServer()
                            disconnecting = false
                        }
                    } label: {
                        Label {
                            Text(disconnecting ? "Disconnecting…" : "Disconnect server")
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.xmark")
                        }
                    }
                    .disabled(disconnecting)
                    .tint(LedgerTheme.negative)
                } else {
                    Button {
                        showingSignIn = true
                    } label: {
                        Label("Sign in to sync", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }

            Section("Explore") {
                NavigationLink {
                    InsightsView(scopeKey: scopeKey)
                } label: {
                    Label("Insights", systemImage: "chart.xyaxis.line")
                }

                NavigationLink {
                    SettingsView(scopeKey: scopeKey)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("More")
        .sheet(isPresented: $showingSignIn) {
            LoginView(allowsDismiss: true)
        }
        .alert("Session notice", isPresented: Binding(
            get: { session.logoutWarning != nil },
            set: { if !$0 { session.logoutWarning = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.logoutWarning ?? "")
        }
    }
}
