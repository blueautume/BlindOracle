import XCTest

final class ReadingContinuationUITests: XCTestCase {
    @MainActor func testDetailFollowUpUsesSavedReadingWithoutAnotherIntakeAndSurvivesRelaunch() throws {
        let app = launchSavedReading()
        let firstReferences = readingReferenceIDs(in: app)
        send("这个卦象里的建议具体是什么意思？", in: app)
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "沿用这次已保存的卦象")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        assertNoNewCast(in: app)
        capture("follow-up-reuses-saved-reading", in: app)
        openFollowUpReading(in: app, excluding: firstReferences)

        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.textFields["questionInput"].waitForExistence(timeout: 15))
        let restoredReferences = readingReferenceIDs(in: app)
        send("我接下来应该先做哪件事？", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "沿用这次已保存的卦象")).firstMatch.waitForExistence(timeout: 15))
        assertNoNewCast(in: app)
        openFollowUpReading(in: app, excluding: restoredReferences)
    }

    @MainActor func testExplicitFreshReadingRequestStillConfirmsThenOffersSixCoinCasts() throws {
        let app = launchSavedReading()
        send("重新起卦，只用六爻看看明天出行是否顺利", in: app)
        let confirm = app.buttons["confirmIntake"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        XCTAssertTrue(app.scrollViews["intakeFormScroll"].exists)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        for _ in 0..<24 where !confirm.isHittable { app.scrollViews["intakeFormScroll"].swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(app.buttons["castCoins"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "castCoins").count, 1)
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
        XCTAssertFalse(app.buttons["confirmInteraction"].isEnabled)
        capture("explicit-new-reading-starts-coins", in: app)
    }

    @MainActor func testAddingTarotAfterSixCoinsOnlyRequestsNewCardsAndThenReusesThem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.textFields["questionInput"].waitForExistence(timeout: 15))
        send("只用六爻看看这次出行如何安排", in: app)
        let intake = app.buttons["confirmIntake"]
        XCTAssertTrue(intake.waitForExistence(timeout: 15))
        for _ in 0..<24 where !intake.isHittable { app.scrollViews["intakeFormScroll"].swipeUp() }
        XCTAssertTrue(intake.isHittable)
        intake.tap()
        let cast = app.buttons["castCoins"]
        XCTAssertTrue(cast.waitForExistence(timeout: 10))
        for _ in 0..<6 {
            waitUntilEnabled(cast)
            cast.tap()
        }
        let confirm = app.buttons["confirmInteraction"]
        waitUntilEnabled(confirm)
        confirm.tap()
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        let originalReference = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        XCTAssertTrue(originalReference.waitForExistence(timeout: 10))
        let originalReferenceID = originalReference.identifier

        send("加上塔罗", in: app)
        let shuffle = app.buttons["shuffleTarot"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["castCoins"].exists)
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
        XCTAssertFalse(app.scrollViews["intakeFormScroll"].exists)
        capture("supplement-only-new-tarot-interaction", in: app)
        shuffle.tap()
        XCTAssertTrue(app.buttons["tarotCard-0"].waitForExistence(timeout: 5))
        for index in 0..<3 { app.buttons["tarotCard-\(index)"].tap() }
        XCTAssertTrue(app.buttons["revealTarot-0"].waitForExistence(timeout: 5))
        for index in 0..<3 {
            let card = app.buttons["revealTarot-\(index)"]
            waitUntilEnabled(card)
            card.tap()
        }
        waitUntilEnabled(confirm)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        confirm.tap()

        // Identify the new answer explicitly so the first local summary cannot
        // make the supplemental calculation appear complete before it finishes.
        let supplementalReference = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
            "readingData-", originalReferenceID)).firstMatch
        XCTAssertTrue(supplementalReference.waitForExistence(timeout: 30))
        let messageID = String(supplementalReference.identifier.dropFirst("readingData-".count))
        let bubble = app.descendants(matching: .any).matching(identifier: "assistantBubble-" + messageID).firstMatch
        XCTAssertTrue(bubble.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch.waitForExistence(timeout: 10))
        assertNoNewCast(in: app)
        capture("supplement-completed-local-summary", in: app)

        send("再用塔罗看看", in: app)
        let reused = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "沿用这次已保存的卦象")).firstMatch
        XCTAssertTrue(reused.waitForExistence(timeout: 15))
        assertNoNewCast(in: app)
        capture("supplement-repeated-tarot-reuses-cards", in: app)
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
        XCTAssertFalse(app.buttons["openIntake"].exists)
        XCTAssertFalse(app.buttons["interactionCard"].exists)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        XCTAssertFalse(app.scrollViews["intakeFormScroll"].exists)
    }

    @MainActor private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    @MainActor private func readingReferenceIDs(in app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-"))
            .allElementsBoundByIndex.map(\.identifier)
    }

    @MainActor private func openFollowUpReading(in app: XCUIApplication, excluding existingIDs: [String]) {
        let references = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier IN %@)", "readingData-", existingIDs))
        XCTAssertTrue(references.firstMatch.waitForExistence(timeout: 10))
        let reference = references.element(boundBy: max(0, references.count - 1))
        for _ in 0..<4 where !reference.isHittable { app.scrollViews["chatTranscript"].swipeUp() }
        XCTAssertTrue(reference.isHittable)
        reference.tap()
        let question = app.staticTexts["runResultsQuestion"]
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        XCTAssertEqual(question.label, "推演删除测试10")
        app.buttons["closeRunResults"].tap()
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
