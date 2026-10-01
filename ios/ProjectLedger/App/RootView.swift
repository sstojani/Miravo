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
            if let previous, previous != current {
                Task {
                    await sync.cancelSynchronization(scopeKey: previous)
                    if current == nil { await reminders.deactivate() }
                }
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
                        .id(scopeKey)
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
                            guard !Task.isCancelled, session.scopeKey == scopeKey, session.hasServerConnection else { return }
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
                .environment(
                    \.floatingNavigationClearance,
                    shouldReserveFloatingTabSpace ? LedgerTheme.floatingNavigationClearance : 0
                )
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selectedTab)
        .overlay(alignment: .bottom) {
            if !keyboardVisible {
                FloatingTabBar(selectedTab: selectedTab, onSelect: selectTab)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: scopeKey) {
            await reminders.configure(scopeKey: scopeKey)
            #if DEBUG
                if !ProcessInfo.processInfo.arguments.contains("-ui-testing-authenticated") {
                    await reminders.activateAfterSystemPrompt(scopeKey: scopeKey)
                }
            #else
                await reminders.activateAfterSystemPrompt(scopeKey: scopeKey)
            #endif

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
    case plans
    case more
    case add

    static var navigationTabs: [MainTab] { [.overview, .transactions, .plans, .more] }

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

    var navigationLabel: LocalizedStringKey {
        switch self {
        case .overview:
            "Home"
        case .transactions:
            "History"
        case .plans:
            "Plans"
        case .more:
            "More"
        case .add:
            "Add"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "house"
        case .transactions:
            "banknote"
        case .add:
            "plus"
        case .plans:
            "wallet.pass"
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
        case .plans:
            2
        case .more:
            3
        case .add:
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
}

private struct FloatingTabBar: View {
    let selectedTab: MainTab
    let onSelect: (MainTab) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var selectionNamespace

    private let addColor = Color(red: 0.33, green: 0.20, blue: 0.97)

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 330
            let addDiameter: CGFloat = compact ? 56 : 64
            let gap: CGFloat = compact ? 8 : 10
            let capsuleWidth = geometry.size.width - addDiameter - gap
            let itemWidth = capsuleWidth - 8
            let selectedWidth = min(132, max(92, itemWidth * 0.40))
            let inactiveWidth = (itemWidth - selectedWidth) / 3

            HStack(spacing: gap) {
                navigationCapsule(
                    width: capsuleWidth,
                    itemWidth: itemWidth,
                    inactiveWidth: inactiveWidth,
                    selectedWidth: selectedWidth
                )

                Button {
                    onSelect(.add)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: addDiameter, height: addDiameter)
                        .background(addColor, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(
                                    .white.opacity(selectedTab == .add ? 0.85 : 0.14),
                                    lineWidth: selectedTab == .add ? 2 : 1
                                )
                        }
                        .shadow(color: addColor.opacity(0.28), radius: 14, y: 8)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(MainTab.add.title)
                .accessibilityIdentifier("tab.add")
                .accessibilityAddTraits(
                    selectedTab == .add ? .isSelected : AccessibilityTraits()
                )
            }
            .frame(width: geometry.size.width, height: 64)
        }
        .frame(height: 64)
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
    }

    private func navigationCapsule(
        width: CGFloat,
        itemWidth: CGFloat,
        inactiveWidth: CGFloat,
        selectedWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(MainTab.navigationTabs) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    HStack(spacing: 6) {
                        let iconName = selectedTab == .overview && tab == .overview
                            ? "house.fill"
                            : tab.systemImage
                        Image(systemName: iconName)
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 22, height: 22)
                        if selectedTab == tab {
                            Text(tab.navigationLabel)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .transition(.opacity)
                        }
                    }
                    .foregroundStyle(Color.primary.opacity(selectedTab == tab ? 1 : 0.78))
                    .frame(
                        width: selectedTab == .add
                            ? itemWidth / 4
                            : (selectedTab == tab ? selectedWidth : inactiveWidth),
                        height: 56
                    )
                    .background {
                        if selectedTab == tab {
                            Capsule()
                                .fill(selectedSurface)
                                .overlay {
                                    Capsule()
                                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                                }
                                .shadow(color: .black.opacity(0.09), radius: 7, y: 2)
                                .matchedGeometryEffect(id: "selectedTab", in: selectionNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityIdentifier("tab.\(tab.rawValue)")
                .accessibilityAddTraits(
                    selectedTab == tab ? .isSelected : AccessibilityTraits()
                )
            }
        }
        .padding(4)
        .frame(width: width, height: 64)
        .background {
            Capsule()
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
        }
    }

    private var selectedSurface: Color {
        colorScheme == .dark ? Color(uiColor: .tertiarySystemBackground) : .white
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
                .accessibilityIdentifier("more.insights")

                NavigationLink {
                    SettingsView(scopeKey: scopeKey)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("more.settings")
            }
        }
        .floatingNavigationScrollClearance()
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
                    Task { await session.signOut() }
                } label: {
                    HStack {
                        if session.isSigningOut {
                            ProgressView()
                        }
                        Text("Sign out")
                    }
                }
                .disabled(session.isSigningOut)
                .accessibilityIdentifier("account.signOut")
            }
        }
        .floatingNavigationScrollClearance()
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
