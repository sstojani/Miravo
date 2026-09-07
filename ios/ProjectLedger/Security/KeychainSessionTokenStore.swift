import Foundation
import Security

enum KeychainStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

struct StoredSessionCandidate: Equatable, Sendable {
    let scopeKey: String
    let tokens: SessionTokenBundle
}

actor KeychainSessionTokenStore {
    private let service: String

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

    func loadSavedSessions() throws -> [StoredSessionCandidate] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let items = item as? [[String: Any]] else {
            throw KeychainStoreError.invalidData
        }

        return try items.map { item in
            guard let scopeKey = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let tokens = try? JSONDecoder().decode(SessionTokenBundle.self, from: data)
            else {
                throw KeychainStoreError.invalidData
            }
            return StoredSessionCandidate(scopeKey: scopeKey, tokens: tokens)
        }
    }

    func delete(scopeKey: String) throws {
        let status = SecItemDelete(baseQuery(scopeKey: scopeKey) as CFDictionary)
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
