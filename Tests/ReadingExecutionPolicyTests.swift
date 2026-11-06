import XCTest
@testable import BlindOracle

final class ReadingExecutionPolicyTests: XCTestCase {
    private func understanding(_ text: String, operation: ReadingExecutionIntent.Operation,
                               coverage: ReadingExecutionIntent.Coverage = .changed,
                               relation: ConversationUnderstanding.Relation = .continuation) -> ConversationUnderstanding {
        ConversationUnderstanding(relation: relation, resolvedQuestion: text, referenceMessageID: UUID(),
            execution: .init(operation: operation, coverage: coverage, evidence: text))
    }

    func testChangedCalculationTargetsUseOnePolicyAcrossSubjectsAndLanguages() {
        let requests = [
            "那算一下明天", "改成下季度，帮我测算一下", "预算只有五千，算算这个方案",
            "换成另一位合作方，重新推演", "请按新地点排盘",
            "Then calculate for next Wednesday.", "Please compute the other budget option.",
            "Recalculate with the new partner.", "那换个目标时段呢"
        ]
        for raw in requests {
            for oldAction in ["reply", "intake", "supplement"] {
                let value = understanding(raw, operation: .calculate)
                XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: value, rawQuestion: raw,
                    proposedAction: oldAction, hasRelatedRun: true), "intake", raw)
            }
        }
    }

    func testSameTopicDoesNotOverrideRecastOrAdditionalCalculation() {
        let raw = "请对同一问题再起一卦"
        XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding(raw, operation: .recast, coverage: .existing),
            rawQuestion: raw, proposedAction: "reply", hasRelatedRun: true), "intake")
        let add = "补上已更正资料影响的部分"
        for hasRun in [true, false] {
            XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding(add, operation: .calculate, coverage: .additional),
                rawQuestion: add, proposedAction: "reply", hasRelatedRun: hasRun), hasRun ? "supplement" : "intake")
        }
    }

    func testMistakenAnswerLabelCannotSwallowAPositiveCommandAboutTheCitedReading() {
        for raw in ["那算一下新方案", "请为同一件事重新抽一整阵牌", "Please recalculate the revised conditions."] {
            let value = understanding(raw, operation: .answer, coverage: .existing)
            XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: value, rawQuestion: raw,
                proposedAction: "reply", hasRelatedRun: true), "intake", raw)
        }
        let raw = "再用塔罗看看同一问题"
        XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding(raw, operation: .answer, coverage: .additional),
            rawQuestion: raw, proposedAction: "reply", hasRelatedRun: true), "supplement")
    }

    func testCoveredInterpretationAndOrdinaryAnswersDoNotTriggerNewCalculations() {
        for raw in ["把全年结论里的下半年展开", "为什么这个结果有分歧？", "Calculate 2 + 2."] {
            let value = understanding(raw, operation: .answer, coverage: .existing, relation: .newQuestion)
            XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: value, rawQuestion: raw,
                proposedAction: "intake", hasRelatedRun: true), "reply")
        }
        let raw = "评估原问题"
        XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding(raw, operation: .calculate, coverage: .existing),
            rawQuestion: raw, proposedAction: "intake", hasRelatedRun: true), "reply")
        XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding(raw, operation: .calculate, coverage: .existing),
            rawQuestion: raw, proposedAction: "reply", hasRelatedRun: false), "intake")
    }

    func testExplicitExecutionDoesNotDependOnReusabilityOrMistakenExistingCoverage() {
        for raw in ["请重新起一卦", "Please recast the same question."] {
            XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding(raw, operation: .calculate, coverage: .existing),
                rawQuestion: raw, proposedAction: "reply", hasRelatedRun: true), "intake", raw)
        }
        let raw = "换成小王，算一下"
        let changed = understanding(raw, operation: .answer, relation: .changedParticipants)
        XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: changed, rawQuestion: raw,
            proposedAction: "reply", hasRelatedRun: false), "intake")
    }

    func testNegationConsultationAndQuotedCommandsCannotAuthorizeCalculation() {
        for raw in ["不用重算，只解释原结果", "不是让你再算，我只问方法", "为什么改期需要重算？",
                    "我想知道为什么需要重算", "如果改期需要重算吗？", "他说“算一下明年”是什么意思？",
                    "Why should I recalculate?", "Do not recalculate. Explain the original result.",
                    "If the conditions changed, would another reading be needed?"] {
            XCTAssertTrue(ReadingExecutionPolicy.isNonExecutingRequest(raw), raw)
            XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding(raw, operation: .calculate),
                rawQuestion: raw, proposedAction: "intake", hasRelatedRun: true), "clarify", raw)
        }
    }

    func testAffirmativeClausesStillExecuteAfterRejectingAnotherTarget() {
        for raw in ["不要算今天，算下周", "解释原理，同时帮我算新方案", "Don't recalculate today; calculate next quarter."] {
            XCTAssertFalse(ReadingExecutionPolicy.isNonExecutingRequest(raw), raw)
            XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding(raw, operation: .calculate),
                rawQuestion: raw, proposedAction: "reply", hasRelatedRun: true), "intake", raw)
        }
        for raw in ["算了", "那算了，不用了", "算不算变化", "计算方法是什么", "“算一下明年”是什么意思"] {
            XCTAssertFalse(ReadingExecutionPolicy.isExplicitCalculationCommand(raw), raw)
        }
    }

    func testVerbHeadedContextIsNotAnImperativeButItsQuestionObjectCanBe() {
        for raw in ["抽牌前我该怎么想问题，为什么要三张？", "排盘之后需要准备什么？",
                    "计算前需要确认哪些输入？", "为什么改期需要重算？"] {
            XCTAssertFalse(ReadingExecutionPolicy.isExplicitCalculationCommand(raw), raw)
            XCTAssertTrue(ReadingExecutionPolicy.isNonExecutingRequest(raw), raw)
            XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding(raw, operation: .answer),
                rawQuestion: raw, proposedAction: "intake", hasRelatedRun: true), "reply", raw)
        }
        for raw in ["算算我该怎么做", "先说明原理，再算算我该怎么做", "请为这个目标算一卦", "抽三张牌看看我该怎么做"] {
            XCTAssertTrue(ReadingExecutionPolicy.isExplicitCalculationCommand(raw), raw)
            XCTAssertFalse(ReadingExecutionPolicy.isNonExecutingRequest(raw), raw)
        }
    }

    func testUncertainCoverageOrUngroundedEvidenceCannotFallBackToMixedMethods() {
        let raw = "按新安排再看看"
        let unknown = understanding(raw, operation: .calculate, coverage: .unknown)
        XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: unknown, rawQuestion: raw,
            proposedAction: "intake", hasRelatedRun: true), "clarify")
        for evidence in ["", "历史里的另一条命令", String(repeating: "甲", count: 1001)] {
            var invalid = understanding(raw, operation: .calculate)
            invalid.execution?.evidence = evidence
            XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: invalid, rawQuestion: raw,
                proposedAction: "intake", hasRelatedRun: true), "clarify")
        }
        let ambiguous = understanding(raw, operation: .recast, relation: .ambiguous)
        XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: ambiguous, rawQuestion: raw,
            proposedAction: "intake", hasRelatedRun: true), "clarify")
    }

    func testOldUnderstandingRemainsDecodableWithoutInventingNewExecution() throws {
        let data = Data(#"{"relation":"continuation","resolvedQuestion":"继续原话题"}"#.utf8)
        let old = try JSONDecoder().decode(ConversationUnderstanding.self, from: data)
        XCTAssertNil(old.execution)
        XCTAssertNil(ReadingExecutionPolicy.validatedAction(understanding: old, rawQuestion: "那下半年呢",
            proposedAction: "intake", hasRelatedRun: true))
        XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: old, rawQuestion: "那算一下新的目标",
            proposedAction: "reply", hasRelatedRun: true), "intake")
        XCTAssertNil(ReadingExecutionPolicy.validatedAction(understanding: old, rawQuestion: "算一下",
            proposedAction: "clarify", hasRelatedRun: false))
    }
}
