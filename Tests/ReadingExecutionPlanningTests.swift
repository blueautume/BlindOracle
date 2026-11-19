import Foundation
import XCTest
@testable import BlindOracle

/// These exercise the actual response decoder and method selection together.
/// The mock transport never sends a request to the account or model services.
final class ReadingExecutionPlanningTests: XCTestCase {
    func testSelectedExplicitMethodsBecomeMandatoryWithoutAPlannerMandatoryField() async throws {
        let names: [OracleMethod: String] = [.bazi: "八字", .ziwei: "紫微斗数", .liuyao: "六爻", .meihua: "梅花易数",
            .qimen: "奇门遁甲", .xiaoliuren: "小六壬", .chenggu: "称骨", .xingming: "姓名五格", .astrology: "西方占星", .tarot: "塔罗"]
        let cases: [(String, [OracleMethod])] = OracleMethod.allCases.map { method in
            ("请用\(names[method]!)推算这次安排。", [method])
        } + [("请用八字和塔罗一起分析我的职业发展。", [.bazi, .tarot])]
        for (question, methods) in cases {
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "intake", methods: methods.map(\.rawValue),
                    relation: "newQuestion", execution: execution("calculate", "changed", question)))
            XCTAssertEqual(plan.action, "intake", question)
            XCTAssertEqual(Set(plan.methods), Set(methods), question)
            XCTAssertEqual(Set(plan.mandatoryMethods ?? []), Set(methods), question)
        }

        // The decoder protects an explicit user choice before the Store
        // recomputes the fields and interactions.
        let question = "请用紫微斗数看我的职业发展。"
        let wrongSelection = try await planned(question: question,
            payload: payload(question: question, action: "intake", methods: ["xiaoliuren"],
                relation: "newQuestion", execution: execution("calculate", "changed", question)))
        XCTAssertEqual(wrongSelection.methods, [.ziwei])
        XCTAssertEqual(wrongSelection.mandatoryMethods, [.ziwei])
    }

    func testClearQuestionRecoversFromPlannerAskingTheUserToChooseAMethod() async throws {
        let question = "最近的工作，该进还是该守？"
        var proposal = payload(question: question, action: "clarify", methods: [],
                               relation: "newQuestion", execution: execution("clarify", "unknown", question))
        proposal["note"] = "你希望用哪种方法推演这次问题？"
        let plan = try await planned(question: question, payload: proposal)
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(Set(plan.methods), [.liuyao, .tarot])
        XCTAssertTrue((plan.mandatoryMethods ?? []).isEmpty)
        XCTAssertNotEqual(plan.note, proposal["note"] as? String)
    }

    func testExplicitMethodRecoversANewQuestionMislabeledAsAnAnswer() async throws {
        let question = "只用六爻推算我该不该接这个项目。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: ["tarot"],
                             relation: "newQuestion", execution: execution("answer", "changed", question)))
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.liuyao])
        XCTAssertEqual(plan.mandatoryMethods, [.liuyao])
    }

    func testBroadSelectionCanCarryEveryRelevantMethodThroughTheDecoder() async throws {
        let question = """
        看未来五年事业的方向；也看我目前处在什么人生阶段；
        这份合作该不该接；近期项目进展如何；什么时候提出方案最合适；
        分析这个笔名是否合适；我也想看骨重与传统命诗。
        """
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "intake", methods: ["tarot"],
                             relation: "newQuestion", execution: execution("calculate", "changed", question)))
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(Set(plan.methods), Set(OracleMethod.allCases))
        XCTAssertTrue((plan.mandatoryMethods ?? []).isEmpty)
    }

    func testQuotedMethodNamesDoNotBecomeMandatoryForAnExplanation() async throws {
        let question = "不要替我计算。朋友说“用八字重新算一下”是什么意思？只解释这句话。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: [], relation: "newQuestion",
                execution: execution("answer", "existing", question)))
        XCTAssertEqual(plan.action, "reply")
        XCTAssertTrue(plan.methods.isEmpty)
        XCTAssertTrue((plan.mandatoryMethods ?? []).isEmpty)
    }

    func testQuotedMethodCommandsCannotTurnAnAnchoredExplanationIntoASupplement() async throws {
        let reference = makeReference(run: makeRun(methods: [.tarot]))
        for question in ["朋友说“用八字看事业”这句话是否可靠？",
            "朋友说「再用紫微斗数补充分析事业」，我该怎么理解？",
            "『用八字推算事业』是朋友的话，请解释这句话。"] {
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "reply", methods: [],
                    reference: reference.messageID, execution: execution("answer", "existing", question)),
                references: [reference])
            XCTAssertEqual(plan.action, "reply", question)
            XCTAssertTrue(plan.methods.isEmpty, question)
            XCTAssertTrue((plan.mandatoryMethods ?? []).isEmpty, question)
            XCTAssertNil(plan.baseRunID, question)
        }
    }

    func testApostropheOnlyEvidenceChangesRestoreTheExactUserSpan() async throws {
        let original = "Use only Mei Hua Yi Shu to calculate whether tomorrow’s contract negotiation will go smoothly."
        let normalized = original.replacingOccurrences(of: "’", with: "'")
        for (question, evidence) in [(original, normalized), (normalized, original),
            ("明天的安排📅：" + original, normalized)] {
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "intake", methods: ["meihua"],
                    relation: "newQuestion", execution: execution("calculate", "changed", evidence)))
            XCTAssertEqual(plan.action, "intake", question)
            XCTAssertEqual(plan.methods, [.meihua], question)
            let expected = question.contains(original) ? original : normalized
            XCTAssertEqual(plan.understanding?.execution?.evidence, expected,
                "Later authorization must use the exact source spelling, including Unicode boundaries")
            XCTAssertTrue(question.contains(try XCTUnwrap(plan.understanding?.execution?.evidence)))
        }
    }

    func testApostropheEvidenceAlignmentCannotChangeWordsOrAuthorizeQuotedAndNegatedCommands() async throws {
        let cases: [(String, String)] = [
            ("Use only Mei Hua Yi Shu to calculate tomorrow’s contract negotiation.",
             "Use only Mei Hua Yi Shu to calculate today's contract negotiation."),
            ("Don’t calculate tomorrow’s negotiation; explain the existing reading.",
             "Calculate tomorrow's negotiation; explain the existing reading."),
            ("What does \"Use only Mei Hua Yi Shu to calculate tomorrow’s negotiation\" mean?",
             "Use only Mei Hua Yi Shu to calculate tomorrow's negotiation"),
            ("Don’t use Mei Hua Yi Shu to calculate tomorrow’s negotiation.",
             "Don't use Mei Hua Yi Shu to calculate tomorrow's negotiation.")
        ]
        for (question, evidence) in cases {
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "intake", methods: ["meihua"],
                    relation: "newQuestion", execution: execution("calculate", "changed", evidence)))
            assertClarification(plan, context: question)
            XCTAssertNil(plan.mandatoryMethods, question)
        }
    }

    func testKnownZiweiQuestionWithMissingBirthTimeOpensTheFormInsteadOfChangingMethods() async throws {
        // This response reproduces the actual model failure from the live matrix.
        let question = "请用紫微斗数看我的职业发展，但我不记得出生时辰。"
        var response = payload(question: question, action: "clarify", methods: [], relation: "newQuestion",
            execution: execution("clarify", "unknown", question))
        response["subject"] = "本人"
        response["note"] = "紫微斗数需要唯一的出生时辰，你记得大致是几点，或者有其他线索吗？"
        let plan = try await planned(question: question, payload: response)
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.ziwei])
        XCTAssertEqual(plan.mandatoryMethods, [.ziwei])
        XCTAssertTrue(plan.requiredFields.contains(.birthTime))
        XCTAssertEqual(plan.question, question)
        XCTAssertNil(plan.profileUpdates)

        let run = makeRun(methods: [.bazi])
        let reference = makeReference(run: run)
        let supplement = "同一个职业问题，请再用紫微斗数补充分析，但我不记得出生时辰。"
        response = payload(question: supplement, action: "clarify", methods: [],
            reference: reference.messageID, execution: execution("clarify", "unknown", supplement))
        response["note"] = "紫微斗数需要唯一的出生时辰，你记得大致是几点，或者有其他线索吗？"
        let added = try await planned(question: supplement, payload: response, references: [reference])
        XCTAssertEqual(added.action, "supplement")
        XCTAssertEqual(added.methods, [.ziwei])
        XCTAssertEqual(added.mandatoryMethods, [.ziwei])
        XCTAssertEqual(added.baseRunID, run.id)
        XCTAssertTrue(added.requiredFields.contains(.birthTime))
        XCTAssertNil(added.profileUpdates)
    }

    func testMissingProfileRecoveryCannotResolveAnAmbiguousTopicOrAConsultation() async throws {
        let question = "请用紫微斗数看我的职业发展，但我不记得出生时辰。"
        let cases: [(String, String, String)] = [
            (question, "ambiguous", "请提供出生时辰，你具体想看哪件事？"),
            (question, "newQuestion", "你具体想看哪份工作，还是换一个问题？"),
            ("请用紫微斗数看职业发展，但不记得出生时辰。", "newQuestion",
             "请先确认这次要看你还是朋友的职业发展，并补充出生时辰。"),
            ("不要算紫微斗数，只解释为什么需要出生时辰。", "newQuestion", "请提供出生时辰。")
        ]
        for (question, relation, note) in cases {
            var response = payload(question: question, action: "clarify", methods: [], relation: relation,
                execution: execution("clarify", "unknown", question))
            response["note"] = note
            let plan = try await planned(question: question, payload: response)
            assertClarification(plan, context: question + note)
            XCTAssertNil(plan.mandatoryMethods)
            XCTAssertNil(plan.profileUpdates)
        }
    }

    func testMissingCastingLocationOpensQimenFormWithoutReplacingTheMethod() async throws {
        let cases = [
            ("Use only Qi Men Dun Jia to calculate this trip. I have not provided the location yet; ask me for it rather than switching methods.",
             "Please provide the current location so I can calculate the Qi Men Dun Jia chart for this trip."),
            ("Use only Qi Men Dun Jia to calculate this trip. I have not provided the location yet; ask me for it rather than switching methods.",
             "Please provide the location for the Qi Men Dun Jia calculation."),
            ("请用奇门遁甲看这次出行，我还没有提供起局地。",
             "请提供当前地点，以便为这次出行起奇门遁甲局。")
        ]
        for (question, note) in cases {
            var response = payload(question: question, action: "clarify", methods: [], relation: "newQuestion",
                execution: execution("clarify", "unknown", question))
            response["note"] = note
            let plan = try await planned(question: question, payload: response)
            XCTAssertEqual(plan.action, "intake", question)
            XCTAssertEqual(plan.methods, [.qimen], question)
            XCTAssertEqual(plan.mandatoryMethods, [.qimen], question)
            XCTAssertTrue(plan.requiredFields.contains(.currentLocation), question)
            XCTAssertNil(plan.profileUpdates, question)
        }
    }

    @MainActor func testExplicitMethodsRemainMandatoryThroughTheRealStoreWhenPlannerChoosesAnAlternative() async throws {
        let names: [OracleMethod: String] = [.bazi: "八字", .ziwei: "紫微斗数", .liuyao: "六爻", .meihua: "梅花易数",
            .qimen: "奇门遁甲", .xiaoliuren: "小六壬", .chenggu: "称骨", .xingming: "姓名五格", .astrology: "西方占星", .tarot: "塔罗"]
        let cases: [(String, [OracleMethod])] = OracleMethod.allCases.map { method in
            ("请用\(names[method]!)推算这次安排。", [method])
        } + [("请用八字和塔罗一起分析我的职业发展。", [.bazi, .tarot]),
             ("请用紫微斗数看我的职业发展，但我不记得出生时辰。", [.ziwei])]
        for (question, expected) in cases {
            let key = "mandatory-store-" + UUID().uuidString
            let proposal = payload(question: question, action: "intake", methods: ["xiaoliuren"],
                relation: "newQuestion", execution: execution("calculate", "changed", question))
            let content = String(decoding: try JSONSerialization.data(withJSONObject: proposal), as: UTF8.self)
            let response = try JSONSerialization.data(withJSONObject: ["model": DeepSeekConfiguration.defaultModel,
                "choices": [["message": ["content": content], "finish_reason": "stop"]]])
            ExecutionPlanningURLProtocol.install(.init(body: response, question: question), for: key)
            defer { ExecutionPlanningURLProtocol.remove(key) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ExecutionPlanningURLProtocol.self]
            let client = DeepSeekClient(accessToken: key, sessionConfiguration: configuration)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(key)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = OracleStore(vault: LocalVault(directory: directory), bootstrapCredential: false, aiClient: client)
            store.send(question)
            let deadline = ContinuousClock.now + .seconds(3)
            while store.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(store.isBusy, question)
            let plan = try XCTUnwrap(store.pendingPlan, question)
            XCTAssertEqual(Set(plan.methods), Set(expected), question)
            XCTAssertEqual(Set(plan.mandatoryMethods ?? []), Set(expected), question)
            XCTAssertTrue(store.runs.isEmpty, "An explicit method request must still await user confirmation")
            if expected == [.ziwei] {
                XCTAssertFalse(store.confirmGroupIntake(profiles: [], numbers: []),
                    "Missing birth facts must not silently downgrade the mandated method")
                XCTAssertEqual(store.pendingPlan?.methods, [.ziwei])
                XCTAssertTrue(store.runs.isEmpty)
            }
        }
    }

    func testValidRoutingResponseCannotAutomaticallySupplyBirthFacts() async throws {
        let question = "请用八字分析事业，出生资料我会在表单里填写。"
        var response = payload(question: question, action: "intake", methods: ["bazi"],
            relation: "newQuestion", execution: execution("calculate", "changed", question))
        response["profileUpdates"] = [["name": "虚构自动填写", "birthDate": "1990-01-02", "birthTime": "08:30",
            "birthTimeZoneID": "Asia/Shanghai", "birthPlace": "上海市黄浦区", "birthLatitude": 31.2304,
            "birthLongitude": 121.4737]]
        let plan = try await planned(question: question, payload: response)
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.bazi])
        XCTAssertNil(plan.profileUpdates, "Routing may ask for a form; it must not fabricate its values")
    }

    func testChangedTargetsRecoverReferencedMethodsBeforeReplyCanDiscardThem() async throws {
        let referenced = makeRun(methods: [.tarot, .xiaoliuren])
        let unrelatedLatest = makeRun(methods: [.bazi])
        let reference = makeReference(run: referenced)
        let questions = [
            "计划改为下周出发，请重新计算这次出行。",
            "目标从找工作改为准备考试，请重新推演。",
            "合作对象换成另一家公司，请重新算这次合作。",
            "The budget is now half as much. Please calculate the revised project."
        ]
        for question in questions {
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "reply", methods: [],
                    relation: "changedConditions", reference: reference.messageID,
                    execution: execution("calculate", "changed", question)),
                existingRun: unrelatedLatest, references: [reference])
            XCTAssertEqual(plan.action, "intake", question)
            XCTAssertEqual(plan.methods, referenced.plan.methods, question)
            XCTAssertFalse(plan.methods.contains(.bazi), question)
            XCTAssertNil(plan.baseRunID, question)
            XCTAssertEqual(plan.question, question)
            XCTAssertEqual(plan.understanding?.referenceMessageID, reference.messageID)
            XCTAssertEqual(plan.understanding?.execution?.operation, .calculate)
            XCTAssertEqual(plan.understanding?.execution?.coverage, .changed)
        }
    }

    func testRecastWithAnOldReplyActionStartsFreshUsingTheReferencedMethods() async throws {
        let run = makeRun(methods: [.tarot])
        let reference = makeReference(run: run)
        let question = "请为同一件事重新抽一整阵牌。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: [],
                reference: reference.messageID, execution: execution("recast", "existing", question)),
            references: [reference])
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.tarot])
        XCTAssertNil(plan.baseRunID)
        XCTAssertEqual(plan.question, question)
        XCTAssertEqual(plan.interactions?.map(\.method), [.tarot])
    }

    func testRecastKeepsSelectedMethodsMandatoryWhenTheModelOmitsThatField() async throws {
        let reference = makeReference(run: makeRun(methods: [.tarot]))
        let question = "For the same market project, please draw a completely new Tarot spread and recalculate. Do not reuse the old cards."
        let response = payload(question: question, action: "intake", methods: ["tarot"],
            reference: reference.messageID, execution: execution("recast", "changed", question))
        XCTAssertNil(response["mandatoryMethods"])
        let plan = try await planned(question: question, payload: response, references: [reference])
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.tarot])
        XCTAssertEqual(plan.mandatoryMethods, [.tarot])
        XCTAssertNil(plan.baseRunID)
        XCTAssertEqual(plan.interactions?.map(\.method), [.tarot])

        for question in ["Don't redraw; explain the saved spread.",
            "What does \"draw a completely new Tarot spread\" mean? Do not calculate.",
            "他说“重新起卦”是什么意思？"] {
            let denied = try await planned(question: question,
                payload: payload(question: question, action: "intake", methods: ["tarot"],
                    reference: reference.messageID, execution: execution("recast", "changed", question)),
                references: [reference])
            assertClarification(denied, context: question)
            XCTAssertNil(denied.mandatoryMethods, "A fabricated recast cannot lock any method")
        }
    }

    func testCoveredAnswerCannotBecomeANewReadingBecauseThePayloadSaysIntake() async throws {
        let run = makeRun(methods: [.xiaoliuren])
        let reference = makeReference(run: run)
        let question = "为什么刚才的结论建议先等消息？"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "intake", methods: ["xiaoliuren"],
                reference: reference.messageID, execution: execution("answer", "existing", question)),
            references: [reference])
        XCTAssertEqual(plan.action, "reply")
        XCTAssertTrue(plan.methods.isEmpty)
        XCTAssertTrue(plan.requiredFields.isEmpty)
        XCTAssertTrue(plan.interactions?.isEmpty == true)
        XCTAssertNil(plan.baseRunID)
        XCTAssertEqual(plan.understanding?.execution?.operation, .answer)
    }

    func testMistakenAnswerLabelCannotSwallowAnExplicitContextualCalculation() async throws {
        let run = makeRun(methods: [.xiaoliuren])
        let reference = makeReference(run: run)
        for question in ["那就算一下修改后的目标。", "Please recalculate the revised project."] {
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "reply", methods: [],
                    reference: reference.messageID, execution: execution("answer", "existing", question)),
                references: [reference])
            XCTAssertEqual(plan.action, "intake", question)
            XCTAssertEqual(plan.methods, [.xiaoliuren], question)
            XCTAssertNil(plan.baseRunID)
            XCTAssertEqual(plan.question, question)
        }
    }

    func testMistakenAnswerLabelStillRespectsNamedSupplementAndChangedScope() async throws {
        let run = makeRun(methods: [.tarot])
        let reference = makeReference(run: run)
        for (coverage, expectedAction) in [("additional", "supplement"), ("changed", "intake")] {
            let question = "请用六爻再看看这次项目安排。"
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "reply", methods: ["liuyao"],
                    reference: reference.messageID, execution: execution("answer", coverage, question)),
                references: [reference])
            XCTAssertEqual(plan.action, expectedAction, coverage)
            XCTAssertEqual(plan.methods, [.liuyao], coverage)
            XCTAssertEqual(plan.baseRunID, coverage == "additional" ? run.id : nil)
        }
    }

    func testStandaloneAnswerDoesNotStartAChartWhenItMentionsCalculation() async throws {
        let question = "计算方法是什么？"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: ["xiaoliuren"],
                relation: "newQuestion", execution: execution("answer", "existing", question)),
            existingRun: makeRun(methods: [.tarot]))
        XCTAssertEqual(plan.action, "reply")
        XCTAssertTrue(plan.methods.isEmpty)
        XCTAssertTrue(plan.interactions?.isEmpty == true)
        XCTAssertNil(plan.baseRunID)
    }

    func testAlreadyCoveredCalculationReusesTheAnswerInsteadOfStartingAgain() async throws {
        let run = makeRun(methods: [.tarot])
        let reference = makeReference(run: run)
        let question = "沿着刚才的结果再展开下一步建议。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "intake", methods: ["tarot"],
                reference: reference.messageID, execution: execution("calculate", "existing", question)),
            references: [reference])
        XCTAssertEqual(plan.action, "reply")
        XCTAssertTrue(plan.methods.isEmpty)
        XCTAssertTrue(plan.interactions?.isEmpty == true)
    }

    func testAdditionalCoverageRequestsOnlyTheSupplementAndKeepsItsBase() async throws {
        let run = makeRun(methods: [.tarot])
        let reference = makeReference(run: run)
        let question = "再用梅花补充看看同一个合作安排。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: ["meihua", "meihua"],
                reference: reference.messageID, execution: execution("calculate", "additional", question)),
            references: [reference])
        XCTAssertEqual(plan.action, "supplement")
        XCTAssertEqual(plan.methods, [.meihua])
        XCTAssertEqual(plan.baseRunID, run.id)
        XCTAssertEqual(plan.question, run.input.question)
        XCTAssertEqual(plan.followUpQuestion, question)
        XCTAssertFalse(plan.methods.contains(.tarot))
    }

    func testAdditionalCoverageWithoutABaseCanStartOnlyItsExplicitMethods() async throws {
        let question = "Please calculate a fresh reading of this project."
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: ["xiaoliuren"],
                relation: "newQuestion", execution: execution("calculate", "additional", question)))
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.xiaoliuren])
        XCTAssertNil(plan.baseRunID)
    }

    func testExplicitMethodCanRecoverAMethodlessCalculationWithoutABase() async throws {
        let question = "请用六爻再看看这次安排。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: [],
                relation: "newQuestion", execution: execution("calculate", "changed", question)))
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.liuyao])
        XCTAssertEqual(plan.interactions?.map(\.method), [.liuyao])
    }

    func testMethodlessCalculationWithoutABaseDoesNotInventDefaultMethods() async throws {
        let question = "请重新计算修改后的目标。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: [],
                relation: "newQuestion", execution: execution("calculate", "changed", question)))
        assertClarification(plan)
    }

    func testUnavailableBaseMethodsDoNotBecomeUnrelatedCatalogDefaults() async throws {
        let run = makeRun(methods: [.bazi])
        let reference = makeReference(run: run)
        let question = "请重新计算修改后的目标。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: [],
                reference: reference.messageID, execution: execution("calculate", "changed", question)),
            references: [reference], available: [.tarot, .meihua])
        assertClarification(plan)
    }

    func testMissingReferenceCannotBorrowTheUnrelatedLatestRun() async throws {
        let question = "请重新计算修改后的目标。"
        let unofferedID = UUID()
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: ["tarot"],
                reference: unofferedID, execution: execution("calculate", "changed", question)),
            existingRun: makeRun(methods: [.bazi]))
        assertClarification(plan)
        XCTAssertNil(plan.understanding?.referenceMessageID)
    }

    func testNewQuestionIgnoresUnusedReferencePlaceholdersWithoutAdoptingAnOldReading() async throws {
        let reference = makeReference(run: makeRun(methods: [.bazi]))
        let question = "Use only Chinese Name Numerology to calculate the five-grid stroke pattern of my name 陈平."
        let placeholders: [Any] = ["", "not-a-uuid", 17, ["id": reference.messageID.uuidString],
            [reference.messageID.uuidString], NSNull(), reference.messageID.uuidString]
        for placeholder in placeholders {
            var response = payload(question: question, action: "intake", methods: ["xingming"],
                relation: "newQuestion", execution: execution("calculate", "changed", question))
            var understanding = try XCTUnwrap(response["understanding"] as? [String: Any])
            understanding["referenceMessageID"] = placeholder
            response["understanding"] = understanding
            let plan = try await planned(question: question, payload: response,
                existingRun: reference.run, references: [reference])
            XCTAssertEqual(plan.action, "intake", String(describing: placeholder))
            XCTAssertEqual(plan.methods, [.xingming])
            XCTAssertEqual(plan.mandatoryMethods, [.xingming])
            XCTAssertEqual(plan.understanding?.relation, .newQuestion)
            XCTAssertEqual(plan.understanding?.execution?.evidence, question)
            XCTAssertNil(plan.understanding?.referenceMessageID)
            XCTAssertNil(plan.baseRunID)
            XCTAssertEqual(plan.question, question)
        }
    }

    func testActualContinuationReferencesRemainStrictAndAmbiguousMessagesStayUnbound() async throws {
        let reference = makeReference(run: makeRun(methods: [.bazi]))
        let question = "请用姓名五格推算陈平的名字。"
        for relation in ["continuation", "changedConditions", "changedParticipants", "ambiguous"] {
            for placeholder: Any in ["", "not-a-uuid", 17, NSNull()] {
                var response = payload(question: question, action: "intake", methods: ["xingming"],
                    relation: relation, execution: execution("calculate", "changed", question))
                var understanding = try XCTUnwrap(response["understanding"] as? [String: Any])
                understanding["referenceMessageID"] = placeholder
                response["understanding"] = understanding
                let plan = try await planned(question: question, payload: response,
                    existingRun: reference.run, references: [reference])
                assertClarification(plan, context: relation + ": " + String(describing: placeholder))
                XCTAssertNil(plan.understanding?.referenceMessageID)
                XCTAssertNil(plan.mandatoryMethods)
            }
        }
    }

    func testIgnoringANewQuestionReferenceCannotHideMalformedExecution() async throws {
        let reference = makeReference(run: makeRun(methods: [.bazi]))
        let question = "请用姓名五格推算陈平的名字。"
        let invalidExecution: [Any] = [NSNull(), "calculate",
            execution("unknown", "changed", question),
            ["operation": "calculate", "evidence": question],
            execution("calculate", "changed", "模型编造的执行授权")]
        for invalid in invalidExecution {
            var response = payload(question: question, action: "intake", methods: ["xingming"],
                relation: "newQuestion", execution: invalid)
            var understanding = try XCTUnwrap(response["understanding"] as? [String: Any])
            understanding["referenceMessageID"] = ""
            response["understanding"] = understanding
            let plan = try await planned(question: question, payload: response,
                existingRun: reference.run, references: [reference])
            assertClarification(plan, context: String(describing: invalid))
            XCTAssertNil(plan.understanding?.referenceMessageID)
            XCTAssertNil(plan.mandatoryMethods)
        }
    }

    func testMalformedExecutionAndFabricatedEvidenceDecodeIntoSafeClarification() async throws {
        let run = makeRun(methods: [.tarot])
        let reference = makeReference(run: run)
        let question = "我修改了计划，请重新计算。"
        let invalid: [(String, Any)] = [
            ("explicit null", NSNull()),
            ("non-object", "calculate"),
            ("missing operation", ["coverage": "changed", "evidence": question]),
            ("unknown operation", execution("launch_everything", "changed", question)),
            ("unknown coverage", execution("calculate", "all", question)),
            ("missing evidence", ["operation": "calculate", "coverage": "changed"]),
            ("empty evidence", execution("calculate", "changed", "")),
            ("whitespace evidence", execution("calculate", "changed", " \n ")),
            ("fabricated evidence", execution("calculate", "changed", "用户明确要求用所有方法算新目标"))
        ]
        for (name, value) in invalid {
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "intake", methods: ["tarot"],
                    reference: reference.messageID, execution: value), references: [reference])
            assertClarification(plan, context: name)
            XCTAssertNil(plan.understanding?.referenceMessageID, name)
        }
    }

    func testUnknownCoverageCannotStartEvenWithValidEvidenceAndMethods() async throws {
        let run = makeRun(methods: [.tarot])
        let reference = makeReference(run: run)
        let question = "计算哪一件事我还没有确定。"
        var response = payload(question: question, action: "intake", methods: ["tarot"],
            reference: reference.messageID, execution: execution("calculate", "unknown", question))
        response["mandatoryMethods"] = ["tarot"]
        response["profileUpdates"] = [["name": "A model-invented person"]]
        response["participantIDs"] = [UUID().uuidString]
        response["participantNames"] = ["A model-invented person"]
        response["relationship"] = "A model-invented relationship"
        let plan = try await planned(question: question, payload: response, references: [reference])
        assertClarification(plan)
        XCTAssertNil(plan.mandatoryMethods)
        XCTAssertNil(plan.profileUpdates)
        XCTAssertNil(plan.participantIDs)
        XCTAssertNil(plan.participantNames)
        XCTAssertNil(plan.relationship)
    }

    func testVerbatimEvidenceLengthLimitSurvivesTheResponseDecoder() async throws {
        let run = makeRun(methods: [.tarot])
        let reference = makeReference(run: run)
        for length in [1000, 1001] {
            let question = String(repeating: "甲", count: length)
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "reply", methods: ["tarot"],
                    reference: reference.messageID, execution: execution("calculate", "changed", question)),
                references: [reference])
            if length == 1000 {
                XCTAssertEqual(plan.action, "intake")
                XCTAssertEqual(plan.methods, [.tarot])
                XCTAssertEqual(plan.understanding?.execution?.evidence, question)
            } else {
                assertClarification(plan)
            }
        }
    }

    func testNegatedAndQuotedConsultationCannotAuthorizeExecution() async throws {
        let run = makeRun(methods: [.tarot])
        let reference = makeReference(run: run)
        let questions = [
            "不要重算，只解释已有结果。",
            "Don't recast; explain the current reading.",
            "他说“重新起卦”是什么意思？",
            "What does \"recast a reading\" mean?"
        ]
        for question in questions {
            let plan = try await planned(question: question,
                payload: payload(question: question, action: "intake", methods: ["tarot"],
                    reference: reference.messageID, execution: execution("recast", "changed", question)),
                references: [reference])
            assertClarification(plan, context: question)
        }
    }

    func testLegacyUnderstandingWithoutExecutionStillDecodesAndKeepsChosenMethods() async throws {
        let question = "这次合作适合推进吗？"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "intake", methods: ["tarot"], relation: "newQuestion"))
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.tarot])
        XCTAssertEqual(plan.understanding?.relation, .newQuestion)
        XCTAssertNil(plan.understanding?.execution)
    }

    func testLegacyContinuationWithoutExecutionCanRecoverItsReferencedMethods() async throws {
        let run = makeRun(methods: [.xiaoliuren])
        let reference = makeReference(run: run)
        let question = "那就算一下修改后的目标。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: [], reference: reference.messageID),
            references: [reference])
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.xiaoliuren])
        XCTAssertEqual(plan.understanding?.referenceMessageID, reference.messageID)
        XCTAssertNil(plan.understanding?.execution)
    }

    func testLegacyPayloadWithoutUnderstandingKeepsTheOldReplyContract() async throws {
        let question = "那就算一下修改后的目标。"
        var response = payload(question: question, action: "reply", methods: ["tarot"])
        response.removeValue(forKey: "understanding")
        let plan = try await planned(question: question, payload: response,
                                     existingRun: makeRun(methods: [.xiaoliuren]))
        XCTAssertEqual(plan.action, "reply")
        XCTAssertTrue(plan.methods.isEmpty)
        XCTAssertNil(plan.understanding)
    }

    func testBoundPendingTextReferenceCanInheritMethodsWithoutResumingOldInputs() async throws {
        let pending = makePendingPlan()
        let reference = ConversationPlanningReference(messageID: UUID(), role: .user,
            excerpt: " \n" + pending.question + "\n ", resolvedQuestion: nil, run: nil)
        let question = "目标改了，请重新计算这次安排。"
        var response = payload(question: question, action: "reply", methods: [],
            relation: "changedConditions", reference: reference.messageID,
            execution: execution("calculate", "changed", question))
        response["resumePending"] = true
        let plan = try await planned(question: question, payload: response,
                                     references: [reference], pendingPlan: pending)
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.tarot])
        XCTAssertEqual(plan.question, question)
        XCTAssertEqual(plan.understanding?.referenceMessageID, reference.messageID)
        XCTAssertEqual(plan.resumesPendingQuestion, false)
        XCTAssertNil(plan.baseRunID)
        XCTAssertNil(plan.followUpQuestion)
        XCTAssertNil(plan.castingProfile)
        XCTAssertNil(plan.draftNumbers)
        XCTAssertNil(plan.draftParticipants)
        XCTAssertNil(plan.reviewedParticipants)
        XCTAssertNil(plan.mandatoryMethods)
        XCTAssertNotEqual(plan.createdAt, pending.createdAt)
        XCTAssertEqual(plan.interactions?.map(\.method), [.tarot])
        XCTAssertFalse(plan.interactions?.contains { $0.prompt == "An old, partially completed interaction" } == true)
    }

    func testPendingReferenceUsesTheResolvedQuestionAndDoesNotRequireResumeFlag() async throws {
        let pending = makePendingPlan()
        let reference = ConversationPlanningReference(messageID: UUID(), role: .assistant,
            excerpt: "An answer that does not repeat the question",
            resolvedQuestion: " \n" + pending.question + "\n ", run: nil)
        let question = "Please calculate the revised goal."
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: [],
                reference: reference.messageID, execution: execution("recast", "changed", question)),
            references: [reference], pendingPlan: pending)
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.tarot])
        XCTAssertEqual(plan.question, question)
        XCTAssertEqual(plan.resumesPendingQuestion, false)
        XCTAssertNil(plan.castingProfile)
        XCTAssertNil(plan.draftNumbers)
    }

    func testUnrelatedTextReferencesCannotBorrowPendingMethods() async throws {
        let pending = makePendingPlan()
        let question = "请重新计算修改后的目标。"
        let references = [
            ConversationPlanningReference(messageID: UUID(), role: .user,
                excerpt: "A completely different question", resolvedQuestion: nil, run: nil),
            // A matching excerpt cannot override a different resolved topic.
            ConversationPlanningReference(messageID: UUID(), role: .assistant,
                excerpt: pending.question, resolvedQuestion: "A different resolved question", run: nil),
            // Matching only a prefix is not a binding to the pending form.
            ConversationPlanningReference(messageID: UUID(), role: .assistant,
                excerpt: String(pending.question.prefix(12)), resolvedQuestion: nil, run: nil)
        ]
        for reference in references {
            var response = payload(question: question, action: "reply", methods: [],
                reference: reference.messageID, execution: execution("calculate", "changed", question))
            response["resumePending"] = true
            let plan = try await planned(question: question, payload: response,
                                         references: [reference], pendingPlan: pending)
            assertClarification(plan, context: reference.excerpt)
            XCTAssertEqual(plan.resumesPendingQuestion, false)
            XCTAssertNil(plan.castingProfile)
        }
    }

    func testMissingReferenceAndNewQuestionCannotAdoptPendingMethods() async throws {
        let pending = makePendingPlan()
        let reference = ConversationPlanningReference(messageID: UUID(), role: .user,
            excerpt: pending.question, resolvedQuestion: pending.question, run: nil)
        let question = "请重新计算修改后的目标。"
        let cases: [(String, UUID?)] = [("continuation", nil), ("newQuestion", reference.messageID)]
        for (relation, id) in cases {
            var response = payload(question: question, action: "reply", methods: [],
                relation: relation, reference: id, execution: execution("calculate", "changed", question))
            response["resumePending"] = true
            let plan = try await planned(question: question, payload: response,
                                         references: [reference], pendingPlan: pending)
            assertClarification(plan, context: relation)
            XCTAssertEqual(plan.resumesPendingQuestion, false)
        }
    }

    func testAReadingReferenceCannotMasqueradeAsThePendingTextQuestion() async throws {
        let pending = makePendingPlan()
        let reference = ConversationPlanningReference(messageID: UUID(), role: .assistant,
            excerpt: pending.question, resolvedQuestion: pending.question, run: makeRun(methods: [.bazi]))
        let question = "请重新计算修改后的目标。"
        let plan = try await planned(question: question,
            payload: payload(question: question, action: "reply", methods: [],
                reference: reference.messageID, execution: execution("calculate", "changed", question)),
            references: [reference], pendingPlan: pending, available: [.tarot])
        assertClarification(plan)
    }

    private func execution(_ operation: String, _ coverage: String, _ evidence: String) -> [String: Any] {
        ["operation": operation, "coverage": coverage, "evidence": evidence]
    }

    private func payload(question: String, action: String, methods: [String],
                         relation: String = "continuation", reference: UUID? = nil,
                         execution: Any? = nil) -> [String: Any] {
        var understanding: [String: Any] = ["relation": relation, "resolvedQuestion": question]
        if let reference { understanding["referenceMessageID"] = reference.uuidString }
        if let execution { understanding["execution"] = execution }
        return ["action": action, "intent": "Synthetic planning fixture", "subject": "事件",
                "methods": methods, "requiredFields": [], "note": "Please confirm the next step.",
                "question": "An untrusted model-written replacement", "understanding": understanding]
    }

    private func makeRun(methods: [OracleMethod]) -> OracleRun {
        let question = "Earlier synthetic project question"
        var input = OracleInput(question: question, profile: OracleProfile(),
                                castingDate: Date(timeIntervalSince1970: 1_730_000_000), seed: 17)
        input.subject = "事件"
        let plan = OraclePlan(intent: "Fixture", subject: "事件", methods: methods,
                              requiredFields: [], note: "", question: question)
        return OracleRun(input: input, plan: plan,
                         results: methods.map { OracleResult(method: $0, headline: "Synthetic saved result", rows: []) })
    }

    private func makeReference(run: OracleRun) -> ConversationPlanningReference {
        ConversationPlanningReference(messageID: UUID(), role: .assistant, excerpt: "Earlier synthetic answer",
                                      resolvedQuestion: run.input.question, run: run)
    }

    private func makePendingPlan() -> OraclePlan {
        var plan = OraclePlan(intent: "An unfinished synthetic form", subject: "事件", methods: [.tarot],
                              requiredFields: [], note: "", question: "Earlier synthetic question awaiting confirmation")
        plan.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        plan.interactions = [.init(method: .tarot, kind: .tarot, prompt: "An old, partially completed interaction")]
        plan.mandatoryMethods = [.tarot]
        plan.draftNumbers = [11, 22, 33]
        var person = OracleProfile()
        person.name = "Synthetic draft participant"
        person.currentPlace = "An old casting place"
        person.currentLatitude = 40.03102
        person.currentLongitude = 116.22108
        person.currentTimeZoneID = "Asia/Shanghai"
        plan.castingProfile = person
        plan.draftParticipants = [person]
        plan.reviewedParticipants = [person]
        return plan
    }

    private func assertClarification(_ plan: OraclePlan, context: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.action, "clarify", context, file: file, line: line)
        XCTAssertTrue(plan.methods.isEmpty, context, file: file, line: line)
        XCTAssertTrue(plan.requiredFields.isEmpty, context, file: file, line: line)
        XCTAssertTrue(plan.interactions?.isEmpty == true, context, file: file, line: line)
        XCTAssertNil(plan.baseRunID, context, file: file, line: line)
    }

    private func planned(question: String, payload: [String: Any], existingRun: OracleRun? = nil,
                         references: [ConversationPlanningReference] = [],
                         pendingPlan: OraclePlan? = nil,
                         available: Set<OracleMethod> = Set(OracleMethod.allCases)) async throws -> OraclePlan {
        let key = "execution-planning-fixture-" + UUID().uuidString
        let content = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let response = try JSONSerialization.data(withJSONObject: [
            "model": DeepSeekConfiguration.defaultModel,
            "choices": [["message": ["content": content], "finish_reason": "stop"]]
        ])
        ExecutionPlanningURLProtocol.install(.init(body: response, question: question), for: key)
        defer { ExecutionPlanningURLProtocol.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExecutionPlanningURLProtocol.self]
        let client = DeepSeekClient(accessToken: key, sessionConfiguration: configuration)
        let plugins = PluginRegistry().descriptors.filter { available.contains($0.method) }
        let plan = try await client.plan(question: question, profile: OracleProfile(), plugins: plugins,
                                         history: [], pendingPlan: pendingPlan, existingRun: existingRun, references: references,
                                         language: .english)
        XCTAssertEqual(ExecutionPlanningURLProtocol.requestCount(for: key), 1,
                       "Planning should validate the decoded response, not retry malformed intent as a transport failure")
        return plan
    }
}

private final class ExecutionPlanningURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture: Sendable {
        let body: Data
        let question: String
    }

    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]
    private static var counts: [String: Int] = [:]

    static func install(_ fixture: Fixture, for key: String) {
        lock.withLock { fixtures["Bearer " + key] = fixture; counts["Bearer " + key] = 0 }
    }

    static func remove(_ key: String) {
        lock.withLock {
            fixtures.removeValue(forKey: "Bearer " + key)
            counts.removeValue(forKey: "Bearer " + key)
        }
    }

    static func requestCount(for key: String) -> Int {
        lock.withLock { counts["Bearer " + key] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let fixture = try XCTUnwrap(Self.lock.withLock { () -> Fixture? in
                guard let fixture = Self.fixtures[key] else { return nil }
                Self.counts[key, default: 0] += 1
                return fixture
            })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData()) as? [String: Any])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(body["model"] as? String, DeepSeekConfiguration.defaultModel)
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.first?["role"], "system")
            XCTAssertTrue(messages.last?["content"]?.contains(fixture.question) == true)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func requestData() throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            guard count > 0 else { throw stream.streamError ?? URLError(.badServerResponse) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
