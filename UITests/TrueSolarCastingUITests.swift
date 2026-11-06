import XCTest

final class TrueSolarCastingUITests: XCTestCase {
    @MainActor func testChineseCastingPlacePersistsWithoutPeopleAndClearingBlocksStart() {
        verifyCastingPlace(language: "zh-Hans")
    }

    @MainActor func testEnglishCastingPlacePersistsWithoutPeopleAndClearingBlocksStart() {
        verifyCastingPlace(language: "en")
    }

    @MainActor private func verifyCastingPlace(language: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reset-language", "-oracle.appLanguage", language]
        app.launch()
        let question = app.textFields["questionInput"]
        XCTAssertTrue(question.waitForExistence(timeout: 15)); question.tap()
        question.typeText(language == "en" ? "Use only Qi Men to consider tomorrow's study plan." : "只用奇门看看明天的学习安排")
        app.buttons["sendQuestion"].tap()
        let place = app.buttons["castingLocationButton"]
        XCTAssertTrue(place.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["profileBirthDate"].exists)
        reveal(place, app: app); place.tap()
        let province = app.buttons["chinaDistrict-110000"]
        XCTAssertTrue(province.waitForExistence(timeout: 10)); province.tap()
        let city = app.buttons["chinaWholeCity-110000"]
        XCTAssertTrue(city.waitForExistence(timeout: 10)); city.tap()
        XCTAssertTrue(app.buttons["clearCastingLocation"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "solar-casting-location-\(language)"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["cancelIntake"].tap()
        app.terminate()

        app.launchArguments.removeAll { $0 == "--ui-testing-reset" }
        app.launch()
        if !app.buttons["castingLocationButton"].waitForExistence(timeout: 2) {
            let reopen = app.buttons["openIntake"]
            XCTAssertTrue(reopen.waitForExistence(timeout: 10)); reopen.tap()
        }
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

    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
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
