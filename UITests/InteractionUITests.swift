import XCTest

final class InteractionUITests: XCTestCase {
    @MainActor func testLanguagePickerPersistsEnglishAcrossLaunches() {
        let app = XCUIApplication()
        let resetLanguage = ["--ui-testing-local", "--ui-testing-reset-language"]
        app.launchArguments = resetLanguage
        app.launch()
        defer {
            app.terminate()
            app.launchArguments = resetLanguage
            app.launch()
            app.terminate()
        }

        let draft = "An unsent question"
        let input = app.textFields["questionInput"]
        guard input.waitForExistence(timeout: 15) else { return XCTFail("Chat input was not shown") }
        input.tap()
        input.typeText(draft)
        app.staticTexts["瞎子"].firstMatch.tap()

        let data = app.tabBars.buttons["数据"]
        guard data.waitForExistence(timeout: 15) else { return XCTFail("Chinese Data tab was not shown") }
        data.tap()
        let settings = app.buttons["设置"]
        guard settings.waitForExistence(timeout: 5) else { return XCTFail("Settings button was not shown") }
        settings.tap()
        let languagePicker = app.buttons["appLanguagePicker"]
        guard languagePicker.waitForExistence(timeout: 5) else { return XCTFail("Language picker was not shown") }
        languagePicker.tap()
        let english = app.buttons["English"]
        guard english.waitForExistence(timeout: 5) else { return XCTFail("English was not offered in the picker") }
        english.tap()
        guard app.navigationBars["Settings"].waitForExistence(timeout: 5) else { return XCTFail("Settings did not switch to English") }
        app.buttons["Done"].tap()
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, draft)

        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Data"].exists)
    }

    @MainActor func testEnglishTarotReadingFromQuestionToSavedSpread() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "-oracle.appLanguage", "en"]
        app.launch()
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(input.placeholderValue, "What’s on your mind?")
        input.tap()
        input.typeText("Use only tarot. What should I consider before changing jobs?")
        app.buttons["sendQuestion"].tap()
        confirmIntake(in: app)

        let shuffle = app.buttons["shuffleTarot"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 15))
        XCTAssertEqual(shuffle.label, "Shuffle and choose cards")
        shuffle.tap()
        XCTAssertTrue(app.buttons["tarotCard-0"].waitForExistence(timeout: 5))
        for index in 0..<3 { app.buttons["tarotCard-\(index)"].tap() }

        let firstCard = app.buttons["revealTarot-0"]
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5))
        for index in 0..<3 {
            let card = app.buttons["revealTarot-\(index)"]
            waitUntilEnabled(card)
            card.tap()
        }
        let confirm = app.buttons["confirmInteraction"]
        waitUntilEnabled(confirm)
        confirm.tap()

        let reference = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 30))
        XCTAssertEqual(reference.label, "View reading")
        for _ in 0..<5 where !reference.isHittable { app.swipeUp() }
        let originalReferenceID = reference.identifier
        reference.tap()
        let resultQuestion = app.staticTexts["runResultsQuestion"]
        XCTAssertTrue(resultQuestion.waitForExistence(timeout: 10))
        let originalQuestion = resultQuestion.label
        XCTAssertTrue(app.otherElements["savedTarotSpread"].exists)
        XCTAssertTrue(app.staticTexts["Initial spread · 3 cards"].exists)

        app.buttons["closeRunResults"].tap()
        input.tap()
        input.typeText("Explain the Advice card without drawing again.")
        app.buttons["sendQuestion"].tap()
        let followUp = app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@", "Using your saved reading."
        )).firstMatch
        XCTAssertTrue(followUp.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        XCTAssertFalse(app.buttons["confirmIntake"].exists)

        let followUpReference = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@", "readingData-", originalReferenceID
        )).firstMatch
        XCTAssertTrue(followUpReference.waitForExistence(timeout: 5))
        for _ in 0..<5 where !followUpReference.isHittable { app.swipeUp() }
        followUpReference.tap()
        XCTAssertTrue(resultQuestion.waitForExistence(timeout: 10))
        XCTAssertEqual(resultQuestion.label, originalQuestion)
        XCTAssertTrue(app.otherElements["savedTarotSpread"].exists)
    }

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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这次推演已完成")).firstMatch.waitForExistence(timeout: 30))
    }

    @MainActor func testChangingTopicDuringTarotKeepsThePendingSelectionInHistory() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        let original = "用塔罗看看这次选择有哪些启发"
        send(original, in: app)
        confirmIntake(in: app)
        let shuffle = app.buttons["shuffleTarot"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 15)); shuffle.tap()
        XCTAssertTrue(app.buttons["tarotCard-0"].waitForExistence(timeout: 5))
        for index in 0..<3 { app.buttons["tarotCard-\(index)"].tap() }
        let first = app.buttons["revealTarot-0"]
        let second = app.buttons["revealTarot-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        waitUntilEnabled(first); first.tap()
        waitUntilEnabled(second)
        let originalCard = first.label
        app.buttons["deferInteraction"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))

        let next = "换个问题，只用八字看看我同事王安的事业"
        send(next, in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        XCTAssertTrue(form.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "王安的事业")).firstMatch.exists)
        XCTAssertFalse(form.staticTexts[original].exists)
        XCTAssertFalse(app.buttons["interactionCard"].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        XCTAssertTrue(form.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "王安的事业")).firstMatch.exists)
        app.buttons["cancelIntake"].tap()
        XCTAssertTrue(form.waitForNonExistence(timeout: 5))

        app.buttons["historyButton"].tap()
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "historyRow-", original)).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
        let resume = app.buttons["interactionCard"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10)); resume.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.label, originalCard)
        XCTAssertFalse(first.isEnabled)
        XCTAssertTrue(second.isEnabled)
        XCTAssertFalse(app.buttons["confirmInteraction"].isEnabled)
        XCTAssertFalse(shuffle.exists)
    }

    @MainActor func testTarotClarificationResumesTheFourthCardAndKeepsTheOriginalSpread() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        send("用塔罗看看这次选择有哪些启发", in: app)
        confirmIntake(in: app)
        let shuffle = app.buttons["shuffleTarot"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 15)); shuffle.tap()
        XCTAssertTrue(app.buttons["tarotCard-0"].waitForExistence(timeout: 5))
        for index in 0..<3 { app.buttons["tarotCard-\(index)"].tap() }
        for index in 0..<3 {
            let card = app.buttons["revealTarot-\(index)"]
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            waitUntilEnabled(card); card.tap()
        }
        let confirm = app.buttons["confirmInteraction"]
        waitUntilEnabled(confirm)
        let initialCards = (0..<3).map { app.buttons["revealTarot-\($0)"].label }
        confirm.tap()
        let originalReference = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        XCTAssertTrue(originalReference.waitForExistence(timeout: 30))
        let originalID = originalReference.identifier

        let focus = "行动前最值得核实的条件"
        send("补抽一张，\(focus)", in: app)
        XCTAssertTrue(app.staticTexts["tarotClarificationFocus"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["tarotClarificationFocus"].label, focus)
        XCTAssertTrue(app.buttons["cancelTarotClarification"].exists)
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
        shuffle.tap()
        XCTAssertTrue(app.buttons["tarotCard-0"].waitForExistence(timeout: 5)); app.buttons["tarotCard-0"].tap()
        let clarificationCard = app.buttons["revealTarot-0"]
        XCTAssertTrue(clarificationCard.waitForExistence(timeout: 5))
        waitUntilEnabled(clarificationCard)
        XCTAssertFalse(app.buttons["revealTarot-1"].exists)
        clarificationCard.tap()
        waitUntilEnabled(confirm)
        XCTAssertFalse(app.buttons["cancelTarotClarification"].exists)
        let revealedLabel = clarificationCard.label
        let revealedName = try XCTUnwrap(revealedLabel.split(separator: "，").dropFirst().first)
        XCTAssertFalse(initialCards.contains { $0.split(separator: "，").dropFirst().first == revealedName })
        app.buttons["deferInteraction"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()

        let resume = app.buttons["interactionCard"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15)); resume.tap()
        XCTAssertTrue(clarificationCard.waitForExistence(timeout: 5))
        XCTAssertEqual(clarificationCard.label, revealedLabel)
        XCTAssertFalse(clarificationCard.isEnabled)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        waitUntilEnabled(confirm); confirm.tap()

        let newReference = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
            "readingData-", originalID)).firstMatch
        XCTAssertTrue(newReference.waitForExistence(timeout: 30))
        for _ in 0..<5 where !newReference.isHittable { app.scrollViews["chatTranscript"].swipeUp() }
        XCTAssertTrue(newReference.isHittable); newReference.tap()
        let results = app.scrollViews["runResultsSheet"]
        XCTAssertTrue(results.waitForExistence(timeout: 10))
        for label in initialCards {
            XCTAssertTrue(results.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists)
        }
        let savedFocus = app.staticTexts["savedTarotClarificationFocus-0"]
        for _ in 0..<5 where !savedFocus.isHittable { results.swipeUp() }
        XCTAssertEqual(savedFocus.label, focus)
        XCTAssertTrue(results.descendants(matching: .any).matching(NSPredicate(format: "label == %@", revealedLabel)).firstMatch.exists)
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
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这次推演已完成")).firstMatch
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
