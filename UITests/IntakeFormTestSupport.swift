import XCTest

extension XCTestCase {
    @MainActor func selectCastingMode(method: String, mode: String, in app: XCUIApplication,
                                     language: String = "zh-Hans", file: StaticString = #filePath, line: UInt = #line) {
        let data = app.tabBars.buttons[language == "en" ? "Data" : "数据"]
        XCTAssertTrue(data.waitForExistence(timeout: 10), file: file, line: line); data.tap()
        let row = app.buttons["localMethod-\(method)"]
        if !row.exists {
            let directory = app.buttons["localMethodsDirectory"]
            if !directory.exists {
                let back = app.navigationBars.buttons.element(boundBy: 0)
                XCTAssertTrue(back.exists, file: file, line: line); back.tap()
            } else {
                for _ in 0..<6 where !directory.isHittable { app.swipeUp() }
                XCTAssertTrue(directory.isHittable, file: file, line: line); directory.tap()
            }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable, file: file, line: line); row.tap()
        let choice = app.buttons["\(method)Mode-\(mode)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), file: file, line: line)
        for _ in 0..<6 where !choice.isHittable { app.swipeUp() }
        XCTAssertTrue(choice.isHittable, file: file, line: line); choice.tap()
        XCTAssertTrue(choice.isSelected, file: file, line: line)
        let chat = app.tabBars.buttons[language == "en" ? "Chat" : "对话"]
        XCTAssertTrue(chat.exists, file: file, line: line); chat.tap()
        XCTAssertTrue(app.textFields["questionInput"].waitForExistence(timeout: 10), file: file, line: line)
    }

    @MainActor func assertReadingConfirmationInNavigationBar(in app: XCUIApplication, language: String,
                                                             file: StaticString = #filePath, line: UInt = #line) {
        let navigation = app.navigationBars[language == "en" ? "Reading details" : "问事资料"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 10), file: file, line: line)
        let confirm = navigation.buttons["confirmIntake"]
        XCTAssertTrue(confirm.exists, file: file, line: line)
        XCTAssertTrue(confirm.isHittable, "Confirmation must be reachable before scrolling the form", file: file, line: line)
        XCTAssertEqual(confirm.label, language == "en" ? "Confirm and continue" : "确认并继续", file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "confirmIntake").count, 1, file: file, line: line)
        XCTAssertGreaterThan(confirm.frame.midX, navigation.frame.midX, file: file, line: line)
        XCTAssertFalse(app.buttons["cancelIntake"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["稍后填写"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["Finish later"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["确认资料并开始"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["Confirm and begin"].exists, file: file, line: line)
    }

    /// Native sheet dismissal keeps the draft. Cancel reading intentionally
    /// deletes the pending task and cannot stand in for this gesture.
    @MainActor func dismissReadingDetailsSheet(in app: XCUIApplication,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 10), file: file, line: line)
        let navigation = app.navigationBars.containing(.button, identifier: "confirmIntake").firstMatch
        XCTAssertTrue(navigation.exists, file: file, line: line)
        let start = navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(form.waitForNonExistence(timeout: 5), file: file, line: line)
    }
}
