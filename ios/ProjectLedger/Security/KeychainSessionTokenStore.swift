import Foundation
import Security

enum KeychainStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
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

    func delete(scopeKey: String) throws {
        let status = SecItemDelete(baseQuery(scopeKey: scopeKey) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(scopeKey: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scopeKey,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
