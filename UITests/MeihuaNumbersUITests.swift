import XCTest

final class MeihuaNumbersUITests: XCTestCase {
    @MainActor func testChineseRandomNumbersCanBeEditedAndResumeWithoutReplacingTheDraft() throws {
        try verifyNumberEntry(language: "zh-Hans")
    }

    @MainActor func testEnglishRandomNumbersCanBeEditedAndResumeWithoutReplacingTheDraft() throws {
        try verifyNumberEntry(language: "en")
    }

    @MainActor private func verifyNumberEntry(language: String) throws {
        continueAfterFailure = false
        let english = language == "en"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-location-fixture",
                               "--ui-testing-reset-language", "-oracle.appLanguage", language]
        app.launch()
        let question = app.textFields["questionInput"]
        XCTAssertTrue(question.waitForExistence(timeout: 15)); question.tap()
        question.typeText(english ? "Use only Meihua with three numbers to explore this trip." : "只用梅花报数，看看这次出行如何安排")
        app.buttons["sendQuestion"].tap()

        let intake = app.buttons["confirmIntake"]
        XCTAssertTrue(intake.waitForExistence(timeout: 15))
        assertReadingConfirmationInNavigationBar(in: app, language: language)
        XCTAssertFalse(app.textFields["intakeNumber-0"].exists)
        XCTAssertFalse(app.buttons["castingLocationButton"].exists)
        waitUntilEnabled(intake); intake.tap()

        let fields = (0..<3).map { app.textFields["interactionNumber-\($0)"] }
        XCTAssertTrue(fields[0].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        for field in fields { assertEmpty(field) }
        let confirm = app.buttons["confirmInteraction"]
        XCTAssertTrue(confirm.exists); XCTAssertFalse(confirm.isEnabled)

        let generate = app.buttons["generateNumbers"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5)); generate.tap()
        let generated = try fields.map { field -> String in
            let value = try XCTUnwrap(field.value as? String)
            let number = try XCTUnwrap(Int(value))
            XCTAssertTrue((1...999).contains(number))
            return value
        }
        waitUntilEnabled(confirm)
        capture("random-numbers-\(language)", in: app)

        // Invalid and blank edits must not retain a stale, previously valid
        // integer in the confirmation payload.
        replaceNumber(in: fields[1], with: "1000")
        XCTAssertEqual(fields[1].value as? String, "1000")
        XCTAssertFalse(confirm.isEnabled)
        replaceNumber(in: fields[1], with: "")
        assertEmpty(fields[1]); XCTAssertFalse(confirm.isEnabled)
        dismissNumberKeyboard(in: app)

        app.buttons["deferInteraction"].tap()
        XCTAssertTrue(fields[0].waitForNonExistence(timeout: 5))
        reopenNumbers(in: app)
        assertDraft(fields: fields, generated: generated)
        XCTAssertFalse(confirm.isEnabled)

        // Restore a deliberately incomplete draft from disk, not just from a
        // view's memory. Opening it must never silently generate new values.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-testing-reset" || $0 == "--ui-testing-location-fixture" }
        app.launch()
        reopenNumbers(in: app)
        assertDraft(fields: fields, generated: generated)
        XCTAssertFalse(confirm.isEnabled)
        capture("restored-incomplete-number-draft-\(language)", in: app)

        let edited = generated[1] == "317" ? "318" : "317"
        replaceNumber(in: fields[1], with: edited)
        dismissNumberKeyboard(in: app)
        XCTAssertEqual(fields[1].value as? String, edited)
        waitUntilEnabled(confirm)
        capture("edited-numbers-ready-\(language)", in: app)
        confirm.tap()

        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", english ? "Your reading is ready." : "这次推演已完成")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 30))
        XCTAssertFalse(fields[0].exists)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        let reference = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 10))
        for _ in 0..<6 where !reference.isHittable { app.scrollViews["chatTranscript"].swipeUp() }
        XCTAssertTrue(reference.isHittable); reference.tap()
        let results = app.scrollViews["runResultsSheet"]
        XCTAssertTrue(results.waitForExistence(timeout: 10))
        let expected = [generated[0], edited, generated[2]].joined(separator: english ? ", " : "、")
        let numberRow = app.descendants(matching: .any).matching(identifier: "resultRow-meihua-1").firstMatch
        let exactNumbers = numberRow.staticTexts[expected]
        for _ in 0..<10 where !exactNumbers.isHittable { results.swipeUp() }
        XCTAssertTrue(exactNumbers.exists)
        XCTAssertTrue(exactNumbers.isHittable)
        XCTAssertEqual(exactNumbers.label, expected)
        capture("exact-edited-meihua-numbers-\(language)", in: app)
    }

    @MainActor private func assertEmpty(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == field.placeholderValue, file: file, line: line)
    }

    @MainActor private func assertDraft(fields: [XCUIElement], generated: [String],
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fields[0].value as? String, generated[0], file: file, line: line)
        assertEmpty(fields[1], file: file, line: line)
        XCTAssertEqual(fields[2].value as? String, generated[2], file: file, line: line)
    }

    @MainActor private func replaceNumber(in field: XCUIElement, with replacement: String) {
        XCTAssertTrue(field.isHittable)
        let existing = field.value as? String ?? ""
        let text = existing == field.placeholderValue ? "" : existing
        // Touch the trailing edge to place the cursor after the existing digits.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count) + replacement)
    }

    @MainActor private func dismissNumberKeyboard(in app: XCUIApplication) {
        let done = app.buttons["dismissNumberKeyboard"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor private func reopenNumbers(in app: XCUIApplication) {
        if !app.textFields["interactionNumber-0"].waitForExistence(timeout: 2) {
            let resume = app.buttons["interactionCard"]
            XCTAssertTrue(resume.waitForExistence(timeout: 10))
            for _ in 0..<6 where !resume.isHittable { app.scrollViews["chatTranscript"].swipeUp() }
            XCTAssertTrue(resume.isHittable); resume.tap()
        }
        XCTAssertTrue(app.textFields["interactionNumber-0"].waitForExistence(timeout: 10))
    }

    @MainActor private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
