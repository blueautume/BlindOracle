import XCTest

final class BlindOracleUITests: XCTestCase {
    /// Opt-in on a dedicated fresh simulator: exercises the shipped app and its
    /// bundled credential without creating profiles or sending a reading.
    @MainActor func testReleaseBundledCredentialConnectsToTheActualProModel() throws {
        guard ProcessInfo.processInfo.environment["BLINDORACLE_RELEASE_CONNECTION_SMOKE"] == "1" else {
            throw XCTSkip("Release connection smoke is opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        let data = app.tabBars.buttons["数据"]
        XCTAssertTrue(data.waitForExistence(timeout: 15))
        data.tap()
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let savedKey = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "已保存密钥")).firstMatch
        XCTAssertTrue(savedKey.waitForExistence(timeout: 10))
        let status = app.staticTexts["settingsAIConnectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("DeepSeek Pro"))
        XCTAssertTrue(status.label.contains("max"))
        XCTAssertFalse(status.label.contains("仅本地"))
        let check = app.buttons["checkAIConnection"]
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        XCTAssertTrue(check.isEnabled)
        for _ in 0..<6 where !check.isHittable { app.swipeUp() }
        XCTAssertTrue(check.isHittable)
        check.tap()

        let report = app.descendants(matching: .any).matching(identifier: "connectionCheckReport").firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 120))
        guard report.exists else { return }
        // SwiftUI can propagate the group's identifier to its Text children;
        // the first match may itself be a StaticText rather than a container.
        let labels = app.staticTexts.matching(identifier: "connectionCheckReport").allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(labels.contains("请求模型：deepseek-v4-pro"))
        XCTAssertTrue(labels.contains("实际模型：deepseek-v4-pro"))
        XCTAssertTrue(labels.contains("深度思考") && labels.contains("max") && labels.contains("65,536"))
        XCTAssertTrue(labels.contains("api.deepseek.com"))
        let feedback = app.staticTexts["connectionCheckFeedback"]
        XCTAssertTrue(feedback.exists)
        XCTAssertTrue(feedback.label.contains("连接正常"))
        for _ in 0..<6 where !report.isHittable { app.swipeUp() }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "release-pro-connection-report"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testReleaseBundledQwenConnectsAndSelectionPersists() throws {
        guard ProcessInfo.processInfo.environment["BLINDORACLE_RELEASE_CONNECTION_SMOKE"] == "1" else {
            throw XCTSkip("Release connection smoke is opt-in")
        }
        let app = XCUIApplication()
        app.launch()
        openSettings(in: app)

        let picker = app.segmentedControls["aiProviderPicker"]
        let qwen = picker.buttons["千问"]
        XCTAssertTrue(qwen.waitForExistence(timeout: 10))
        qwen.tap()
        XCTAssertTrue(qwen.isSelected)
        let status = app.staticTexts["settingsAIConnectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("千问"))

        let check = app.buttons["checkAIConnection"]
        for _ in 0..<6 where !check.isHittable { app.swipeUp() }
        XCTAssertTrue(check.isHittable)
        XCTAssertTrue(check.isEnabled)
        check.tap()

        let feedback = app.staticTexts["connectionCheckFeedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 120))
        XCTAssertTrue(feedback.label.contains("连接正常"), feedback.label)
        let labels = app.staticTexts.matching(identifier: "connectionCheckReport").allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains("请求模型：qwen3.8-max-0902"))
        XCTAssertTrue(labels.contains("实际模型：qwen3.8-max-0902") || labels.contains("实际模型：qwen3.8-max-2026-09-02"))
        XCTAssertTrue(labels.contains { $0.contains("dashscope.aliyuncs.com") })

        app.terminate()
        app.launch()
        openSettings(in: app)
        XCTAssertTrue(qwen.waitForExistence(timeout: 10))
        XCTAssertTrue(qwen.isSelected)
        let deepSeek = picker.buttons["DeepSeek"]
        deepSeek.tap()
        XCTAssertTrue(deepSeek.isSelected)
    }

    @MainActor func testReadingStylePickerFallsBackToDeadpanForUnknownPreference() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "-oracle.appLanguage", "zh-Hans", "-oracle.voiceStyle", "unsupported"]
        app.launch()
        openSettings(in: app)

        let detail = app.staticTexts["oracleVoiceStyleDetail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.label, "直给判断，带一点冷幽默。")
    }

    @MainActor func testReadingStyleSelectionPersistsAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "-oracle.appLanguage", "zh-Hans"]
        app.launch()
        openSettings(in: app)

        let styles = [
            (title: "经典", detail: "平实稳重，结论之后细讲盘面依据。"),
            (title: "冷面直断", detail: "直给判断，带一点冷幽默。"),
            (title: "温和参谋", detail: "温和给建议，帮你看清下一步。"),
            (title: "江湖说书", detail: "用一个鲜活的比喻说清眼前的局。")
        ]
        let picker = app.buttons["oracleVoiceStylePicker"]
        let detail = app.staticTexts["oracleVoiceStyleDetail"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let initialStyle = try XCTUnwrap(styles.first { $0.detail == detail.label })
        let newStyle = try XCTUnwrap(styles.reversed().first { $0.title != initialStyle.title })

        picker.tap()
        for style in styles {
            XCTAssertTrue(app.buttons[style.title].waitForExistence(timeout: 5))
        }
        app.buttons[newStyle.title].tap()
        defer {
            if picker.exists {
                picker.tap()
                let initialChoice = app.buttons[initialStyle.title]
                if initialChoice.waitForExistence(timeout: 5) { initialChoice.tap() }
            }
        }
        XCTAssertEqual(detail.label, newStyle.detail)

        app.terminate()
        app.launch()
        openSettings(in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.label, newStyle.detail)
    }

    @MainActor private func openSettings(in app: XCUIApplication) {
        // iPadOS exposes the floating tabs without a TabBar ancestor.
        let data = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["数据", "Data"])).firstMatch
        guard data.waitForExistence(timeout: 15) else { return XCTFail("Data tab was not shown") }
        data.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label IN %@", ["设置", "Settings"])).firstMatch
        guard settings.waitForExistence(timeout: 10) else { return XCTFail("Settings button was not shown") }
        settings.tap()
    }

    @MainActor func testProfilePersistsAcrossAppRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        let profile = app.buttons["addProfile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10)); profile.tap()
        let name = app.textFields["profileAlias"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("张小明")
        let save = app.buttons["confirmIntake"]
        for _ in 0..<9 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.staticTexts["张小明"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(app.staticTexts["张小明"].waitForExistence(timeout: 10))
    }
    @MainActor func testTwoTabsAndLocalReadingFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["对话"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["数据"].exists)
        XCTAssertEqual(app.tabBars.buttons.count, 2)
        let welcome = XCTAttachment(screenshot: app.screenshot()); welcome.name = "01-welcome"; welcome.lifetime = .keepAlways; add(welcome)
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.exists)
        input.tap(); input.typeText("未来一周适合推进手头的计划吗？")
        app.buttons["sendQuestion"].tap()
        let confirm = app.buttons["confirmIntake"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        XCTAssertTrue(app.scrollViews["intakeFormScroll"].exists)
        let intake = XCTAttachment(screenshot: app.screenshot()); intake.name = "02-intake"; intake.lifetime = .keepAlways; add(intake)
        for _ in 0..<24 where !confirm.isHittable { app.scrollViews["intakeFormScroll"].swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        completeCoinInteraction(in: app)
        let localSummary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch
        XCTAssertTrue(localSummary.waitForExistence(timeout: 30))
        let reference = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        for _ in 0..<3 where !reference.isHittable { app.swipeUp() }
        let chatShot = XCTAttachment(screenshot: app.screenshot()); chatShot.name = "06-chat-bubbles"; chatShot.lifetime = .keepAlways; add(chatShot)
        XCTAssertTrue(reference.exists); reference.tap()
        XCTAssertTrue(app.staticTexts["runResultsQuestion"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["runResultsQuestion"].label, "未来一周适合推进手头的计划吗？")
        XCTAssertTrue(app.staticTexts["六爻 / 周易筮法"].exists)
        XCTAssertTrue(app.staticTexts["本卦"].firstMatch.exists)
        let referenceShot = XCTAttachment(screenshot: app.screenshot()); referenceShot.name = "04-direct-reading-results"; referenceShot.lifetime = .keepAlways; add(referenceShot)
        app.buttons["closeRunResults"].tap()
        XCTAssertTrue(app.tabBars.buttons["对话"].isSelected)
        app.tabBars.buttons["数据"].tap()
        XCTAssertTrue(app.buttons["addProfile"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["localMethodsDirectory"].exists)
    }

    @MainActor func testHistoryRestoresPendingIntakeAndDeletionSurvivesRestart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        let question = "明天适合推进这个计划吗？"
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15)); input.tap(); input.typeText(question)
        app.buttons["sendQuestion"].tap()
        XCTAssertTrue(app.buttons["confirmIntake"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.matching(identifier: "intakeFormScroll").count, 1)
        cancelForm(in: app)
        XCTAssertTrue(app.buttons["openIntake"].exists)
        startNewConversation(app)
        app.buttons["historyButton"].tap()
        let row = historyRow(in: app, titled: question)
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.buttons["confirmIntake"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[question].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.buttons["confirmIntake"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[question].exists)
        cancelForm(in: app)
        app.buttons["historyButton"].tap()
        let restored = historyRow(in: app, titled: question)
        XCTAssertTrue(restored.waitForExistence(timeout: 10)); restored.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["deleteConversation"].firstMatch.waitForExistence(timeout: 10)); app.buttons["deleteConversation"].firstMatch.tap()
        XCTAssertTrue(app.buttons["confirmDeleteConversation"].firstMatch.waitForExistence(timeout: 10)); app.buttons["confirmDeleteConversation"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["往日问事，都会留在这里。"].waitForExistence(timeout: 10))
        app.buttons["closeHistory"].firstMatch.tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["historyButton"].waitForExistence(timeout: 15)); app.buttons["historyButton"].tap()
        XCTAssertFalse(historyRow(in: app, titled: question).exists)
        XCTAssertTrue(app.staticTexts["往日问事，都会留在这里。"].exists)
    }

    @MainActor func testEarlierReplyOpensItsOwnResultsAfterNewerConversation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset"]
        app.launch()
        let first = "本周适合整理手头的计划吗？"
        let second = "下周适合安排这次出行吗？"
        completeLocalQuestion(first, in: app)
        startNewConversation(app)
        completeLocalQuestion(second, in: app)
        app.buttons["historyButton"].tap()
        let old = historyRow(in: app, titled: first)
        XCTAssertTrue(old.waitForExistence(timeout: 10))
        let historyShot = XCTAttachment(screenshot: app.screenshot()); historyShot.name = "05-history-sidebar"; historyShot.lifetime = .keepAlways; add(historyShot)
        old.tap()
        let dataButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-")).firstMatch
        XCTAssertTrue(dataButton.waitForExistence(timeout: 10))
        for _ in 0..<4 where !dataButton.isHittable { app.swipeUp() }
        dataButton.tap()
        XCTAssertTrue(app.staticTexts["runResultsQuestion"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["runResultsQuestion"].label, first)
        XCTAssertFalse(app.staticTexts[second].exists)
    }

    @MainActor private func cancelForm(in app: XCUIApplication) {
        let cancel = app.buttons["cancelIntake"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(app.scrollViews["intakeFormScroll"].waitForNonExistence(timeout: 5))
    }
    @MainActor private func historyRow(in app: XCUIApplication, titled title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "historyRow-", title)).firstMatch
    }
    @MainActor private func startNewConversation(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["newConversationButton"].waitForExistence(timeout: 10))
        app.buttons["newConversationButton"].tap()
        XCTAssertTrue(app.buttons["confirmNewConversation"].firstMatch.waitForExistence(timeout: 10)); app.buttons["confirmNewConversation"].firstMatch.tap()
    }
    @MainActor private func completeLocalQuestion(_ question: String, in app: XCUIApplication) {
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15)); input.tap(); input.typeText(question)
        app.buttons["sendQuestion"].tap()
        let confirm = app.buttons["confirmIntake"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        for _ in 0..<24 where !confirm.isHittable { app.scrollViews["intakeFormScroll"].swipeUp() }
        XCTAssertTrue(confirm.isHittable); confirm.tap()
        completeCoinInteraction(in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "当前为本地试算")).firstMatch.waitForExistence(timeout: 30))
    }

    @MainActor private func completeCoinInteraction(in app: XCUIApplication) {
        let cast = app.buttons["castCoins"]
        XCTAssertTrue(cast.waitForExistence(timeout: 15))
        for _ in 0..<6 {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: cast)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            XCTAssertTrue(cast.isHittable)
            cast.tap()
        }
        let confirm = app.buttons["confirmInteraction"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
    }
}
