import XCTest

final class TrueSolarCastingUITests: XCTestCase {
    @MainActor func testChineseCastingPlacePersistsWithoutPeopleAndClearingBlocksStart() {
        verifyCastingPlace(language: "zh-Hans")
    }

    @MainActor func testEnglishCastingPlacePersistsWithoutPeopleAndClearingBlocksStart() {
        verifyCastingPlace(language: "en")
    }

    @MainActor func testChineseCastingPlaceAutomaticallyUsesLocationAndPreservesDraftWithoutRelocating() {
        verifyAutomaticCastingPlace(language: "zh-Hans")
    }

    @MainActor func testEnglishCastingPlaceAutomaticallyUsesLocationAndPreservesDraftWithoutRelocating() {
        verifyAutomaticCastingPlace(language: "en")
    }

    @MainActor private func verifyCastingPlace(language: String) {
        continueAfterFailure = false
        let app = launchCastingQuestion(language: language, fixture: "--ui-testing-location-denied-fixture")
        let place = app.buttons["castingLocationButton"]
        XCTAssertTrue(place.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["profileBirthDate"].exists)

        // The form attempts location on opening. A deterministic denial must
        // leave it usable and require a place before starting the reading.
        let locationError = element("castingLocationError", in: app)
        XCTAssertTrue(locationError.waitForExistence(timeout: 10))
        XCTAssertFalse(locationError.label.isEmpty)
        XCTAssertTrue(app.buttons["useCurrentCastingLocation"].exists)
        XCTAssertTrue(element("castingLocationRequired", in: app).exists)
        let confirmWithoutPlace = app.buttons["confirmIntake"]
        reveal(confirmWithoutPlace, app: app); confirmWithoutPlace.tap()
        XCTAssertTrue(element("intakeValidationError", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(place.exists)
        XCTAssertFalse(app.buttons["profileBirthDate"].exists)

        // Exercise the real manual picker as the fallback, without a system
        // location prompt, a real GPS lookup, or an injected place selection.
        reveal(place, app: app); place.tap()
        let province = app.buttons["chinaDistrict-110000"]
        XCTAssertTrue(province.waitForExistence(timeout: 10)); province.tap()
        let city = app.buttons["chinaWholeCity-110000"]
        XCTAssertTrue(city.waitForExistence(timeout: 10)); city.tap()
        XCTAssertTrue(app.buttons["clearCastingLocation"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("castingLocationSummary", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("castingLocationRequired", in: app).exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "solar-casting-location-\(language)"; screenshot.lifetime = .keepAlways; add(screenshot)
        dismissReadingDetailsSheet(in: app)
        app.terminate()

        app.launchArguments.removeAll { $0 == "--ui-testing-reset" }
        app.launch()
        reopenCastingForm(in: app)
        let clear = app.buttons["clearCastingLocation"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10)); reveal(clear, app: app); clear.tap()
        XCTAssertFalse(app.buttons["profileBirthDate"].exists)
        let confirm = app.buttons["confirmIntake"]
        reveal(confirm, app: app); confirm.tap()
        let error = app.descendants(matching: .any).matching(identifier: "intakeValidationError").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["castingLocationButton"].exists)
        XCTAssertFalse(app.buttons["profileBirthDate"].exists)
    }

    @MainActor private func verifyAutomaticCastingPlace(language: String) {
        continueAfterFailure = false
        let app = launchCastingQuestion(language: language, fixture: "--ui-testing-location-fixture")
        let place = app.buttons["castingLocationButton"]
        XCTAssertTrue(place.waitForExistence(timeout: 15))

        // No tap on useCurrentCastingLocation or the picker: opening a
        // time-based casting form must apply the DEBUG GPS result itself.
        let summary = element("castingLocationSummary", in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.label.contains("116.2211"), summary.label)
        XCTAssertFalse(element("castingLocationRequired", in: app).exists)
        XCTAssertFalse(element("castingLocationError", in: app).exists)
        XCTAssertFalse(element("castingLocationProgress", in: app).exists)
        XCTAssertFalse(app.buttons["profileBirthDate"].exists)
        let originalPlace = place.label
        let originalSummary = summary.label
        XCTAssertFalse(originalPlace.isEmpty)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "solar-casting-auto-location-\(language)"; screenshot.lifetime = .keepAlways; add(screenshot)

        assertReadingConfirmationInNavigationBar(in: app, language: language)
        dismissReadingDetailsSheet(in: app)
        app.terminate()
        app.launchArguments.removeAll {
            $0 == "--ui-testing-reset" || $0 == "--ui-testing-location-fixture"
        }
        // If reopening incorrectly requests location again, this fixture
        // produces an observable denial instead of silently succeeding twice.
        app.launchArguments.append("--ui-testing-location-denied-fixture")
        app.launch()
        reopenCastingForm(in: app)
        let restoredSummary = element("castingLocationSummary", in: app)
        XCTAssertTrue(restoredSummary.waitForExistence(timeout: 10))
        XCTAssertEqual(place.label, originalPlace)
        XCTAssertEqual(restoredSummary.label, originalSummary)
        XCTAssertTrue(app.buttons["clearCastingLocation"].exists)
        XCTAssertFalse(element("castingLocationRequired", in: app).exists)
        XCTAssertFalse(app.buttons["profileBirthDate"].exists)
        let unexpectedRelocation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: element("castingLocationError", in: app)
        )
        unexpectedRelocation.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedRelocation], timeout: 2), .completed)
        XCTAssertFalse(element("castingLocationProgress", in: app).exists)
    }

    @MainActor private func launchCastingQuestion(language: String, fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reset-language", fixture, "-oracle.appLanguage", language]
        app.launch()
        let question = app.textFields["questionInput"]
        XCTAssertTrue(question.waitForExistence(timeout: 15)); question.tap()
        question.typeText(language == "en" ? "Use only Qi Men to consider tomorrow's study plan." : "只用奇门看看明天的学习安排")
        app.buttons["sendQuestion"].tap()
        return app
    }

    @MainActor private func reopenCastingForm(in app: XCUIApplication) {
        if !app.buttons["castingLocationButton"].waitForExistence(timeout: 2) {
            let reopen = app.buttons["openIntake"]
            XCTAssertTrue(reopen.waitForExistence(timeout: 10)); reopen.tap()
        }
        XCTAssertTrue(app.buttons["castingLocationButton"].waitForExistence(timeout: 10))
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        if element.identifier == "confirmIntake" {
            XCTAssertTrue(app.navigationBars.buttons["confirmIntake"].exists)
            XCTAssertTrue(element.isHittable)
            return
        }
        let scroll = app.scrollViews["intakeFormScroll"]
        for _ in 0..<10 {
            let navBottom = app.navigationBars.firstMatch.frame.maxY
            if element.isHittable, element.frame.midY > navBottom + 16,
               element.frame.midY < app.frame.maxY - 50 { return }
            if element.exists, element.frame.midY < navBottom + 16 { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }
}
