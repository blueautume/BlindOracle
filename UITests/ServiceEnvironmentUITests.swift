import XCTest

final class ServiceEnvironmentUITests: XCTestCase {
    @MainActor private func launchWithoutStoreKit(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans",
                               "--ui-testing-production-storekit-unavailable", "--ui-testing-auth-signed-out"] + extra
        app.launch()
        return app
    }

    @MainActor func testProductionSignInContinuesWhenStoreKitIsUnavailable() {
        let app = launchWithoutStoreKit(["--ui-testing-auth-progress"])
        let apple = app.buttons["appleSignInButton"]
        XCTAssertTrue(apple.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["openTestAccess"].exists)
        XCTAssertFalse(app.buttons["重新验证 App Store"].exists)

        apple.tap()
        let progress = app.descendants(matching: .any).matching(identifier: "signInProgress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["openTestAccess"].exists)
        XCTAssertFalse(app.staticTexts["测试"].exists)
        XCTAssertFalse(app.buttons["重新验证 App Store"].exists)
    }

    @MainActor func testTestAccessCancelKeepsProductionAvailableAndValidInviteSelectsSandbox() {
        let app = launchWithoutStoreKit()
        let open = app.buttons["openTestAccess"]
        guard open.waitForExistence(timeout: 10) else { return XCTFail("Test access should be available before choosing a route.") }
        open.tap()

        let invite = app.secureTextFields["testAccessInvite"]
        guard invite.waitForExistence(timeout: 5) else { return XCTFail("The invite should use secure text entry.") }
        let submit = app.buttons["submitTestAccessInvite"]
        XCTAssertFalse(submit.isEnabled)
        invite.tap()
        invite.typeText("invalid")
        XCTAssertFalse(submit.isEnabled)
        app.buttons["cancelTestAccess"].tap()

        XCTAssertTrue(invite.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appleSignInButton"].isHittable)
        XCTAssertFalse(app.staticTexts["测试"].exists)
        open.tap()
        XCTAssertTrue(invite.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        invite.tap()
        invite.typeText(String(repeating: "A", count: 43))
        XCTAssertTrue(submit.isEnabled, "Cancellation must discard the previous invalid entry.")
        submit.tap()

        XCTAssertTrue(app.staticTexts["测试"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["appleSignInButton"].isHittable)
        XCTAssertFalse(open.exists)
        XCTAssertFalse(app.buttons["重新验证 App Store"].exists)
    }

    @MainActor func testCancelledRefreshContinuesToSignInOnlyAfterVerifiedRead() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans",
                               "--ui-testing-auth-signed-out", "--ui-testing-service-cancel-recovery"]
        app.launch()

        let retry = app.buttons["重新验证 App Store"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["appleSignInButton"].exists)
        retry.tap()

        // The local SDK fixture returns userCancelled from the only refresh,
        // then verified evidence from its single shared recovery read.
        XCTAssertTrue(app.buttons["appleSignInButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(retry.exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Store verification must not also sign in the application account.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "cancelled-refresh-verified-read-account-gate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testCancelledRefreshUnverifiedReadKeepsAccountBehindVerification() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans",
                               "--ui-testing-auth-signed-out", "--ui-testing-service-cancel-recovery-failure"]
        app.launch()

        let retry = app.buttons["重新验证 App Store"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["验证代码：env_store_unavailable"].exists)
        retry.tap()

        XCTAssertTrue(app.staticTexts["验证代码：env_unverified"].waitForExistence(timeout: 10))
        XCTAssertTrue(retry.isEnabled)
        XCTAssertTrue(app.buttons["复制诊断信息"].exists)
        XCTAssertFalse(app.buttons["appleSignInButton"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "cancelled-refresh-unverified-read-blocked"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testNetworkReadinessAutomaticallyContinuesVerification() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans",
                               "--ui-testing-service-network-recovery"]
        app.launch()

        let waiting = app.staticTexts["正在等待网络连接，允许联网后会自动继续验证。"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["前往系统设置"].isHittable)
        XCTAssertFalse(app.buttons["重新验证 App Store"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "network-readiness-before-store-verification"
        attachment.lifetime = .keepAlways
        add(attachment)

        // The controlled network check completes without any user retry. Its
        // StoreKit fixture then fails, proving verification resumed on its own.
        XCTAssertTrue(app.buttons["重新验证 App Store"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["验证代码：env_network"].exists)
        XCTAssertTrue(app.buttons["复制诊断信息"].exists)
        XCTAssertFalse(app.tabBars.buttons["数据"].exists)
    }

    @MainActor func testLaunchRecoveryCanCopySafeDiagnosticsAndRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans",
                               "--ui-testing-service-environment-failure"]
        app.launch()

        // The recovery surface's container identifier propagates to children;
        // exercise the controls by their visible, fixed-language labels.
        let retry = app.buttons["重新验证 App Store"]
        guard retry.waitForExistence(timeout: 10) else {
            return XCTFail("The failed verification should expose its recovery action.")
        }
        XCTAssertFalse(app.tabBars.buttons["数据"].exists)
        XCTAssertTrue(app.staticTexts["验证代码：env_network"].exists)
        let copy = app.buttons["复制诊断信息"]
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["诊断信息已复制"].waitForExistence(timeout: 3))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "app-store-verification-recovery-diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)

        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "诊断信息")).firstMatch.exists)
        XCTAssertFalse(app.tabBars.buttons["数据"].exists, "An unsuccessful refresh must keep account services behind verification.")
    }
}
