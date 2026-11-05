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

    func testFreshInstallUsesFixedOnlineInterpretationSettings() throws {
        let defaults = try isolatedDefaults()
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-pro")
        XCTAssertEqual(DeepSeekConfiguration.endpoint.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertTrue(DeepSeekConfiguration.thinkingEnabled)
        XCTAssertEqual(DeepSeekConfiguration.reasoningEffort, "max")
        XCTAssertEqual(DeepSeekConfiguration.outputTokenBudget, 65_536)
        XCTAssertNil(defaults.object(forKey: "deepseek.model"))
    }

    func testRetiredModelAndProviderPreferencesCannotOverrideTheBuiltInService() throws {
        for previous in ["deepseek-flash", "deepseek-v4-flash", "deepseek-chat", "custom-compatible-model", "  "] {
            let defaults = try isolatedDefaults()
            defaults.set(previous, forKey: "deepseek.model")
            defaults.set(previous, forKey: "deepseek.model.explicit-selection")
            defaults.set("qwen", forKey: "oracle.aiProvider")
            defaults.set(true, forKey: "oracle.localOnly")
            XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), "deepseek-v4-pro", previous)
        }
    }

    func testFixedModelReadsNeverWriteUserPreferences() throws {
        let suite = "DeepSeekConfigurationTests.reads." + UUID().uuidString
        let defaults = try XCTUnwrap(RecordingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initialWrites = defaults.writes
        for _ in 0..<20 { XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), DeepSeekConfiguration.defaultModel) }
        XCTAssertEqual(defaults.writes, initialWrites)
    }

    func testMigrationRemovesRetiredControlsAndPreservesLanguageVoiceAndUnrelatedPreferences() throws {
        let defaults = try isolatedDefaults()
        let retired = ["oracle.aiProvider", "oracle.localOnly", "deepseek.model", "deepseek.model.explicit-selection",
                       "deepseek.pro-default-migrated", "deepseek.pro-quality-defaults-v2"]
        for key in retired { defaults.set("retired-value", forKey: key) }
        defaults.set("en", forKey: "oracle.appLanguage")
        defaults.set("warm", forKey: "oracle.voiceStyle")
        defaults.set("keep", forKey: "unrelated.preference")
        DeepSeekConfiguration.migrateDefault(in: defaults)
        for key in retired { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(defaults.string(forKey: "oracle.appLanguage"), "en")
        XCTAssertEqual(defaults.string(forKey: "oracle.voiceStyle"), "warm")
        XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "keep")
        DeepSeekConfiguration.migrateDefault(in: defaults)
        XCTAssertEqual(DeepSeekConfiguration.model(in: defaults), DeepSeekConfiguration.defaultModel)
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
