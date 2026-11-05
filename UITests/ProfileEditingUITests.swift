import XCTest

final class ProfileEditingUITests: XCTestCase {
    @MainActor func testTrueSolarBaziPreviewIsReadOnlyAndFollowsBirthDetails() throws {
        let app = launchFreshApp(locationFixture: true)
        openNewProfile(in: app)
        let preview = element("profileBaziPreview", in: app)
        let copy = app.buttons["copyProfileBazi"]
        reveal(preview, in: app)
        XCTAssertTrue(preview.exists)
        XCTAssertTrue(copy.exists)
        XCTAssertFalse(copy.isEnabled)
        XCTAssertFalse(app.textFields["profileBaziPreview"].exists)
        XCTAssertFalse(app.buttons["profileBaziPreview"].exists)
        XCTAssertFalse(isFourPillars(preview.value as? String ?? ""))

        // The birth-date and clock pickers start at 1995-01-01 12:00. Confirm
        // both explicitly; the unselected defaults must never produce a chart.
        for identifier in ["profileBirthDate", "profileBirthTime"] {
            let field = app.buttons[identifier]
            reveal(field, in: app); field.tap()
            let confirm = app.buttons["confirmBirthClock"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        }
        reveal(preview, in: app)
        XCTAssertFalse(isFourPillars(preview.value as? String ?? ""))
        XCTAssertFalse(copy.isEnabled)
        let birthplace = app.buttons["profileBirthPlace"]
        reveal(birthplace, in: app); birthplace.tap()
        tapDistrictPath(["chinaDistrict-110000", "chinaDistrict-110101"], in: app)
        reveal(preview, in: app)
        let beijingPillars = try waitForFourPillars(of: preview)
        XCTAssertTrue(copy.isEnabled)
        let current = app.buttons["profileCurrentPlace"]
        XCTAssertGreaterThan(preview.frame.minY, current.frame.minY)
        let clearBirthplace = app.buttons["clearProfileBirthPlace"]
        reveal(clearBirthplace, in: app)
        let trailingButtonX = clearBirthplace.frame.midX
        reveal(copy, in: app)
        XCTAssertEqual(copy.frame.midX, trailingButtonX, accuracy: 1)
        XCTAssertEqual(copy.frame.width, 44, accuracy: 1)
        XCTAssertEqual(copy.frame.height, 44, accuracy: 1)
        copy.tap()
        waitForCopiedBaziFeedback(of: copy)
        pasteCopiedBazi(beijingPillars, in: app)

        // At the same noon clock time, Urumqi's true solar hour differs from
        // Beijing's. The readonly value must refresh without saving the form.
        reveal(birthplace, in: app); birthplace.tap()
        tapDistrictPath(["chinaDistrict-650000", "chinaDistrict-650100", "chinaDistrict-650102"], in: app)
        reveal(preview, in: app)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", beijingPillars), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        let urumqiPillars = try waitForFourPillars(of: preview)
        XCTAssertNotEqual(urumqiPillars, beijingPillars)
        XCTAssertTrue(copy.isEnabled)
        reveal(copy, in: app); copy.tap()
        waitForCopiedBaziFeedback(of: copy)
        pasteCopiedBazi(urumqiPillars, in: app)

        let currentGPS = app.buttons["useCurrentLocation"]
        reveal(currentGPS, in: app); currentGPS.tap()
        waitForValue("北京市海淀区", of: current)
        reveal(preview, in: app)
        XCTAssertEqual(preview.value as? String, urumqiPillars)
        capture("true-solar-bazi-readonly-preview", in: app)

        let clearDate = app.buttons["clearProfileBirthDate"]
        reveal(clearDate, in: app); clearDate.tap()
        reveal(preview, in: app)
        XCTAssertNotEqual(preview.value as? String, urumqiPillars)
        XCTAssertFalse(isFourPillars(preview.value as? String ?? ""))
        XCTAssertFalse(copy.isEnabled)
        XCTAssertFalse(app.textFields["profileBaziPreview"].exists)
        XCTAssertFalse(app.buttons["profileBaziPreview"].exists)
    }

    @MainActor func testAnonymousProfileUsesStableAliasPlaceholderAcrossRelaunch() throws {
        let app = launchFreshApp()
        openNewProfile(in: app)
        let alias = app.textFields["profileAlias"]
        let code = try XCTUnwrap(alias.placeholderValue)
        XCTAssertNotNil(code.range(of: #"^[0-9]{4}$"#, options: .regularExpression))
        XCTAssertTrue(app.textFields["profileSurname"].exists)
        XCTAssertTrue(app.textFields["profileGivenName"].exists)
        XCTAssertFalse(app.textFields["profileName"].exists)
        XCTAssertEqual(app.buttons["profileBirthDate"].value as? String, "未填写")
        XCTAssertEqual(app.buttons["profileBirthTime"].value as? String, "未填写")
        capture("anonymous-profile-optional-fields", in: app)
        saveProfile(in: app)

        reopenProfile(code, in: app)
        XCTAssertEqual(alias.placeholderValue, code)
        alias.tap(); alias.typeText("同事甲\n")
        saveProfile(in: app)
        reopenProfile("同事甲", in: app)
        XCTAssertEqual(alias.value as? String, "同事甲")
        XCTAssertEqual(alias.placeholderValue, code)
        app.buttons["clear-profileAlias"].tap()
        saveProfile(in: app)
        XCTAssertTrue(profileRow(code, in: app).waitForExistence(timeout: 10))
    }

    @MainActor func testSavedBirthClockSurvivesNameEditAndCanBeCleared() throws {
        let app = launchFreshApp()
        openNewProfile(in: app)
        let surname = app.textFields["profileSurname"]
        surname.tap(); surname.typeText("陈\n")
        let givenName = app.textFields["profileGivenName"]
        givenName.tap(); givenName.typeText("平\n")
        let date = app.buttons["profileBirthDate"]
        let time = app.buttons["profileBirthTime"]
        for field in [date, time] {
            reveal(field, in: app)
            field.tap()
            let confirm = app.buttons["confirmBirthClock"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            confirm.tap()
            XCTAssertNotEqual(field.value as? String, "未填写")
        }
        let savedDate = try XCTUnwrap(date.value as? String)
        let savedTime = try XCTUnwrap(time.value as? String)
        saveProfile(in: app)

        reopenProfile("陈平", in: app)
        XCTAssertEqual(date.value as? String, savedDate)
        XCTAssertEqual(time.value as? String, savedTime)
        for field in [date, time] {
            reveal(field, in: app); field.tap()
            XCTAssertTrue(app.buttons["confirmBirthClock"].waitForExistence(timeout: 10))
            app.buttons["取消"].tap()
        }
        givenName.tap(); givenName.typeText("安\n")
        let renamed = try XCTUnwrap(givenName.value as? String)
        XCTAssertTrue(renamed.contains("平"))
        XCTAssertTrue(renamed.contains("安"))
        saveProfile(in: app)
        reopenProfile("陈" + renamed, in: app)
        XCTAssertEqual(date.value as? String, savedDate)
        XCTAssertEqual(time.value as? String, savedTime)
        for id in ["clearProfileBirthDate", "clearProfileBirthTime"] {
            let clear = app.buttons[id]
            reveal(clear, in: app); clear.tap()
        }
        XCTAssertEqual(date.value as? String, "未填写")
        XCTAssertEqual(time.value as? String, "未填写")
    }

    @MainActor func testSwitchingBirthCalendarPreservesSelectedAndUnselectedDates() throws {
        let app = launchFreshApp()
        openNewProfile(in: app)
        let alias = app.textFields["profileAlias"]
        alias.tap(); alias.typeText("历法测试\n")
        let calendar = element("profileBirthCalendar", in: app)
        let gregorian = calendar.buttons["公历"]
        let lunar = calendar.buttons["农历"]
        let date = app.buttons["profileBirthDate"]
        reveal(calendar, in: app)
        XCTAssertTrue(gregorian.isSelected)
        XCTAssertEqual(date.value as? String, "未填写")
        lunar.tap()
        XCTAssertTrue(lunar.isSelected)
        XCTAssertEqual(date.value as? String, "未填写")
        gregorian.tap()
        XCTAssertEqual(date.value as? String, "未填写")

        reveal(date, in: app); date.tap()
        let confirm = app.buttons["confirmBirthClock"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        waitForValue("1995-01-01", of: date)

        reveal(calendar, in: app); lunar.tap()
        waitForValue("1994年腊月初一", of: date)
        gregorian.tap()
        waitForValue("1995-01-01", of: date)
        lunar.tap()
        waitForValue("1994年腊月初一", of: date)

        reveal(date, in: app); date.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertEqual(app.pickerWheels.count, 3)
        app.pickerWheels.element(boundBy: 2).adjust(toPickerWheelValue: "初二")
        confirm.tap()
        waitForValue("1994年腊月初二", of: date)
        saveProfile(in: app)

        reopenProfile("历法测试", in: app)
        reveal(calendar, in: app)
        XCTAssertTrue(gregorian.isSelected)
        waitForValue("1995-01-02", of: date)
    }

    @MainActor func testLocationPickersAndGPSAreIndependentAndPersist() throws {
        let app = launchFreshApp(locationFixture: true)
        openNewProfile(in: app)
        let alias = app.textFields["profileAlias"]
        alias.tap(); alias.typeText("位置测试\n")
        let birthPlace = app.buttons["profileBirthPlace"]
        let currentPlace = app.buttons["profileCurrentPlace"]
        reveal(birthPlace, in: app); birthPlace.tap()
        tapDistrictPath(["chinaDistrict-110000", "chinaDistrict-110101"], in: app)
        waitForValue("北京市东城区", of: birthPlace)
        XCTAssertFalse(app.textFields["profileBirthLatitude"].exists)
        XCTAssertFalse(app.buttons["profileBirthTimeZone"].exists)

        reveal(currentPlace, in: app)
        XCTAssertEqual(currentPlace.value as? String, "未填写")
        currentPlace.tap()
        tapDistrictPath(["chinaDistrict-130000", "chinaDistrict-130100", "chinaWholeCity-130100"], in: app)
        waitForValue("河北省石家庄市", of: currentPlace)
        XCTAssertEqual(birthPlace.value as? String, "北京市东城区")
        capture("district-and-whole-city", in: app)
        saveProfile(in: app)

        reopenProfile("位置测试", in: app)
        reveal(birthPlace, in: app)
        XCTAssertEqual(birthPlace.value as? String, "北京市东城区")
        reveal(currentPlace, in: app)
        XCTAssertEqual(currentPlace.value as? String, "河北省石家庄市")
        currentPlace.tap()
        tapDistrictPath(["chinaDistrict-110000", "chinaWholeCity-110000"], in: app)
        waitForValue("北京市", of: currentPlace)

        let currentGPS = app.buttons["useCurrentLocation"]
        reveal(currentGPS, in: app); currentGPS.tap()
        waitForValue("北京市海淀区", of: currentPlace)
        XCTAssertEqual(birthPlace.value as? String, "北京市东城区")
        let clearCurrent = app.buttons["clearProfileCurrentPlace"]
        reveal(clearCurrent, in: app); clearCurrent.tap()
        XCTAssertEqual(currentPlace.value as? String, "未填写")
        XCTAssertEqual(birthPlace.value as? String, "北京市东城区")

        let birthGPS = app.buttons["useCurrentLocationForBirthPlace"]
        reveal(birthGPS, in: app); birthGPS.tap()
        waitForValue("北京市海淀区", of: birthPlace)
        XCTAssertEqual(currentPlace.value as? String, "未填写")
        let clearBirth = app.buttons["clearProfileBirthPlace"]
        reveal(clearBirth, in: app); clearBirth.tap()
        XCTAssertEqual(birthPlace.value as? String, "未填写")
    }

    @MainActor private func tapDistrictPath(_ identifiers: [String], in app: XCUIApplication) {
        for identifier in identifiers {
            let item = element(identifier, in: app)
            let picker = element("chinaDistrictPicker", in: app)
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            for _ in 0..<14 {
                if item.exists && item.isHittable { break }
                picker.swipeUp()
            }
            XCTAssertTrue(item.exists, identifier)
            XCTAssertTrue(item.isHittable, identifier)
            item.tap()
        }
    }

    private var fourPillarsPattern: String {
        #"^[甲乙丙丁戊己庚辛壬癸][子丑寅卯辰巳午未申酉戌亥](\s+[甲乙丙丁戊己庚辛壬癸][子丑寅卯辰巳午未申酉戌亥]){3}$"#
    }

    private func isFourPillars(_ value: String) -> Bool {
        value.range(of: fourPillarsPattern, options: .regularExpression) != nil
    }

    @MainActor private func waitForFourPillars(of element: XCUIElement) throws -> String {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", fourPillarsPattern), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        return try XCTUnwrap(element.value as? String)
    }

    @MainActor private func waitForCopiedBaziFeedback(of button: XCUIElement) {
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已复制八字"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed)
    }

    @MainActor private func pasteCopiedBazi(_ expected: String, in app: XCUIApplication) {
        let alias = app.textFields["profileAlias"]
        reveal(alias, in: app)
        let clear = app.buttons["clear-profileAlias"]
        if clear.exists {
            reveal(clear, in: app); clear.tap()
        }
        alias.tap()
        alias.press(forDuration: 1.2)
        // Exercise the app's actual pasteboard through the native edit menu;
        // no test hook or directly injected clipboard value is involved.
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "粘贴")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        waitForValue(expected, of: alias)
        alias.typeText("\n")
    }

    @MainActor private func openNewProfile(in app: XCUIApplication) {
        app.tabBars.buttons["数据"].tap()
        let add = app.buttons["addProfile"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        XCTAssertTrue(app.textFields["profileAlias"].waitForExistence(timeout: 10))
    }

    @MainActor private func saveProfile(in app: XCUIApplication) {
        let save = app.buttons["confirmIntake"]
        reveal(save, in: app); save.tap()
    }

    @MainActor private func reopenProfile(_ label: String, in app: XCUIApplication) {
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-testing-reset" }
        app.launch()
        let data = app.tabBars.buttons["数据"]
        XCTAssertTrue(data.waitForExistence(timeout: 15)); data.tap()
        let row = profileRow(label, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.textFields["profileAlias"].waitForExistence(timeout: 10))
    }

    @MainActor private func waitForValue(_ value: String, of element: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }

    @MainActor private func launchFreshApp(locationFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        if locationFixture { app.launchArguments.append("--ui-testing-location-fixture") }
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
        let editor = app.scrollViews["profileEditorScroll"]
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
