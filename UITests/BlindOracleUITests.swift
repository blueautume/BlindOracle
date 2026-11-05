import XCTest

final class BlindOracleUITests: XCTestCase {
    @MainActor func testSettingsExposeNoModelProviderCredentialOrLocalModeControls() {
        for language in ["zh-Hans", "en"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "-oracle.appLanguage", language]
            app.launch()
            openSettings(in: app)
            let scroll = app.scrollViews["settingsScroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            let removedIDs = ["aiProviderPicker", "settingsAIConnectionStatus", "restoreProConnection",
                              "checkAIConnection", "connectionCheckReport", "connectionCheckFeedback"]
            let removedLabels = ["解读模型", "AI provider", "模型 ID", "Model ID", "输入 API 密钥", "Enter API key",
                                 "输入新密钥以替换", "Enter a replacement key", "仅本地试算", "Local calculations only"]
            for _ in 0..<5 {
                for identifier in removedIDs {
                    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists, identifier)
                }
                for label in removedLabels {
                    XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists, label)
                }
                XCTAssertEqual(app.secureTextFields.count, 0)
                scroll.swipeUp()
            }
            XCTAssertTrue(app.buttons["userAgreementLink"].exists)
            XCTAssertTrue(app.buttons["privacyPolicyLink"].exists)
            app.terminate()
        }
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

    @MainActor func testZiweiMarksChartSexRequiredWhileBaziAllowsItToBeUnknown() {
        for (method, requirement, explanation) in [("紫微", "必填", "紫微斗数需要这一项"), ("八字", "可选", "八字可留空")] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "-oracle.appLanguage", "zh-Hans"]
            app.launch()
            let input = app.textFields["questionInput"]
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            input.tap(); input.typeText("只用\(method)看看今年工作的方向")
            app.buttons["sendQuestion"].tap()
            let scroll = app.scrollViews["intakeFormScroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            let marker = app.staticTexts["profileGenderRequirement"].firstMatch
            for _ in 0..<20 where !marker.isHittable { scroll.swipeUp() }
            XCTAssertTrue(marker.exists)
            XCTAssertEqual(marker.label, requirement)
            XCTAssertTrue(app.staticTexts["profileGenderExplanation"].firstMatch.label.contains(explanation))
            XCTAssertEqual(app.buttons["profileGender"].firstMatch.value as? String, "未填写")
            let cancel = app.buttons["cancelPendingIntake"]
            XCTAssertTrue(cancel.exists)
            cancel.tap()
            XCTAssertTrue(scroll.waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.buttons["openIntake"].exists)
            app.terminate()
        }
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

    @MainActor func testSettingsLegalDocumentsScrollAndReturnInChineseAndEnglish() {
        for language in ["zh-Hans", "en"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing-local", "-oracle.appLanguage", language]
            app.launch()
            openSettings(in: app)
            let settings = app.scrollViews["settingsScroll"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            let documents = [
                (id: "userAgreementLink", title: language == "en" ? "User Agreement" : "用户协议"),
                (id: "privacyPolicyLink", title: language == "en" ? "Privacy Policy" : "隐私政策")
            ]
            for document in documents {
                let link = app.buttons[document.id]
                for _ in 0..<16 where !link.isHittable { settings.swipeUp() }
                XCTAssertTrue(link.isHittable, "\(language) \(document.title)")
                XCTAssertTrue(link.label.contains(document.title))
                link.tap()

                let scroll = app.scrollViews["legalDocumentScroll"]
                XCTAssertTrue(scroll.waitForExistence(timeout: 10))
                let navigation = app.navigationBars[document.title]
                XCTAssertTrue(navigation.exists)
                XCTAssertFalse(app.webViews.firstMatch.exists)
                let contact = scroll.descendants(matching: .any).matching(identifier: "legalDocumentContact").firstMatch
                scroll.swipeUp()
                for _ in 0..<20 where !contact.isHittable { scroll.swipeUp() }
                XCTAssertTrue(contact.isHittable, "\(language) \(document.title) contact section")
                let email = scroll.descendants(matching: .any).matching(identifier: "legalContactEmail").firstMatch
                XCTAssertTrue(email.exists)
                XCTAssertTrue(email.label.contains("2114581274@qq.com"))

                navigation.buttons.firstMatch.tap()
                XCTAssertTrue(scroll.waitForNonExistence(timeout: 5))
                XCTAssertTrue(settings.waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    @MainActor private func openSettings(in app: XCUIApplication) {
        // iPadOS exposes the floating tabs without a TabBar ancestor.
        let taggedData = app.buttons["dataTab"].firstMatch
        let data = taggedData.exists ? taggedData : app.buttons.matching(NSPredicate(format: "label IN %@", ["数据", "Data"])).firstMatch
        guard data.waitForExistence(timeout: 15) else { return XCTFail("Data tab was not shown") }
        data.tap()
        let taggedSettings = app.buttons["settingsButton"].firstMatch
        let settings = taggedSettings.exists ? taggedSettings : app.buttons.matching(NSPredicate(format: "label IN %@", ["设置", "Settings"])).firstMatch
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
    @MainActor func testTwoTabsAndReadingFlow() throws {
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
        let localSummary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这次推演已完成。")).firstMatch
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

    @MainActor func testClearAllHistoryRequiresConfirmationAndPersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "-oracle.appLanguage", "zh-Hans"]
        app.launch()
        let first = "只用八字看看今年换工作的方向"
        let current = "只用紫微看看下半年的工作机会"
        for question in [first, current] {
            let input = app.textFields["questionInput"]
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            input.tap(); input.typeText(question)
            app.buttons["sendQuestion"].tap()
            XCTAssertTrue(app.buttons["confirmIntake"].waitForExistence(timeout: 15))
            cancelForm(in: app)
            if question == first { startNewConversation(app) }
        }
        let input = app.textFields["questionInput"]
        input.tap(); input.typeText("尚未发送的聊天草稿")
        app.buttons["historyButton"].tap()
        XCTAssertTrue(historyRow(in: app, titled: first).waitForExistence(timeout: 5))
        XCTAssertTrue(historyRow(in: app, titled: current).exists)
        let clear = app.buttons["clearConversationHistory"]
        XCTAssertTrue(clear.exists)
        clear.tap()
        let cancel = app.buttons["cancelClearConversationHistory"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(historyRow(in: app, titled: first).exists)
        XCTAssertTrue(historyRow(in: app, titled: current).exists)
        app.buttons["closeHistory"].firstMatch.tap()
        XCTAssertTrue((input.value as? String)?.contains("尚未发送的聊天草稿") == true)

        app.buttons["historyButton"].tap()
        clear.tap()
        let confirm = app.buttons["confirmClearConversationHistory"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "conversationHistorySidebar").firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["openIntake"].exists)
        XCTAssertFalse(app.buttons["interactionCard"].exists)
        XCTAssertFalse((input.value as? String)?.contains("尚未发送的聊天草稿") ?? false)
        app.buttons["historyButton"].tap()
        XCTAssertTrue(app.staticTexts["往日问事，都会留在这里。"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "historyRow-")).count, 0)
        app.buttons["closeHistory"].firstMatch.tap()

        app.terminate()
        app.launchArguments = ["--ui-testing-local", "-oracle.appLanguage", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["historyButton"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["confirmIntake"].exists)
        XCTAssertFalse(app.buttons["openIntake"].exists)
        XCTAssertFalse(app.buttons["retryAnalysis"].exists)
        app.buttons["historyButton"].tap()
        XCTAssertTrue(app.staticTexts["往日问事，都会留在这里。"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "historyRow-")).count, 0)
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
        let button = app.buttons["newConversationButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let welcome = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["水墨绘制的瞎子", "Ink portrait of the Oracle"])).firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这次推演已完成。")).firstMatch.waitForExistence(timeout: 30))
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
