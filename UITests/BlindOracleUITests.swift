import XCTest

final class BlindOracleUITests: XCTestCase {
    @MainActor func testProfilePersistsAcrossAppRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        let profile = app.buttons["addProfile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10)); profile.tap()
        let name = app.textFields["profileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("张小明")
        let save = app.buttons["confirmIntake"]
        for _ in 0..<9 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.staticTexts["张小明"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(app.staticTexts["张小明"].waitForExistence(timeout: 10))
    }
    @MainActor func testTwoTabsAndLocalReadingFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["对话"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["数据"].exists)
        XCTAssertEqual(app.tabBars.buttons.count, 2)
        let welcome = XCTAttachment(screenshot: app.screenshot()); welcome.name = "01-welcome"; welcome.lifetime = .keepAlways; add(welcome)
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.exists)
        input.tap(); input.typeText("未来一周适合推进手头的计划吗？")
        app.buttons["sendQuestion"].tap()
        let confirm = app.buttons["confirmIntake"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        let intake = XCTAttachment(screenshot: app.screenshot()); intake.name = "02-intake"; intake.lifetime = .keepAlways; add(intake)
        for _ in 0..<5 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        completeCoinInteraction(in: app)
        let localSummary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch
        XCTAssertTrue(localSummary.waitForExistence(timeout: 30))
        let reference = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        for _ in 0..<3 where !reference.isHittable { app.swipeUp() }
        let chatShot = XCTAttachment(screenshot: app.screenshot()); chatShot.name = "06-chat-bubbles"; chatShot.lifetime = .keepAlways; add(chatShot)
        XCTAssertTrue(reference.exists); reference.tap()
        XCTAssertTrue(app.staticTexts["runResultsQuestion"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["runResultsQuestion"].label, "未来一周适合推进手头的计划吗？")
        XCTAssertTrue(app.staticTexts["六爻 / 周易筮法"].exists)
        XCTAssertTrue(app.staticTexts["本卦"].firstMatch.exists)
        let referenceShot = XCTAttachment(screenshot: app.screenshot()); referenceShot.name = "04-direct-reading-results"; referenceShot.lifetime = .keepAlways; add(referenceShot)
        app.buttons["closeRunResults"].tap()
        XCTAssertTrue(app.tabBars.buttons["对话"].isSelected)
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(app.staticTexts["推演记录"].waitForExistence(timeout: 10))
        let record = app.staticTexts["未来一周适合推进手头的计划吗？"].firstMatch
        XCTAssertTrue(record.exists); record.tap()
        XCTAssertTrue(app.staticTexts["原始推演"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["梅花易数"].exists)
        let data = XCTAttachment(screenshot: app.screenshot()); data.name = "03-independent-results"; data.lifetime = .keepAlways; add(data)
    }

    @MainActor func testHistoryRestoresPendingIntakeAndDeletionSurvivesRestart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        let question = "明天适合推进这个计划吗？"
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15)); input.tap(); input.typeText(question)
        app.buttons["sendQuestion"].tap()
        XCTAssertTrue(app.buttons["confirmIntake"].waitForExistence(timeout: 15))
        app.buttons["稍后填写"].tap()
        startNewConversation(app)
        app.buttons["historyButton"].tap()
        let row = historyRow(in: app, titled: question)
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.buttons["intakeCard"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[question].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.buttons["intakeCard"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[question].exists)
        app.buttons["historyButton"].tap()
        let restored = historyRow(in: app, titled: question)
        XCTAssertTrue(restored.waitForExistence(timeout: 10)); restored.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["deleteConversation"].firstMatch.waitForExistence(timeout: 10)); app.buttons["deleteConversation"].firstMatch.tap()
        XCTAssertTrue(app.buttons["confirmDeleteConversation"].firstMatch.waitForExistence(timeout: 10)); app.buttons["confirmDeleteConversation"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["往日问事，都会留在这里。"].waitForExistence(timeout: 10))
        app.buttons["closeHistory"].firstMatch.tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["historyButton"].waitForExistence(timeout: 15)); app.buttons["historyButton"].tap()
        XCTAssertFalse(historyRow(in: app, titled: question).exists)
        XCTAssertTrue(app.staticTexts["往日问事，都会留在这里。"].exists)
    }

    @MainActor func testEarlierReplyOpensItsOwnResultsAfterNewerConversation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        let first = "本周适合整理手头的计划吗？"
        let second = "下周适合安排这次出行吗？"
        completeLocalQuestion(first, in: app)
        startNewConversation(app)
        completeLocalQuestion(second, in: app)
        app.buttons["historyButton"].tap()
        let old = historyRow(in: app, titled: first)
        XCTAssertTrue(old.waitForExistence(timeout: 10))
        let historyShot = XCTAttachment(screenshot: app.screenshot()); historyShot.name = "05-history-sidebar"; historyShot.lifetime = .keepAlways; add(historyShot)
        old.tap()
        let dataButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        XCTAssertTrue(dataButton.waitForExistence(timeout: 10))
        for _ in 0..<4 where !dataButton.isHittable { app.swipeUp() }
        dataButton.tap()
        XCTAssertTrue(app.staticTexts["runResultsQuestion"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["runResultsQuestion"].label, first)
        XCTAssertFalse(app.staticTexts[second].exists)
    }

    @MainActor private func historyRow(in app: XCUIApplication, titled title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "historyRow-", title)).firstMatch
    }
    @MainActor private func startNewConversation(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["newConversationButton"].waitForExistence(timeout: 10))
        app.buttons["newConversationButton"].tap()
        XCTAssertTrue(app.buttons["confirmNewConversation"].firstMatch.waitForExistence(timeout: 10)); app.buttons["confirmNewConversation"].firstMatch.tap()
    }
    @MainActor private func completeLocalQuestion(_ question: String, in app: XCUIApplication) {
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15)); input.tap(); input.typeText(question)
        app.buttons["sendQuestion"].tap()
        let confirm = app.buttons["confirmIntake"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        for _ in 0..<7 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable); confirm.tap()
        completeCoinInteraction(in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch.waitForExistence(timeout: 30))
    }

    @MainActor private func completeCoinInteraction(in app: XCUIApplication) {
        let cast = app.buttons["castCoins"]
        XCTAssertTrue(cast.waitForExistence(timeout: 15))
        for _ in 0..<6 {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: cast)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            XCTAssertTrue(cast.isHittable)
            cast.tap()
        }
        let confirm = app.buttons["confirmInteraction"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
    }
}
