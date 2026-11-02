import Foundation

enum DeepSeekConfiguration {
    static let defaultModel = "deepseek-v4-pro"

    /// Upgrade the previous shipped Flash default once, while allowing a later
    /// explicit model change in Settings to remain the user's choice.
    static func migrateDefault(in defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "deepseek.pro-default-migrated") else { return }
        let previous = defaults.string(forKey: "deepseek.model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if previous.isEmpty || ["deepseek-flash", "deepseek-v4-flash", "deepseek-chat"].contains(previous) {
            defaults.set(defaultModel, forKey: "deepseek.model")
        }
        defaults.set(true, forKey: "deepseek.pro-default-migrated")
    }

    static func model(in defaults: UserDefaults = .standard) -> String {
        migrateDefault(in: defaults)
        let stored = defaults.string(forKey: "deepseek.model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultModel : stored
    }
}
