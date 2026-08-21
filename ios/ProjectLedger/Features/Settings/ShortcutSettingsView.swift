import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct ShortcutCreateDraft: Identifiable {
    let id = UUID()
    let name: String
    let trackerID: UUID?
}

struct ShortcutSettingsView: View {
    let scopeKey: String

    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var trackers: [LocalTracker]
    @Query private var accounts: [LocalAccount]
    @Query private var categories: [LocalCategory]
    @StateObject private var controller = ShortcutCredentialController()
    @State private var selectedTrackerID: UUID?
    @State private var didChooseInitialTracker = false
    @State private var createDraft: ShortcutCreateDraft?
    @State private var pendingRevocation: ShortcutCredentialSummary?

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _trackers = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LocalTracker.sortOrder
        )
        _accounts = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LocalAccount.name
        )
        _categories = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \LocalCategory.sortOrder
        )
    }

    private var eligibleTrackers: [LocalTracker] {
        trackers.filter {
            $0.deletedAt == nil && $0.archivedAt == nil && $0.role.canEditFinancialData
        }
    }

    private var selectedTracker: LocalTracker? {
        eligibleTrackers.first { $0.id == selectedTrackerID }
    }

    private var selectedDefaultAccount: LocalAccount? {
        guard let tracker = selectedTracker else { return nil }
        return accounts.first {
            $0.id == tracker.defaultAccountID && $0.deletedAt == nil && $0.archivedAt == nil
        }
    }

    private var selectedDefaultCategory: LocalCategory? {
        guard let tracker = selectedTracker else { return nil }
        return categories.first {
            $0.id == tracker.defaultCategoryID && $0.deletedAt == nil && $0.archivedAt == nil
        }
    }

    private var activeCredentials: [ShortcutCredentialSummary] {
        controller.credentials.filter { !$0.isRevoked && !$0.isExpired() }
    }

    private var inactiveCredentials: [ShortcutCredentialSummary] {
        controller.credentials.filter { $0.isRevoked || $0.isExpired() }
    }

    var body: some View {
        Form {
            Section("Optional Wallet capture") {
                Text("A personal Apple Wallet Transaction automation can send one purchase to your server. Miravo remains fully useful without it.")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = controller.errorMessage {
                Section("Shortcut access notice") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                    if let requestID = controller.requestID {
                        Text(String(format: String(localized: "Request ID format"), requestID))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Retry") {
                        Task {
                            _ = await sync.synchronize(session: session)
                            await loadCredentials()
                        }
                    }
                    .disabled(controller.isWorking || sync.isRunning)
                }
            }

            Section {
                if eligibleTrackers.isEmpty {
                    Label("No editable tracker is available", systemImage: "person.crop.circle.badge.exclamationmark")
                    Text("An editor, admin, or owner role is required to create expenses with a Shortcut token.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Token tracker", selection: $selectedTrackerID) {
                        ForEach(eligibleTrackers) { tracker in
                            Text(tracker.name).tag(Optional(tracker.id))
                        }
                        Text("All editable trackers").tag(UUID?.none)
                    }
                    LabeledContent(
                        "Default account",
                        value: selectedTrackerID == nil
                            ? String(localized: "Chosen by the automation")
                            : selectedDefaultAccount?.name ?? String(localized: "Not configured")
                    )
                    LabeledContent(
                        "Default category",
                        value: selectedTrackerID == nil
                            ? String(localized: "Chosen by the automation")
                            : selectedDefaultCategory?.name ?? String(localized: "Not configured")
                    )
                    NavigationLink {
                        LocalDataSettingsView(scopeKey: scopeKey)
                    } label: {
                        Label("Edit tracker defaults", systemImage: "slider.horizontal.3")
                    }
                }
            } header: {
                Text("Capture defaults")
            } footer: {
                Text("A tracker-restricted token is safer. Tracker defaults are shared settings and still follow your current server role.")
            }

            Section {
                if controller.isWorking && controller.credentials.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading Shortcut access…")
                    }
                } else if activeCredentials.isEmpty {
                    Text("No active Shortcut tokens")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeCredentials) { credential in
                        ShortcutCredentialRow(
                            credential: credential,
                            trackerName: trackerName(for: credential.trackerID),
                            isRevoking: controller.revokingID == credential.id,
                            rotate: {
                                createDraft = ShortcutCreateDraft(
                                    name: String(localized: "Wallet automation replacement"),
                                    trackerID: credential.trackerID
                                )
                            },
                            revoke: { pendingRevocation = credential }
                        )
                    }
                }

                Button {
                    createDraft = ShortcutCreateDraft(
                        name: String(localized: "Wallet automation"),
                        trackerID: selectedTrackerID
                    )
                } label: {
                    Label("Create Shortcut token", systemImage: "key.fill")
                }
                .disabled(eligibleTrackers.isEmpty || controller.isWorking || sync.isRunning)
            } header: {
                Text("Active Shortcut tokens")
            } footer: {
                Text("Creating and revoking tokens requires the server. Existing automations are unchanged while this iPhone is offline.")
            }

            if !inactiveCredentials.isEmpty {
                Section("Inactive Shortcut tokens") {
                    ForEach(inactiveCredentials) { credential in
                        ShortcutCredentialRow(
                            credential: credential,
                            trackerName: trackerName(for: credential.trackerID),
                            isRevoking: false,
                            rotate: nil,
                            revoke: nil
                        )
                    }
                }
            }

            Section {
                LabeledContent("API host") {
                    Text(session.configuredServerURL)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                LabeledContent("Capture endpoint") {
                    Text(verbatim: "/api/v1/shortcut/transactions")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Label("The raw token is shown once and is never saved by Miravo.", systemImage: "eye.slash")
                Label("Use the same event UUID for retries and queued flushes.", systemImage: "arrow.triangle.2.circlepath")
                Label("Wallet capture is not bank reconciliation.", systemImage: "exclamationmark.shield")
            } header: {
                Text("Setup and recovery")
            } footer: {
                Text("When rotating, copy and test the replacement in Shortcuts before revoking the old token.")
            }
        }
        .navigationTitle("Wallet Shortcut")
        .task {
            if !didChooseInitialTracker {
                selectedTrackerID = eligibleTrackers.first?.id
                didChooseInitialTracker = true
            }
            _ = await sync.synchronize(session: session)
            await loadCredentials()
        }
        .refreshable {
            _ = await sync.synchronize(session: session)
            await loadCredentials()
        }
        .sheet(item: $createDraft, onDismiss: controller.clearOneTimeToken) { draft in
            NavigationStack {
                if let token = controller.oneTimeToken {
                    OneTimeShortcutTokenView(token: token) {
                        controller.clearOneTimeToken()
                        createDraft = nil
                    }
                } else {
                    ShortcutCredentialCreateView(
                        trackers: eligibleTrackers,
                        initialName: draft.name,
                        initialTrackerID: draft.trackerID,
                        isWorking: controller.isWorking,
                        errorMessage: controller.errorMessage,
                        requestID: controller.requestID,
                        create: createCredential
                    )
                }
            }
            .interactiveDismissDisabled(controller.oneTimeToken != nil)
        }
        .confirmationDialog(
            "Revoke Shortcut token?",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke token", role: .destructive) {
                guard let credential = pendingRevocation else { return }
                pendingRevocation = nil
                Task { await revoke(credential) }
            }
            Button("Cancel", role: .cancel) { pendingRevocation = nil }
        } message: {
            Text("The related automation will stop immediately. Existing transactions remain unchanged.")
        }
    }

    private func trackerName(for trackerID: UUID?) -> String {
        guard let trackerID else { return String(localized: "All editable trackers") }
        return trackers.first { $0.id == trackerID }?.name ?? String(localized: "Unavailable")
    }

    private func loadCredentials() async {
        guard let authentication = await authenticationContext() else { return }
        await controller.load(authentication: authentication)
    }

    private func createCredential(name: String, trackerID: UUID?) async -> Bool {
        _ = await sync.synchronize(session: session)
        guard let authentication = await authenticationContext() else { return false }
        return await controller.create(
            name: name,
            trackerID: trackerID,
            authentication: authentication
        )
    }

    private func revoke(_ credential: ShortcutCredentialSummary) async {
        _ = await sync.synchronize(session: session)
        guard let authentication = await authenticationContext() else { return }
        _ = await controller.revoke(id: credential.id, authentication: authentication)
    }

    private func authenticationContext() async -> SyncAuthenticationContext? {
        do {
            guard let authentication = try await session.synchronizationContext() else {
                controller.presentAuthenticationUnavailable()
                return nil
            }
            return authentication
        } catch {
            controller.presentAuthenticationUnavailable()
            return nil
        }
    }
}

private struct ShortcutCredentialRow: View {
    let credential: ShortcutCredentialSummary
    let trackerName: String
    let isRevoking: Bool
    let rotate: (() -> Void)?
    let revoke: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(credential.name)
                    .font(.headline)
                Spacer()
                statusLabel
            }
            Text(trackerName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: "•••• \(credential.tokenPrefix)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Token prefix")
            LabeledContent("Permissions", value: scopeSummary)
                .font(.caption)
            if let expirationDate = credential.expirationDate {
                LabeledContent("Expires") {
                    Text(expirationDate, format: .dateTime.day().month().year())
                }
                .font(.caption)
            }
            if rotate != nil || revoke != nil {
                HStack {
                    if let rotate {
                        Button("Rotate", action: rotate)
                            .buttonStyle(.bordered)
                    }
                    if let revoke {
                        Button("Revoke", role: .destructive, action: revoke)
                            .buttonStyle(.bordered)
                    }
                    if isRevoking { ProgressView() }
                }
            }
        }
        .padding(.vertical, LedgerTheme.smallSpacing)
    }

    private var scopeSummary: String {
        credential.scopes.map { scope in
            switch scope {
            case .categoriesRead:
                String(localized: "Categories")
            case .accountsRead:
                String(localized: "Accounts")
            case .transactionsCreate:
                String(localized: "Create expenses")
            }
        }.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusLabel: some View {
        if credential.isRevoked {
            Label("Revoked", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        } else if credential.isExpired() {
            Label("Expired", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.secondary)
        } else {
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(LedgerTheme.positive)
        }
    }
}

private struct ShortcutCredentialCreateView: View {
    let trackers: [LocalTracker]
    let isWorking: Bool
    let errorMessage: String?
    let requestID: String?
    let create: (String, UUID?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var restrictToTracker: Bool
    @State private var trackerID: UUID?

    init(
        trackers: [LocalTracker],
        initialName: String,
        initialTrackerID: UUID?,
        isWorking: Bool,
        errorMessage: String?,
        requestID: String?,
        create: @escaping (String, UUID?) async -> Bool
    ) {
        self.trackers = trackers
        self.isWorking = isWorking
        self.errorMessage = errorMessage
        self.requestID = requestID
        self.create = create
        _name = State(initialValue: initialName)
        _restrictToTracker = State(initialValue: initialTrackerID != nil)
        _trackerID = State(initialValue: initialTrackerID ?? trackers.first?.id)
    }

    var body: some View {
        Form {
            if let errorMessage {
                Section("Shortcut access notice") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                    if let requestID {
                        Text(String(format: String(localized: "Request ID format"), requestID))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                Toggle("Restrict to one tracker", isOn: $restrictToTracker)
                if restrictToTracker {
                    Picker("Tracker", selection: $trackerID) {
                        ForEach(trackers) { tracker in
                            Text(tracker.name).tag(Optional(tracker.id))
                        }
                    }
                }
            } header: {
                Text("Token details")
            } footer: {
                Text("The recommended tracker restriction limits the token if it is leaked. An unrestricted token follows every tracker where you can edit.")
            }

            Section {
                Label("Read expense categories", systemImage: "tag")
                Label("Read accounts", systemImage: "wallet.pass")
                Label("Create expenses", systemImage: "plus.circle")
            } header: {
                Text("Permissions")
            } footer: {
                Text("The token cannot read transactions, change settings, move money, or use your normal app session.")
            }
        }
        .navigationTitle("New Shortcut token")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isWorking)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    Task {
                        _ = await create(name, restrictToTracker ? trackerID : nil)
                    }
                }
                .disabled(
                    isWorking || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        (restrictToTracker && trackerID == nil)
                )
            }
        }
        .overlay {
            if isWorking {
                ProgressView("Creating token…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct OneTimeShortcutTokenView: View {
    let token: OneTimeShortcutToken
    let close: () -> Void

    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LedgerTheme.sectionSpacing) {
                Label("Save this token now", systemImage: "key.viewfinder")
                    .font(.title2.bold())
                Text("Miravo will never show this raw token again. Put it only in the Shortcut Authorization header.")
                    .foregroundStyle(.secondary)
                Text(token.rawValue)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .privacySensitive()
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("One-time Shortcut token")
                Button {
                    copyToken()
                } label: {
                    Label {
                        Text(
                            copied
                                ? String(localized: "Copied for five minutes")
                                : String(localized: "Copy token")
                        )
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("Do not share screenshots containing this token. If you are rotating, update and test the automation before revoking the old token.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("I saved the token", action: close)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle(token.name)
    }

    private func copyToken() {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: token.rawValue]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(300),
            ]
        )
        copied = true
    }
}
