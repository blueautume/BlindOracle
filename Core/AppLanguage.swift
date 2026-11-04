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
