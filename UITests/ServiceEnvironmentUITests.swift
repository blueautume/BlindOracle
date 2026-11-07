import XCTest

final class ServiceEnvironmentUITests: XCTestCase {
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
