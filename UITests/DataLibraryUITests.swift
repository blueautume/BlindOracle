import XCTest

final class DataLibraryUITests: XCTestCase {
    @MainActor func testCastingModeDefaultsAppearOnlyInTheirMethodDetails() {
        let app = castingPreferencesApp()
        app.launch()
        openMethod("meihua", in: app)
        XCTAssertTrue(app.buttons["meihuaMode-time"].isSelected)
        XCTAssertFalse(app.buttons["meihuaMode-twoNumbers"].isSelected)
        XCTAssertFalse(app.buttons["meihuaMode-threeNumbers"].isSelected)
        XCTAssertFalse(app.buttons["liuyaoMode-coins"].exists)
        capture("meihua-default-time-mode", in: app)

        returnToMethodDirectory(in: app)
        openMethod("liuyao", in: app)
        XCTAssertTrue(app.buttons["liuyaoMode-coins"].isSelected)
        XCTAssertFalse(app.buttons["liuyaoMode-yarrow"].isSelected)
        XCTAssertFalse(app.buttons["liuyaoMode-manual"].isSelected)
        XCTAssertFalse(app.buttons["meihuaMode-time"].exists)
        capture("liuyao-default-coins-mode", in: app)

        returnToMethodDirectory(in: app)
        openMethod("xingming", in: app)
        XCTAssertTrue(app.staticTexts["所需资料"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meihuaMode-")).count, 0)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "liuyaoMode-")).count, 0)
        capture("casting-preferences-absent-from-name-method", in: app)
    }

    @MainActor func testCastingModeChoicesPersistAcrossApplicationRestart() {
        let app = castingPreferencesApp()
        app.launch()
        openMethod("meihua", in: app)
        tapMode("meihuaMode-twoNumbers", in: app)
        XCTAssertTrue(app.buttons["meihuaMode-twoNumbers"].isSelected)
        returnToMethodDirectory(in: app)
        openMethod("liuyao", in: app)
        tapMode("liuyaoMode-manual", in: app)
        XCTAssertTrue(app.buttons["liuyaoMode-manual"].isSelected)
        capture("casting-mode-selections-before-restart", in: app)

        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-testing-reset" }
        app.launch()
        openMethod("meihua", in: app)
        XCTAssertTrue(app.buttons["meihuaMode-twoNumbers"].isSelected)
        XCTAssertFalse(app.buttons["meihuaMode-time"].isSelected)
        returnToMethodDirectory(in: app)
        openMethod("liuyao", in: app)
        XCTAssertTrue(app.buttons["liuyaoMode-manual"].isSelected)
        XCTAssertFalse(app.buttons["liuyaoMode-coins"].isSelected)
        capture("casting-mode-selections-after-restart", in: app)
    }

    @MainActor func testArchivedConflictDetailsRemainStaticBodyTextWithoutPreferenceChoices() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reading-library",
                               "--ui-testing-archived-conflicts", "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans"]
        app.launch()
        openDataTab(in: app)
        XCTAssertTrue(app.staticTexts["留存资料"].exists)
        XCTAssertTrue(app.buttons["localMethodsDirectory"].exists)
        openChatTab(in: app)

        let transcript = app.scrollViews["chatTranscript"]
        let archived = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "archivedConflictDetails-")).firstMatch
        for _ in 0..<12 {
            if archived.exists && archived.isHittable { break }
            transcript.swipeUp()
        }
        XCTAssertTrue(archived.exists)
        XCTAssertTrue(archived.isHittable)
        XCTAssertEqual(archived.label, "原记录分歧：一处倾向先推进，另一处倾向先核对条件。")
        XCTAssertEqual(archived.elementType, .staticText)
        XCTAssertTrue(app.staticTexts["第10份测试解读。"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "原记录分歧")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["两种处境，哪一种更贴近你？"].exists)
        XCTAssertFalse(app.staticTexts["只作细微调整，慢慢认识你的处境。"].exists)
        XCTAssertFalse(app.staticTexts["已记下这次选择。"].exists)
        capture("archived-reading-conflict-as-body-text", in: app)
    }

    @MainActor func testSwipingAProfileDeletesItImmediatelyAndKeepsOtherProfilesAndReadingSnapshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reading-library",
                               "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans"]
        app.launch()
        openDataTab(in: app)
        let deletedRow = profileRow("陈平", in: app)
        XCTAssertTrue(deletedRow.waitForExistence(timeout: 15))
        let deletedID = deletedRow.identifier
        let deleteID = deletedID.replacingOccurrences(of: "profileRow-", with: "deleteProfile-")

        // Create a second person through the normal chat path so deleting the
        // fixture person must not clear the whole directory or its old runs.
        openChatTab(in: app)
        let input = app.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("姓名：李岚，女，出生日期1995-03-11。")
        app.buttons["sendQuestion"].tap()
        openDataTab(in: app)
        let remaining = profileRow("李岚", in: app)
        XCTAssertTrue(remaining.waitForExistence(timeout: 15))
        let remainingID = remaining.identifier
        XCTAssertEqual(profileRows(in: app).count, 2)
        XCTAssertFalse(app.buttons[deleteID].exists)
        XCTAssertFalse(app.buttons["confirmDeleteProfile"].exists)
        capture("saved-profiles-without-inline-delete", in: app)

        // A partial left swipe reveals the native action without triggering
        // full-swipe deletion, so the visible Delete button can be exercised.
        let start = deletedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.5))
        let end = deletedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let delete = app.buttons[deleteID]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(delete.isHittable)
        capture("saved-profile-left-swipe-delete", in: app)
        delete.tap()

        XCTAssertTrue(app.buttons[deletedID].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertFalse(app.buttons["confirmDeleteProfile"].exists)
        XCTAssertTrue(app.buttons[remainingID].exists)
        XCTAssertEqual(profileRows(in: app).count, 1)
        capture("saved-profile-deleted-without-confirmation", in: app)

        app.terminate()
        app.launchArguments.removeAll { ["--ui-testing-reset", "--ui-testing-reading-library"].contains($0) }
        app.launch()
        openDataTab(in: app)
        XCTAssertTrue(app.buttons[remainingID].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons[deletedID].exists)
        XCTAssertEqual(profileRows(in: app).count, 1)
        app.buttons[remainingID].tap()
        let alias = app.textFields["profileAlias"]
        XCTAssertTrue(alias.waitForExistence(timeout: 10))
        let savedName = app.descendants(matching: .any).matching(identifier: "legacyProfileName").firstMatch
        let nameContents = [savedName.label, savedName.value as? String ?? ""]
            + savedName.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(nameContents.joined(separator: " ").contains("李岚"))
        XCTAssertTrue(alias.isEnabled)
        app.buttons["稍后填写"].tap()
        XCTAssertTrue(alias.waitForNonExistence(timeout: 5))

        openChatTab(in: app)
        let references = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-"))
        XCTAssertTrue(references.firstMatch.waitForExistence(timeout: 10))
        let latestReference = try XCTUnwrap(references.allElementsBoundByIndex.last)
        for _ in 0..<6 where !latestReference.isHittable { app.scrollViews["chatTranscript"].swipeUp() }
        XCTAssertTrue(latestReference.isHittable)
        latestReference.tap()
        let question = app.staticTexts["runResultsQuestion"]
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        XCTAssertEqual(question.label, "推演删除测试10")
        XCTAssertTrue(app.staticTexts["测试编号"].exists)
        capture("old-reading-remains-after-profile-deletion", in: app)
    }

    @MainActor func testDataTabOmitsStoredReadingsAndChatStillOpensThem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reading-library"]
        app.launch()
        openDataTab(in: app)

        XCTAssertTrue(app.staticTexts["留存资料"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["陈平"].exists)
        XCTAssertFalse(app.staticTexts["推演记录"].exists)
        XCTAssertFalse(app.buttons["allReadings"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingRecord-")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["解读偏好"].exists)
        XCTAssertFalse(app.staticTexts["原始结果按方法单独留存，此处不做合并。"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "compact-data-library"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let methods = app.buttons["localMethodsDirectory"]
        XCTAssertTrue(methods.isHittable)
        methods.tap()
        let method = app.buttons["localMethod-bazi"]
        XCTAssertTrue(method.waitForExistence(timeout: 10))
        method.tap()
        XCTAssertTrue(app.staticTexts["所需资料"].waitForExistence(timeout: 10))

        openChatTab(in: app)
        let references = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readingData-"))
        XCTAssertTrue(references.firstMatch.waitForExistence(timeout: 10))
        let lastReference = try XCTUnwrap(references.allElementsBoundByIndex.last)
        for _ in 0..<4 where !lastReference.isHittable { app.scrollViews["chatTranscript"].swipeUp() }
        XCTAssertTrue(lastReference.isHittable)
        lastReference.tap()
        let question = app.staticTexts["runResultsQuestion"]
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        XCTAssertEqual(question.label, "推演删除测试10")
        XCTAssertTrue(app.staticTexts["测试编号"].exists)
    }

    @MainActor private func openDataTab(in app: XCUIApplication) {
        let identified = app.buttons.matching(identifier: "dataTab").firstMatch
        let tab = identified.waitForExistence(timeout: 2) ? identified : app.buttons["数据"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
        XCTAssertTrue(app.buttons["addProfile"].waitForExistence(timeout: 10))
    }

    @MainActor private func castingPreferencesApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reset-language",
                               "-oracle.appLanguage", "zh-Hans"]
        return app
    }

    @MainActor private func openMethod(_ method: String, in app: XCUIApplication) {
        let row = app.buttons["localMethod-\(method)"]
        if !row.exists {
            openDataTab(in: app)
            let directory = app.buttons["localMethodsDirectory"]
            XCTAssertTrue(directory.waitForExistence(timeout: 10))
            for _ in 0..<6 where !directory.isHittable { app.swipeUp() }
            XCTAssertTrue(directory.isHittable); directory.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.staticTexts["所需资料"].waitForExistence(timeout: 10))
    }

    @MainActor private func returnToMethodDirectory(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.exists); back.tap()
        XCTAssertTrue(app.buttons["localMethod-bazi"].waitForExistence(timeout: 10))
    }

    @MainActor private func tapMode(_ identifier: String, in app: XCUIApplication) {
        let option = app.buttons[identifier]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        for _ in 0..<6 where !option.isHittable { app.swipeUp() }
        XCTAssertTrue(option.isHittable); option.tap()
    }

    @MainActor private func openChatTab(in app: XCUIApplication) {
        let tab = app.buttons["对话"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
        XCTAssertTrue(app.textFields["questionInput"].waitForExistence(timeout: 10))
    }

    @MainActor private func profileRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profileRow-"))
    }

    @MainActor private func profileRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        profileRows(in: app).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
