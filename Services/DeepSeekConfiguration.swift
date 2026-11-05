import Foundation

/// Application-owned interpretation settings. Legacy preferences never select
/// an endpoint, model, or offline interpretation mode.
enum DeepSeekConfiguration {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static let defaultModel = "deepseek-v4-pro"
    static let thinkingEnabled = true
    static let reasoningEffort = "max"
    static let outputTokenBudget = 65_536

    static func model(in defaults: UserDefaults = .standard) -> String { defaultModel }

    /// Remove retired controls while preserving language, voice and user data.
    static func migrateDefault(in defaults: UserDefaults = .standard) {
        for key in ["oracle.aiProvider", "oracle.localOnly", "deepseek.model",
                    "deepseek.model.explicit-selection", "deepseek.pro-default-migrated",
                    "deepseek.pro-quality-defaults-v2"] where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}
