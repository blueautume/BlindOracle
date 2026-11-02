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
        name.tap(); name.typeText("陈平\n")
        for identifier in ["profileBirthPlace", "profileBirthTimeZone", "profileBirthLatitude", "profileBirthLongitude", "profileCurrentPlace", "profileCurrentTimeZone", "profileCurrentLatitude", "profileCurrentLongitude"] {
            let field = element(identifier, in: app)
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
        name.tap(); name.typeText("安\n")
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

    @MainActor func testBirthPlaceShortcutFillsPlaceCoordinatesAndLocalTimezoneOnly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-location-fixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        app.buttons["addProfile"].tap()
        let name = app.textFields["profileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("位置测试\n")
        let currentPlace = app.textFields["profileCurrentPlace"]
        reveal(currentPlace, in: app)
        currentPlace.tap(); currentPlace.typeText("原所在地\n")
        let currentZone = try XCTUnwrap(app.buttons["profileCurrentTimeZone"].value as? String)
        // Reopen the saved profile at its top before testing the birth shortcut.
        // Dragging down from a keyboard-focused field can dismiss an iOS sheet.
        let initialSave = app.buttons["confirmIntake"]
        reveal(initialSave, in: app); initialSave.tap()
        let initialRow = profileRow("位置测试", in: app)
        XCTAssertTrue(initialRow.waitForExistence(timeout: 10)); initialRow.tap()
        XCTAssertTrue(app.textFields["profileName"].waitForExistence(timeout: 10))
        let shortcut = app.buttons["useCurrentLocationForBirthPlace"]
        reveal(shortcut, in: app)
        XCTAssertTrue(shortcut.isHittable)
        shortcut.tap()
        let birthPlace = app.textFields["profileBirthPlace"]
        let populated = NSPredicate(format: "value == %@", "日本东京都")
        expectation(for: populated, evaluatedWith: birthPlace)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.buttons["profileBirthTimeZone"].value as? String, "Asia/Tokyo")
        XCTAssertTrue((app.textFields["profileBirthLatitude"].value as? String ?? "").contains("35.6762"))
        XCTAssertTrue((app.textFields["profileBirthLongitude"].value as? String ?? "").contains("139.6503"))
        capture("birthplace-current-location-shortcut", in: app)
        reveal(currentPlace, in: app)
        XCTAssertEqual(currentPlace.value as? String, "原所在地")
        XCTAssertEqual(app.buttons["profileCurrentTimeZone"].value as? String, currentZone)
        let save = app.buttons["confirmIntake"]
        reveal(save, in: app); save.tap()
        XCTAssertTrue(profileRow("位置测试", in: app).waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        let row = profileRow("位置测试", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.textFields["profileName"].waitForExistence(timeout: 10))
        reveal(app.textFields["profileBirthPlace"], in: app)
        XCTAssertEqual(app.textFields["profileBirthPlace"].value as? String, "日本东京都")
        XCTAssertEqual(app.buttons["profileBirthTimeZone"].value as? String, "Asia/Tokyo")
        reveal(app.textFields["profileCurrentPlace"], in: app)
        XCTAssertEqual(app.textFields["profileCurrentPlace"].value as? String, "原所在地")
        XCTAssertEqual(app.buttons["profileCurrentTimeZone"].value as? String, currentZone)
    }

    @MainActor func testTimezonePickerSupportsChineseSearchAndIndependentSelections() throws {
        let app = launchFreshApp()
        app.tabBars.buttons["数据"].tap(); app.buttons["addProfile"].tap()
        let name = app.textFields["profileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("时区测试\n")
        let birthZone = app.buttons["profileBirthTimeZone"]
        reveal(birthZone, in: app)
        let originalCurrentZone = app.buttons["profileCurrentTimeZone"].value as? String
        XCTAssertFalse(app.textFields["profileBirthTimeZone"].exists)
        birthZone.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("巴黎")
        let paris = app.buttons["timeZone-Europe/Paris"]
        XCTAssertTrue(paris.waitForExistence(timeout: 10)); paris.tap()
        XCTAssertEqual(birthZone.value as? String, "Europe/Paris")
        XCTAssertEqual(app.buttons["profileCurrentTimeZone"].value as? String, originalCurrentZone)
        let currentZone = app.buttons["profileCurrentTimeZone"]
        reveal(currentZone, in: app); currentZone.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("纽约")
        let newYork = app.buttons["timeZone-America/New_York"]
        XCTAssertTrue(newYork.waitForExistence(timeout: 10)); newYork.tap()
        XCTAssertEqual(currentZone.value as? String, "America/New_York")
        XCTAssertEqual(birthZone.value as? String, "Europe/Paris")
        currentZone.tap()
        XCTAssertTrue(app.buttons["cancelTimeZonePicker"].waitForExistence(timeout: 10))
        app.buttons["cancelTimeZonePicker"].tap()
        XCTAssertEqual(currentZone.value as? String, "America/New_York")
        capture("timezone-chinese-city-selection", in: app)
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
        let editor = app.scrollViews.containing(.textField, identifier: "profileName").firstMatch
        XCTAssertTrue(editor.exists)
        for _ in 0..<18 {
            if element.exists && element.isHittable { return }
            let bounds = editor.frame.intersection(app.frame)
            var bottom = bounds.maxY - 28
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists { bottom = min(bottom, keyboard.frame.minY - 16) }
            let top = bounds.minY + 28
            let height = max(100, bottom - top)
            let target = element.exists ? element.frame : .zero
            // Short, held drags avoid flicking past a small text field. If a
            // previous scroll passed it, recover upward within the form.
            let towardEarlierFields = !target.isEmpty && target.midY < top + height * 0.2
            let startY = top + height * (towardEarlierFields ? 0.3 : 0.72)
            let endY = top + height * (towardEarlierFields ? 0.65 : 0.37)
            let origin = editor.coordinate(withNormalizedOffset: .zero)
            // The outer paper margin keeps the drag away from text fields,
            // menus, and pickers, and from the sheet's dismissal handle.
            let start = origin.withOffset(CGVector(dx: 12, dy: startY - bounds.minY))
            let end = origin.withOffset(CGVector(dx: 12, dy: endY - bounds.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable, element.identifier)
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
