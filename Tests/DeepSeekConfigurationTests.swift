import XCTest
@testable import BlindOracle

final class DeepSeekConfigurationTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "DeepSeekConfigurationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testFreshInstallUsesPro() throws {
        let defaults = try isolatedDefaults()
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-pro")
        XCTAssertEqual(defaults.string(forKey: "deepseek.model"), "deepseek-v4-pro")
    }

    func testPreviousShippedDefaultsMigrateToPro() throws {
        for previous in ["deepseek-flash", "deepseek-v4-flash", "deepseek-chat", "  deepseek-flash\n", "  "] {
            let defaults = try isolatedDefaults()
            defaults.set(previous, forKey: "deepseek.model")
            XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-pro", previous)
        }
    }

    func testExplicitModelSelectedAfterMigrationIsPreserved() throws {
        let defaults = try isolatedDefaults()
        defaults.set("deepseek-flash", forKey: "deepseek.model")
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-pro")
        defaults.set("deepseek-v4-flash", forKey: "deepseek.model")
        DeepSeekConfiguration.migrateDefault(in: defaults)
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-flash")
    }

    func testExistingCustomModelIsPreservedAndEmptySettingFallsBackToPro() throws {
        let defaults = try isolatedDefaults()
        defaults.set("  custom-compatible-model  ", forKey: "deepseek.model")
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "custom-compatible-model")
        defaults.set("\n ", forKey: "deepseek.model")
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-pro")
    }
}
