import XCTest

final class InteractionUITests: XCTestCase {
    @MainActor func testTappingOutsideComposerDismissesKeyboardAndPreservesDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap(); input.typeText("先留下这句话")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "先留下这句话")
        input.tap(); input.typeText("，再继续")
        let continuedDraft = try XCTUnwrap(input.value as? String)
        XCTAssertTrue(continuedDraft.contains("先留下这句话"))
        XCTAssertTrue(continuedDraft.contains("，再继续"))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let transcript = app.scrollViews["chatTranscript"]
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, continuedDraft)
        XCTAssertTrue(app.buttons["sendQuestion"].isEnabled)
    }

    @MainActor func testTarotSelectionAndRevealedCardsSurviveRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap(); input.typeText("用塔罗看看这次选择有哪些启发")
        app.buttons["sendQuestion"].tap()
        confirmIntake(in: app)
        let shuffle = app.buttons["shuffleTarot"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 15))
        capture("tarot-shuffle", in: app)
        shuffle.tap()
        let first = app.buttons["tarotCard-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        app.buttons["tarotCard-1"].tap()
        capture("tarot-card-selection", in: app)
        app.buttons["tarotCard-2"].tap()
        let revealFirst = app.buttons["revealTarot-0"]
        XCTAssertTrue(revealFirst.waitForExistence(timeout: 5))
        waitUntilEnabled(revealFirst)
        revealFirst.tap()
        waitUntilEnabled(app.buttons["revealTarot-1"])
        XCTAssertFalse(app.buttons["confirmInteraction"].isEnabled)
        let firstCard = revealFirst.label
        app.buttons["deferInteraction"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.buttons["interactionCard"].waitForExistence(timeout: 15)); app.buttons["interactionCard"].tap()
        XCTAssertTrue(app.buttons["revealTarot-0"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["revealTarot-0"].label, firstCard)
        XCTAssertFalse(app.buttons["revealTarot-0"].isEnabled)
        let revealSecond = app.buttons["revealTarot-1"]
        waitUntilEnabled(revealSecond)
        revealSecond.tap()
        let revealThird = app.buttons["revealTarot-2"]
        waitUntilEnabled(revealThird)
        revealThird.tap()
        waitUntilEnabled(app.buttons["confirmInteraction"])
        capture("tarot-three-cards", in: app)
        app.buttons["confirmInteraction"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch.waitForExistence(timeout: 30))
    }

    @MainActor func testSelectedNumbersReachMeihuaAfterSixCoinCasts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        send("用梅花报数，看看这次出行如何安排", in: app)
        let firstNumber = app.textFields["intakeNumber-0"]
        XCTAssertTrue(firstNumber.waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        let form = app.scrollViews["intakeFormScroll"]
        for _ in 0..<10 where !firstNumber.isHittable { form.swipeUp() }
        XCTAssertTrue(firstNumber.isHittable)
        for (index, value) in ["8", "8", "6"].enumerated() {
            let field = app.textFields["intakeNumber-\(index)"]
            field.tap(); field.typeText(value)
        }
        capture("numbers-filled-in-unified-form", in: app)
        confirmIntake(in: app)
        let cast = app.buttons["castCoins"]
        XCTAssertTrue(cast.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "castCoins").count, 1)
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
        XCTAssertFalse(app.buttons["confirmInteraction"].isEnabled)
        for index in 0..<6 {
            waitUntilEnabled(cast)
            cast.tap()
            if index == 2 { capture("six-coins-halfway", in: app) }
        }
        let confirm = app.buttons["confirmInteraction"]
        waitUntilEnabled(confirm)
        capture("six-coins-complete", in: app)
        confirm.tap()
        openResults(in: app)
        let numbers = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "8、8、6")).firstMatch
        for _ in 0..<10 where !numbers.isHittable { app.scrollViews["runResultsSheet"].swipeUp() }
        XCTAssertTrue(numbers.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "三数法")).firstMatch.exists)
        capture("numbers-in-meihua-result", in: app)
    }

    @MainActor func testYarrowInteractionUsesThreeChangesAndCompletesSixLines() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        send("用蓍草看看明天这件事如何推进", in: app)
        confirmIntake(in: app)
        let cast = app.buttons["castCoins"]
        XCTAssertTrue(cast.waitForExistence(timeout: 10))
        XCTAssertTrue(cast.label.contains("归奇"))
        XCTAssertFalse(cast.label.contains("铜钱"))
        for index in 0..<6 {
            waitUntilEnabled(cast)
            cast.tap()
            if index == 0 {
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "三变余")).firstMatch.waitForExistence(timeout: 5))
                capture("yarrow-three-changes", in: app)
            }
        }
        let confirm = app.buttons["confirmInteraction"]
        waitUntilEnabled(confirm)
        confirm.tap()
        openResults(in: app)
        let castingStyle = app.descendants(matching: .any).matching(identifier: "resultRow-liuyao-0").firstMatch
        XCTAssertTrue(castingStyle.waitForExistence(timeout: 10))
        XCTAssertTrue(castingStyle.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "蓍草")).firstMatch.exists)
    }

    @MainActor private func send(_ question: String, in app: XCUIApplication) {
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap(); input.typeText(question)
        app.buttons["sendQuestion"].tap()
    }

    @MainActor private func confirmIntake(in app: XCUIApplication) {
        let confirm = app.buttons["confirmIntake"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollViews["intakeFormScroll"].exists)
        for _ in 0..<24 where !confirm.isHittable { app.scrollViews["intakeFormScroll"].swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
    }

    @MainActor private func openResults(in app: XCUIApplication) {
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        let reference = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        for _ in 0..<5 where !reference.isHittable { app.swipeUp() }
        XCTAssertTrue(reference.isHittable)
        reference.tap()
        XCTAssertTrue(app.staticTexts["runResultsQuestion"].waitForExistence(timeout: 10))
    }

    @MainActor private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
