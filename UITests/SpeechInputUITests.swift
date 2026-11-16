import XCTest

/// Uses a DEBUG-only, in-memory recognizer. These cases exercise the real text
/// input gesture and draft integration without requesting microphone access.
final class SpeechInputUITests: XCTestCase {
    private let recognizedText = "今天想聊聊工作"

    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reset-language",
                               "-oracle.appLanguage", "zh-Hans", "--ui-testing-speech-input"]
        app.launch()
        XCTAssertTrue(app.textViews["questionInput"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor func testShortPressKeepsKeyboardInputAndDoesNotStartSpeech() {
        let app = launch()
        let input = app.textViews["questionInput"]
        input.press(forDuration: 0.04)

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse((input.value as? String ?? "").contains(recognizedText))
        XCTAssertFalse(app.buttons["sendQuestion"].isEnabled)
        XCTAssertFalse(app.buttons["newConversationButton"].isEnabled)

        input.typeText("这是键盘输入")
        XCTAssertEqual(input.value as? String, "这是键盘输入")
        XCTAssertTrue(app.buttons["sendQuestion"].isEnabled)
        XCTAssertFalse(app.staticTexts["这是键盘输入"].exists)
    }

    @MainActor func testHoldPastThresholdLeavesFinalTextWithoutSendingOrAddingButtons() {
        let app = launch()
        let input = app.textViews["questionInput"]
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposerPanel").firstMatch
        let originalButtonCount = composer.buttons.count
        XCTAssertEqual(originalButtonCount, 1)

        input.press(forDuration: 0.12)
        waitForValue(recognizedText, in: input)

        XCTAssertTrue(app.buttons["sendQuestion"].isEnabled)
        XCTAssertFalse(app.buttons["newConversationButton"].isEnabled)
        XCTAssertFalse(app.staticTexts[recognizedText].exists, "Releasing the hold must not append a chat message")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(composer.buttons.count, originalButtonCount)
        capture("speech-released-draft-not-sent", in: app)
    }

    @MainActor func testRepeatedHoldsAppendToExistingDraftWithoutRepeatingPartialResults() {
        let app = launch()
        let input = app.textViews["questionInput"]
        input.tap()
        input.typeText("补充：")

        input.press(forDuration: 0.8)
        let firstResult = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@ AND value ENDSWITH %@", "补充：", recognizedText), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [firstResult], timeout: 5), .completed)
        let firstDraft = input.value as? String ?? ""
        XCTAssertEqual(occurrences(of: recognizedText, in: firstDraft), 1)
        XCTAssertEqual(occurrences(of: "今天想聊聊", in: firstDraft), 1, "Cumulative partial results must replace this round's text")

        input.press(forDuration: 0.8)
        let secondResult = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String else { return false }
            return value.hasPrefix(firstDraft) && value.components(separatedBy: self.recognizedText).count == 3
        }, object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [secondResult], timeout: 5), .completed)
        let secondDraft = input.value as? String ?? ""
        XCTAssertEqual(occurrences(of: "今天想聊聊", in: secondDraft), 2)
        XCTAssertFalse(app.buttons["newConversationButton"].isEnabled)
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
    }

    @MainActor func testReleasedTextCanBeEditedAndOnlySendsOnExplicitSend() {
        let app = launch()
        let input = app.textViews["questionInput"]
        input.press(forDuration: 0.8)
        waitForValue(recognizedText, in: input)
        XCTAssertFalse(app.buttons["newConversationButton"].isEnabled)
        XCTAssertFalse(app.buttons["confirmIntake"].exists)

        input.tap()
        input.typeText("，只用塔罗。")
        let appended = recognizedText + "，只用塔罗。"
        waitForValue(appended, in: input)
        // The first focus resumes at the end of dictation. Later taps must
        // still support positioning the caret to edit an earlier word.
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        input.typeText("补充：")
        let submitted = "补充：" + appended
        waitForValue(submitted, in: input)
        app.buttons["sendQuestion"].tap()

        XCTAssertTrue(app.buttons["confirmIntake"].waitForExistence(timeout: 15))
        app.buttons["cancelPendingIntake"].tap()
        XCTAssertTrue(app.buttons["confirmIntake"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[submitted].exists)
        XCTAssertFalse((input.value as? String ?? "").contains(recognizedText), "Sending must clear the draft and prevent late recognition callbacks from restoring it")
        capture("speech-edited-and-explicitly-sent", in: app)
    }

    @MainActor private func waitForValue(_ text: String, in input: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func occurrences(of text: String, in value: String) -> Int {
        value.components(separatedBy: text).count - 1
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
