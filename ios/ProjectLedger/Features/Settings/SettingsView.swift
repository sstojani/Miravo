import SwiftData
import SwiftUI

struct SettingsView: View {
    let scopeKey: String

    @EnvironmentObject private var session: SessionController
    @Query private var outbox: [OutboxMutation]
    @State private var signingOut = false

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _outbox = Query(
            filter: #Predicate { $0.scopeKey == scopeKey },
            sort: \OutboxMutation.createdAt
        )
    }

    private var pendingCount: Int {
        outbox.filter { $0.state == .pending || $0.state == .failed }.count
    }

    var body: some View {
        Form {
            Section("Your ledger") {
                NavigationLink {
                    LocalDataSettingsView(scopeKey: scopeKey)
                } label: {
                    Label("Trackers, accounts, and categories", systemImage: "square.stack.3d.up")
                }
            }

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

            Section("Synchronization") {
                LabeledContent("Pending operations", value: pendingCount, format: .number)
                LabeledContent("Failed operations", value: outbox.filter { $0.state == .failed }.count, format: .number)
                LabeledContent("Last successful sync", value: String(localized: "Not synchronized yet"))
                Text("Manual retry, server cursors, and conflict review are implemented with the synchronization milestone. Local saving does not depend on them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                LabeledContent("Server") {
                    Text(session.configuredServerURL)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                LabeledContent("Local scope") {
                    Text(scopeKey.split(separator: "|").last.map(String.init) ?? "—")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                Button(role: .destructive) {
                    signingOut = true
                    Task {
                        await session.signOut()
                        signingOut = false
                    }
                } label: {
                    HStack {
                        if signingOut { ProgressView() }
                        Text("Sign out")
                    }
                }
                .disabled(signingOut)
            } footer: {
                Text("Signing out does not erase local records. Another account cannot see them because every cached object is scoped to its server and user.")
            }
        }
        .navigationTitle("Settings")
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
