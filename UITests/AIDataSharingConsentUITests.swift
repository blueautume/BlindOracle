import XCTest

final class AIDataSharingConsentUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans",
            "--ui-testing-ai-consent-required", "--ui-testing-ai-consent-reset", "--ui-testing-ai-consent-suite", UUID().uuidString]
        app.launch()
        return app
    }

    @MainActor private func tapConsentButton(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let scroll = app.scrollViews["aiDataSharingScroll"]
        for _ in 0..<6 where !button.isHittable {
            if scroll.exists { scroll.swipeUp() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    @MainActor func testDecliningKeepsDraftAndLocalDataAccessible() {
        let app = launch()
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let draft = "这是一条尚未发送的问题"
        input.tap(); input.typeText(draft)
        app.buttons["sendQuestion"].tap()
        let decline = app.buttons["declineAIDataSharing"]
        XCTAssertTrue(decline.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "wellecho.cn")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "DeepSeek")).firstMatch.exists)
        XCTAssertTrue(app.buttons["aiDataSharingPrivacy"].exists)
        XCTAssertFalse(app.scrollViews["intakeFormScroll"].exists)
        tapConsentButton("declineAIDataSharing", in: app)
        XCTAssertTrue(decline.waitForNonExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertFalse(app.staticTexts[draft].exists, "Declining must not append the unsent draft to the conversation")
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(app.buttons["accountEntry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settingsButton"].exists)
    }

    @MainActor func testAgreementContinuesPendingSendAndWithdrawalRequiresConsentAgain() {
        let app = launch()
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let question = "只用塔罗看看今年工作的方向"
        input.tap(); input.typeText(question)
        app.buttons["sendQuestion"].tap()
        XCTAssertTrue(app.buttons["agreeAIDataSharing"].waitForExistence(timeout: 5))
        tapConsentButton("agreeAIDataSharing", in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 10), "The local test agent should continue only after agreement")
        app.buttons["cancelPendingIntake"].tap()
        XCTAssertTrue(form.waitForNonExistence(timeout: 5))
        app.buttons["aiDataSharingSettings"].tap()
        let revoke = app.buttons["revokeAIDataSharing"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 5)); tapConsentButton("revokeAIDataSharing", in: app)
        XCTAssertTrue(app.buttons["declineAIDataSharing"].waitForExistence(timeout: 5))
        tapConsentButton("declineAIDataSharing", in: app)
        let draft = "撤回后保留的草稿"
        input.tap(); input.typeText(draft)
        app.buttons["sendQuestion"].tap()
        XCTAssertTrue(app.buttons["agreeAIDataSharing"].waitForExistence(timeout: 5))
        tapConsentButton("declineAIDataSharing", in: app)
        XCTAssertEqual(input.value as? String, draft)
    }
}
