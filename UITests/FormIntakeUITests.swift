import XCTest

final class FormIntakeUITests: XCTestCase {
    @MainActor func testNewEventQuestionOpensOneFormAndSingleConfirmationStartsCoins() {
        let app = launchFreshApp()
        send("明天是否适合出行？", in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        let confirm = app.buttons["confirmIntake"]
        XCTAssertEqual(app.buttons.matching(identifier: "confirmIntake").count, 1)
        reveal(confirm, in: app)
        XCTAssertEqual(confirm.label, "确认资料并开始")
        capture("new-question-unified-form", in: app)
        confirm.tap()

        XCTAssertTrue(app.buttons["castCoins"].waitForExistence(timeout: 15))
        XCTAssertFalse(form.exists)
        completeCoins(in: app)
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        XCTAssertEqual(app.sheets.count, 0)
    }

    @MainActor func testStrictMethodListsMissingFieldsTogetherAndKeepsTheFormOpen() {
        let app = launchFreshApp()
        send("只用八字看看我的事业", in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        let name = app.textFields["profileName"]
        reveal(name, in: app)
        name.tap(); name.typeText("陈平\n")
        XCTAssertTrue(element("profileBirthDate", in: app).exists)
        XCTAssertTrue(element("profileBirthTime", in: app).exists)
        XCTAssertTrue(app.buttons["profileBirthTimeZone"].exists)
        XCTAssertFalse(app.buttons["editParticipant"].exists)
        let confirm = app.buttons["confirmIntake"]
        reveal(confirm, in: app)
        confirm.tap()

        let error = app.staticTexts["intakeValidationError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("出生日期"))
        XCTAssertTrue(error.label.contains("时区"))
        XCTAssertTrue(form.exists)
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        capture("strict-method-all-missing-fields", in: app)
    }

    @MainActor func testBothParticipantsCanBeEditedInlineBeforeOneConfirmation() throws {
        let app = launchFreshApp()
        send("姓名：陈平，男，1992年6月15日08:30出生，出生时区Asia/Shanghai；姓名：王安，女，1994年3月12日14:00出生，出生时区Asia/Shanghai", in: app)
        waitUntilReadyToSend(in: app)
        XCTAssertFalse(app.scrollViews["intakeFormScroll"].exists)
        send("陈平和王安的合作关系如何安排？", in: app)
        XCTAssertTrue(app.scrollViews["intakeFormScroll"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        XCTAssertEqual(app.textFields.matching(identifier: "profileName").count, 2)
        XCTAssertEqual(app.buttons.matching(identifier: "confirmIntake").count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editParticipant-")).count, 0)

        let first = try participantForm(named: "陈平", in: app)
        let second = try participantForm(named: "王安", in: app)
        let firstPlace = first.textFields["profileCurrentPlace"]
        reveal(firstPlace, in: app)
        firstPlace.tap(); firstPlace.typeText("北京\n")
        let secondPlace = second.textFields["profileCurrentPlace"]
        reveal(secondPlace, in: app)
        secondPlace.tap(); secondPlace.typeText("上海\n")
        XCTAssertEqual(firstPlace.value as? String, "北京")
        XCTAssertEqual(secondPlace.value as? String, "上海")
        XCTAssertEqual(first.textFields["profileName"].value as? String, "陈平")
        XCTAssertEqual(second.textFields["profileName"].value as? String, "王安")
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        capture("two-participants-inline-one-form", in: app)
        let confirm = app.buttons["confirmIntake"]
        reveal(confirm, in: app)
        confirm.tap()
        XCTAssertTrue(app.buttons["castCoins"].waitForExistence(timeout: 15))
        completeCoins(in: app)
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
    }

    @MainActor private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["sendQuestion"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        waitUntilReadyToSend(in: app)
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText(text)
        app.buttons["sendQuestion"].tap()
    }

    @MainActor private func waitUntilReadyToSend(in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "发送问题"), object: app.buttons["sendQuestion"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    @MainActor private func participantForm(named name: String, in app: XCUIApplication) throws -> XCUIElement {
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "removeParticipant-", "移除" + name)).firstMatch
        XCTAssertTrue(remove.exists)
        let id = String(remove.identifier.dropFirst("removeParticipant-".count))
        _ = try XCTUnwrap(UUID(uuidString: id))
        let container = app.otherElements["participantForm-" + id]
        XCTAssertTrue(container.exists)
        return container
    }

    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(scroll.exists)
        for _ in 0..<35 {
            if element.exists && element.isHittable { return }
            let bounds = scroll.frame.intersection(app.frame)
            var bottom = bounds.maxY - 28
            if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY - 16) }
            let top = bounds.minY + 28
            let height = max(100, bottom - top)
            let target = element.exists ? element.frame : .zero
            let towardsEarlier = !target.isEmpty && target.midY < top + height * 0.2
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: 12, dy: top + height * (towardsEarlier ? 0.3 : 0.75) - bounds.minY))
            let end = origin.withOffset(CGVector(dx: 12, dy: top + height * (towardsEarlier ? 0.68 : 0.35) - bounds.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable, element.identifier)
    }

    @MainActor private func completeCoins(in app: XCUIApplication) {
        let cast = app.buttons["castCoins"]
        XCTAssertTrue(cast.waitForExistence(timeout: 15))
        for _ in 0..<6 {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: cast)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            cast.tap()
        }
        let confirm = app.buttons["confirmInteraction"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        confirm.tap()
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
