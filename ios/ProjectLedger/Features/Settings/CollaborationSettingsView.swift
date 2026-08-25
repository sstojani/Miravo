import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum CollaborationSheet: Identifiable {
    case acceptInvitation
    case createInvitation(UUID)
    case manageMember(UUID)
    case mergeGuest(UUID)

    var id: String {
        switch self {
        case .acceptInvitation:
            "accept-invitation"
        case let .createInvitation(trackerID):
            "create-invitation-\(trackerID)"
        case let .manageMember(membershipID):
            "manage-member-\(membershipID)"
        case let .mergeGuest(trackerID):
            "merge-guest-\(trackerID)"
        }
    }
}

struct CollaborationSettingsView: View {
    let scopeKey: String

    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var trackers: [LocalTracker]
    @Query private var memberships: [LocalTrackerMembership]
    @Query private var participants: [LocalParticipant]
    @Query private var outbox: [OutboxMutation]
    @Query private var conflicts: [SyncConflict]
    @StateObject private var controller = CollaborationController()
    @State private var selectedTrackerID: UUID?
    @State private var sheet: CollaborationSheet?
    @State private var pendingInvitationRevocation: TrackerInvitationSummary?

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _trackers = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey &&
                    $0.deletedAt == nil &&
                    $0.accessRevokedAt == nil
            },
            sort: \LocalTracker.sortOrder
        )
        _memberships = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.deletedAt == nil && $0.stateRaw == "active"
            },
            sort: \LocalTrackerMembership.email
        )
        _participants = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil },
            sort: \LocalParticipant.displayName
        )
        _outbox = Query(filter: #Predicate { $0.scopeKey == scopeKey })
        _conflicts = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.resolvedAt == nil }
        )
    }

    private var manageableTrackers: [LocalTracker] {
        trackers.filter { $0.archivedAt == nil && $0.role.canManageTracker }
    }

    private var selectedTracker: LocalTracker? {
        manageableTrackers.first { $0.id == selectedTrackerID }
    }

    private var selectedMemberships: [LocalTrackerMembership] {
        guard let selectedTrackerID else { return [] }
        return memberships.filter { $0.trackerID == selectedTrackerID }
    }

    private var selectedParticipants: [LocalParticipant] {
        guard let selectedTrackerID else { return [] }
        return participants.filter { $0.trackerID == selectedTrackerID }
    }

    private var currentUserID: UUID? {
        scopeKey.split(separator: "|").last.flatMap { UUID(uuidString: String($0)) }
    }

    private var canMergeGuests: Bool {
        selectedParticipants.contains { !$0.isRegistered && $0.archivedAt == nil } &&
            selectedParticipants.contains { $0.isRegistered && $0.archivedAt == nil }
    }

    private var localQueueIsClean: Bool {
        !sync.isRunning &&
            outbox.isEmpty &&
            conflicts.isEmpty &&
            sync.diagnostics.failedCount == 0 &&
            sync.diagnostics.conflictCount == 0
    }

    var body: some View {
        Form {
            Section("Join a tracker") {
                Button {
                    sheet = .acceptInvitation
                } label: {
                    Label("Enter invitation code", systemImage: "person.badge.plus")
                }
                Text("Joining requires your signed-in server account and a connection. The invitation email must match your account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if manageableTrackers.isEmpty {
                Section("Manage collaboration") {
                    ContentUnavailableView(
                        "No manageable tracker",
                        systemImage: "person.2.slash",
                        description: Text("An owner or admin role is required to invite or manage members.")
                    )
                }
            } else {
                Section("Manage collaboration") {
                    Picker("Tracker", selection: $selectedTrackerID) {
                        ForEach(manageableTrackers) { tracker in
                            Text(tracker.name).tag(Optional(tracker.id))
                        }
                    }
                    Button {
                        guard let selectedTrackerID else { return }
                        sheet = .createInvitation(selectedTrackerID)
                    } label: {
                        Label("Invite member", systemImage: "envelope.badge.person.crop")
                    }
                }

                memberSection
                invitationSection
                guestMergeSection
            }

            if let errorMessage = controller.errorMessage {
                Section("Collaboration notice") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                    if let requestID = controller.requestID {
                        Text(String(format: String(localized: "Request ID format"), requestID))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Collaboration")
        .task {
            chooseInitialTracker()
        }
        .task(id: selectedTrackerID) {
            await loadInvitations()
        }
        .refreshable {
            _ = await sync.synchronize(session: session)
            await loadInvitations()
        }
        .sheet(item: $sheet) { route in
            switch route {
            case .acceptInvitation:
                AcceptTrackerInvitationView(controller: controller)
            case let .createInvitation(trackerID):
                if let tracker = trackers.first(where: { $0.id == trackerID }) {
                    CreateTrackerInvitationView(tracker: tracker, controller: controller)
                }
            case let .manageMember(membershipID):
                if let membership = memberships.first(where: { $0.id == membershipID }),
                   let tracker = trackers.first(where: { $0.id == membership.trackerID }) {
                    ManageTrackerMemberView(
                        tracker: tracker,
                        membership: membership,
                        controller: controller
                    )
                }
            case let .mergeGuest(trackerID):
                if let tracker = trackers.first(where: { $0.id == trackerID }) {
                    MergeGuestParticipantView(
                        tracker: tracker,
                        participants: participants.filter { $0.trackerID == trackerID },
                        queueWasClean: localQueueIsClean,
                        controller: controller
                    )
                }
            }
        }
        .confirmationDialog(
            "Revoke invitation?",
            isPresented: Binding(
                get: { pendingInvitationRevocation != nil },
                set: { if !$0 { pendingInvitationRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke invitation", role: .destructive) {
                guard let invitation = pendingInvitationRevocation,
                      let trackerID = selectedTrackerID
                else { return }
                pendingInvitationRevocation = nil
                Task { await revoke(invitation, trackerID: trackerID) }
            }
            Button("Cancel", role: .cancel) { pendingInvitationRevocation = nil }
        } message: {
            Text("The code will stop working immediately. Existing membership is unchanged.")
        }
    }

    @ViewBuilder
    private var memberSection: some View {
        Section {
            ForEach(selectedMemberships) { member in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.email)
                        Text(member.role.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if canManage(member) {
                        Button("Manage") {
                            sheet = .manageMember(member.id)
                        }
                        .buttonStyle(.bordered)
                    } else if member.userID == currentUserID {
                        Text("You")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Members")
        } footer: {
            Text("Roles are enforced by the server. Viewer access is read only; editors may change financial records; admins manage tracker collaboration.")
        }
    }

    @ViewBuilder
    private var invitationSection: some View {
        Section("Invitations") {
            if controller.isWorking && controller.invitations.isEmpty {
                ProgressView("Loading invitations…")
            } else if controller.invitations.isEmpty {
                Text("No invitations for this tracker.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.invitations) { invitation in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(invitation.email)
                            Spacer()
                            invitationStatus(invitation)
                        }
                        Text(invitation.role.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let expirationDate = invitation.expirationDate {
                            LabeledContent("Expires") {
                                Text(expirationDate, format: .dateTime.day().month().year())
                            }
                            .font(.caption)
                        }
                        if invitation.isActive {
                            Button("Revoke", role: .destructive) {
                                pendingInvitationRevocation = invitation
                            }
                            .buttonStyle(.bordered)
                            .disabled(controller.isWorking)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private var guestMergeSection: some View {
        Section {
            Button {
                guard let selectedTrackerID else { return }
                sheet = .mergeGuest(selectedTrackerID)
            } label: {
                Label("Merge guest into member", systemImage: "person.2.badge.gearshape")
            }
            .disabled(!canMergeGuests || !localQueueIsClean)
        } header: {
            Text("Guest identity")
        } footer: {
            Text(
                localQueueIsClean
                    ? String(localized: "A merge preserves split and settlement history and cannot be undone.")
                    : String(localized: "Synchronize or resolve every pending operation before merging identities.")
            )
        }
    }

    @ViewBuilder
    private func invitationStatus(_ invitation: TrackerInvitationSummary) -> some View {
        if invitation.acceptedAt != nil {
            Label("Accepted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(LedgerTheme.positive)
        } else if invitation.revokedAt != nil {
            Label("Revoked", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        } else if invitation.isExpired() {
            Label("Expired", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.secondary)
        } else {
            Label("Pending", systemImage: "clock")
                .foregroundStyle(LedgerTheme.warning)
        }
    }

    private func canManage(_ member: LocalTrackerMembership) -> Bool {
        guard let tracker = selectedTracker,
              member.userID != currentUserID,
              member.role != .owner
        else { return false }
        return tracker.role == .owner ||
            (tracker.role == .admin && member.role != .admin)
    }

    private func chooseInitialTracker() {
        if selectedTracker == nil {
            selectedTrackerID = manageableTrackers.first?.id
        }
    }

    private func loadInvitations() async {
        guard let selectedTrackerID else { return }
        _ = await sync.synchronize(session: session, presentErrors: false)
        guard let authentication = await authenticationContext() else { return }
        await controller.loadInvitations(
            trackerID: selectedTrackerID,
            authentication: authentication
        )
    }

    private func revoke(
        _ invitation: TrackerInvitationSummary,
        trackerID: UUID
    ) async {
        _ = await sync.synchronize(session: session)
        guard let authentication = await authenticationContext() else { return }
        _ = await controller.revokeInvitation(
            trackerID: trackerID,
            invitationID: invitation.id,
            authentication: authentication
        )
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

private struct AcceptTrackerInvitationView: View {
    @ObservedObject var controller: CollaborationController

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var enteredValue = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Code or invitation link", text: $enteredValue, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                } header: {
                    Text("Invitation")
                } footer: {
                    Text("The invitation must be active and addressed to the email on your Miravo account.")
                }
                if let errorMessage = controller.errorMessage {
                    Section("Could not join") {
                        Text(errorMessage)
                    }
                }
            }
            .navigationTitle("Join tracker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") { Task { await accept() } }
                        .disabled(
                            controller.isWorking ||
                                enteredValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            .overlay {
                if controller.isWorking { ProgressView("Joining…") }
            }
        }
    }

    private func accept() async {
        _ = await sync.synchronize(session: session)
        guard let authentication = try? await session.synchronizationContext() else {
            controller.presentAuthenticationUnavailable()
            return
        }
        if await controller.acceptInvitation(
            enteredValue: enteredValue,
            authentication: authentication
        ) {
            _ = await sync.synchronize(session: session)
            dismiss()
        }
    }
}

private struct CreateTrackerInvitationView: View {
    let tracker: LocalTracker
    @ObservedObject var controller: CollaborationController

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var email = ""
    @State private var role = TrackerRole.editor
    @State private var expiresInDays = 7

    var body: some View {
        NavigationStack {
            if let invitation = controller.oneTimeInvitation {
                OneTimeTrackerInvitationView(invitation: invitation) {
                    controller.clearOneTimeInvitation()
                    dismiss()
                }
            } else {
                Form {
                    Section {
                        TextField("Email address", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("Role", selection: $role) {
                            Text("Admin").tag(TrackerRole.admin)
                            Text("Editor").tag(TrackerRole.editor)
                            Text("Viewer").tag(TrackerRole.viewer)
                        }
                        Stepper(
                            value: $expiresInDays,
                            in: 1 ... 30
                        ) {
                            LabeledContent("Valid for", value: expiresInDays, format: .number)
                        }
                    } header: {
                        Text("Member")
                    } footer: {
                        Text("The raw invitation code appears once. Send it privately to the intended account holder.")
                    }
                }
                .navigationTitle(
                    String.localizedStringWithFormat(
                        String(localized: "Invite to tracker format"),
                        tracker.name
                    )
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(controller.isWorking)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { Task { await create() } }
                            .disabled(
                                controller.isWorking ||
                                    email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                    }
                }
                .overlay {
                    if controller.isWorking { ProgressView("Creating invitation…") }
                }
            }
        }
        .interactiveDismissDisabled(controller.oneTimeInvitation != nil)
    }

    private func create() async {
        _ = await sync.synchronize(session: session)
        guard let authentication = try? await session.synchronizationContext() else {
            controller.presentAuthenticationUnavailable()
            return
        }
        _ = await controller.createInvitation(
            trackerID: tracker.id,
            email: email,
            role: role,
            expiresInDays: expiresInDays,
            authentication: authentication
        )
    }
}

private struct OneTimeTrackerInvitationView: View {
    let invitation: OneTimeTrackerInvitation
    let close: () -> Void

    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LedgerTheme.sectionSpacing) {
                Label("Save this invitation now", systemImage: "envelope.open")
                    .font(.title2.bold())
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "One-time invitation recipient format"),
                        invitation.email
                    )
                )
                    .foregroundStyle(.secondary)
                Text(invitation.rawValue)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .privacySensitive()
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("One-time tracker invitation code")
                Button {
                    UIPasteboard.general.setItems(
                        [[UTType.plainText.identifier: invitation.rawValue]],
                        options: [
                            .localOnly: true,
                            .expirationDate: Date().addingTimeInterval(300),
                        ]
                    )
                    copied = true
                } label: {
                    Label {
                        Text(
                            copied
                                ? String(localized: "Copied for five minutes")
                                : String(localized: "Copy invitation code")
                        )
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("Do not share screenshots containing this code. Revoke it if it reaches the wrong person.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("I sent the invitation", action: close)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("Invitation created")
    }
}

private struct ManageTrackerMemberView: View {
    let tracker: LocalTracker
    let membership: LocalTrackerMembership
    @ObservedObject var controller: CollaborationController

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var selectedRole: TrackerRole
    @State private var confirmRemoval = false

    init(
        tracker: LocalTracker,
        membership: LocalTrackerMembership,
        controller: CollaborationController
    ) {
        self.tracker = tracker
        self.membership = membership
        self.controller = controller
        _selectedRole = State(initialValue: membership.role)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Member") {
                    LabeledContent("Email", value: membership.email)
                    Picker("Role", selection: $selectedRole) {
                        Text("Admin").tag(TrackerRole.admin)
                        Text("Editor").tag(TrackerRole.editor)
                        Text("Viewer").tag(TrackerRole.viewer)
                    }
                }
                Section {
                    Button("Remove from tracker", role: .destructive) {
                        confirmRemoval = true
                    }
                    .disabled(controller.isWorking)
                } footer: {
                    Text("Removing access preserves shared financial history and audit events.")
                }
            }
            .navigationTitle("Manage member")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(controller.isWorking || selectedRole == membership.role)
                }
            }
            .confirmationDialog(
                "Remove member?",
                isPresented: $confirmRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove member", role: .destructive) { Task { await remove() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This person will immediately lose access to the tracker.")
            }
            .overlay {
                if controller.isWorking { ProgressView("Updating member…") }
            }
        }
    }

    private func save() async {
        _ = await sync.synchronize(session: session)
        guard let authentication = try? await session.synchronizationContext() else {
            controller.presentAuthenticationUnavailable()
            return
        }
        if await controller.updateMemberRole(
            trackerID: tracker.id,
            membershipID: membership.id,
            role: selectedRole,
            authentication: authentication
        ) {
            _ = await sync.synchronize(session: session)
            dismiss()
        }
    }

    private func remove() async {
        _ = await sync.synchronize(session: session)
        guard let authentication = try? await session.synchronizationContext() else {
            controller.presentAuthenticationUnavailable()
            return
        }
        if await controller.removeMember(
            trackerID: tracker.id,
            membershipID: membership.id,
            authentication: authentication
        ) {
            _ = await sync.synchronize(session: session)
            dismiss()
        }
    }
}

private struct MergeGuestParticipantView: View {
    let tracker: LocalTracker
    let participants: [LocalParticipant]
    let queueWasClean: Bool
    @ObservedObject var controller: CollaborationController

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var guestID: UUID?
    @State private var memberID: UUID?
    @State private var confirmed = false

    private var guests: [LocalParticipant] {
        participants.filter { !$0.isRegistered && $0.archivedAt == nil && $0.deletedAt == nil }
    }

    private var registeredMembers: [LocalParticipant] {
        participants.filter { $0.isRegistered && $0.archivedAt == nil && $0.deletedAt == nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Guest", selection: $guestID) {
                        Text("Choose guest").tag(UUID?.none)
                        ForEach(guests) { guest in
                            Text(guest.displayName).tag(Optional(guest.id))
                        }
                    }
                    Picker("Registered member", selection: $memberID) {
                        Text("Choose member").tag(UUID?.none)
                        ForEach(registeredMembers) { member in
                            Text(member.displayName).tag(Optional(member.id))
                        }
                    }
                    Toggle("I understand this cannot be undone", isOn: $confirmed)
                } header: {
                    Text("Identity merge")
                } footer: {
                    Text("Every split, payment, and settlement referring to the guest will move to the registered member. Collapsed balances remain auditable.")
                }
            }
            .navigationTitle("Merge guest")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge", role: .destructive) { Task { await merge() } }
                        .disabled(
                            controller.isWorking || !queueWasClean || !confirmed ||
                                guestID == nil || memberID == nil
                        )
                }
            }
            .overlay {
                if controller.isWorking { ProgressView("Merging identities…") }
            }
            .onAppear {
                guestID = guests.first?.id
                memberID = registeredMembers.first?.id
            }
        }
    }

    private func merge() async {
        guard queueWasClean else {
            controller.presentSynchronizationRequired()
            return
        }
        guard await sync.synchronize(session: session),
              sync.diagnostics.pendingCount == 0,
              sync.diagnostics.failedCount == 0,
              sync.diagnostics.conflictCount == 0,
              let guest = guests.first(where: { $0.id == guestID }),
              let member = registeredMembers.first(where: { $0.id == memberID }),
              let authentication = try? await session.synchronizationContext()
        else {
            controller.presentSynchronizationRequired()
            return
        }
        if await controller.mergeGuest(
            source: guest,
            target: member,
            authentication: authentication
        ) {
            _ = await sync.synchronize(session: session)
            dismiss()
        }
    }
}
