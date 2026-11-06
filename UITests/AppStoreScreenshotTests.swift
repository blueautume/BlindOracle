import XCTest

/// Captures the app's actual views with explicit example input. The DEBUG local
/// transport avoids live AI requests; no generated answer, test wallet, identity
/// fixture, or payment-success screen is used as a store screenshot.
final class AppStoreScreenshotTests: XCTestCase {
    @MainActor func testCaptureChineseStorefrontScreens() throws {
        try captureStorefront(language: "zh-Hans")
    }

    @MainActor func testCaptureEnglishStorefrontScreens() throws {
        try captureStorefront(language: "en")
    }

    @MainActor private func captureStorefront(language: String) throws {
        continueAfterFailure = false
        let isChinese = language == "zh-Hans"
        let locale = isChinese ? "zh-Hans" : "en-US"

        let chat = launch(language: language)
        let input = chat.textFields["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        capture("appstore-\(locale)-01-question", app: chat)
        input.tap()
        input.typeText(isChinese
            ? "示例：只用塔罗，怎样安排下周的学习计划？"
            : "Example: Use only tarot. How can I organize next week's study?")
        chat.buttons["sendQuestion"].tap()
        acceptExplicitAISharing(in: chat, locale: locale)
        let form = chat.scrollViews["intakeFormScroll"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        capture("appstore-\(locale)-02-reading-form", app: chat)
        let confirm = chat.buttons["confirmIntake"]
        reveal(confirm, in: form)
        confirm.tap()
        let shuffle = chat.buttons["shuffleTarot"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 15))
        shuffle.tap()
        XCTAssertTrue(chat.buttons["tarotCard-0"].waitForExistence(timeout: 10))
        chat.buttons["tarotCard-0"].tap()
        chat.buttons["tarotCard-1"].tap()
        capture("appstore-\(locale)-03-tarot-selection", app: chat)
        // Stop before the last card/reveal can trigger a synthetic AI answer.
        chat.terminate()

        let methods = launch(language: language)
        openData(in: methods, isChinese: isChinese)
        let directory = methods.buttons["localMethodsDirectory"]
        XCTAssertTrue(directory.waitForExistence(timeout: 10))
        for _ in 0..<5 where !directory.isHittable { methods.swipeUp() }
        XCTAssertTrue(directory.isHittable); directory.tap()
        XCTAssertTrue(methods.buttons["localMethod-bazi"].waitForExistence(timeout: 10))
        capture("appstore-\(locale)-04-method-directory", app: methods)
        methods.terminate()

        let profile = launch(language: language)
        let editor: XCUIElement
        if profile.frame.width > 700 {
            // iPad presents editors in a centered sheet. Enter through Chat
            // so its background cannot expose the DEBUG account fixture.
            let question = profile.textFields["questionInput"]
            XCTAssertTrue(question.waitForExistence(timeout: 15))
            question.tap()
            question.typeText(isChinese
                ? "示例：只用八字看看学习计划。"
                : "Example: Use only BaZi to reflect on a study plan.")
            profile.buttons["sendQuestion"].tap()
            acceptExplicitAISharing(in: profile, locale: locale, captureEvidence: false)
            editor = profile.scrollViews["intakeFormScroll"]
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            if !profile.textFields["profileAlias"].exists {
                let addPerson = profile.buttons["addParticipant"]
                reveal(addPerson, in: editor); addPerson.tap()
            }
        } else {
            openData(in: profile, isChinese: isChinese)
            let addProfile = profile.buttons["addProfile"]
            XCTAssertTrue(addProfile.waitForExistence(timeout: 10)); addProfile.tap()
            editor = profile.scrollViews["profileEditorScroll"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
        }
        let alias = profile.textFields["profileAlias"]
        XCTAssertTrue(alias.waitForExistence(timeout: 10))
        reveal(alias, in: editor)
        alias.tap(); alias.typeText(isChinese ? "示例人物\n" : "Example profile\n")
        for identifier in ["profileBirthDate", "profileBirthTime"] {
            let field = profile.buttons[identifier]
            reveal(field, in: editor); field.tap()
            let confirmClock = profile.buttons["confirmBirthClock"]
            if !confirmClock.waitForExistence(timeout: 3) {
                // On iPad the first tap can dismiss the keyboard/popover
                // instead of opening the date control. Tap the real field
                // once more; still require its native confirmation page.
                field.tap()
            }
            XCTAssertTrue(confirmClock.waitForExistence(timeout: 10)); confirmClock.tap()
            XCTAssertTrue(confirmClock.waitForNonExistence(timeout: 5))
        }
        let birthplace = profile.buttons["profileBirthPlace"]
        reveal(birthplace, in: editor); birthplace.tap()
        for identifier in ["chinaDistrict-110000", "chinaDistrict-110101"] {
            let district = profile.buttons[identifier]
            XCTAssertTrue(district.waitForExistence(timeout: 10)); district.tap()
        }
        let preview = profile.descendants(matching: .any).matching(identifier: "profileBaziPreview").firstMatch
        reveal(preview, in: editor)
        let fourPillars = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value MATCHES %@", ".*([甲乙丙丁戊己庚辛壬癸][子丑寅卯辰巳午未申酉戌亥].*){4}"),
            object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [fourPillars], timeout: 10), .completed)
        capture("appstore-\(locale)-05-local-bazi-preview", app: profile)
        profile.terminate()
    }

    @MainActor private func launch(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-local", "--ui-testing-reset", "--ui-testing-reset-language",
                               "--ui-testing-ai-consent-required", "--ui-testing-ai-consent-reset",
                               "--ui-testing-ai-consent-suite", "screenshots48",
                               "-oracle.appLanguage", language]
        app.launch()
        return app
    }

    @MainActor private func openData(in app: XCUIApplication, isChinese: Bool) {
        // iPadOS exposes its top tab outside XCUIElementTypeTabBar.
        let identified = app.descendants(matching: .any).matching(identifier: "dataTab").firstMatch
        let tab = identified.waitForExistence(timeout: 2) ? identified : app.buttons[isChinese ? "数据" : "Data"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        XCTAssertTrue(tab.isHittable); tab.tap()
    }

    @MainActor private func acceptExplicitAISharing(in app: XCUIApplication, locale: String, captureEvidence: Bool = true) {
        // Require and accept the real disclosure through its visible UI.
        // No consent preference is injected by the screenshot harness.
        let allow = app.buttons["agreeAIDataSharing"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        if captureEvidence { capture("review-only-\(locale)-ai-sharing-disclosure", app: app) }
        let disclosure = app.scrollViews["aiDataSharingScroll"]
        for _ in 0..<8 where !allow.isHittable {
            if disclosure.exists { disclosure.swipeUp() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(allow.isHittable)
        allow.tap()
    }

    @MainActor private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<20 {
            if element.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
