import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    let scopeKey: String

    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var reminders: RecurringReminderController
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var outbox: [OutboxMutation]
    @Query private var cursors: [SyncCursor]
    @Query private var conflicts: [SyncConflict]
    @Query private var attachmentTransfers: [AttachmentTransfer]
    @State private var signingOut = false
    @State private var showingServerAddress = false
    @State private var showingServerSetup = false

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
        Form {
            ledgerSection
            privacySection
            notificationsSection
            synchronizationSection
            advancedSection
            if session.hasServerConnection {
                serverConnectionSection
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingServerSetup) {
            LoginView(allowsDismiss: true)
        }
        .sheet(isPresented: $showingServerAddress) {
            ServerAddressSettingsView()
        }
        .task {
            await sync.refreshDiagnostics(scopeKey: scopeKey)
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
        Section("Your ledger") {
            NavigationLink {
                LocalDataSettingsView(scopeKey: scopeKey)
            } label: {
                Label("Trackers, accounts, and categories", systemImage: "square.stack.3d.up")
            }
            if session.hasServerConnection {
                NavigationLink {
                    CollaborationSettingsView(scopeKey: scopeKey)
                } label: {
                    Label("Collaboration", systemImage: "person.2")
                }

                NavigationLink {
                    ShortcutSettingsView(scopeKey: scopeKey)
                } label: {
                    Label(
                        "Apple Wallet Shortcut",
                        systemImage: "bolt.horizontal.circle"
                    )
                }
            }
            NavigationLink {
                ExportSettingsView(scopeKey: scopeKey)
            } label: {
                Label("Exports", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Toggle(
                "Face ID or passcode app lock",
                isOn: Binding(
                    get: { session.appLockEnabled },
                    set: { session.setAppLockEnabled($0) }
                )
            )
            Text("App lock protects the user interface. iOS Data Protection and a device passcode protect local files.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle(
                "Local notifications",
                isOn: Binding(
                    get: { reminders.isEnabled },
                    set: { enabled in
                        Task {
                            await reminders.setEnabled(
                                enabled,
                                scopeKey: scopeKey
                            )
                        }
                    }
                )
            )

            LabeledContent(
                "Notification permission",
                value: reminders.authorizationState.displayName
            )

            LabeledContent(
                "Scheduled plan reminders",
                value: reminders.scheduledCount.formatted()
            )

            if reminders.authorizationState == .denied {
                Button("Open notification settings") {
                    if let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) {
                        openURL(url)
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(
                "Local notifications include budget threshold alerts and reminders for recurring and installment plans."
            )
        }
        .disabled(reminders.isUpdating)
    }

    private var synchronizationSection: some View {
        Section {
            if session.hasServerConnection {
                synchronizationRows
            } else {
                Label("Local data", systemImage: "iphone")

                Button {
                    showingServerSetup = true
                } label: {
                    Label(
                        "Configure server",
                        systemImage: "externaldrive.connected.to.line.below"
                    )
                }

                Button {
                    showingServerAddress = true
                } label: {
                    Label("Server address", systemImage: "link")
                }
            }
        } header: {
            Text("Synchronization")
        } footer: {
            if session.hasServerConnection {
                Text("Local changes remain available while offline. Failed and conflicting operations stay on this iPhone until you retry or resolve them.")
            } else {
                Text("Financial records stay on this iPhone and synchronize only with the self-hosted server you choose.")
            }
        }
    }

    @ViewBuilder
    private var synchronizationRows: some View {
        if sync.isRunning || cursor?.isSyncing == true {
            HStack {
                ProgressView()
                Text("Synchronizing…")
            }
        }
        LabeledContent(
            "Foreground updates",
            value: sync.realtimeConnected
                ? String(localized: "Connected")
                : String(localized: "Polling fallback")
        )
        LabeledContent(
            "Background refresh",
            value: backgroundRefreshStatus
        )
        LabeledContent("Pending operations", value: pendingCount, format: .number)
        LabeledContent("Failed operations", value: failedOutboxCount, format: .number)
        LabeledContent("Pending attachments", value: pendingAttachmentCount, format: .number)
        LabeledContent("Failed attachments", value: failedAttachmentCount, format: .number)
        NavigationLink {
            SyncConflictsView(scopeKey: scopeKey)
        } label: {
            LabeledContent("Conflicts", value: conflicts.count, format: .number)
        }
        .disabled(conflicts.isEmpty)

        if let lastSync = cursor?.lastSuccessfulSyncAt {
            LabeledContent("Last successful sync") {
                Text(lastSync, format: .dateTime.day().month().year().hour().minute())
            }
        } else {
            LabeledContent("Last successful sync", value: String(localized: "Not synchronized yet"))
        }

        if cursor?.bootstrapRequired != false {
            Label("Initial server download required", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }

        if let errorCode = cursor?.lastSafeErrorCode {
            LabeledContent("Last sync status") {
                Text(verbatim: errorCode)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }

        Button {
            Task { await sync.synchronize(session: session) }
        } label: {
            Label("Synchronize now", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(sync.isRunning)

        if failedOutboxCount > 0 {
            Button {
                Task {
                    await sync.retryFailed(scopeKey: scopeKey, session: session)
                }
            } label: {
                Label("Retry failed operations", systemImage: "arrow.clockwise")
            }
            .disabled(sync.isRunning)
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            LabeledContent("Server") {
                Text(
                    session.configuredServerURL.isEmpty
                        ? String(localized: "Not connected")
                        : session.configuredServerURL
                )
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            }
            LabeledContent("Local scope") {
                Text(scopeKey.split(separator: "|").last.map(String.init) ?? "—")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var serverConnectionSection: some View {
        Section {
            Button(role: .destructive) {
                signingOut = true
                Task {
                    await sync.stopForegroundTriggers()
                    await session.disconnectServer()
                    signingOut = false
                }
            } label: {
                HStack {
                    if signingOut {
                        ProgressView()
                    }
                    Text("Disconnect server")
                }
            }
            .disabled(signingOut)
        } footer: {
            Text("Financial records stay on this iPhone and synchronize only with the self-hosted server you choose.")
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
