import Foundation
import Security

/// A single device-only credential. Never persisted in chat, profiles, logs or UserDefaults.
final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private let service = "com.blindoracle.deepseek"
    private let account = "api-key"
    private init() {}

    func string() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else {
            throw KeychainError.invalidValue
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        } else if updated != errSecSuccess {
            throw KeychainError.status(updated)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    /// Only the development target may contain this untracked resource.
    /// Release builds cannot import a credential from their app bundle.
    func bootstrapDevelopmentKey() {
        #if DEBUG
        guard let url = Bundle.main.url(forResource: "dev-key", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, string() != key else { return }
        try? save(key)
        #endif
    }

    enum KeychainError: LocalizedError {
        case invalidValue
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalidValue: "请输入完整的 API 密钥。"
            case .status: "无法将密钥保存到本机钥匙串，请重试。"
            }
        }
    }
}
