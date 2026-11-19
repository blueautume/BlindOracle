import XCTest

final class MultiPersonUITests: XCTestCase {
    @MainActor func testCreateTwoNamedProfilesAndChooseBothForRelationshipReading() {
        let app = launchFreshApp()
        app.tabBars.buttons["数据"].tap()
        createSavedProfile("张三", birthDistrict: ["chinaDistrict-110000", "chinaDistrict-110101"], in: app)
        createSavedProfile("李四", birthDistrict: ["chinaDistrict-310000", "chinaDistrict-310101"], in: app)
        XCTAssertTrue(profileRow("张三", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(profileRow("李四", in: app).exists)
        capture("named-profile-directory", in: app)
        app.tabBars.buttons["对话"].tap()
        send("只用八字看看张三和李四的合作关系如何安排？", in: app)
        let confirm = app.buttons["confirmIntake"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.exists)
        for name in ["张三", "李四"] {
            let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "selectProfile-", name)).firstMatch
            XCTAssertTrue(selected.exists)
            XCTAssertTrue(selected.label.contains("已选"))
        }
        XCTAssertEqual(app.textFields.matching(identifier: "profileAlias").count, 2)
        capture("joint-reading-all-data-in-one-form", in: app)
        assertReadingConfirmationInNavigationBar(in: app, language: "zh-Hans")
        confirm.tap()
        XCTAssertTrue(app.buttons["confirmIntake"].waitForNonExistence(timeout: 5))
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这次推演已完成")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        let data = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        for _ in 0..<8 where !data.isHittable { app.scrollViews["chatTranscript"].swipeUp() }
        XCTAssertTrue(data.isHittable)
        data.tap()
        XCTAssertTrue(app.scrollViews["runResultsSheet"].waitForExistence(timeout: 10))
        for name in ["张三", "李四"] {
            let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", name + " · ")).firstMatch
            for _ in 0..<14 where !title.isHittable { app.scrollViews["runResultsSheet"].swipeUp() }
            XCTAssertTrue(title.exists)
        }
        capture("joint-reading-separate-person-results", in: app)
    }

    @MainActor func testChatDoesNotSavePeopleAndManualCorrectionPreservesBothIDsAcrossRelaunch() {
        let app = launchFreshApp()
        send("姓名：张三，男，1995年1月2日出生；姓名：李四，女，1996年3月4日出生", in: app)
        waitUntilReadyToSend(in: app)
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(app.buttons["addProfile"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profileRow-")).count, 0)
        createSavedProfile("张三", in: app)
        createSavedProfile("李四", in: app)
        XCTAssertTrue(profileRow("张三", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(profileRow("李四", in: app).exists)
        let firstID = profileRow("张三", in: app).identifier
        let secondID = profileRow("李四", in: app).identifier
        app.tabBars.buttons["对话"].tap()
        send("更正张三的出生时刻和出生地为上海。", in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        let birthplace = app.buttons["profileBirthPlace"]
        reveal(birthplace, in: form, app: app)
        XCTAssertEqual(birthplace.value as? String, "未填写")
        chooseBirthClock("profileBirthTime", in: form, app: app)
        chooseBirthplace(["chinaDistrict-110000", "chinaDistrict-110101"], in: form, app: app)
        app.buttons["confirmIntake"].tap()
        XCTAssertTrue(form.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["数据"].tap()
        let updated = profileRow("张三", in: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "北京"), object: updated)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        XCTAssertEqual(updated.identifier, firstID)
        XCTAssertEqual(profileRow("李四", in: app).identifier, secondID)
        XCTAssertFalse(profileRow("李四", in: app).label.contains("北京"))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-testing-reset" }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(profileRow("张三", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(profileRow("张三", in: app).identifier, firstID)
        XCTAssertEqual(profileRow("李四", in: app).identifier, secondID)
        XCTAssertTrue(profileRow("张三", in: app).label.contains("北京"))
        XCTAssertFalse(profileRow("张三", in: app).label.contains("时辰未定"))
        XCTAssertTrue(profileRow("李四", in: app).label.contains("时辰未定"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profileRow-")).count, 2)
        capture("manually-corrected-profiles-after-relaunch", in: app)
    }

    @MainActor private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reset-language",
                               "-oracle.appLanguage", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func profileRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "profileRow-", name)).firstMatch
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        waitUntilReadyToSend(in: app)
        input.tap(); input.typeText(text)
        app.buttons["sendQuestion"].tap()
    }

    @MainActor private func waitUntilReadyToSend(in app: XCUIApplication) {
        let send = app.buttons["sendQuestion"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "发送问题"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    @MainActor private func createSavedProfile(_ name: String, birthDistrict: [String] = [], in app: XCUIApplication) {
        let add = app.buttons["addProfile"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let editor = app.scrollViews["profileEditorScroll"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let surname = editor.textFields["profileSurname"]
        let givenName = editor.textFields["profileGivenName"]
        surname.tap(); surname.typeText(String(name.prefix(1)) + "\n")
        givenName.tap(); givenName.typeText(String(name.dropFirst()) + "\n")
        chooseBirthClock("profileBirthDate", in: editor, app: app)
        if !birthDistrict.isEmpty {
            chooseBirthClock("profileBirthTime", in: editor, app: app)
            chooseBirthplace(birthDistrict, in: editor, app: app)
        }
        let save = app.buttons["confirmIntake"]
        reveal(save, in: editor, app: app)
        save.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(profileRow(name, in: app).waitForExistence(timeout: 10))
    }

    @MainActor private func chooseBirthClock(_ id: String, in form: XCUIElement, app: XCUIApplication) {
        let field = form.buttons[id]
        reveal(field, in: form, app: app)
        field.tap()
        let confirm = app.buttons["confirmBirthClock"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
    }

    @MainActor private func chooseBirthplace(_ path: [String], in form: XCUIElement, app: XCUIApplication) {
        let field = form.buttons["profileBirthPlace"]
        reveal(field, in: form, app: app)
        field.tap()
        let picker = app.descendants(matching: .any).matching(identifier: "chinaDistrictPicker").firstMatch
        for id in path {
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            let item = app.descendants(matching: .any).matching(identifier: id).firstMatch
            for _ in 0..<14 {
                if item.exists && item.isHittable { break }
                picker.swipeUp()
            }
            XCTAssertTrue(item.isHittable, id)
            item.tap()
        }
    }

    @MainActor private func reveal(_ element: XCUIElement, in form: XCUIElement, app: XCUIApplication) {
        for _ in 0..<18 {
            if element.exists && element.isHittable { return }
            let bounds = form.frame.intersection(app.frame)
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? min(bounds.maxY, keyboard.frame.minY) : bounds.maxY
            let top = bounds.minY + 28
            let height = max(100, bottom - top - 28)
            let target = element.exists ? element.frame : .zero
            let earlier = !target.isEmpty && target.midY < top + height * 0.2
            let origin = form.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: 12, dy: top - bounds.minY + height * (earlier ? 0.3 : 0.75)))
            let end = origin.withOffset(CGVector(dx: 12, dy: top - bounds.minY + height * (earlier ? 0.68 : 0.35)))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable, element.identifier)
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
