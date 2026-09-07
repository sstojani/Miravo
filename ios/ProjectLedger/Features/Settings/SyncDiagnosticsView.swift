import SwiftUI
import UIKit

struct SyncDiagnosticsView: View {
    let scopeKey: String
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var confirmingRepair = false
    @State private var copied = false
    @State private var copyFailed = false

    var body: some View {
        Form {
            Section("Synchronization") {
                LabeledContent("Pending operations", value: sync.diagnostics.pendingCount, format: .number)
                NavigationLink { FailedOperationsView(scopeKey: scopeKey) } label: {
                    LabeledContent("Failed operations", value: sync.diagnostics.failedCount, format: .number)
                }
                NavigationLink { SyncConflictsView(scopeKey: scopeKey) } label: {
                    LabeledContent("Conflicts", value: sync.diagnostics.conflictCount, format: .number)
                }
                LabeledContent("Bootstrap required", value: sync.diagnostics.bootstrapRequired ? String(localized: "Yes") : String(localized: "No"))
                if let date = sync.diagnostics.lastSuccessfulSyncAt {
                    LabeledContent("Last successful sync") { Text(date, format: .dateTime) }
                }
                if let date = sync.diagnostics.lastAttemptAt {
                    LabeledContent("Last attempted sync") { Text(date, format: .dateTime) }
                }
                LabeledContent("Safe error code", value: SyncRecoveryPolicy.safeCode(sync.diagnostics.lastSafeErrorCode))
            }
            Section("App identity") {
                LabeledContent("Bundle identifier", value: Bundle.main.bundleIdentifier ?? String(localized: "Unknown"))
                LabeledContent("App version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown"))
                LabeledContent("Build number", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "Unknown"))
                LabeledContent("Scope type", value: SessionScope.isLocal(scopeKey) ? String(localized: "Local") : String(localized: "Authenticated"))
                LabeledContent("Scope digest", value: SyncDiagnosticReport.digest(scopeKey))
                LabeledContent("Device digest", value: SyncDiagnosticReport.digest(session.preferences.deviceID))
                Button {
                    Task {
                        do {
                            let operations = try await sync.failedOperations(scopeKey: scopeKey)
                            UIPasteboard.general.string = SyncDiagnosticReport.text(scopeKey: scopeKey, deviceID: session.preferences.deviceID, diagnostics: sync.diagnostics, operations: operations)
                            copied = true
                            copyFailed = false
                        } catch { copyFailed = true }
                    }
                } label: {
                    Label("Copy diagnostics", systemImage: "doc.on.doc")
                }
                if copied { Label("Diagnostics copied", systemImage: "checkmark") }
                if copyFailed { Text("Recovery details could not be loaded.") }
            }
            Section {
                Button { confirmingRepair = true } label: {
                    Label("Repair synchronization", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.isRunning || !session.hasServerConnection)
            } footer: {
                Text("Downloads your server data again. Resolve local edits and receipt uploads first. Server records and receipt files are not deleted.")
            }
        }
        .navigationTitle("Sync diagnostics")
        .task { await sync.refreshDiagnostics(scopeKey: scopeKey) }
        .confirmationDialog("Repair synchronization?", isPresented: $confirmingRepair, titleVisibility: .visible) {
            Button("Download server data again") {
                Task { await sync.repairSynchronization(scopeKey: scopeKey, session: session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Miravo will replace stale sync metadata and download a fresh server copy. This repair refuses to discard unsynchronized changes.")
        }
    }
}
