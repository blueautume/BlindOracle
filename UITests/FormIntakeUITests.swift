import XCTest

final class FormIntakeUITests: XCTestCase {
    @MainActor func testEnglishCareerQuestionShowsPrefilledBirthDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "-oracle.appLanguage", "en",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Please use BaZi to explore my career strengths and what kind of work would suit me best. My name is Alex Chen, and I’m male. I was born on June 15, 1995, at 9:30 a.m. in Shanghai, China.")
        app.buttons["sendQuestion"].tap()

        XCTAssertTrue(app.scrollViews["intakeFormScroll"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Reading details"].exists)
        assertReadingConfirmationInNavigationBar(in: app, language: "en")
        let savedName = element("legacyProfileName", in: app)
        reveal(savedName, in: app)
        let nameContents = ([savedName] + savedName.descendants(matching: .any).allElementsBoundByIndex)
            .flatMap { [$0.label, $0.value as? String ?? ""] }.joined(separator: " ")
        XCTAssertTrue(nameContents.contains("Alex Chen"))
        let gender = element("profileGender", in: app)
        reveal(gender, in: app)
        XCTAssertEqual(gender.value as? String, "Male")

        let birthDate = element("profileBirthDate", in: app)
        reveal(birthDate, in: app)
        XCTAssertEqual(birthDate.value as? String, "Jun 15, 1995")
        let birthTime = element("profileBirthTime", in: app)
        reveal(birthTime, in: app)
        let clock = (birthTime.value as? String)?.filter { !$0.isWhitespace }.lowercased()
        XCTAssertEqual(clock, "9:30am")
        let birthplace = app.buttons["profileBirthPlace"]
        reveal(birthplace, in: app)
        XCTAssertEqual(birthplace.value as? String, "Shanghai")
        capture("english-career-question-prefilled-birth-details", in: app)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
    }

    @MainActor func testEnglishDistrictAndClockCombinationsShowPrefilledBirthDetails() {
        let scenarios = [
            (date: "June 15, 1995", clock: "9:30 a.m.", place: "Xuhui District, Shanghai", dateValue: "Jun 15, 1995", clockValue: "9:30am", code: "310104"),
            (date: "15 June 1995", clock: "8:45 PM", place: "Chaoyang District, Beijing", dateValue: "Jun 15, 1995", clockValue: "8:45pm", code: "110105"),
            (date: "February 29, 2000", clock: "12 a.m.", place: "Tianhe District, Guangzhou, Guangdong", dateValue: "Feb 29, 2000", clockValue: "12:00am", code: "440106"),
            (date: "Feb 29, 2000", clock: "23:59:30", place: "Chaoyang District, Changchun, Jilin", dateValue: "Feb 29, 2000", clockValue: "11:59pm", code: "220104")
        ]
        for scenario in scenarios {
            XCTContext.runActivity(named: scenario.place + " · " + scenario.clock) { _ in
                let app = XCUIApplication()
                app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "-oracle.appLanguage", "en",
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                app.launch()
                defer { app.terminate() }
                let input = app.textFields["questionInput"]
                XCTAssertTrue(input.waitForExistence(timeout: 15))
                input.tap()
                input.typeText("Please use BaZi to explore my career strengths. My name is Alex Chen, and I’m male. I was born on \(scenario.date), at \(scenario.clock) in \(scenario.place), China.")
                app.buttons["sendQuestion"].tap()

                XCTAssertTrue(app.scrollViews["intakeFormScroll"].waitForExistence(timeout: 15))
                let birthDate = element("profileBirthDate", in: app)
                reveal(birthDate, in: app)
                XCTAssertEqual(birthDate.value as? String, scenario.dateValue)
                let birthTime = element("profileBirthTime", in: app)
                reveal(birthTime, in: app)
                let clock = (birthTime.value as? String)?.filter { !$0.isWhitespace }.lowercased()
                XCTAssertEqual(clock, scenario.clockValue)
                let birthplace = app.buttons["profileBirthPlace"]
                reveal(birthplace, in: app)
                XCTAssertEqual(birthplace.value as? String, scenario.place)
                capture("english-district-prefilled-" + scenario.code, in: app)
                XCTAssertFalse(app.buttons["castCoins"].exists)
                XCTAssertFalse(app.buttons["shuffleTarot"].exists)
            }
        }
    }

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
        assertReadingConfirmationInNavigationBar(in: app, language: "zh-Hans")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        capture("new-question-unified-form", in: app)
        confirm.tap()

        XCTAssertTrue(app.buttons["castCoins"].waitForExistence(timeout: 15))
        XCTAssertFalse(form.exists)
        completeCoins(in: app)
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这次推演已完成")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        XCTAssertEqual(app.sheets.count, 0)
    }

    @MainActor func testStrictMethodListsMissingFieldsTogetherAndKeepsTheFormOpen() {
        let app = launchFreshApp()
        send("只用八字看看我的事业", in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        let name = app.textFields["profileAlias"]
        reveal(name, in: app)
        name.tap(); name.typeText("陈平\n")
        XCTAssertTrue(element("profileBirthDate", in: app).exists)
        XCTAssertTrue(element("profileBirthTime", in: app).exists)
        XCTAssertTrue(app.buttons["profileBirthPlace"].exists)
        XCTAssertFalse(app.buttons["profileBirthTimeZone"].exists)
        XCTAssertFalse(app.buttons["editParticipant"].exists)
        let confirm = app.buttons["confirmIntake"]
        assertReadingConfirmationInNavigationBar(in: app, language: "zh-Hans")
        confirm.tap()

        let error = app.staticTexts["intakeValidationError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.isHittable, "A failed toolbar confirmation must show its validation feedback")
        XCTAssertTrue(error.label.contains("出生日期"))
        XCTAssertTrue(form.exists)
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        capture("strict-method-all-missing-fields", in: app)
    }

    @MainActor func testSwitchingThePendingMethodKeepsUnsubmittedPersonAcrossRelaunch() {
        let app = launchFreshApp()
        let question = "只用八字看看我的事业"
        send(question, in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        let name = form.textFields["profileAlias"]
        reveal(name, in: app)
        name.tap(); name.typeText("陈平\n")
        XCTAssertEqual(name.value as? String, "陈平")
        dismissReadingDetailsSheet(in: app)
        XCTAssertTrue(form.waitForNonExistence(timeout: 5))

        send("改用塔罗", in: app)
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        XCTAssertTrue(form.staticTexts[question].exists)
        XCTAssertTrue(form.staticTexts["本次方法：塔罗牌"].exists)
        XCTAssertEqual(name.value as? String, "陈平")
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)

        let clearAlias = form.buttons["clear-profileAlias"]
        reveal(clearAlias, in: app)
        clearAlias.tap()
        XCTAssertEqual(name.value as? String, name.placeholderValue)
        reveal(name, in: app)
        name.tap(); name.typeText("陈平宁\n")
        XCTAssertEqual(name.value as? String, "陈平宁")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        XCTAssertTrue(form.staticTexts[question].exists)
        XCTAssertTrue(form.staticTexts["本次方法：塔罗牌"].exists)
        XCTAssertEqual(name.value as? String, "陈平宁")
    }

    @MainActor func testBothParticipantsCanBeEditedInlineBeforeOneConfirmation() throws {
        let app = launchFreshApp()
        send("姓名：陈平，男，1992年6月15日08:30出生，出生时区Asia/Shanghai；姓名：王安，女，1994年3月12日14:00出生，出生时区Asia/Shanghai", in: app)
        waitUntilReadyToSend(in: app)
        XCTAssertFalse(app.scrollViews["intakeFormScroll"].exists)
        send("陈平和王安的合作关系如何安排？", in: app)
        XCTAssertTrue(app.scrollViews["intakeFormScroll"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        XCTAssertEqual(app.textFields.matching(identifier: "profileAlias").count, 2)
        XCTAssertEqual(app.buttons.matching(identifier: "confirmIntake").count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editParticipant-")).count, 0)

        let first = try participantForm(named: "陈平", in: app)
        let second = try participantForm(named: "王安", in: app)
        let firstAlias = first.textFields["profileAlias"]
        reveal(firstAlias, in: app)
        firstAlias.tap(); firstAlias.typeText("工作甲\n")
        let secondAlias = second.textFields["profileAlias"]
        reveal(secondAlias, in: app)
        secondAlias.tap(); secondAlias.typeText("工作乙\n")
        XCTAssertEqual(firstAlias.value as? String, "工作甲")
        XCTAssertEqual(secondAlias.value as? String, "工作乙")
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        capture("two-participants-inline-one-form", in: app)
        let confirm = app.buttons["confirmIntake"]
        reveal(confirm, in: app)
        confirm.tap()
        XCTAssertTrue(app.buttons["castCoins"].waitForExistence(timeout: 15))
        completeCoins(in: app)
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这次推演已完成")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
    }

    @MainActor private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-location-fixture",
                               "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans"]
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
