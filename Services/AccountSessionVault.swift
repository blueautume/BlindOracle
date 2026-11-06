import Foundation
import Security

protocol AccountSessionStorage {
    func load() throws -> AccountSession?
    func save(_ session: AccountSession) throws
    func delete() throws
}

/// Separate from the existing AI credential namespace and from all local reading files.
final class AccountSessionVault: AccountSessionStorage {
    private let service: String
    private var invalidatedKey: String { service + ".session-invalidated" }
    private let account = "apple-account-session-v1"
    init(service: String = ServiceEnvironment.current.sessionKeychainService) { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func load() throws -> AccountSession? {
        guard !UserDefaults.standard.bool(forKey: invalidatedKey) else { return nil }
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(AccountSession.self, from: data) else { throw AccountAPIError.storage }
        return value
    }
    func save(_ session: AccountSession) throws {
        let fields: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(fields) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw AccountAPIError.storage }
        } else if status != errSecSuccess { throw AccountAPIError.storage }
        UserDefaults.standard.removeObject(forKey: invalidatedKey)
    }
    func delete() throws {
        // Persist the lock even if Keychain is temporarily locked; an old token must not restore after logout.
        UserDefaults.standard.set(true, forKey: invalidatedKey)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountAPIError.storage }
    }
}
