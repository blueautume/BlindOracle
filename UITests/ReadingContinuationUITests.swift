import XCTest

final class ReadingContinuationUITests: XCTestCase {
    @MainActor func testDetailFollowUpUsesSavedReadingWithoutAnotherIntakeAndSurvivesRelaunch() throws {
        let app = launchSavedReading()
        send("这个卦象里的建议具体是什么意思？", in: app)
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "沿用这次已保存的卦象")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        assertNoNewCast(in: app)
        capture("follow-up-reuses-saved-reading", in: app)
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(record("推演删除测试10", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(record("这个卦象里的建议具体是什么意思？", in: app).exists)

        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.textFields["questionInput"].waitForExistence(timeout: 15))
        send("我接下来应该先做哪件事？", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "沿用这次已保存的卦象")).firstMatch.waitForExistence(timeout: 15))
        assertNoNewCast(in: app)
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(record("推演删除测试10", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(record("我接下来应该先做哪件事？", in: app).exists)
    }

    @MainActor func testExplicitFreshReadingRequestStillConfirmsThenOffersSixCoinCasts() throws {
        let app = launchSavedReading()
        send("重新起卦，只用六爻看看明天出行是否顺利", in: app)
        let confirm = app.buttons["confirmIntake"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["castCoins"].exists)
        for _ in 0..<6 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(app.buttons["castCoins"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["confirmInteraction"].isEnabled)
        capture("explicit-new-reading-starts-coins", in: app)
    }

    @MainActor private func launchSavedReading() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reading-library"]
        app.launch()
        XCTAssertTrue(app.textFields["questionInput"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let input = app.textFields["questionInput"]
        input.tap(); input.typeText(text)
        app.buttons["sendQuestion"].tap()
    }

    @MainActor private func assertNoNewCast(in app: XCUIApplication) {
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
        XCTAssertFalse(app.buttons["interactionCard"].exists)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        XCTAssertEqual(app.sheets.count, 0)
    }

    @MainActor private func record(_ question: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "readingRecord-", question)).firstMatch
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
