import XCTest

final class AccountUITests: XCTestCase {
    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset-language", "-oracle.appLanguage", "zh-Hans"] + extra
        app.launch()
        return app
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func openDeletion(in app: XCUIApplication) {
        let data = app.tabBars.buttons["数据"]
        XCTAssertTrue(data.waitForExistence(timeout: 10)); data.tap()
        app.buttons["accountEntry"].tap()
        let deletion = app.buttons["deleteAccount"]
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        reveal(deletion, app: app)
        deletion.tap()
        XCTAssertTrue(app.buttons["cancelAccountDeletion"].waitForExistence(timeout: 5))
    }

    @MainActor func testDataShowsAppleIdentityAndOnlyAllowancePercentageBeforeOpeningAccountDetails() {
        let app = launch(["--ui-testing-reset", "--ui-testing-reading-library"])
        let data = app.tabBars.buttons["数据"]
        XCTAssertTrue(data.waitForExistence(timeout: 15)); data.tap()

        let summary = element("accountSummary", in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        // SwiftUI propagates this container identifier to its visible label
        // nodes; inspect all labels rather than whichever child sorts first.
        let summaryLabel = app.descendants(matching: .any).matching(identifier: "accountSummary")
            .allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(summaryLabel.contains("测试账号"), summaryLabel)
        XCTAssertTrue(summaryLabel.contains("tester@example.com"), summaryLabel)
        XCTAssertTrue(summaryLabel.contains("Apple"), summaryLabel)
        XCTAssertTrue(summaryLabel.contains("100%"), summaryLabel)
        for hidden in ["token", "积分", "请求数", "累计", "1400", "1600"] {
            XCTAssertFalse(summaryLabel.lowercased().contains(hidden.lowercased()), summaryLabel)
        }
        XCTAssertFalse(app.staticTexts["账号、余额与用量"].exists)
        XCTAssertFalse(app.buttons["账号、余额与用量"].exists)
        capture("data-apple-account-summary", app: app)

        let profile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profileRow-")).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        let profileID = profile.identifier
        let entry = app.buttons["accountEntry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        XCTAssertTrue(app.buttons["logoutAccount"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["本机资料独立保存"].exists)
        XCTAssertTrue(app.buttons["deleteAccount"].exists)
        capture("account-details", app: app)
        let logoutFrame = app.buttons["logoutAccount"].frame
        let deletion = app.buttons["deleteAccount"]
        XCTAssertGreaterThan(deletion.frame.minY - logoutFrame.maxY, 100)
        reveal(deletion, app: app)
        capture("account-separated-actions", app: app)
        deletion.tap()
        XCTAssertTrue(app.staticTexts["已购额度无法恢复"].waitForExistence(timeout: 5))
        #if BLINDORACLE_SANDBOX
        reveal(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Apple 授权保留")).firstMatch, app: app)
        #else
        reveal(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "撤销已知 Apple 登录授权")).firstMatch, app: app)
        #endif
        app.buttons["cancelAccountDeletion"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons[profileID].waitForExistence(timeout: 5))
    }

    @MainActor func testDeletionRequiresExactAccountConfirmationAndCancellationKeepsRecords() {
        let app = launch(["--ui-testing-reset", "--ui-testing-reading-library"])
        openDeletion(in: app)
        let phrase = app.staticTexts["deletionConfirmationPhrase"]
        XCTAssertTrue(phrase.label.hasPrefix("我确认永久注销测试账号"))
        let confirmation = app.buttons["confirmPermanentDeletion"]
        XCTAssertFalse(confirmation.isEnabled)
        let input = app.textFields["deletionConfirmationInput"].exists
            ? app.textFields["deletionConfirmationInput"] : app.textViews["deletionConfirmationInput"]
        reveal(input, app: app)
        input.tap(); input.typeText("取消")
        XCTAssertFalse(confirmation.isEnabled)
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        input.typeText(phrase.label + "x")
        XCTAssertFalse(confirmation.isEnabled, "A different account or extra character must not confirm deletion")
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(confirmation.isEnabled)
        app.swipeUp()
        capture("account-deletion-typed-confirmation", app: app)
        app.buttons["cancelAccountDeletion"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profileRow-")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testDeletionConfirmationCanBeCopiedAndPastedBeforeSyntheticDeletion() {
        let app = launch(["--ui-testing-reset", "--ui-testing-reading-library"])
        openDeletion(in: app)
        capture("account-deletion-consequences", app: app)
        let copy = app.buttons["copyDeletionConfirmation"]
        reveal(copy, app: app); copy.tap()
        XCTAssertTrue(copy.label.contains("已复制"))
        let input = app.textFields["deletionConfirmationInput"].exists
            ? app.textFields["deletionConfirmationInput"] : app.textViews["deletionConfirmationInput"]
        reveal(input, app: app)
        input.tap(); input.press(forDuration: 1.2)
        let pastePredicate = NSPredicate(format: "label IN %@", ["粘贴", "Paste"])
        let menuPaste = app.menuItems.matching(pastePredicate).firstMatch
        let paste = menuPaste.exists ? menuPaste : app.buttons.matching(pastePredicate).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        let confirmation = app.buttons["confirmPermanentDeletion"]
        XCTAssertTrue(confirmation.isEnabled)
        app.swipeUp(); reveal(confirmation, app: app)
        capture("account-deletion-pasted-confirmation", app: app)
        // --ui-testing-local uses a synthetic server result; never deletes a real account.
        confirmation.tap()
        XCTAssertTrue(app.buttons["appleSignInButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        capture("account-deletion-completed-gate", app: app)
    }

    @MainActor func testSignedOutLaunchCannotReachTabsDataOrSettingsButCanReadPrivacy() {
        let app = launch(["--ui-testing-auth-signed-out"])
        XCTAssertTrue(app.buttons["appleSignInButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("accountGate", in: app).exists)
        XCTAssertFalse(element("accountLaunchScreen", in: app).exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.textFields["questionInput"].exists)
        XCTAssertFalse(app.buttons["settingsButton"].exists)
        XCTAssertFalse(app.buttons["accountEntry"].exists)
        XCTAssertTrue(app.buttons["gateUserAgreement"].exists)
        capture("apple-sign-in-page", app: app)
        app.buttons["gatePrivacyPolicy"].tap()
        XCTAssertTrue(app.staticTexts["隐私政策"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        capture("login-gate-privacy", app: app)
    }
    @MainActor func testCompactEnvironmentBadgeCannotBeChangedByPreferences() {
        let app = launch(["--ui-testing-auth-signed-out", "-BLINDORACLE_SANDBOX", "YES"])
        XCTAssertTrue(app.buttons["appleSignInButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("serviceEnvironmentNotice", in: app).exists)
        XCTAssertFalse(app.staticTexts["测试环境 · 购买不扣款"].exists)
        #if BLINDORACLE_SANDBOX
        XCTAssertTrue(element("serviceEnvironmentBadge", in: app).exists)
        XCTAssertEqual(element("serviceEnvironmentBadge", in: app).label, "测试")
        XCTAssertTrue(app.staticTexts["请用你之前的 Apple 账号登录。沙盒测试账号仅用于系统购买。"].exists)
        #else
        XCTAssertFalse(element("serviceEnvironmentBadge", in: app).exists, "Preferences must not switch a production build to sandbox")
        #endif
        capture("build-environment-login", app: app)
    }

    @MainActor func testCompactEnvironmentBadgeSharesTheChatTitleRow() {
        let app = launch()
        let title = app.staticTexts["chatTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertFalse(element("serviceEnvironmentNotice", in: app).exists)
        #if BLINDORACLE_SANDBOX
        let badge = element("serviceEnvironmentBadge", in: app)
        XCTAssertTrue(badge.exists)
        XCTAssertEqual(badge.label, "测试")
        XCTAssertGreaterThanOrEqual(badge.frame.minX, title.frame.maxX)
        XCTAssertLessThan(abs(badge.frame.midY - title.frame.midY), 10)
        #else
        XCTAssertFalse(element("serviceEnvironmentBadge", in: app).exists)
        #endif
        capture("compact-chat-environment-badge", app: app)
    }

    @MainActor func testSavedSessionRestoresThroughDedicatedLaunchScreenWithoutShowingSignIn() {
        let app = launch(["--ui-testing-auth-restoring"])
        let launchScreen = element("accountLaunchScreen", in: app)
        XCTAssertTrue(launchScreen.waitForExistence(timeout: 5))
        capture("saved-session-launch-screen", app: app)
        XCTAssertFalse(app.buttons["appleSignInButton"].exists)
        XCTAssertFalse(element("accountGate", in: app).exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 15))
        XCTAssertFalse(launchScreen.exists)
        XCTAssertFalse(app.buttons["appleSignInButton"].exists)
    }

    @MainActor func testLogoutFromSettingsImmediatelyReturnsToGateAndDismissesSettings() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["数据"].waitForExistence(timeout: 10)); app.tabBars.buttons["数据"].tap()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["settingsAccountEntry"].waitForExistence(timeout: 5))
        app.buttons["settingsAccountEntry"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        let logout = app.buttons["logoutAccount"]
        XCTAssertTrue(logout.waitForExistence(timeout: 5))
        logout.tap()
        app.alerts.buttons["退出"].tap()
        XCTAssertTrue(app.buttons["appleSignInButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.scrollViews["settingsScroll"].exists)
        XCTAssertFalse(app.buttons["settingsAccountEntry"].exists)
        capture("logout-login-gate", app: app)
    }
}
