import XCTest

final class ServiceEnvironmentUITests: XCTestCase {
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
