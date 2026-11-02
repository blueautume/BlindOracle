import XCTest

final class ChatProgressUITests: XCTestCase {
    @MainActor func testProgressStartsCollapsedAndExpandedHistoryIncludesEveryStep() {
        let app = launchProgressFixture(paused: true)
        let toggle = app.buttons["progressToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "已折叠")
        XCTAssertEqual(progressRows(in: app).count, 0)
        XCTAssertTrue(toggle.label.contains("综合解析"))
        let spinner = app.descendants(matching: .any).matching(identifier: "progressRunningIndicator").firstMatch
        XCTAssertTrue(spinner.waitForExistence(timeout: 5))
        capture("spinner-running-a", in: app)
        Thread.sleep(forTimeInterval: 0.4)
        capture("spinner-running-b", in: app)
        XCTAssertTrue(toggle.label.contains("综合解析"))

        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "已展开")
        XCTAssertGreaterThanOrEqual(progressRows(in: app).count, 9)
        capture("progress-all-steps-expanded", in: app)
        reveal(toggle, in: app)
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "已折叠")
        XCTAssertEqual(progressRows(in: app).count, 0)
        capture("progress-collapsed-current-step", in: app)
    }

    @MainActor func testCurrentStepChangesWhenProcessingReachesOutputAndCompletion() {
        let app = launchProgressFixture(paused: false)
        let title = app.buttons["progressToggle"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertTrue(title.label.contains("综合解析"))
        let writing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "正在整理中文解读"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [writing], timeout: 20), .completed)
        XCTAssertEqual(app.buttons["progressToggle"].value as? String, "已折叠")
        capture("progress-writing-output", in: app)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "解读已完成"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        XCTAssertEqual(app.buttons["sendQuestion"].label, "发送问题")
        reveal(app.buttons["progressToggle"], in: app)
        capture("progress-completed", in: app)
    }

    @MainActor func testScrollingKeepsTranscriptAboveOpaqueComposer() {
        let app = launchProgressFixture(paused: true)
        let toggle = app.buttons["progressToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        let panel = app.descendants(matching: .any).matching(identifier: "chatComposerPanel").firstMatch
        let transcript = app.scrollViews["chatTranscript"]
        let input = app.textFields["questionInput"]
        XCTAssertTrue(panel.exists)
        XCTAssertTrue(transcript.exists)
        XCTAssertFalse(panel.frame.isEmpty)
        XCTAssertLessThanOrEqual(transcript.frame.maxY, panel.frame.minY + 1)
        XCTAssertTrue(panel.frame.contains(input.frame))
        capture("chat-opaque-composer-at-bottom", in: app)

        transcript.swipeDown()
        transcript.swipeDown()
        XCTAssertLessThanOrEqual(transcript.frame.maxY, panel.frame.minY + 1)
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(app.buttons["sendQuestion"].isHittable)
        capture("chat-opaque-composer-after-scroll", in: app)
    }

    @MainActor private func launchProgressFixture(paused: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset",
                               paused ? "--ui-testing-progress-paused" : "--ui-testing-progress"]
        app.launch()
        return app
    }

    @MainActor private func progressRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "progressStep-"))
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.scrollViews["chatTranscript"].swipeDown() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
