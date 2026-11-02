import XCTest

final class ReadingDeletionUITests: XCTestCase {
    @MainActor func testRecentTrashCancelsWithoutOpeningDetailsThenDeletesPermanently() throws {
        let app = launchLibraryFixture()
        let recent = record(titled: "推演删除测试10", in: app)
        XCTAssertTrue(recent.waitForExistence(timeout: 15))
        let removedID = try readingID(from: recent)
        let trash = app.buttons["deleteReading-" + removedID]
        XCTAssertTrue(trash.isHittable)
        XCTAssertGreaterThan(trash.frame.midX, recent.frame.midX)
        capture("reading-library-trash-icons", in: app)
        trash.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "cancelDeleteReading", "取消")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["原始推演"].exists)
        capture("reading-delete-confirmation", in: app)
        cancel.tap()
        XCTAssertTrue(app.buttons["readingRecord-" + removedID].exists)
        XCTAssertTrue(app.tabBars.buttons["数据"].isSelected)
        XCTAssertFalse(app.staticTexts["原始推演"].exists)

        trash.tap()
        confirmDeletion(in: app)
        waitUntilDeleted(removedID, in: app)
        XCTAssertTrue(record(titled: "推演删除测试9", in: app).exists)
        XCTAssertTrue(app.tabBars.buttons["数据"].isSelected)
        XCTAssertFalse(app.staticTexts["原始推演"].exists)

        relaunchSavedLibrary(app)
        XCTAssertFalse(app.buttons["readingRecord-" + removedID].exists)
        XCTAssertFalse(record(titled: "推演删除测试10", in: app).exists)
        XCTAssertTrue(record(titled: "推演删除测试9", in: app).waitForExistence(timeout: 10))
    }

    @MainActor func testAllReadingsTrashDeletesAnOlderRecordAndPersistsAcrossRelaunch() throws {
        let app = launchLibraryFixture()
        openAllReadings(in: app)
        let oldest = record(titled: "推演删除测试1", in: app)
        reveal(oldest, in: app)
        let removedID = try readingID(from: oldest)
        let trash = app.buttons["deleteReading-" + removedID]
        XCTAssertTrue(trash.isHittable)
        trash.tap()
        confirmDeletion(in: app)
        waitUntilDeleted(removedID, in: app)
        XCTAssertFalse(app.staticTexts["原始推演"].exists)
        XCTAssertTrue(record(titled: "推演删除测试2", in: app).exists)

        relaunchSavedLibrary(app)
        openAllReadings(in: app)
        let retained = record(titled: "推演删除测试2", in: app)
        reveal(retained, in: app)
        XCTAssertFalse(app.buttons["readingRecord-" + removedID].exists)
        XCTAssertFalse(record(titled: "推演删除测试1", in: app).exists)
        XCTAssertTrue(retained.exists)
    }

    @MainActor private func launchLibraryFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reading-library"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
        return app
    }

    @MainActor private func relaunchSavedLibrary(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["--ui-testing-local"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        app.tabBars.buttons["数据"].tap()
    }

    @MainActor private func record(titled question: String, in app: XCUIApplication) -> XCUIElement {
        let titlePattern = "(?s).*" + NSRegularExpression.escapedPattern(for: question) + "(?![0-9]).*"
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label MATCHES %@", "readingRecord-", titlePattern)).firstMatch
    }

    @MainActor private func readingID(from record: XCUIElement) throws -> String {
        let id = String(record.identifier.dropFirst("readingRecord-".count))
        XCTAssertNotNil(UUID(uuidString: id))
        return try XCTUnwrap(UUID(uuidString: id)).uuidString
    }

    @MainActor private func openAllReadings(in app: XCUIApplication) {
        let all = app.buttons["allReadings"]
        reveal(all, in: app)
        all.tap()
        XCTAssertTrue(record(titled: "推演删除测试9", in: app).waitForExistence(timeout: 10))
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<15 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func confirmDeletion(in app: XCUIApplication) {
        let confirm = app.buttons["confirmDeleteReading"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    @MainActor private func waitUntilDeleted(_ id: String, in app: XCUIApplication) {
        let removed = app.buttons["readingRecord-" + id]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: removed)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
