import Foundation
import Security
import CryptoKit

/// A single device-only credential. Never persisted in chat, profiles, logs or UserDefaults.
final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore(namespace: "deepseek", bundleResource: "dev-key")
    private static let qwen = KeychainStore(namespace: "qwen", bundleResource: "qwen-key")
    private let service: String
    private let bundleResource: String
    private let account = "api-key"
    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let bundledFingerprintKey: String
    private let manuallySavedKey: String

    private init(namespace: String, bundleResource: String) {
        service = "com.blindoracle.\(namespace)"
        self.bundleResource = bundleResource
        bundledFingerprintKey = "\(namespace).bundled-key.sha256"
        manuallySavedKey = "\(namespace).credential.manually-saved"
    }

    static func store(for provider: AIProvider) -> KeychainStore {
        switch provider {
        case .deepSeek: shared
        case .qwen: qwen
        }
    }

    func string() -> String? {
        try? load()
    }

    func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try storedString()
    }

    /// An absent item is different from a locked or inaccessible keychain.
    /// Bootstrap must not replace an unreadable user credential with another account.
    private func storedString() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.readStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unreadableValue
        }
        return try? BootstrapPolicy.normalizedKey(value)
    }

    func save(_ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        try persist(BootstrapPolicy.normalizedKey(value))
        // Settings is an explicit choice, including re-entering the same key.
        defaults.set(true, forKey: manuallySavedKey)
    }

    private func persist(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
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
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
        defaults.removeObject(forKey: bundledFingerprintKey)
        defaults.removeObject(forKey: manuallySavedKey)
    }

    enum BootstrapResult: Equatable {
        case missingResource, imported, updated, unchanged, preservedUserKey
    }

    /// Imports the application's bundled credential in both Debug and Release.
    /// The historical method name remains compatible with existing callers.
    @discardableResult func bootstrapDevelopmentKey() throws -> BootstrapResult {
        lock.lock(); defer { lock.unlock() }
        guard let url = Bundle.main.url(forResource: bundleResource, withExtension: "txt") else { return .missingResource }
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch { throw KeychainError.bundledResourceUnreadable }
        let key = try BootstrapPolicy.normalizedKey(text)
        let result = try BootstrapPolicy.decision(
            bundledKey: key, existingKey: storedString(),
            previousBundledFingerprint: defaults.string(forKey: bundledFingerprintKey),
            manuallySaved: defaults.bool(forKey: manuallySavedKey))
        if result == .imported || result == .updated {
            try persist(key)
        }
        if result == .imported || result == .updated || result == .unchanged {
            // Commit ownership only after the keychain write succeeds.
            // Matching legacy imports can acquire provenance without rewriting
            // the key; explicit manual keys return preservedUserKey instead.
            defaults.set(BootstrapPolicy.fingerprint(key), forKey: bundledFingerprintKey)
            defaults.set(false, forKey: manuallySavedKey)
        }
        return result
    }

    /// Pure decisions are testable without accessing the user's real keychain.
    enum BootstrapPolicy {
        static func normalizedKey(_ value: String) throws -> String {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw KeychainError.invalidValue
            }
            return key
        }

        static func fingerprint(_ key: String) -> String {
            SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        static func decision(bundledKey: String, existingKey: String?, previousBundledFingerprint: String?,
                             manuallySaved: Bool) throws -> BootstrapResult {
            let bundled = try normalizedKey(bundledKey)
            guard let existing = existingKey.flatMap({ try? normalizedKey($0) }) else { return .imported }
            guard !manuallySaved else { return .preservedUserKey }
            if existing == bundled { return .unchanged }
            // Only replace a key that is still the last credential we imported.
            // Unknown legacy ownership and external/manual replacements are preserved.
            guard fingerprint(existing) == previousBundledFingerprint else { return .preservedUserKey }
            return .updated
        }
    }

    enum KeychainError: LocalizedError {
        case invalidValue
        case status(OSStatus)
        case readStatus(OSStatus)
        case unreadableValue
        case bundledResourceUnreadable
        var errorDescription: String? {
            switch self {
            case .invalidValue: L10n.text("请输入完整的 API 密钥。", "Enter the full API key.")
            case .status: L10n.text("无法将密钥保存到本机钥匙串，请重试。", "Couldn't save the API key to the device keychain. Try again.")
            case .readStatus, .unreadableValue: L10n.text("无法读取本机钥匙串中的解读密钥，请解锁设备后重试。", "Couldn't read the API key from the device keychain. Unlock your device and try again.")
            case .bundledResourceUnreadable: L10n.text("随包解读密钥未能读取，请检查应用资源配置。", "Couldn't read the bundled API key. Check the app's configuration.")
            }
        }
    }
}
