import XCTest

final class MultiPersonUITests: XCTestCase {
    @MainActor func testCreateTwoNamedProfilesAndChooseBothForRelationshipReading() {
        let app = launchFreshApp()
        app.tabBars.buttons["数据"].tap()
        addProfile("张三", in: app)
        addProfile("李四", in: app)
        XCTAssertTrue(profileRow("张三", in: app).exists)
        XCTAssertTrue(profileRow("李四", in: app).exists)
        capture("named-profile-directory", in: app)
        app.tabBars.buttons["对话"].tap()
        send("张三和李四的合作关系如何安排？", in: app)
        let confirm = app.buttons["confirmIntake"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        for name in ["张三", "李四"] {
            let selection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "selectProfile-", name)).firstMatch
            for _ in 0..<8 where !selection.isHittable { app.swipeUp() }
            XCTAssertTrue(selection.exists)
            if !selection.label.contains("已选") { selection.tap() }
        }
        XCTAssertTrue(app.staticTexts["已选 2 人"].exists)
        capture("joint-reading-two-people-selected", in: app)
        for _ in 0..<10 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        completeCoinsIfRequested(in: app)
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        let data = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        for _ in 0..<8 where !data.isHittable { app.scrollViews["chatTranscript"].swipeUp() }
        XCTAssertTrue(data.isHittable)
        data.tap()
        XCTAssertTrue(app.scrollViews["runResultsSheet"].waitForExistence(timeout: 10))
        for name in ["张三", "李四"] {
            let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", name + " · ")).firstMatch
            for _ in 0..<14 where !title.isHittable { app.scrollViews["runResultsSheet"].swipeUp() }
            XCTAssertTrue(title.exists)
        }
        capture("joint-reading-separate-person-results", in: app)
    }

    @MainActor func testTwoPeopleCollectedFromChatThenNamedUpdateSurvivesRelaunch() {
        let app = launchFreshApp()
        send("姓名：张三，男，1995年1月2日出生；姓名：李四，女，1996年3月4日出生", in: app)
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(profileRow("张三", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(profileRow("李四", in: app).exists)
        let firstID = profileRow("张三", in: app).identifier
        let secondID = profileRow("李四", in: app).identifier
        app.tabBars.buttons["对话"].tap()
        send("张三出生时间08:30，出生地北京", in: app)
        app.tabBars.buttons["数据"].tap()
        let updated = profileRow("张三", in: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "北京"), object: updated)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        XCTAssertEqual(updated.identifier, firstID)
        XCTAssertEqual(profileRow("李四", in: app).identifier, secondID)
        XCTAssertFalse(profileRow("李四", in: app).label.contains("北京"))
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(profileRow("张三", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(profileRow("张三", in: app).identifier, firstID)
        XCTAssertEqual(profileRow("李四", in: app).identifier, secondID)
        XCTAssertTrue(profileRow("张三", in: app).label.contains("北京"))
        XCTAssertFalse(profileRow("张三", in: app).label.contains("时辰未定"))
        XCTAssertTrue(profileRow("李四", in: app).label.contains("时辰未定"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profileRow-")).count, 2)
        capture("chat-collected-profiles-after-relaunch", in: app)
    }

    @MainActor private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func profileRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "profileRow-", name)).firstMatch
    }

    @MainActor private func addProfile(_ name: String, in app: XCUIApplication) {
        let add = app.buttons["addProfile"]
        for _ in 0..<8 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        add.tap()
        let field = app.textFields["profileName"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(name)
        let confirm = app.buttons["confirmIntake"]
        for _ in 0..<10 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(profileRow(name, in: app).waitForExistence(timeout: 10))
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap(); input.typeText(text)
        app.buttons["sendQuestion"].tap()
    }

    @MainActor private func completeCoinsIfRequested(in app: XCUIApplication) {
        let cast = app.buttons["castCoins"]
        guard cast.waitForExistence(timeout: 3) else { return }
        for _ in 0..<6 {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: cast)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            cast.tap()
        }
        let confirm = app.buttons["confirmInteraction"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        confirm.tap()
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
