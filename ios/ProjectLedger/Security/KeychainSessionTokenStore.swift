import Foundation
import Security

enum KeychainStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

actor KeychainSessionTokenStore {
    private let service: String
    private var refreshes: [String: (id: UUID, sessionID: UUID, task: Task<SessionTokenBundle, Error>)] = [:]

    init(service: String = (Bundle.main.bundleIdentifier ?? "ProjectLedger") + ".session") {
        self.service = service
    }

    func save(_ tokens: SessionTokenBundle, scopeKey: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let query = baseQuery(scopeKey: scopeKey)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var insertion = query
        insertion.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func load(scopeKey: String) throws -> SessionTokenBundle? {
        var query = baseQuery(scopeKey: scopeKey)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data,
              let tokens = try? JSONDecoder().decode(SessionTokenBundle.self, from: data)
        else {
            throw KeychainStoreError.invalidData
        }
        return tokens
    }

    func delete(scopeKey: String) throws {
        let status = SecItemDelete(baseQuery(scopeKey: scopeKey) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func delete(scopeKey: String, matching tokens: SessionTokenBundle) throws {
        guard try load(scopeKey: scopeKey) == tokens else { return }
        try delete(scopeKey: scopeKey)
    }

    func refresh(
        scopeKey: String,
        replacing previous: SessionTokenBundle,
        request: @escaping @Sendable (String) async throws -> SessionTokenBundle
    ) async throws -> SessionTokenBundle {
        guard let current = try load(scopeKey: scopeKey), current.sessionID == previous.sessionID else {
            throw CancellationError()
        }
        if current != previous { return current }

        // Sync and settings share one rotation; replaying a refresh token revokes the session.
        let existing = refreshes[scopeKey].flatMap { $0.sessionID == previous.sessionID ? $0 : nil }
        let refresh = existing ?? (
            id: UUID(),
            sessionID: previous.sessionID,
            task: Task { try await request(previous.refreshToken) }
        )
        refreshes[scopeKey] = refresh
        defer {
            if refreshes[scopeKey]?.id == refresh.id { refreshes[scopeKey] = nil }
        }
        let updated = try await refresh.task.value
        guard updated.sessionID == previous.sessionID,
              updated.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              !updated.accessToken.isEmpty, !updated.refreshToken.isEmpty
        else { throw KeychainStoreError.invalidData }
        // A completed refresh must never restore credentials removed by sign-out.
        guard let saved = try load(scopeKey: scopeKey) else { throw CancellationError() }
        if saved == updated { return updated }
        guard saved == previous else { throw CancellationError() }
        try save(updated, scopeKey: scopeKey)
        return updated
    }

    func deleteAll() throws {
        let status = SecItemDelete(serviceQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func serviceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func baseQuery(scopeKey: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = scopeKey
        return query
    }
}
