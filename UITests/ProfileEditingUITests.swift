import XCTest

final class ProfileEditingUITests: XCTestCase {
    @MainActor func testNewProfileShowsAllFieldsWithoutExpanding() throws {
        let app = launchFreshApp()
        app.tabBars.buttons["数据"].tap()
        app.buttons["addProfile"].tap()
        let name = app.textFields["profileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["profileSurname"].exists)
        XCTAssertTrue(app.textFields["profileGivenName"].exists)
        XCTAssertFalse(app.buttons["toggleBirthDetails"].exists)
        XCTAssertFalse(app.buttons["姓名推演用字 · 选填"].exists)
        XCTAssertTrue(element("profileBirthDate", in: app).exists)
        XCTAssertTrue(element("profileBirthTime", in: app).exists)
        XCTAssertEqual(app.switches["birthDateKnown"].value as? String, "0")
        XCTAssertEqual(app.switches["birthTimeKnown"].value as? String, "0")
        capture("profile-flat-name-and-birth", in: app)
        name.tap(); name.typeText("陈平")
        for identifier in ["profileBirthPlace", "profileBirthTimeZone", "profileBirthLatitude", "profileBirthLongitude", "profileCurrentPlace", "profileCurrentTimeZone", "profileCurrentLatitude", "profileCurrentLongitude"] {
            let field = app.textFields[identifier]
            reveal(field, in: app)
            XCTAssertTrue(field.isHittable, identifier)
        }
        capture("profile-flat-location-fields", in: app)
        let save = app.buttons["confirmIntake"]
        reveal(save, in: app)
        save.tap()
        XCTAssertTrue(profileRow("陈平", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(profileRow("陈平", in: app).label.contains("出生资料待补充"))
    }

    @MainActor func testSavedBirthdayIsVisibleAndSurvivesNameOnlyEdit() throws {
        let app = launchFreshApp()
        let input = app.textFields["questionInput"]
        input.tap(); input.typeText("姓名：陈平，男，1992年6月15日08:30出生，出生地上海")
        app.buttons["sendQuestion"].tap()
        app.tabBars.buttons["数据"].tap()
        let row = profileRow("陈平", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.label.contains("1992"))
        row.tap()
        let name = app.textFields["profileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let date = element("profileBirthDate", in: app)
        XCTAssertTrue(date.exists)
        XCTAssertEqual(app.switches["birthDateKnown"].value as? String, "1")
        XCTAssertEqual(app.switches["birthTimeKnown"].value as? String, "1")
        XCTAssertFalse(app.buttons["toggleBirthDetails"].exists)
        capture("saved-birthday-visible-on-entry", in: app)
        name.tap(); name.typeText("安")
        let renamed = try XCTUnwrap(name.value as? String)
        XCTAssertTrue(renamed.contains("陈平")); XCTAssertTrue(renamed.contains("安"))
        let save = app.buttons["confirmIntake"]
        reveal(save, in: app)
        save.tap()
        let saved = profileRow(renamed, in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(saved.label.contains("1992"))
        XCTAssertFalse(saved.label.contains("时辰未定"))
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(profileRow(renamed, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(profileRow(renamed, in: app).label.contains("1992"))
        XCTAssertFalse(profileRow(renamed, in: app).label.contains("时辰未定"))
    }

    @MainActor private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func profileRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "profileRow-", name)).firstMatch
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.exists)
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
