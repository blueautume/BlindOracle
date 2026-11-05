import XCTest

final class DataLibraryUITests: XCTestCase {
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
