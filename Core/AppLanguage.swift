import Foundation

enum AppLanguage: String, Sendable, Codable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "oracle.appLanguage"

    /// Holds the language steady for an operation that spans multiple async stages.
    @TaskLocal static var override: AppLanguage?

    static var current: AppLanguage {
        override ?? AppLanguagePreference.current.language
    }

    static func systemLanguage(preferredLocalizations: [String] = Bundle.main.preferredLocalizations) -> AppLanguage {
        preferredLocalizations.lazy.compactMap { identifier -> AppLanguage? in
            switch identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased() {
            case "en": .english
            case "zh": .simplifiedChinese
            default: nil
            }
        }.first ?? .simplifiedChinese
    }

    var isEnglish: Bool { self == .english }

    var locale: Locale {
        let region = Locale.autoupdatingCurrent.region?.identifier ?? (isEnglish ? "US" : "CN")
        return Locale(identifier: "\(rawValue)-\(region)")
    }
}

enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    static var current: Self {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: AppLanguage.preferenceKey), let preference = Self(rawValue: value) {
            return preference
        }
        return .system
    }

    var language: AppLanguage { AppLanguage(rawValue: rawValue) ?? AppLanguage.systemLanguage() }
}

enum OracleVoiceStyle: String, CaseIterable, Identifiable, Sendable {
    case classic, deadpan, warm, storyteller

    static let preferenceKey = "oracle.voiceStyle"
    static let defaultStyle: Self = .deadpan

    var id: String { rawValue }

    static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? defaultStyle
    }

    var title: String { title(language: .current) }

    func title(language: AppLanguage) -> String {
        switch self {
        case .classic: L10n.text("经典", "Classic", language: language)
        case .deadpan: L10n.text("冷面直断", "Deadpan", language: language)
        case .warm: L10n.text("温和参谋", "Warm Adviser", language: language)
        case .storyteller: L10n.text("江湖说书", "Folk Storyteller", language: language)
        }
    }

    var detail: String {
        switch self {
        case .classic: L10n.text("平实稳重，结论之后细讲盘面依据。", "Measured and plainspoken, with the reasoning behind the answer.")
        case .deadpan: L10n.text("直给判断，带一点冷幽默。", "A straight answer with a touch of dry humor.")
        case .warm: L10n.text("温和给建议，帮你看清下一步。", "Gentle, practical guidance on what to do next.")
        case .storyteller: L10n.text("用一个鲜活的比喻说清眼前的局。", "A vivid image that makes the situation easier to read.")
        }
    }
}

enum L10n {
    static func text(_ chinese: String, _ english: @autoclosure () -> String, language: AppLanguage = .current) -> String {
        language.isEnglish ? english() : chinese
    }

    static func ui(_ key: String, language: AppLanguage = .current) -> String {
        let bundle = language.isEnglish ? englishBundle : chineseBundle
        return (bundle ?? Bundle.main).localizedString(forKey: key, value: nil, table: "Localizable")
    }

    private static let englishBundle = bundle(for: .english)
    private static let chineseBundle = bundle(for: .simplifiedChinese)

    private static func bundle(for language: AppLanguage) -> Bundle? {
        Bundle.main.url(forResource: language.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:))
    }
}
