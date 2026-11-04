import Foundation

enum AIProvider: String, CaseIterable, Sendable {
    case deepSeek
    case qwen

    static let selectionKey = "oracle.aiProvider"
    static let qwenSnapshotModel = "qwen3.8-max-0902"

    var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .qwen: L10n.text("千问", "Qwen")
        }
    }

    var endpoint: URL {
        switch self {
        case .deepSeek: URL(string: "https://api.deepseek.com/chat/completions")!
        case .qwen: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
        }
    }

    func model(in defaults: UserDefaults = .standard) -> String {
        switch self {
        case .deepSeek: DeepSeekConfiguration.model(in: defaults)
        case .qwen: Self.qwenSnapshotModel
        }
    }

    var reasoningEffort: String {
        switch self {
        case .deepSeek: DeepSeekConfiguration.reasoningEffort
        case .qwen: "xhigh"
        }
    }

    var reasoningDescription: String { L10n.text("深度思考 \(reasoningEffort)", "Reasoning: \(reasoningEffort)") }

    var outputTokenBudget: Int {
        switch self {
        case .deepSeek: DeepSeekConfiguration.outputTokenBudget
        case .qwen: 65_536
        }
    }

    var outputTokenParameter: String {
        switch self {
        case .deepSeek: "max_tokens"
        case .qwen: "max_completion_tokens"
        }
    }
}

enum DeepSeekConfiguration {
    static let defaultModel = "deepseek-v4-pro"
    static let thinkingEnabled = true
    static let reasoningEffort = "max"
    static let outputTokenBudget = 65_536
    private static let qualityMigrationKey = "deepseek.pro-quality-defaults-v2"
    private static let explicitModelKey = "deepseek.model.explicit-selection"

    /// Upgrade the previous shipped Flash default once, while allowing a later
    /// explicit model change in Settings to remain the user's choice.
    static func migrateDefault(in defaults: UserDefaults = .standard) {
        let previous = defaults.string(forKey: "deepseek.model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacy = ["deepseek-flash", "deepseek-v4-flash", "deepseek-chat"]
        let firstMigration = !defaults.bool(forKey: "deepseek.pro-default-migrated")
        let qualityMigration = !defaults.bool(forKey: qualityMigrationKey)
        // Connection status is read while rendering views with @AppStorage.
        // Rewriting completed migration flags would continuously invalidate them.
        guard firstMigration || qualityMigration else { return }
        let explicitlySelected = defaults.string(forKey: explicitModelKey) == previous
        if (previous.isEmpty && (firstMigration || qualityMigration)) || (legacy.contains(previous) && (firstMigration || (qualityMigration && !explicitlySelected))) {
            defaults.set(defaultModel, forKey: "deepseek.model")
        }
        defaults.set(true, forKey: "deepseek.pro-default-migrated")
        defaults.set(true, forKey: qualityMigrationKey)
    }

    static func model(in defaults: UserDefaults = .standard) -> String {
        migrateDefault(in: defaults)
        let stored = defaults.string(forKey: "deepseek.model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultModel : stored
    }

    static func recordUserModelSelection(_ model: String, in defaults: UserDefaults = .standard) {
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: explicitModelKey)
    }

    static func restoreRecommendedSettings(in defaults: UserDefaults = .standard) {
        defaults.set(defaultModel, forKey: "deepseek.model")
        defaults.set(false, forKey: "oracle.localOnly")
        recordUserModelSelection(defaultModel, in: defaults)
        migrateDefault(in: defaults)
    }
}
