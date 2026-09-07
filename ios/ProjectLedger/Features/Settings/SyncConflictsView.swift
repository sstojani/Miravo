import Foundation
import SwiftData
import SwiftUI

struct SyncConflictsView: View {
    let scopeKey: String

    @Query private var conflicts: [SyncConflict]

    init(scopeKey: String) {
        self.scopeKey = scopeKey
        _conflicts = Query(
            filter: #Predicate { $0.scopeKey == scopeKey && $0.resolvedAt == nil },
            sort: \SyncConflict.createdAt,
            order: .reverse
        )
    }

    var body: some View {
        Group {
            if conflicts.isEmpty {
                ContentUnavailableView(
                    "No synchronization conflicts",
                    systemImage: "checkmark.circle",
                    description: Text("Conflicting edits that need your decision will appear here.")
                )
            } else {
                List(conflicts) { conflict in
                    NavigationLink {
                        SyncConflictReviewView(scopeKey: scopeKey, conflict: conflict)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: conflict.entityType.replacingOccurrences(
                                of: "_",
                                with: " "
                            ).capitalized)
                                .font(.headline)
                            Text(conflict.createdAt, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: conflict.safeErrorCode)
                                .font(.caption.monospaced())
                                .foregroundStyle(LedgerTheme.warning)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("Conflicts")
    }
}

private struct SyncConflictReviewView: View {
    let scopeKey: String
    let conflict: SyncConflict

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var resolving = false
    @State private var confirmingServer = false

    private var serverDeleted: Bool {
        guard let current = try? JSONDecoder().decode(JSONValue.self, from: conflict.currentJSON) else { return false }
        return SyncRecoveryPolicy.isDeleted(current)
    }

    private var comparisons: [ConflictFieldComparison] {
        let current = decodedObject(conflict.currentJSON)
        let proposed = decodedObject(conflict.proposedJSON)
        let keys = Set(current.keys).union(proposed.keys)
        return keys.sorted().map { key in
            ConflictFieldComparison(
                key: key,
                current: current[key],
                proposed: proposed[key]
            )
        }
    }

    var body: some View {
        List {
            if serverDeleted {
                Section("Server deletion") {
                    Text("The server deleted this record. Your phone still has edits for an older version. Keeping those edits cannot restore a deleted record.")
                }
            }
            Section("Conflict details") {
                LabeledContent("Record type") {
                    Text(verbatim: conflict.entityType)
                }
                LabeledContent("Reason") {
                    Text(verbatim: conflict.safeErrorCode)
                        .font(.caption.monospaced())
                }
                LabeledContent("Detected") {
                    Text(conflict.createdAt, format: .dateTime.day().month().year().hour().minute())
                }
            }

            Section {
                ForEach(comparisons) { comparison in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: comparison.displayName)
                            .font(.headline)
                        HStack(alignment: .top, spacing: 12) {
                            ConflictValueColumn(
                                title: "Server version",
                                value: comparison.currentText,
                                changed: comparison.isDifferent
                            )
                            Divider()
                            ConflictValueColumn(
                                title: "My pending version",
                                value: comparison.proposedText,
                                changed: comparison.isDifferent
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Field review")
            } footer: {
                if serverDeleted {
                    Text("Using the server deletion discards queued edits for this record. Other unsynchronized records remain available for review.")
                } else {
                    Text("Keeping your version creates a new update based on the current server version. Keeping the server version discards only this pending edit.")
                }
            }

            Section {
                Button {
                    confirmingServer = true
                } label: {
                    if serverDeleted {
                        Label("Use server deletion", systemImage: "trash")
                    } else {
                        Label("Keep server version", systemImage: "server.rack")
                    }
                }
                if !serverDeleted {
                    Button {
                        resolve(keepingMine: true)
                    } label: {
                        Label("Keep my version", systemImage: "iphone")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Review conflict")
        .disabled(resolving || sync.isRunning)
        .confirmationDialog("Use server version?", isPresented: $confirmingServer, titleVisibility: .visible) {
            Button("Use server version", role: .destructive) { resolve(keepingMine: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if serverDeleted {
                Text("This accepts the server deletion and discards all queued edits for this record. Dependent changes remain on this iPhone for review.")
            } else {
                Text("This discards the selected local edit and uses the server version.")
            }
        }
        .overlay {
            if resolving {
                ProgressView("Resolving conflict…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func decodedObject(_ data: Data) -> [String: JSONValue] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return [:]
        }
        return value.objectValue ?? [:]
    }

    private func resolve(keepingMine: Bool) {
        resolving = true
        Task {
            let didResolve = if keepingMine {
                await sync.keepMine(
                    scopeKey: scopeKey,
                    operationID: conflict.operationID,
                    session: session
                )
            } else {
                await sync.keepServer(
                    scopeKey: scopeKey,
                    operationID: conflict.operationID,
                    session: session
                )
            }
            resolving = false
            if didResolve { dismiss() }
        }
    }
}

private struct ConflictFieldComparison: Identifiable {
    let key: String
    let current: JSONValue?
    let proposed: JSONValue?

    var id: String { key }
    var displayName: String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }
    var currentText: String { ConflictValueFormatter.text(current) }
    var proposedText: String { ConflictValueFormatter.text(proposed) }
    var isDifferent: Bool { current != proposed }
}

private struct ConflictValueColumn: View {
    let title: LocalizedStringKey
    let value: String
    let changed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.caption.monospaced())
                .foregroundStyle(changed ? .primary : .secondary)
                .lineLimit(5)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ConflictValueFormatter {
    static func text(_ value: JSONValue?) -> String {
        guard let value else { return String(localized: "No value") }
        switch value {
        case let .string(text): return text.isEmpty ? String(localized: "Empty") : text
        case let .integer(number): return String(number)
        case let .number(number): return NSDecimalNumber(decimal: number).stringValue
        case let .bool(flag): return flag ? String(localized: "Yes") : String(localized: "No")
        case .null: return String(localized: "No value")
        case .object, .array:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value),
                  let text = String(data: data, encoding: .utf8)
            else {
                return String(localized: "Unreadable value")
            }
            return text
        }
    }
}
