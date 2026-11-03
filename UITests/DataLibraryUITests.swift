import XCTest

final class DataLibraryUITests: XCTestCase {
    @MainActor func testDataTabOmitsStoredReadingsAndChatStillOpensThem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reading-library"]
        app.launch()
        let dataTab = app.tabBars.buttons["数据"]
        XCTAssertTrue(dataTab.waitForExistence(timeout: 15))
        dataTab.tap()

        XCTAssertTrue(app.staticTexts["留存资料"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["陈平"].exists)
        XCTAssertFalse(app.staticTexts["推演记录"].exists)
        XCTAssertFalse(app.buttons["allReadings"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingRecord-")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["解读偏好"].exists)
        XCTAssertFalse(app.staticTexts["原始结果按方法单独留存，此处不做合并。"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "compact-data-library"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let methods = app.buttons["localMethodsDirectory"]
        XCTAssertTrue(methods.isHittable)
        methods.tap()
        let method = app.buttons["localMethod-bazi"]
        XCTAssertTrue(method.waitForExistence(timeout: 10))
        method.tap()
        XCTAssertTrue(app.staticTexts["所需资料"].waitForExistence(timeout: 10))

        app.tabBars.buttons["对话"].tap()
        let references = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-"))
        XCTAssertTrue(references.firstMatch.waitForExistence(timeout: 10))
        let lastReference = try XCTUnwrap(references.allElementsBoundByIndex.last)
        for _ in 0..<4 where !lastReference.isHittable { app.scrollViews["chatTranscript"].swipeUp() }
        XCTAssertTrue(lastReference.isHittable)
        lastReference.tap()
        let question = app.staticTexts["runResultsQuestion"]
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        XCTAssertEqual(question.label, "推演删除测试10")
        XCTAssertTrue(app.staticTexts["测试编号"].exists)
    }
}
