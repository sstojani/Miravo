import SwiftData
import SwiftUI

struct FailedOperationsView: View {
    let scopeKey: String
    @EnvironmentObject private var sync: SyncController
    @Query private var outbox: [OutboxMutation]
    @State private var operations: [FailedOperationSnapshot] = []
    @State private var loadFailed = false

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _outbox = Query(filter: #Predicate { $0.scopeKey == scopeKey }, sort: \OutboxMutation.localSequence)
    }

    private var revision: String {
        outbox.map { "\($0.operationID)|\($0.stateRaw)|\($0.updatedAt)|\($0.serverStateRequestedAt?.description ?? "")" }.joined()
    }

    var body: some View {
        List {
            if loadFailed {
                Label("Recovery details could not be loaded.", systemImage: "exclamationmark.triangle")
            } else if operations.isEmpty {
                ContentUnavailableView("No failed operations", systemImage: "checkmark.circle")
            }
            ForEach(operations) { operation in
                NavigationLink {
                    FailedOperationDetailView(scopeKey: scopeKey, operation: operation)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: operation.entityType.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.headline)
                        Text(verbatim: "\(operation.command.uppercased()) · \(operation.safeErrorCode)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if operation.awaitingServerState {
                            Label("Waiting for server recovery", systemImage: "arrow.down.circle")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Failed operations")
        .task(id: revision) {
            do {
                operations = try await sync.failedOperations(scopeKey: scopeKey)
                loadFailed = false
            } catch { loadFailed = true }
        }
    }
}

private struct FailedOperationDetailView: View {
    let scopeKey: String
    let operation: FailedOperationSnapshot
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false
    @State private var working = false

    var body: some View {
        List {
            Section("Recovery") {
                if operation.awaitingServerState {
                    Label("Waiting for server recovery", systemImage: "arrow.down.circle")
                    Text("Your local change stays on this iPhone until the server download completes.")
                } else if operation.serverDeleted || operation.serverMissing {
                    Text("This record is deleted or no longer available from your server account. Retrying this edit cannot restore it.")
                } else if !operation.canRetry {
                    Text("This change needs repair before it can synchronize.")
                }
                if operation.canRetry {
                    Button { recover(useServer: false) } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) { confirmingDiscard = true } label: {
                    Label("Discard local change and use server state", systemImage: "arrow.down.doc")
                }
                .disabled(operation.awaitingServerState)
            }
            Section("Operation details") {
                LabeledContent("Record type", value: operation.entityType)
                LabeledContent("Command", value: operation.command.uppercased())
                LabeledContent("State", value: operation.state)
                LabeledContent("Safe error code", value: operation.safeErrorCode)
                LabeledContent("Base server version", value: operation.baseServerVersion.map(String.init) ?? String(localized: "Unknown"))
                LabeledContent("Attempt count", value: operation.attemptCount, format: .number)
                LabeledContent("Local sequence", value: operation.localSequence, format: .number)
                LabeledContent("Local record exists", value: operation.existsLocally ? String(localized: "Yes") : String(localized: "No"))
                LabeledContent("Changes for this record", value: operation.sameEntityOperationCount, format: .number)
                LabeledContent("Created") { Text(operation.createdAt, style: .date) }
                LabeledContent("Updated") { Text(operation.updatedAt, style: .date) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Entity ID")
                    Text(operation.entityID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Review failed operation")
        .disabled(working || sync.isRunning)
        .overlay { if working { ProgressView("Recovering synchronization…") } }
        .confirmationDialog("Use server state for this record?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard local changes", role: .destructive) { recover(useServer: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards all currently queued edits for this record after a complete server download. A deleted or unavailable server record will disappear locally. Changes to other records and receipt files remain on this iPhone.")
        }
    }

    private func recover(useServer: Bool) {
        working = true
        Task {
            let requested = await sync.recoverOperation(scopeKey: scopeKey, operationID: operation.id, useServer: useServer, session: session)
            working = false
            if requested { dismiss() }
        }
    }
}
