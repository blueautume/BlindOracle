import XCTest
@testable import BlindOracle

final class ReadingContinuationTests: XCTestCase {
    private func reading(method: OracleMethod = .liuyao, status: OracleResultStatus = .complete) -> OracleRun {
        let plan = OraclePlan(intent: "事业选择", subject: "事件", methods: [method], requiredFields: [], note: "", question: "这次工作机会如何？")
        var input = OracleInput(question: plan.question, profile: OracleProfile(), seed: 42)
        input.manualLines = [6, 7, 8, 9, 7, 8]
        var run = OracleRun(input: input, plan: plan)
        run.results = [OracleResult(method: method, status: status, headline: "已保存的盘面", rows: [.init("本卦", "乾为天")])]
        run.synthesis = ReadingSynthesis(text: "原有解读", alternatives: [])
        run.completedAt = Date(timeIntervalSince1970: 100)
        return run
    }

    func testDetailsAndConversationalFollowupsKeepTheExistingReading() {
        for question in ["这个卦里的动爻是什么意思？", "为什么这样判断？", "能展开说说吗", "那我具体应该怎么做？", "世爻和应爻的关系能解释一下吗", "用六爻解释一下这卦", "继续", "谢谢", "你刚刚说的阻力指什么", "再讲讲你是怎么算的"] {
            XCTAssertTrue(ReadingContinuationPolicy.shouldReuse(question: question, run: reading(), pendingPlan: nil), question)
        }
    }

    func testOnlyConcreteFreshReadingRequestsLeaveTheSavedReading() {
        for question in ["重新起卦", "请重新算一次", "再算一卦", "再帮我算一下下个月的事业", "换个问题，看看感情", "我想另问一件事", "重新六掷成卦", "再抽三张牌", "帮我算算婚姻", "改用塔罗抽牌看看", "再用六爻起一卦", "重新抽一次牌", "重新抽三张牌", "再抽一次", "再掷六次", "再来一卦", "只用六爻再帮我算一次"] {
            XCTAssertTrue(ReadingContinuationPolicy.explicitlyRequestsNewReading(question), question)
            XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: question, run: reading(), pendingPlan: nil), question)
        }
    }

    func testBareRecastCommandsKeepTheOriginalQuestionScope() {
        for question in ["重新起卦", "再算一卦", "重新抽一次牌", "再掷六次", "请重新算一次", "再来一卦", "重新抽三张牌。", "麻烦你再抽一次，谢谢！", "只用六爻再帮我算一次", "重新起卦，只用六爻", "请重新六掷成卦吧"] {
            XCTAssertTrue(ReadingContinuationPolicy.isBareRecastRequest(question), question)
        }
    }

    func testRecastWithANewQuestionOrProfileUpdateIsNotABareCommand() {
        for question in ["重新起卦只用六爻看看明天出行是否顺利", "再帮我算一下下个月的事业", "重新抽一次牌，看看我和李四的感情", "陈平出生时间改为09:30，重新起卦", "换个问题", "我想另问一件事", "不要重新起卦", "为什么要重新抽一次牌？", "这个卦是什么意思？"] {
            XCTAssertFalse(ReadingContinuationPolicy.isBareRecastRequest(question), question)
        }
    }

    func testNegatedFreshReadingRequestsRemainFollowups() {
        for question in ["不要重新算，只解释原卦", "不用重新起卦", "我不是要重新抽牌，是想知道这张牌的意思", "不需要现在重新起卦，继续分析", "我不想再算一卦", "无需再帮我算一下", "别换个问题，继续讲刚才的", "不要重新六掷，直接解释", "不用重新抽一次牌", "不要再掷六次了"] {
            XCTAssertFalse(ReadingContinuationPolicy.explicitlyRequestsNewReading(question), question)
            XCTAssertTrue(ReadingContinuationPolicy.shouldReuse(question: question, run: reading(), pendingPlan: nil), question)
        }
    }

    func testQuestionsAboutRecastingDoNotCountAsPermissionToRecast() {
        for question in ["为什么要重新起卦？", "什么时候需要重新算？", "什么情况下需要再算一卦？", "重新起卦是什么意思？", "你说“重新起卦”是什么意思？", "解释一下重新起卦的步骤", "一定要重新六掷吗？"] {
            XCTAssertFalse(ReadingContinuationPolicy.explicitlyRequestsNewReading(question), question)
            XCTAssertTrue(ReadingContinuationPolicy.shouldReuse(question: question, run: reading(), pendingPlan: nil), question)
        }
    }

    func testAnAffirmativeNewRequestInAnotherClauseStillStartsNewPreparation() {
        for question in ["不要只解释，我要重新起卦", "不用旧卦了，重新算一次", "无需重新起卦，改用塔罗抽牌看看"] {
            XCTAssertTrue(ReadingContinuationPolicy.explicitlyRequestsNewReading(question), question)
        }
    }

    func testPendingQuestionKeepsItsPreparationFlow() {
        var plan = reading().plan
        plan.preparationStage = .confirming
        XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: "确认，开始", run: reading(), pendingPlan: plan))
        plan.preparationStage = .collecting
        XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: "上午八点", run: reading(), pendingPlan: plan))
    }

    func testMissingDeletedOrUnavailableReadingsCannotBecomeFollowupEvidence() {
        XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: "解释一下", run: nil, pendingPlan: nil))
        for status in [OracleResultStatus.failed, .unavailable] {
            XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: "解释一下", run: reading(status: status), pendingPlan: nil))
        }
        var empty = reading(); empty.results = []
        XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: "解释一下", run: empty, pendingPlan: nil))
        XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: " \n ", run: reading(), pendingPlan: nil))
    }

    func testPartialAndRestoredTarotOrCoinReadingsRemainReusableWithoutNewRandomInput() throws {
        for method in [OracleMethod.liuyao, .tarot] {
            let saved = reading(method: method, status: .partial)
            let restored = try JSONDecoder().decode(OracleRun.self, from: JSONEncoder().encode(saved))
            XCTAssertTrue(ReadingContinuationPolicy.shouldReuse(question: "这部分能解释得详细一点吗？", run: restored, pendingPlan: nil))
            XCTAssertEqual(restored.id, saved.id)
            XCTAssertEqual(restored.input.seed, saved.input.seed)
            XCTAssertEqual(restored.input.manualLines, saved.input.manualLines)
        }
    }
}
