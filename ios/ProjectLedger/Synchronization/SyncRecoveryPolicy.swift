import CryptoKit
import Foundation

struct SyncRecordKey: Hashable, Sendable {
    let entityType: String
    let entityID: UUID

    var storageKey: String { "\(entityType)|\(entityID.uuidString)" }
}

enum SyncRecoveryError: Error, Equatable {
    case syncInProgress
    case serverDeletionCannotBeKept
    case retryRequiresRepair
    case unsynchronizedChangesRemain
    case operationChanged
}

enum SyncRecoveryPolicy {
    static func isDeleted(_ value: JSONValue) -> Bool {
        guard let deleted = value.objectValue?["deleted_at"] else { return false }
        return deleted != .null
    }

    static func canRetry(code: String?) -> Bool {
        guard let code else { return false }
        return [
            "network_unavailable", "request_failed", "rate_limited", "throttled",
            "server_error", "service_unavailable", "temporarily_unavailable",
            "invalid_access_token", "authentication_required",
        ].contains(code)
    }

    static func safeCode(_ code: String?) -> String {
        guard let code, !code.isEmpty, code.count <= 64,
              code.utf8.allSatisfy({ (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 })
        else { return "sync_error" }
        return code
    }

    static func references(in payload: JSONValue) -> Set<SyncRecordKey> {
        guard let object = payload.objectValue else { return [] }
        let fields = [
            "tracker_id": "tracker", "account_id": "account",
            "destination_account_id": "account", "default_account_id": "account",
            "category_id": "category", "parent_id": "category",
            "default_category_id": "category", "refund_of_id": "transaction",
            "from_participant_id": "participant", "to_participant_id": "participant",
        ]
        var result = Set<SyncRecordKey>()
        for (field, type) in fields {
            if let raw = object[field]?.stringValue, let id = UUID(uuidString: raw) {
                result.insert(SyncRecordKey(entityType: type, entityID: id))
            }
        }
        for (field, type) in [("tag_ids", "tag"), ("category_ids", "category")] {
            for value in object[field]?.arrayValue ?? [] {
                if let raw = value.stringValue, let id = UUID(uuidString: raw) {
                    result.insert(SyncRecordKey(entityType: type, entityID: id))
                }
            }
        }
        if let split = object["split"]?.objectValue {
            for field in ["payments", "shares"] {
                for value in split[field]?.arrayValue ?? [] {
                    if let raw = value.objectValue?["participant_id"]?.stringValue,
                       let id = UUID(uuidString: raw) {
                        result.insert(SyncRecordKey(entityType: "participant", entityID: id))
                    }
                }
            }
        }
        return result
    }
}

struct FailedOperationSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let entityType: String
    let entityID: UUID
    let command: String
    let localSequence: Int64
    let state: String
    let safeErrorCode: String
    let baseServerVersion: Int64?
    let attemptCount: Int
    let createdAt: Date
    let updatedAt: Date
    let existsLocally: Bool
    let serverDeleted: Bool
    let serverMissing: Bool
    let canRetry: Bool
    let awaitingServerState: Bool
    let sameEntityOperationCount: Int
}

enum SyncDiagnosticReport {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func errorCodeText(_ code: String?) -> String {
        code.map(SyncRecoveryPolicy.safeCode) ?? "none"
    }

    static func text(
        scopeKey: String,
        deviceID: String,
        diagnostics: SyncDiagnosticsSnapshot,
        operations: [FailedOperationSnapshot],
        bundle: Bundle = .main
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Miravo synchronization diagnostics",
            "bundle: \(bundle.bundleIdentifier ?? "unknown")",
            "version: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")",
            "build: \(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")",
            "scope_type: \(SessionScope.isLocal(scopeKey) ? "local" : "authenticated")",
            "scope_digest: \(digest(scopeKey))", "device_digest: \(digest(deviceID))",
            "pending: \(diagnostics.pendingCount)", "failed: \(diagnostics.failedCount)",
            "conflicts: \(diagnostics.conflictCount)", "bootstrap_required: \(diagnostics.bootstrapRequired)",
            "syncing: \(diagnostics.isSyncing)",
            "last_success: \(diagnostics.lastSuccessfulSyncAt.map(formatter.string) ?? "none")",
            "last_attempt: \(diagnostics.lastAttemptAt.map(formatter.string) ?? "none")",
            "last_error: \(errorCodeText(diagnostics.lastSafeErrorCode))",
        ]
        for operation in operations {
            lines.append("operation: \(operation.id) entity: \(operation.entityType) id: \(operation.entityID) command: \(operation.command) sequence: \(operation.localSequence) state: \(operation.state) error: \(operation.safeErrorCode) base: \(operation.baseServerVersion.map(String.init) ?? "nil") attempts: \(operation.attemptCount) deleted: \(operation.serverDeleted) recovery_requested: \(operation.awaitingServerState)")
        }
        return lines.joined(separator: "\n")
    }
}
