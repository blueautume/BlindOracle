import XCTest
@testable import BlindOracle

final class AppLanguageTests: XCTestCase {
    func testLanguageResolutionAndBundledTranslations() throws {
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLocalizations: ["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLocalizations: ["zh-Hant"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLocalizations: ["fr", "Base"]), .simplifiedChinese)
        XCTAssertEqual(L10n.ui("tab.chat", language: .english), "Chat")
        XCTAssertEqual(L10n.ui("tab.chat", language: .simplifiedChinese), "对话")
        let path = try XCTUnwrap(Bundle.main.url(forResource: "en", withExtension: "lproj"))
        let bundle = try XCTUnwrap(Bundle(url: path))
        XCTAssertEqual(bundle.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist"), "BlindOracle")
    }
}
