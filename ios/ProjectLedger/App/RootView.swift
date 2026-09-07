import SwiftData
import SwiftUI
import UIKit

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
    @State private var tabTransitionDirection: TabTransitionDirection = .forward
    @State private var keyboardVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @EnvironmentObject private var reminders: RecurringReminderController

    var body: some View {
        ZStack {
            selectedContent
                .id(selectedTab)
                .transition(selectedContentTransition)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if shouldReserveFloatingTabSpace {
                        Color.clear
                            .frame(height: FloatingTabBarMetrics.contentClearance)
                            .allowsHitTesting(false)
                    }
                }
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selectedTab)
        .overlay(alignment: .bottom) {
            if !keyboardVisible {
                FloatingTabBar(selectedTab: selectedTab, onSelect: selectTab)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )
        ) { _ in
            setKeyboardVisible(true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )
        ) { _ in
            setKeyboardVisible(false)
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
            NavigationStack {
                QuickAddView(
                    scopeKey: scopeKey,
                    bottomAccessoryPadding: keyboardVisible
                        ? 0
                        : FloatingTabBarMetrics.quickAddClearance
                )
            }
        case .plans:
            NavigationStack { PlansView(scopeKey: scopeKey) }
        case .more:
            NavigationStack { MoreView(scopeKey: scopeKey) }
        }
    }

    private var selectedContentTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: tabTransitionDirection.insertionEdge)
                .combined(with: .opacity),
            removal: .move(edge: tabTransitionDirection.removalEdge)
                .combined(with: .opacity)
        )
    }

    private var shouldReserveFloatingTabSpace: Bool {
        !keyboardVisible && selectedTab != .add
    }

    private func selectTab(_ tab: MainTab) {
        guard tab != selectedTab else { return }
        tabTransitionDirection = tab.order > selectedTab.order ? .forward : .backward
        if reduceMotion {
            selectedTab = tab
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                selectedTab = tab
            }
        }
    }

    private func setKeyboardVisible(_ visible: Bool) {
        if reduceMotion {
            keyboardVisible = visible
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                keyboardVisible = visible
            }
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

    var order: Int {
        switch self {
        case .overview:
            0
        case .transactions:
            1
        case .add:
            2
        case .plans:
            3
        case .more:
            4
        }
    }
}

private enum TabTransitionDirection {
    case forward
    case backward

    var insertionEdge: Edge {
        self == .forward ? .trailing : .leading
    }

    var removalEdge: Edge {
        self == .forward ? .leading : .trailing
    }
}

private enum FloatingTabBarMetrics {
    static let quickAddClearance: CGFloat = 88
    static let contentClearance: CGFloat = 104
}

private struct FloatingTabBar: View {
    let selectedTab: MainTab
    let onSelect: (MainTab) -> Void

    var body: some View {
        HStack(spacing: 18) {
            ForEach(MainTab.allCases) { tab in
                Button {
                    onSelect(tab)
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
    @State private var showingSignIn = false

    private var accountEmail: String {
        session.preferences.lastEmail.isEmpty
            ? String(localized: "Server account")
            : session.preferences.lastEmail
    }

    var body: some View {
        List {
            Section("Account") {
                if session.hasServerConnection {
                    NavigationLink {
                        AccountSettingsView(scopeKey: scopeKey)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(accountEmail)
                                Text("Signed in and syncing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundStyle(LedgerTheme.positive)
                        }
                    }
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

private struct AccountSettingsView: View {
    let scopeKey: String

    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var disconnecting = false

    private var accountEmail: String {
        session.preferences.lastEmail.isEmpty
            ? String(localized: "Server account")
            : session.preferences.lastEmail
    }

    private var serverAddress: String {
        session.configuredServerURL.isEmpty
            ? String(localized: "Not connected")
            : session.configuredServerURL
    }

    private var syncStatus: String {
        session.hasServerConnection
            ? String(localized: "Connected")
            : String(localized: "Local only")
    }

    var body: some View {
        Form {
            Section("Profile") {
                LabeledContent("Email", value: accountEmail)
                LabeledContent("Name", value: String(localized: "Not set"))
            }

            Section("Security") {
                LabeledContent("Password", value: String(localized: "Server managed"))
            }

            Section("Server") {
                LabeledContent("Sync", value: syncStatus)
                LabeledContent("Server") {
                    Text(serverAddress)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                LabeledContent("Scope") {
                    Text(SyncDiagnosticReport.digest(scopeKey))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                Button(role: .destructive) {
                    disconnecting = true
                    Task {
                        await sync.stopForegroundTriggers()
                        await session.disconnectServer()
                        disconnecting = false
                    }
                } label: {
                    HStack {
                        if disconnecting {
                            ProgressView()
                        }
                        Text(disconnecting ? "Disconnecting…" : "Disconnect server")
                    }
                }
                .disabled(disconnecting)
            }
        }
        .navigationTitle("User account")
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
