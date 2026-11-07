import XCTest

final class ExperienceFixUITests: XCTestCase {
    @MainActor func testPendingTarotAcceptsHelpAndSameQuestionMethodChange() {
        let app = launchApp()
        send("只用塔罗看看今晚合作的安排", in: app)
        confirmIntake(in: app)
        XCTAssertTrue(app.buttons["shuffleTarot"].waitForExistence(timeout: 15))
        app.buttons["deferInteraction"].tap()
        XCTAssertTrue(app.buttons["shuffleTarot"].waitForNonExistence(timeout: 5))

        let previousAnswers = assistantIDs(in: app)
        let help = "为什么是三张牌？"
        send(help, in: app)
        let answer = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT (identifier IN %@)", "assistantBubble-", previousAnswers)).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[help].exists)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
        XCTAssertTrue(app.buttons["interactionCard"].exists)
        XCTAssertFalse((app.textFields["questionInput"].value as? String ?? "").contains(help))
        capture("pending-tarot-help-keeps-chat-open", in: app)

        send("先不抽了，改用梅花", in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        XCTAssertTrue(form.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "本次方法：梅花")).firstMatch.exists)
        XCTAssertFalse(app.buttons["shuffleTarot"].exists)
        XCTAssertFalse(app.buttons["castCoins"].exists)
        capture("pending-tarot-switches-to-meihua", in: app)
    }

    @MainActor func testCardAndCoinStepsCanBeDeferredResumedAndCanceled() {
        for (name, markerID) in [("塔罗", "shuffleTarot"), ("六爻", "castCoins")] {
            XCTContext.runActivity(named: name) { _ in
                let app = launchApp()
                defer { app.terminate() }
                send("只用\(name)看看今晚合作的安排", in: app)
                confirmIntake(in: app)
                let marker = app.buttons[markerID]
                XCTAssertTrue(marker.waitForExistence(timeout: 15))
                XCTAssertTrue(app.buttons["cancelInteraction"].exists)

                app.buttons["deferInteraction"].tap()
                XCTAssertTrue(marker.waitForNonExistence(timeout: 5))
                let resume = app.buttons["interactionCard"]
                XCTAssertTrue(resume.waitForExistence(timeout: 5))
                resume.tap()
                XCTAssertTrue(marker.waitForExistence(timeout: 5))
                capture("\(markerID)-resumes-after-deferral", in: app)

                app.buttons["cancelInteraction"].tap()
                XCTAssertTrue(marker.waitForNonExistence(timeout: 5))
                XCTAssertFalse(app.buttons["interactionCard"].exists)
                XCTAssertFalse(app.scrollViews["intakeFormScroll"].exists)
                let closing = "谢谢，先聊到这里"
                let previousAnswers = assistantIDs(in: app)
                send(closing, in: app)
                XCTAssertTrue(app.staticTexts[closing].waitForExistence(timeout: 10))
                let answer = app.descendants(matching: .any).matching(NSPredicate(
                    format: "identifier BEGINSWITH %@ AND NOT (identifier IN %@)", "assistantBubble-", previousAnswers)).firstMatch
                XCTAssertTrue(answer.waitForExistence(timeout: 15))
                XCTAssertFalse(marker.exists)
                XCTAssertFalse(app.buttons["confirmIntake"].exists)
                capture("\(markerID)-canceled-with-chat-available", in: app)
            }
        }
    }

    @MainActor func testChartGenderRequirementAndQuestionFollowTheSelectedMethod() {
        let app = launchApp(withSavedProfile: true)
        send("只用紫微斗数看看陈平今年的工作", in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        let requirement = app.staticTexts["profileGenderRequirement"].firstMatch
        reveal(requirement, in: form)
        XCTAssertEqual(requirement.label, "必填")
        let explanation = app.staticTexts["profileGenderExplanation"].firstMatch
        XCTAssertTrue(explanation.label.contains("紫微斗数需要"))
        XCTAssertFalse(form.staticTexts["可留空"].exists)
        capture("ziwei-chart-gender-required-and-explained", in: app)

        dismissReadingDetailsSheet(in: app)
        XCTAssertTrue(form.waitForNonExistence(timeout: 5))
        send("改用八字", in: app)
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        reveal(requirement, in: form)
        XCTAssertEqual(requirement.label, "可选")
        XCTAssertTrue(explanation.label.contains("八字可留空"))
        for _ in 0..<20 where !form.staticTexts["intakeQuestion"].isHittable { form.swipeDown() }
        let question = form.staticTexts["intakeQuestion"].label
        XCTAssertTrue(question.contains("八字"))
        XCTAssertFalse(question.contains("紫微"))
        capture("bazi-chart-gender-optional-and-question-updated", in: app)
    }

    @MainActor private func launchApp(withSavedProfile: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reset-language"]
        if withSavedProfile { app.launchArguments.append("--ui-testing-reading-library") }
        app.launch()
        XCTAssertTrue(app.textFields["questionInput"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText(text)
        app.buttons["sendQuestion"].tap()
    }

    @MainActor private func confirmIntake(in app: XCUIApplication) {
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        let confirm = app.buttons["confirmIntake"]
        reveal(confirm, in: form)
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
    }

    @MainActor private func reveal(_ element: XCUIElement, in form: XCUIElement) {
        for _ in 0..<24 where !element.isHittable { form.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func assistantIDs(in app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistantBubble-"))
            .allElementsBoundByIndex.map(\.identifier)
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
