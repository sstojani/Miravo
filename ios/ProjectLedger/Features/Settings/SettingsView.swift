import SwiftData
import SwiftUI

struct SettingsView: View {
    let scopeKey: String

    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var outbox: [OutboxMutation]
    @Query private var cursors: [SyncCursor]
    @Query private var conflicts: [SyncConflict]
    @Query private var attachmentTransfers: [AttachmentTransfer]
    @State private var showingServerAddress = false
    @State private var showingServerSetup = false
    @State private var presentedDestination: SettingsDestination?

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _outbox = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \OutboxMutation.createdAt
        )
        _cursors = Query(filter: #Predicate { $0.scopeKey == scopeKey })
        _conflicts = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.resolvedAt == nil },
            sort: \SyncConflict.createdAt,
            order: .reverse
        )
        _attachmentTransfers = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \AttachmentTransfer.createdAt
        )
    }

    private var pendingCount: Int {
        outbox.filter { $0.state == .pending || $0.state == .syncing }.count
    }

    private var cursor: SyncCursor? { cursors.first }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerTheme.sectionSpacing) {
                ledgerSection
                appearanceSection
                privacySection
                synchronizationSection
                advancedSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Settings")
        .sheet(isPresented: $showingServerSetup) {
            LoginView(allowsDismiss: true)
        }
        .sheet(isPresented: $showingServerAddress) {
            ServerAddressSettingsView()
        }
        .fullScreenCover(item: $presentedDestination) { destination in
            destinationView(destination)
        }
        .alert("Session notice", isPresented: Binding(
            get: { session.logoutWarning != nil },
            set: { if !$0 { session.logoutWarning = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.logoutWarning ?? "")
        }
        .alert("Synchronization notice", isPresented: Binding(
            get: { sync.message != nil },
            set: { if !$0 { sync.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sync.message ?? "")
        }
    }

    private var ledgerSection: some View {
        settingsSection(Text("Your ledger")) {
            settingsLink(.localData) {
                Label("Trackers, accounts, and categories", systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("settings.localData")
            settingsDivider
            if session.hasServerConnection {
                settingsLink(.collaboration) {
                    Label("Collaboration", systemImage: "person.2")
                }
                .accessibilityIdentifier("settings.collaboration")
                settingsDivider
                settingsLink(.shortcut) {
                    Label(
                        "Apple Wallet Shortcut",
                        systemImage: "bolt.horizontal.circle"
                    )
                }
                .accessibilityIdentifier("settings.shortcut")
                settingsDivider
            }
            settingsLink(.exports) {
                Label("Exports", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("settings.exports")
        }
    }

    private var privacySection: some View {
        settingsSection(Text("Privacy")) {
            settingsRow {
                Toggle(
                    "Face ID or passcode app lock",
                    isOn: Binding(
                        get: { session.appLockEnabled },
                        set: { session.setAppLockEnabled($0) }
                    )
                )
            }
            settingsDivider
            settingsRow {
                Text("App lock protects the user interface. iOS Data Protection and a device passcode protect local files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSection: some View {
        settingsSection(Text("Appearance")) {
            settingsRow {
                Picker(
                    "App appearance",
                    selection: Binding(
                        get: { session.appAppearance },
                        set: { session.setAppAppearance($0) }
                    )
                ) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var synchronizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsSection(Text("Synchronization")) {
                if session.hasServerConnection {
                    synchronizationRows
                } else {
                    settingsRow {
                        Label("Local data", systemImage: "iphone")
                    }
                    settingsDivider
                    settingsRow {
                        Button {
                            showingServerSetup = true
                        } label: {
                            Label(
                                "Configure server",
                                systemImage: "externaldrive.connected.to.line.below"
                            )
                        }
                    }
                    settingsDivider
                    settingsRow {
                        Button {
                            showingServerAddress = true
                        } label: {
                            Label("Server address", systemImage: "link")
                        }
                    }
                }
            }
            if session.hasServerConnection {
                Text("Local changes remain available while offline. Failed and conflicting operations stay on this iPhone until you retry or resolve them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                Text("Financial records stay on this iPhone and synchronize only with the self-hosted server you choose.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var synchronizationRows: some View {
        if sync.isRunning || cursor?.isSyncing == true {
            settingsRow {
                HStack {
                    ProgressView()
                    Text("Synchronizing…")
                }
            }
            settingsDivider
        }
        settingsRow {
            LabeledContent(
                "Foreground updates",
                value: sync.realtimeConnected
                    ? String(localized: "Connected")
                    : String(localized: "Polling fallback")
            )
        }
        settingsDivider
        settingsRow {
            LabeledContent("Background refresh", value: backgroundRefreshStatus)
        }
        settingsDivider
        settingsRow {
            LabeledContent("Pending operations", value: pendingCount, format: .number)
        }
        settingsDivider
        settingsLink(.failedOperations) {
            LabeledContent("Failed operations", value: failedOutboxCount, format: .number)
        }
        .accessibilityIdentifier("settings.failedOperations")
        settingsDivider
        settingsRow {
            LabeledContent("Pending attachments", value: pendingAttachmentCount, format: .number)
        }
        settingsDivider
        settingsRow {
            LabeledContent("Failed attachments", value: failedAttachmentCount, format: .number)
        }
        settingsDivider
        settingsLink(.conflicts) {
            LabeledContent("Conflicts", value: conflicts.count, format: .number)
        }
        .accessibilityIdentifier("settings.conflicts")
        .disabled(conflicts.isEmpty)
        settingsDivider
        if let lastSync = cursor?.lastSuccessfulSyncAt {
            settingsRow {
                LabeledContent("Last successful sync") {
                    Text(lastSync, format: .dateTime.day().month().year().hour().minute())
                }
            }
        } else {
            settingsRow {
                LabeledContent("Last successful sync", value: String(localized: "Not synchronized yet"))
            }
        }
        if cursor?.bootstrapRequired != false {
            settingsDivider
            settingsRow {
                Label("Initial server download required", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        }
        if let errorCode = cursor?.lastSafeErrorCode {
            settingsDivider
            settingsRow {
                LabeledContent("Last sync status") {
                    Text(verbatim: errorCode)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        settingsDivider
        settingsRow {
            Button {
                Task { await sync.synchronize(session: session) }
            } label: {
                Label("Synchronize now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.isRunning)
        }
        settingsDivider
        settingsLink(.diagnostics) {
            Label("Sync diagnostics and repair", systemImage: "stethoscope")
        }
        .accessibilityIdentifier("settings.diagnostics")
    }

    private var advancedSection: some View {
        settingsSection(Text("Advanced")) {
            settingsRow {
                LabeledContent("Server") {
                    Text(
                        session.configuredServerURL.isEmpty
                            ? String(localized: "Not connected")
                            : session.configuredServerURL
                    )
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                }
            }
            settingsDivider
            settingsRow {
                LabeledContent("Local scope") {
                    Text(SyncDiagnosticReport.digest(scopeKey))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func settingsSection<Content: View>(
        _ title: Text,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.footnote)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            VStack(spacing: 0, content: content)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
    }

    private func settingsRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    private func settingsLink<LabelContent: View>(
        _ destination: SettingsDestination,
        @ViewBuilder label: () -> LabelContent
    ) -> some View {
        Button {
            presentedDestination = destination
        } label: {
            HStack(spacing: 12) {
                label()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var settingsDivider: some View {
        Divider().padding(.leading, 16)
    }

    private func destinationView(_ destination: SettingsDestination) -> some View {
        NavigationStack {
            Group {
                switch destination {
                case .localData:
                    LocalDataSettingsView(scopeKey: scopeKey)
                case .collaboration:
                    CollaborationSettingsView(scopeKey: scopeKey)
                case .shortcut:
                    ShortcutSettingsView(scopeKey: scopeKey)
                case .exports:
                    ExportSettingsView(scopeKey: scopeKey)
                case .failedOperations:
                    FailedOperationsView(scopeKey: scopeKey)
                case .conflicts:
                    SyncConflictsView(scopeKey: scopeKey)
                case .diagnostics:
                    SyncDiagnosticsView(scopeKey: scopeKey)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings") { presentedDestination = nil }
                }
            }
        }
    }

    private var backgroundRefreshStatus: String {
        switch sync.backgroundRefreshScheduled {
        case .some(true):
            String(localized: "Requested")
        case .some(false):
            String(localized: "Unavailable")
        case .none:
            String(localized: "Not requested")
        }
    }

    private var failedOutboxCount: Int {
        outbox.filter { $0.state == .failed }.count
    }

    private var pendingAttachmentCount: Int {
        attachmentTransfers.filter {
            $0.state == .pending || $0.state == .uploading
        }.count
    }

    private var failedAttachmentCount: Int {
        attachmentTransfers.filter { $0.state == .failed }.count
    }
}

private enum SettingsDestination: String, Identifiable {
    case localData
    case collaboration
    case shortcut
    case exports
    case failedOperations
    case conflicts
    case diagnostics

    var id: String { rawValue }
}

private struct ServerAddressSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @State private var serverURL = ""
    @State private var safeError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $serverURL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    if !session.defaultServerURLString.isEmpty {
                        Button("Use bundled server") {
                            serverURL = ""
                            safeError = nil
                        }
                    }
                } footer: {
                    Text("Leave this blank to use the server bundled with this build.")
                }

                if let safeError {
                    Section {
                        Label(safeError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LedgerTheme.negative)
                    }
                }
            }
            .navigationTitle("Server address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                if serverURL.isEmpty {
                    serverURL = session.preferences.serverURLString
                }
            }
        }
    }

    private func save() {
        let clean = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = clean.isEmpty ? session.defaultServerURLString : clean
        do {
            _ = try ServerURLPolicy.validated(candidate)
            session.preferences.serverURLString = clean
            dismiss()
        } catch {
            safeError = String(localized: "Enter a complete HTTPS server URL.")
        }
    }
}
