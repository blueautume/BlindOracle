import XCTest
@testable import BlindOracle

final class OracleInteractionTests: XCTestCase {
    private func plan(methods: [OracleMethod] = [.tarot, .liuyao, .meihua],
                      interactions: [OracleInteractionRequest]? = nil) -> OraclePlan {
        OraclePlan(intent: "具体问事", subject: "本人", methods: methods, requiredFields: [],
                   note: "请完成这次交互。", question: "下一阶段如何安排？", interactions: interactions)
    }

    private func session(_ requests: [OracleInteractionRequest]) -> OracleInteractionSession {
        let plan = plan(methods: requests.map(\.method), interactions: requests)
        return OracleInteractionSession(input: OracleInput(question: plan.question, profile: OracleProfile(), seed: 42),
                                        plan: plan, requests: requests)
    }

    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("interaction-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    private func draws() -> [TarotDraw] {
        zip(["major-00", "cups-01", "swords-14"], TarotDeck.positions).enumerated().map { index, value in
            TarotDraw(cardID: value.0, isReversed: index == 1, position: value.1)
        }
    }

    @MainActor private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isBusy, "本地计算或解读未按时完成")
    }

    private func removing(_ keys: [String], from value: some Encodable) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in keys { object.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testCastingPreferencesUseSafeDefaultsAndDecodeSavedChoices() throws {
        let suite = "casting-preferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CastingMethodPreferences.meihua(in: defaults), .time)
        XCTAssertEqual(CastingMethodPreferences.liuyao(in: defaults), .coins)
        defaults.set("unknown", forKey: CastingMethodPreferences.meihuaKey)
        defaults.set("unknown", forKey: CastingMethodPreferences.liuyaoKey)
        XCTAssertEqual(CastingMethodPreferences.meihua(in: defaults), .time)
        XCTAssertEqual(CastingMethodPreferences.liuyao(in: defaults), .coins)
        for mode in MeihuaCastingMode.allCases {
            defaults.set(mode.rawValue, forKey: CastingMethodPreferences.meihuaKey)
            XCTAssertEqual(CastingMethodPreferences.meihua(in: defaults), mode)
        }
        for mode in LiuyaoCastingMode.allCases {
            defaults.set(mode.rawValue, forKey: CastingMethodPreferences.liuyaoKey)
            XCTAssertEqual(CastingMethodPreferences.liuyao(in: defaults), mode)
        }
    }

    func testFrozenTimeModeIgnoresAIRequestedNumbersAndStillNeedsCastingPlace() {
        var selected = plan(methods: [.meihua], interactions: [.init(method: .meihua, kind: .numbers)])
        selected.requiredFields = [.numbers]
        selected.meihuaCastingMode = .time
        for numbers in [[], [8], [8, 8], [8, 8, 6], [0, 8, 6]] {
            XCTAssertTrue(OracleInteractionPolicy.requests(for: selected, numbers: numbers).isEmpty)
            XCTAssertTrue(ReadingPreparationPolicy.requiresCastingLocation(plan: selected, method: .meihua, numbers: numbers))
        }
    }

    func testFrozenNumberModesRequireTheirExactCountAndReplaceAIRequests() throws {
        for mode in [MeihuaCastingMode.twoNumbers, .threeNumbers] {
            var selected = plan(methods: [.meihua], interactions: [
                .init(method: .meihua, kind: .numbers, prompt: "模型指定的其他取数方式", numberCount: mode == .twoNumbers ? 3 : 2)
            ])
            selected.meihuaCastingMode = mode
            let count = try XCTUnwrap(mode.numberCount)
            let request = try XCTUnwrap(OracleInteractionPolicy.requests(for: selected).first)
            XCTAssertEqual(request.requiredNumberCount, count)
            XCTAssertEqual(request.prompt, OracleInteractionRequest(method: .meihua, kind: .numbers, numberCount: count).prompt)
            let valid = Array(repeating: 8, count: count)
            XCTAssertTrue(OracleInteractionPolicy.requests(for: selected, numbers: valid).isEmpty)
            for invalid in [Array(valid.dropLast()), valid + [6], Array(repeating: 0, count: count)] {
                XCTAssertEqual(OracleInteractionPolicy.requests(for: selected, numbers: invalid).first?.requiredNumberCount, count)
            }
            XCTAssertEqual(ReadingPreparationPolicy.requiresCastingLocation(plan: selected, method: .meihua, numbers: []), mode == .twoNumbers)
            XCTAssertEqual(ReadingPreparationPolicy.requiresCastingLocation(plan: selected, method: .meihua, numbers: valid), mode == .twoNumbers)
        }
    }

    func testCastingPreferencesDoNotAddUnselectedMethodsAndFrozenLiuyaoModeOverridesAI() throws {
        var unrelated = plan(methods: [.bazi])
        unrelated.meihuaCastingMode = .twoNumbers
        unrelated.liuyaoCastingMode = .manual
        XCTAssertTrue(OracleInteractionPolicy.requests(for: unrelated).isEmpty)
        var selected = plan(methods: [.liuyao], interactions: [.init(method: .liuyao, kind: .coins, liuyaoCastingMode: .manual)])
        selected.liuyaoCastingMode = .yarrow
        let request = try XCTUnwrap(OracleInteractionPolicy.requests(for: selected).first)
        XCTAssertEqual(request.liuyaoCastingMode, .yarrow)
        XCTAssertEqual(request.kind, .coins)
        selected.liuyaoCastingMode = nil
        XCTAssertNil(OracleInteractionPolicy.requests(for: selected).first?.liuyaoCastingMode)
    }

    func testLegacyRequestsAndPlansDecodeWithoutNewCastingFields() throws {
        let request = OracleInteractionRequest(method: .meihua, kind: .numbers)
        let restored = try JSONDecoder().decode(OracleInteractionRequest.self,
            from: removing(["numberCount", "liuyaoCastingMode"], from: request))
        XCTAssertNil(restored.numberCount)
        XCTAssertNil(restored.liuyaoCastingMode)
        XCTAssertEqual(restored.requiredNumberCount, 3)
        var old = plan(methods: [.meihua], interactions: [restored])
        old.meihuaCastingMode = .twoNumbers
        old.liuyaoCastingMode = .manual
        let restoredPlan = try JSONDecoder().decode(OraclePlan.self,
            from: removing(["meihuaCastingMode", "liuyaoCastingMode"], from: old))
        XCTAssertNil(restoredPlan.meihuaCastingMode)
        XCTAssertNil(restoredPlan.liuyaoCastingMode)
        XCTAssertEqual(OracleInteractionPolicy.requests(for: restoredPlan).first?.requiredNumberCount, 3)
    }

    func testTwoNumberDraftRestoresIncompleteEditsAndCompletesOnlyAnExactPair() throws {
        let request = OracleInteractionRequest(method: .meihua, kind: .numbers, numberCount: 2)
        var pending = session([request])
        let partial = OracleInteractionResponse(requestID: request.id, numberTexts: ["008", ""])
        XCTAssertTrue(pending.saveProgress(partial))
        XCTAssertFalse(pending.complete(partial))
        var restored = try JSONDecoder().decode(OracleInteractionSession.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(restored.currentRequest?.requiredNumberCount, 2)
        XCTAssertEqual(NumberInteractionDraft.texts(for: try XCTUnwrap(restored.draft), count: 2), ["008", ""])
        XCTAssertNil(NumberInteractionDraft.values(in: ["008", ""], count: 2))
        XCTAssertEqual(NumberInteractionDraft.values(in: ["008", " 9 "], count: 2), [8, 9])
        XCTAssertFalse(restored.complete(.init(requestID: request.id, numbers: [8, 9, 6])))
        XCTAssertFalse(restored.saveProgress(.init(requestID: request.id, numberTexts: ["8", "9", ""])))
        XCTAssertFalse(restored.complete(.init(requestID: request.id, numbers: [8, 6], numberTexts: ["8", "9"])))
        let corrected = OracleInteractionResponse(requestID: request.id, numbers: [8, 9], numberTexts: ["008", " 9 "])
        XCTAssertTrue(restored.complete(corrected))
        XCTAssertEqual(restored.input.numbers, [8, 9])
        XCTAssertEqual(restored.input.interactionResponses, [corrected])
        XCTAssertNil(restored.currentRequest)
    }

    func testPhysicalCoinDraftCanBeCorrectedAfterRestoringAndKeepsItsSource() async throws {
        let request = OracleInteractionRequest(method: .liuyao, kind: .coins, liuyaoCastingMode: .manual)
        var pending = session([request])
        let partial = OracleInteractionResponse(requestID: request.id, lines: [6, 7, 8])
        XCTAssertTrue(pending.saveProgress(partial))
        XCTAssertFalse(pending.complete(partial))
        var restored = try JSONDecoder().decode(OracleInteractionSession.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(restored.currentRequest?.liuyaoCastingMode, .manual)
        var corrected = try XCTUnwrap(restored.draft)
        corrected.lines[1] = 9
        corrected.lines += [9, 7, 6]
        XCTAssertTrue(restored.complete(corrected))
        XCTAssertEqual(restored.input.manualLines, [6, 9, 8, 9, 7, 6])
        XCTAssertEqual(restored.input.castingStyle, "manual")
        let result = try await LiuyaoPlugin().calculate(restored.input)
        XCTAssertEqual(result.rows.first?.value, L10n.text("用户实体铜钱投掷录入 · 初爻至上爻", "User-entered physical coin tosses · bottom to top"))
        XCTAssertEqual(result.rows.dropFirst().first?.value, "6 9 8 9 7 6")
    }

    func testPhysicalCoinModeNeverGeneratesMissingLines() async throws {
        var input = OracleInput(question: "实体投掷", profile: OracleProfile(), seed: 42, castingStyle: "manual")
        let empty = try await LiuyaoPlugin().calculate(input)
        XCTAssertEqual(empty.status, .unavailable)
        input.manualLines = [6, 7, 8]
        let partial = try await LiuyaoPlugin().calculate(input)
        XCTAssertEqual(partial.status, .unavailable)
    }

    func testRequestsRejectUnselectedOrMismatchedOperationsAndDeduplicate() {
        let requests = [
            OracleInteractionRequest(method: .bazi, kind: .numbers),
            OracleInteractionRequest(method: .meihua, kind: .tarot),
            OracleInteractionRequest(method: .meihua, kind: .numbers, prompt: "请留三个数字。"),
            OracleInteractionRequest(method: .meihua, kind: .numbers, prompt: "重复请求"),
            OracleInteractionRequest(method: .tarot, kind: .tarot)
        ]
        let accepted = OracleInteractionPolicy.requests(for: plan(methods: [.meihua, .liuyao], interactions: requests))
        XCTAssertEqual(accepted.map(\.method), [.meihua, .liuyao])
        XCTAssertEqual(accepted.map(\.kind), [.numbers, .coins])
        XCTAssertEqual(accepted.first?.prompt, "请留三个数字。")
    }

    func testOlderPlanCannotBypassTarotAndCoinInteraction() {
        let accepted = OracleInteractionPolicy.requests(for: plan())
        XCTAssertEqual(Set(accepted.map(\.method)), [.tarot, .liuyao])
        XCTAssertFalse(accepted.contains { $0.kind == .numbers })
        XCTAssertTrue(OracleInteractionPolicy.requests(for: plan(methods: [.bazi])).isEmpty)
    }

    func testExistingNumbersSatisfyRequestedNumberInteraction() {
        let requested = plan(methods: [.meihua], interactions: [.init(method: .meihua, kind: .numbers)])
        XCTAssertEqual(OracleInteractionPolicy.requests(for: requested).map(\.kind), [.numbers])
        XCTAssertTrue(OracleInteractionPolicy.requests(for: requested, numbers: [8, 8, 6]).isEmpty)
        for values in [[8, 8], [0, 8, 6], [8, 8, 1000], [8]] {
            XCTAssertEqual(OracleInteractionPolicy.requests(for: requested, numbers: values).map(\.kind), [.numbers])
        }
        let timeOrLegacy = plan(methods: [.meihua])
        XCTAssertTrue(OracleInteractionPolicy.requests(for: timeOrLegacy).isEmpty)
        XCTAssertTrue(OracleInteractionPolicy.requests(for: timeOrLegacy, numbers: [8, 8]).isEmpty)
        XCTAssertEqual(OracleInteractionPolicy.requests(for: timeOrLegacy, numbers: [0, 8, 6]).map(\.kind), [.numbers])
    }

    func testLegacyRequiredNumberFieldCreatesNumberInteraction() throws {
        var original = plan(methods: [.meihua])
        original.requiredFields = [.numbers]
        let legacy = try JSONDecoder().decode(OraclePlan.self, from: removing(["interactions"], from: original))
        XCTAssertNil(legacy.interactions)
        let requests = OracleInteractionPolicy.requests(for: legacy)
        XCTAssertEqual(requests.map(\.method), [.meihua])
        XCTAssertEqual(requests.map(\.kind), [.numbers])
    }

    func testNumberValidationRejectsIncompleteOutOfRangeAndMixedPayloads() {
        let request = OracleInteractionRequest(method: .meihua, kind: .numbers)
        for values in [[1, 2], [0, 2, 3], [1, 2, 1000], [1, 2, 3, 4]] {
            XCTAssertFalse(OracleInteractionPolicy.isValid(.init(requestID: request.id, numbers: values), for: request, complete: true))
        }
        XCTAssertFalse(OracleInteractionPolicy.isValid(.init(requestID: "liuyao", numbers: [1, 2, 3]), for: request, complete: true))
        XCTAssertFalse(OracleInteractionPolicy.isValid(.init(requestID: request.id, numbers: [1, 2, 3], lines: [7]), for: request, complete: true))
        XCTAssertTrue(OracleInteractionPolicy.isValid(.init(requestID: request.id, numbers: [1, 999, 3]), for: request, complete: true))
    }

    func testEditableNumberDraftKeepsBlankSlotsAndInvalidValuesWithoutStartingTheReading() throws {
        let request = OracleInteractionRequest(method: .meihua, kind: .numbers)
        for texts in [["8", "", "6"], ["0", "8", "6"], ["8", "1000", "6"], ["x", "8", "6"]] {
            var pending = session([request])
            let draft = OracleInteractionResponse(requestID: request.id, numberTexts: texts)
            XCTAssertTrue(pending.saveProgress(draft), texts.joined(separator: ","))
            XCTAssertFalse(pending.complete(draft))
            XCTAssertTrue(pending.input.numbers.isEmpty)
            XCTAssertEqual(pending.currentIndex, 0)
            let restored = try JSONDecoder().decode(OracleInteractionSession.self, from: JSONEncoder().encode(pending))
            XCTAssertEqual(restored.draft?.numberTexts, texts)
            XCTAssertEqual(restored.draft?.numbers, [])
            XCTAssertEqual(restored.seed, pending.seed)
        }
    }

    func testEditedNumberTextsMustAgreeWithTheCompletedNumbers() throws {
        let request = OracleInteractionRequest(method: .meihua, kind: .numbers)
        var pending = session([request])
        let stale = OracleInteractionResponse(requestID: request.id, numbers: [8, 8, 6], numberTexts: ["8", "", "6"])
        XCTAssertFalse(pending.saveProgress(stale))
        XCTAssertFalse(pending.complete(stale))
        let mismatched = OracleInteractionResponse(requestID: request.id, numbers: [8, 8, 5], numberTexts: ["8", "8", "6"])
        XCTAssertFalse(pending.complete(mismatched))
        let corrected = OracleInteractionResponse(requestID: request.id, numbers: [8, 8, 6], numberTexts: ["008", " 8 ", "6"])
        XCTAssertTrue(pending.saveProgress(corrected))
        var restored = try JSONDecoder().decode(OracleInteractionSession.self, from: JSONEncoder().encode(pending))
        XCTAssertTrue(restored.complete(corrected))
        XCTAssertEqual(restored.input.numbers, [8, 8, 6])
        XCTAssertEqual(restored.input.interactionResponses, [corrected])
        XCTAssertFalse(restored.complete(corrected))
    }

    func testNumberTextDraftsAreBoundedAndCannotBeMixedIntoOtherSteps() {
        let request = OracleInteractionRequest(method: .meihua, kind: .numbers)
        for texts in [["8", "6"], ["8", "6", "1", "2"], [String(repeating: "8", count: 17), "8", "6"]] {
            XCTAssertFalse(OracleInteractionPolicy.isValid(.init(requestID: request.id, numberTexts: texts), for: request, complete: false))
        }
        let coins = OracleInteractionRequest(method: .liuyao, kind: .coins)
        XCTAssertFalse(OracleInteractionPolicy.isValid(.init(requestID: coins.id, lines: [7, 7, 7, 7, 7, 7], numberTexts: ["", "", ""]), for: coins, complete: true))
        let tarot = OracleInteractionRequest(method: .tarot, kind: .tarot)
        XCTAssertFalse(OracleInteractionPolicy.isValid(.init(requestID: tarot.id, tarotDraws: draws(), revealedCount: 3, numberTexts: ["", "", ""]), for: tarot, complete: true))
    }

    func testOldNumberResponsesRemainDecodableAndKeepTheirExactSelection() throws {
        let old = OracleInteractionResponse(requestID: "meihua", numbers: [8, 8, 6])
        let restored = try JSONDecoder().decode(OracleInteractionResponse.self, from: removing(["numberTexts"], from: old))
        XCTAssertNil(restored.numberTexts)
        XCTAssertEqual(NumberInteractionDraft.texts(for: restored), ["8", "8", "6"])
        XCTAssertTrue(OracleInteractionPolicy.isValid(restored, for: .init(method: .meihua, kind: .numbers), complete: true))
        XCTAssertEqual(NumberInteractionDraft.texts(for: .init(requestID: "meihua", numbers: [8])), ["8", "", ""])
        XCTAssertNil(NumberInteractionDraft.values(in: ["", "", ""]))
    }

    func testPartialCoinsCanBeSavedButCannotAdvanceOrChangeInput() throws {
        let request = OracleInteractionRequest(method: .liuyao, kind: .coins)
        var pending = session([request])
        let partial = OracleInteractionResponse(requestID: request.id, lines: [6, 7, 8])
        let originalSeed = pending.seed
        XCTAssertTrue(pending.saveProgress(partial))
        XCTAssertFalse(pending.complete(partial))
        XCTAssertEqual(pending.currentIndex, 0)
        XCTAssertEqual(pending.draft, partial)
        XCTAssertTrue(pending.input.manualLines.isEmpty)
        let restored = try JSONDecoder().decode(OracleInteractionSession.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(restored.id, pending.id)
        XCTAssertEqual(restored.seed, originalSeed)
        XCTAssertEqual(restored.draft, partial)
    }

    func testCoinValidationRejectsWrongValuesAndTooManyLines() {
        let request = OracleInteractionRequest(method: .liuyao, kind: .coins)
        for values in [[7, 7, 7, 7, 7], [5, 7, 7, 7, 7, 7], [10, 7, 7, 7, 7, 7], [7, 7, 7, 7, 7, 7, 7]] {
            XCTAssertFalse(OracleInteractionPolicy.isValid(.init(requestID: request.id, lines: values), for: request, complete: true))
        }
        XCTAssertFalse(OracleInteractionPolicy.isValid(.init(requestID: request.id, numbers: [1], lines: [6, 7, 8, 9, 7, 7]), for: request, complete: true))
    }

    func testOnlyCurrentStepCanCompleteAndAllResponsesEnterInputSnapshot() {
        let requests = [OracleInteractionRequest(method: .meihua, kind: .numbers),
                        OracleInteractionRequest(method: .liuyao, kind: .coins)]
        var pending = session(requests)
        let numbers = OracleInteractionResponse(requestID: "meihua", numbers: [8, 8, 6])
        let coins = OracleInteractionResponse(requestID: "liuyao", lines: [6, 7, 8, 9, 7, 8])
        XCTAssertFalse(pending.complete(coins))
        XCTAssertEqual(pending.currentRequest?.method, .meihua)
        XCTAssertTrue(pending.complete(numbers))
        XCTAssertEqual(pending.input.numbers, numbers.numbers)
        XCTAssertEqual(pending.input.interactionResponses, [numbers])
        XCTAssertFalse(pending.complete(numbers))
        XCTAssertTrue(pending.complete(coins))
        XCTAssertNil(pending.currentRequest)
        XCTAssertEqual(pending.input.manualLines, coins.lines)
        XCTAssertEqual(pending.responses, [numbers, coins])
        XCTAssertEqual(pending.input.interactionResponses, [numbers, coins])
        XCTAssertFalse(pending.complete(coins))
    }

    func testSupplementInteractionPreservesOtherMethodsSavedResponses() throws {
        let numbers = OracleInteractionResponse(requestID: "meihua", numbers: [8, 8, 6])
        let coins = OracleInteractionResponse(requestID: "liuyao", lines: [6, 7, 8, 9, 7, 8])
        var original = OracleInput(question: "原问题", profile: OracleProfile(), seed: 42)
        original.numbers = numbers.numbers; original.manualLines = coins.lines
        original.interactionResponses = [numbers, coins]
        let request = OracleInteractionRequest(method: .tarot, kind: .tarot)
        let pending = OracleInteractionSession(input: original, plan: plan(methods: [.meihua, .liuyao, .tarot]), requests: [request])
        var restored = try JSONDecoder().decode(OracleInteractionSession.self, from: JSONEncoder().encode(pending))
        let cards = OracleInteractionResponse(requestID: "tarot", tarotDraws: draws(), revealedCount: 3)

        XCTAssertTrue(restored.complete(cards))
        XCTAssertEqual(restored.responses, [cards])
        XCTAssertEqual(restored.input.interactionResponses, [numbers, coins, cards])
        XCTAssertEqual(restored.input.numbers, original.numbers)
        XCTAssertEqual(restored.input.manualLines, original.manualLines)
        XCTAssertEqual(restored.input.castingDate, original.castingDate)
        XCTAssertEqual(restored.input.seed, original.seed)
        XCTAssertEqual(original.interactionResponses, [numbers, coins])
    }

    func testInteractiveNumbersOverrideEarlierUnknownFlag() async throws {
        var pending = session([.init(method: .meihua, kind: .numbers)])
        pending.input.profile.unknownFields.insert(.numbers)
        pending.input.profile.declaredUnknownFields = [.numbers]
        XCTAssertTrue(pending.complete(.init(requestID: "meihua", numbers: [8, 8, 6])))
        XCTAssertFalse(pending.input.profile.unknownFields.contains(.numbers))
        XCTAssertFalse(pending.input.profile.declaredUnknownFields?.contains(.numbers) == true)
        let result = try await MeihuaPlugin().calculate(pending.input)
        XCTAssertEqual(result.rows.first { $0.label == "本卦" }?.value, "坤为地")
        XCTAssertEqual(result.rows.first { $0.label == "动爻" }?.value, "第6爻（自下而上）")
    }

    func testTarotCannotAdvanceUntilEverySelectedCardIsRevealed() throws {
        var pending = session([.init(method: .tarot, kind: .tarot)])
        var response = OracleInteractionResponse(requestID: "tarot", tarotDraws: draws(), revealedCount: 2)
        XCTAssertTrue(pending.saveProgress(response))
        XCTAssertFalse(pending.complete(response))
        XCTAssertNil(pending.input.tarotDraws)
        XCTAssertEqual(pending.draft, response)
        var restored = try JSONDecoder().decode(OracleInteractionSession.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(restored.draft?.tarotDraws, response.tarotDraws)
        XCTAssertEqual(restored.draft?.revealedCount, 2)
        response.revealedCount = 3
        XCTAssertTrue(restored.complete(response))
        XCTAssertEqual(restored.input.tarotDraws, draws())
        XCTAssertEqual(restored.input.interactionResponses, [response])
        XCTAssertNil(restored.currentRequest)
        XCTAssertNil(restored.draft)
    }

    func testInvalidTarotSelectionCannotBecomeSavedProgress() {
        var pending = session([.init(method: .tarot, kind: .tarot)])
        var response = OracleInteractionResponse(requestID: "tarot", tarotDraws: draws(), revealedCount: 3)
        response.tarotDraws[1].cardID = response.tarotDraws[0].cardID
        XCTAssertFalse(pending.saveProgress(response))
        response.tarotDraws = draws()
        response.tarotDraws[0].cardID = "nonexistent-card"
        XCTAssertFalse(pending.saveProgress(response))
        response.tarotDraws = draws()
        response.tarotDraws.swapAt(0, 1)
        XCTAssertFalse(pending.complete(response))
        response.tarotDraws = draws()
        response.revealedCount = 4
        XCTAssertFalse(pending.saveProgress(response))
        XCTAssertNil(pending.draft)
        XCTAssertTrue(pending.responses.isEmpty)
    }

    func testClarificationRestoresTheSameSelectionAndPreservesOriginalCards() throws {
        let clarification = TarotClarificationRequest(focus: "具体行动", originalPosition: TarotDeck.positions[2], question: "下一步先做什么？")
        let request = OracleInteractionRequest(method: .tarot, kind: .tarot, tarotClarification: clarification)
        var pending = session([request])
        let initial = OracleInteractionResponse(requestID: "tarot", tarotDraws: draws(), revealedCount: 3)
        pending.input.tarotDraws = initial.tarotDraws
        pending.input.interactionResponses = [initial]

        let deck = pending.availableTarotCards
        XCTAssertEqual(deck.count, 75)
        XCTAssertTrue(Set(deck.map(\.id)).isDisjoint(with: initial.tarotDraws.map(\.cardID)))
        let card = try XCTUnwrap(deck.first)
        let selection = TarotDraw(cardID: card.id, isReversed: TarotDeck.isReversed(seed: pending.seed, cardID: card.id), position: TarotDeck.clarificationPosition)
        var wrongOrientation = selection
        wrongOrientation.isReversed.toggle()
        XCTAssertFalse(pending.saveProgress(.init(requestID: request.id, tarotDraws: [wrongOrientation])))
        var response = OracleInteractionResponse(requestID: request.id, tarotDraws: [selection])
        XCTAssertTrue(pending.saveProgress(response))
        XCTAssertFalse(pending.complete(response))

        var restored = try JSONDecoder().decode(OracleInteractionSession.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(restored.currentRequest?.id, request.id)
        XCTAssertEqual(restored.availableTarotCards, deck)
        XCTAssertEqual(restored.draft, response)
        let replacement = TarotDraw(cardID: deck[1].id, isReversed: TarotDeck.isReversed(seed: restored.seed, cardID: deck[1].id), position: TarotDeck.clarificationPosition)
        XCTAssertFalse(restored.saveProgress(.init(requestID: request.id, tarotDraws: [replacement])))
        XCTAssertFalse(restored.complete(.init(requestID: request.id, tarotDraws: [replacement], revealedCount: 1)))

        response.revealedCount = 1
        XCTAssertTrue(restored.complete(response))
        XCTAssertEqual(restored.input.tarotDraws, initial.tarotDraws)
        XCTAssertEqual(restored.input.interactionResponses, [initial, response])
        XCTAssertEqual(restored.input.tarotClarificationRounds, [.init(request: clarification, draw: selection)])
        XCTAssertFalse(restored.complete(response))
    }

    func testClarificationRejectsEarlierCardsAndStopsAtTheRoundLimit() throws {
        let first = TarotClarificationRequest(focus: "现状")
        let second = TarotClarificationRequest(focus: "下一步")
        let third = TarotClarificationRequest(focus: "再次确认")
        let requests = [first, second, third].map {
            OracleInteractionRequest(method: .tarot, kind: .tarot, tarotClarification: $0)
        }
        var pending = session(requests)
        pending.input.tarotDraws = draws()
        let seed = pending.seed
        func response(for request: OracleInteractionRequest, cardID: String) -> OracleInteractionResponse {
            let draw = TarotDraw(cardID: cardID, isReversed: TarotDeck.isReversed(seed: seed, cardID: cardID), position: TarotDeck.clarificationPosition)
            return .init(requestID: request.id, tarotDraws: [draw], revealedCount: 1)
        }

        XCTAssertFalse(pending.complete(response(for: requests[0], cardID: draws()[0].cardID)))
        let firstCard = try XCTUnwrap(pending.availableTarotCards.first)
        let firstResponse = response(for: requests[0], cardID: firstCard.id)
        XCTAssertTrue(pending.complete(firstResponse))
        XCTAssertFalse(pending.complete(firstResponse))
        XCTAssertFalse(pending.availableTarotCards.contains(firstCard))
        XCTAssertFalse(pending.complete(response(for: requests[1], cardID: firstCard.id)))

        let secondCard = try XCTUnwrap(pending.availableTarotCards.first)
        XCTAssertTrue(pending.complete(response(for: requests[1], cardID: secondCard.id)))
        XCTAssertEqual(pending.input.tarotClarificationRounds?.map(\.id), [first.id, second.id])
        XCTAssertFalse(TarotDeck.canAppendClarification(to: pending.input))
        XCTAssertTrue(pending.availableTarotCards.isEmpty)
        XCTAssertFalse(pending.complete(response(for: requests[2], cardID: "major-21")))
    }

    @MainActor func testPendingInteractionSurvivesChatSwitchAndRestartWithItsOriginalDraft() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let originalID = store.activeConversationID
        store.messages = [ChatMessage(role: .user, content: "抽牌后再看六爻"),
                          ChatMessage(role: .assistant, content: "请确认资料", kind: .intake)]
        store.pendingPlan = plan(methods: [.tarot, .liuyao])
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        let original = try XCTUnwrap(store.pendingInteraction)
        let draft = OracleInteractionResponse(requestID: "tarot", tarotDraws: Array(draws().prefix(2)))
        store.saveInteractionProgress(draft, sessionID: original.id)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertEqual(store.phase, .awaitingInteraction)

        store.newConversation()
        XCTAssertNil(store.pendingInteraction)
        store.openConversation(originalID)
        XCTAssertEqual(store.pendingInteraction?.id, original.id)
        XCTAssertEqual(store.pendingInteraction?.input.seed, original.input.seed)
        XCTAssertEqual(store.pendingInteraction?.draft, draft)
        XCTAssertEqual(store.phase, .awaitingInteraction)

        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.pendingInteraction?.id, original.id)
        XCTAssertEqual(restarted.pendingInteraction?.input.seed, original.input.seed)
        XCTAssertEqual(restarted.pendingInteraction?.draft, draft)
        restarted.saveInteractionProgress(.init(requestID: "tarot"), sessionID: UUID())
        restarted.completeInteraction(.init(requestID: "tarot", tarotDraws: draws(), revealedCount: 3), sessionID: UUID())
        XCTAssertEqual(restarted.pendingInteraction?.draft, draft)
        XCTAssertTrue(restarted.runs.isEmpty)
    }

    @MainActor func testAllStepsCompleteBeforeRunAndRetryKeepsSelectionsAndCoinResults() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        store.messages = [ChatMessage(role: .user, content: "为这件事抽牌起卦"),
                          ChatMessage(role: .assistant, content: "请确认资料", kind: .intake)]
        store.pendingPlan = plan(methods: [.tarot, .liuyao])
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        let pending = try XCTUnwrap(store.pendingInteraction)
        let cards = OracleInteractionResponse(requestID: "tarot", tarotDraws: draws(), revealedCount: 3)
        store.completeInteraction(cards, sessionID: pending.id)
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.method, .liuyao)
        XCTAssertTrue(store.runs.isEmpty)
        store.completeInteraction(.init(requestID: "liuyao", lines: [6, 7]), sessionID: pending.id)
        XCTAssertTrue(store.runs.isEmpty)
        let lines = [6, 7, 8, 9, 7, 8]
        store.completeInteraction(.init(requestID: "liuyao", lines: lines), sessionID: pending.id)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.count, 1)
        try await waitUntilIdle(store)
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.input.seed, pending.input.seed)
        XCTAssertEqual(run.input.tarotDraws, draws())
        XCTAssertEqual(run.input.manualLines, lines)
        XCTAssertEqual(run.input.interactionResponses, [cards, .init(requestID: "liuyao", lines: lines)])
        XCTAssertEqual(run.results.first { $0.method == .tarot }?.tarotDraws, draws())
        XCTAssertEqual(run.results.first { $0.method == .liuyao }?.rows.first { $0.label == "爻值（初→上）" }?.value, "6 7 8 9 7 8")
        let resultIDs = run.results.map(\.id)

        store.retrySynthesis(run)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.runs.first?.results.map(\.id), resultIDs)
        XCTAssertEqual(store.runs.first?.input.tarotDraws, draws())
        XCTAssertEqual(store.runs.first?.input.manualLines, lines)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.runs.first?.input.tarotDraws, draws())
        XCTAssertEqual(restarted.runs.first?.input.manualLines, lines)
        XCTAssertEqual(restarted.runs.first?.input.interactionResponses, run.input.interactionResponses)
        XCTAssertEqual(restarted.runs.first?.results.map(\.id), resultIDs)
    }

    @MainActor func testRetryingOldReadingCannotInterruptPendingInteraction() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let oldPlan = plan(methods: [.meihua])
        let oldRun = OracleRun(input: OracleInput(question: oldPlan.question, profile: store.profile), plan: oldPlan,
                               results: [.init(method: .meihua, headline: "已保存的结果", rows: [])],
                               synthesis: ReadingSynthesis(text: "已有解读"), completedAt: Date())
        store.runs = [oldRun]
        store.messages = [ChatMessage(role: .user, content: "继续完成这次抽牌")]
        store.pendingPlan = plan(methods: [.tarot])
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        let pending = try XCTUnwrap(store.pendingInteraction)
        let draft = OracleInteractionResponse(requestID: "tarot", tarotDraws: Array(draws().prefix(2)))
        store.saveInteractionProgress(draft, sessionID: pending.id)
        let messageCount = store.messages.count

        store.retrySynthesis(oldRun)

        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.phase, .awaitingInteraction)
        XCTAssertEqual(store.pendingInteraction?.id, pending.id)
        XCTAssertEqual(store.pendingInteraction?.input.seed, pending.input.seed)
        XCTAssertEqual(store.pendingInteraction?.draft, draft)
        XCTAssertEqual(store.pendingInteraction?.responses, [])
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.method, .tarot)
        XCTAssertEqual(store.messages.count, messageCount)
        XCTAssertEqual(store.runs.map(\.id), [oldRun.id])
    }

    func testLegacyInputPlanResultAndConversationDecodeWithoutNewFields() throws {
        let oldInput = OracleInput(question: "原有问题", profile: OracleProfile(), numbers: [8, 8, 6],
                                   manualLines: [7, 7, 7, 7, 7, 7], seed: 123)
        let input = try JSONDecoder().decode(OracleInput.self, from: removing(["tarotDraws", "interactionResponses"], from: oldInput))
        XCTAssertNil(input.tarotDraws)
        XCTAssertNil(input.interactionResponses)
        XCTAssertEqual(input.seed, 123)
        XCTAssertEqual(input.numbers, [8, 8, 6])
        XCTAssertEqual(input.manualLines, [7, 7, 7, 7, 7, 7])

        let originalPlan = plan(methods: [.liuyao])
        let oldPlan = try JSONDecoder().decode(OraclePlan.self, from: removing(["interactions"], from: originalPlan))
        XCTAssertNil(oldPlan.interactions)
        XCTAssertEqual(oldPlan.question, originalPlan.question)
        let result = OracleResult(method: .liuyao, headline: "乾为天", rows: [.init("本卦", "乾为天")])
        let oldResult = try JSONDecoder().decode(OracleResult.self, from: removing(["tarotDraws"], from: result))
        XCTAssertNil(oldResult.tarotDraws)
        XCTAssertEqual(oldResult.rows, result.rows)

        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: "旧会话")], pendingPlan: oldPlan)
        let oldConversation = try JSONDecoder().decode(OracleConversation.self, from: removing(["pendingInteraction"], from: conversation))
        XCTAssertNil(oldConversation.pendingInteraction)
        XCTAssertEqual(oldConversation.pendingPlan?.question, originalPlan.question)
        XCTAssertEqual(oldConversation.messages.first?.content, "旧会话")
    }
}
