import XCTest
@testable import BlindOracle

final class DeepSeekConfigurationTests: XCTestCase {
    private final class RecordingDefaults: UserDefaults, @unchecked Sendable {
        var writes = 0
        override func set(_ value: Any?, forKey defaultName: String) {
            writes += 1
            super.set(value, forKey: defaultName)
        }
        override func set(_ value: Bool, forKey defaultName: String) {
            writes += 1
            super.set(value, forKey: defaultName)
        }
    }
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

    func testRepeatedConnectionStatusReadsDoNotRewriteCompletedMigrations() throws {
        let suite = "DeepSeekConfigurationTests.reads." + UUID().uuidString
        let defaults = try XCTUnwrap(RecordingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), DeepSeekConfiguration.defaultModel)
        let initialWrites = defaults.writes
        for _ in 0..<20 { XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), DeepSeekConfiguration.defaultModel) }
        XCTAssertEqual(defaults.writes, initialWrites)
    }

    func testPreviousShippedDefaultsMigrateToPro() throws {
        for previous in ["deepseek-flash", "deepseek-v4-flash", "deepseek-chat", "  deepseek-flash\n", "  "] {
            let defaults = try isolatedDefaults()
            defaults.set(previous, forKey: "deepseek.model")
            XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-pro", previous)
        }
    }

    func testLegacyFlashRestoredWithOldMigrationFlagStillUpgradesToPro() throws {
        let defaults = try isolatedDefaults()
        defaults.set(true, forKey: "deepseek.pro-default-migrated")
        defaults.set("deepseek-v4-flash", forKey: "deepseek.model")
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), DeepSeekConfiguration.defaultModel)
    }

    func testKnownExplicitModelSelectionSurvivesQualityMigration() throws {
        let defaults = try isolatedDefaults()
        defaults.set(true, forKey: "deepseek.pro-default-migrated")
        defaults.set("deepseek-v4-flash", forKey: "deepseek.model")
        DeepSeekConfiguration.recordUserModelSelection("deepseek-v4-flash", in: defaults)
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-flash")
    }

    func testRestoreRecommendedSettingsEnablesOnlineProWithoutRemovingOtherPreferences() throws {
        let defaults = try isolatedDefaults()
        defaults.set("deepseek-v4-flash", forKey: "deepseek.model")
        defaults.set(true, forKey: "oracle.localOnly")
        defaults.set("keep", forKey: "unrelated.preference")
        DeepSeekConfiguration.restoreRecommendedSettings(in: defaults)
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-pro")
        XCTAssertFalse(defaults.bool(forKey: "oracle.localOnly"))
        XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "keep")
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

    func testBundledCredentialTrimsFileWhitespaceAndRejectsEmptyOrMalformedValues() throws {
        XCTAssertEqual(try KeychainStore.BootstrapPolicy.normalizedKey(" \nfixture-bundled-key\r\n"), "fixture-bundled-key")
        for value in ["", " \n\t", "fixture key", "fixture\nkey", "fixture\tkey", "fixture\u{0}key"] {
            XCTAssertThrowsError(try KeychainStore.BootstrapPolicy.normalizedKey(value))
        }
    }

    func testBundledCredentialPopulatesMissingKeychainIncludingAfterCredentialRemoval() throws {
        for manuallySaved in [false, true] {
            let result = try KeychainStore.BootstrapPolicy.decision(
                bundledKey: "fixture-bundled-key", existingKey: nil,
                previousBundledFingerprint: nil, manuallySaved: manuallySaved)
            XCTAssertEqual(result, .imported)
        }
        XCTAssertEqual(try KeychainStore.BootstrapPolicy.decision(
            bundledKey: "fixture-bundled-key", existingKey: " \n",
            previousBundledFingerprint: nil, manuallySaved: false), .imported)
    }

    func testChangedBundledCredentialOnlyUpdatesThePreviouslyImportedKey() throws {
        let previous = KeychainStore.BootstrapPolicy.fingerprint("fixture-bundled-old")
        XCTAssertEqual(try KeychainStore.BootstrapPolicy.decision(
            bundledKey: "fixture-bundled-new", existingKey: "fixture-bundled-old",
            previousBundledFingerprint: previous, manuallySaved: false), .updated)
        XCTAssertEqual(try KeychainStore.BootstrapPolicy.decision(
            bundledKey: "fixture-bundled-old", existingKey: "fixture-bundled-old",
            previousBundledFingerprint: previous, manuallySaved: false), .unchanged)
        XCTAssertEqual(try KeychainStore.BootstrapPolicy.decision(
            bundledKey: "fixture-bundled-new", existingKey: "fixture-external-key",
            previousBundledFingerprint: previous, manuallySaved: false), .preservedUserKey)
    }

    func testManuallySelectedAndLegacyCredentialsArePreserved() throws {
        let previous = KeychainStore.BootstrapPolicy.fingerprint("fixture-bundled-old")
        // Re-entering a previously imported key in Settings is still an explicit choice.
        XCTAssertEqual(try KeychainStore.BootstrapPolicy.decision(
            bundledKey: "fixture-bundled-new", existingKey: "fixture-bundled-old",
            previousBundledFingerprint: previous, manuallySaved: true), .preservedUserKey)
        XCTAssertEqual(try KeychainStore.BootstrapPolicy.decision(
            bundledKey: "fixture-bundled-new", existingKey: "fixture-legacy-key",
            previousBundledFingerprint: nil, manuallySaved: false), .preservedUserKey)
        XCTAssertEqual(try KeychainStore.BootstrapPolicy.decision(
            bundledKey: "fixture-bundled-new", existingKey: "fixture-bundled-new",
            previousBundledFingerprint: previous, manuallySaved: true), .preservedUserKey)
    }

    func testBootstrapRejectsInvalidBundleBeforeConsideringAnExistingCredential() {
        XCTAssertThrowsError(try KeychainStore.BootstrapPolicy.decision(
            bundledKey: " \n", existingKey: "fixture-user-key",
            previousBundledFingerprint: nil, manuallySaved: true))
    }

    func testCredentialFingerprintContainsOnlyAStableDigest() {
        let first = KeychainStore.BootstrapPolicy.fingerprint("fixture-bundled-key")
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(first, KeychainStore.BootstrapPolicy.fingerprint("fixture-bundled-key"))
        XCTAssertNotEqual(first, KeychainStore.BootstrapPolicy.fingerprint("fixture-other-key"))
        XCTAssertNotNil(first.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertFalse(first.contains("fixture"))
    }
}
