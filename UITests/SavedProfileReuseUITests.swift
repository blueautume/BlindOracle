import XCTest

final class SavedProfileReuseUITests: XCTestCase {
    @MainActor func testSavedSoleProfilePrefillsNewQuestionWithoutAskingForKnownBirthInformationAgain() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["sendQuestion"].waitForExistence(timeout: 15))
        send("姓名：陈平，男，1992年6月15日08:30出生，出生时区Asia/Shanghai，出生地甘肃省武威市民勤县", in: app)
        waitUntilReadyToSend(in: app)
        XCTAssertFalse(app.scrollViews["intakeFormScroll"].exists)

        // This question deliberately omits both the name and a self pronoun.
        // The sole saved person should be offered with the original facts.
        send("明年财运", in: app)
        let form = app.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        XCTAssertEqual(app.textFields.matching(identifier: "profileName").count, 1)
        XCTAssertEqual(app.textFields["profileName"].value as? String, "陈平")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "removeParticipant-")).count, 1)
        let savedPerson = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "selectProfile-", "陈平，已选")).firstMatch
        XCTAssertTrue(savedPerson.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "confirmIntake").count, 1)

        let date = element("profileBirthDate", in: app)
        reveal(date, in: app)
        XCTAssertEqual(app.switches["birthDateKnown"].value as? String, "1")
        XCTAssertTrue(date.isEnabled)
        let dateContents = accessibilityContents(of: date)
        XCTAssertTrue(dateContents.contains("1992"), "Date picker contents: " + dateContents)
        let time = element("profileBirthTime", in: app)
        reveal(time, in: app)
        XCTAssertEqual(app.switches["birthTimeKnown"].value as? String, "1")
        XCTAssertTrue(time.isEnabled)
        let timeContents = accessibilityContents(of: time)
        let hasSavedTime = timeContents.range(of: #"(?:^|[^\d])0?8[^\d]+30(?:[^\d]|$)"#,
                                              options: .regularExpression) != nil
        XCTAssertTrue(hasSavedTime, "Time picker contents: " + timeContents)
        let birthPlace = app.textFields["profileBirthPlace"]
        reveal(birthPlace, in: app)
        XCTAssertEqual(birthPlace.value as? String, "甘肃省武威市民勤县")
        let birthZone = app.buttons["profileBirthTimeZone"]
        reveal(birthZone, in: app)
        XCTAssertEqual(birthZone.value as? String, "Asia/Shanghai")
        XCTAssertFalse(birthZone.label.contains("尚未确认"))
        capture("saved-profile-prefills-unqualified-fortune-question", in: app)

        // No profile field is edited and there is only one confirmation.
        let confirm = app.buttons["confirmIntake"]
        reveal(confirm, in: app); confirm.tap()
        let cast = app.buttons["castCoins"]
        XCTAssertTrue(cast.waitForExistence(timeout: 15))
        XCTAssertFalse(form.exists)
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
        for _ in 0..<6 {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: cast)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            cast.tap()
        }
        let interaction = app.buttons["confirmInteraction"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: interaction)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        interaction.tap()
        let summary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        XCTAssertFalse(form.exists)
        XCTAssertEqual(app.sheets.count, 0)

        app.tabBars.buttons["数据"].tap()
        let people = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profileRow-"))
        XCTAssertEqual(people.count, 1)
        XCTAssertTrue(people.firstMatch.label.contains("陈平"))
        XCTAssertTrue(people.firstMatch.label.contains("1992"))
        capture("saved-profile-remains-single-after-reading", in: app)
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        waitUntilReadyToSend(in: app)
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText(text)
        app.buttons["sendQuestion"].tap()
    }

    @MainActor private func waitUntilReadyToSend(in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "发送问题"), object: app.buttons["sendQuestion"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func accessibilityContents(of element: XCUIElement) -> String {
        // Compact SwiftUI DatePicker containers can expose only their caption.
        // UIKit puts the selected date/time on descendant buttons or wheels.
        ([element] + element.descendants(matching: .any).allElementsBoundByIndex)
            .flatMap { [$0.label, $0.value as? String ?? ""] }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
