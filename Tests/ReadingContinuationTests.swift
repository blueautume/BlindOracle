import XCTest
@testable import BlindOracle

final class ReadingContinuationTests: XCTestCase {
    private func reading(method: OracleMethod = .liuyao, status: OracleResultStatus = .complete) -> OracleRun {
        let plan = OraclePlan(intent: "事业选择", subject: "事件", methods: [method], requiredFields: [], note: "", question: "这次工作机会如何？")
        var input = OracleInput(question: plan.question, profile: OracleProfile(), seed: 42)
        input.manualLines = [6, 7, 8, 9, 7, 8]
        var run = OracleRun(input: input, plan: plan)
        run.results = [OracleResult(method: method, status: status, headline: "已保存的盘面", rows: [.init("本卦", "乾为天")])]
        run.synthesis = ReadingSynthesis(text: "原有解读")
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
        for question in ["重新起卦", "再算一卦", "重新抽一次牌", "再掷六次", "请重新算一次", "再来一卦", "重新抽三张牌。", "麻烦你再抽一次，谢谢！", "只用六爻再帮我算一次", "重新起卦，只用六爻", "请重新六掷成卦吧", "我是想重新抽三张牌，不是解释旧结果。"] {
            XCTAssertTrue(ReadingContinuationPolicy.isBareRecastRequest(question), question)
        }
    }

    func testRecastWithANewQuestionOrProfileUpdateIsNotABareCommand() {
        for question in ["重新起卦只用六爻看看明天出行是否顺利", "再帮我算一下下个月的事业", "重新抽一次牌，看看我和李四的感情", "陈平出生时间改为09:30，重新起卦", "换个问题", "我想另问一件事", "不要重新起卦", "为什么要重新抽一次牌？", "这个卦是什么意思？", "我是想重新抽三张牌看看下个月的工作，不是解释旧结果。"] {
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

    func testShortRedrawCommandsKeepTheQuestionButChangeTheDraw() {
        for question in ["重新抽", "重抽", "请重新抽吧", "再抽一次"] {
            XCTAssertTrue(ReadingContinuationPolicy.explicitlyRequestsNewReading(question), question)
            XCTAssertTrue(ReadingContinuationPolicy.isBareRecastRequest(question), question)
        }
        for question in ["不要重新抽", "先别重抽", "重新抽象描述一下"] {
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

    func testExplicitAdditionalMethodsRequirePreparationWithoutAuthorizingAFreshDraw() {
        let cases: [(String, [OracleMethod])] = [
            ("加上八字和紫微一起看看", [.bazi, .ziwei]),
            ("帮我补算占星", [.astrology]),
            ("再用八字看看", [.bazi]),
            ("再用小六壬算一下", [.xiaoliuren]),
            ("用八字看看", [.bazi]),
            ("请用占星排盘分析", [.astrology]),
            ("姓名五格也算一下", [.xingming]),
            ("加上姓名学", [.xingming]),
            ("加上塔罗", [.tarot]),
            ("加上塔罗抽牌看看", [.tarot]),
            ("不要补算八字，加上称骨", [.chenggu]),
            ("加上八字但不要紫微", [.bazi])
        ]
        for (question, expected) in cases {
            XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: question), expected, question)
            XCTAssertFalse(ReadingContinuationPolicy.explicitlyRequestsNewReading(question), question)
            XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: question, run: reading(), pendingPlan: nil), question)
        }
    }

    func testMentioningExplainingOrRejectingAdditionalMethodsDoesNotCalculateThem() {
        for question in ["解释八字是什么", "八字和紫微有什么区别", "不要补算八字", "不要补算", "不用再用占星算一下", "不用八字看看", "不要用占星排盘分析", "用六爻解释一下这卦", "用八字排盘的原理是什么", "加上张三的姓名资料", "为什么要补算八字？", "补算八字是什么意思", "我想了解补算紫微的步骤", "再用六爻起一卦", "改用塔罗抽牌看看", "再用TAROT抽三张牌"] {
            XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: question).isEmpty, question)
        }
    }

    func testNaturalCalculationCommandsRecognizeEveryMethod() {
        let names: [(OracleMethod, String)] = [
            (.bazi, "八字"), (.ziwei, "紫微斗数"), (.liuyao, "六爻"), (.meihua, "梅花易数"),
            (.qimen, "奇门遁甲"), (.xiaoliuren, "小六壬"), (.chenggu, "称骨"),
            (.xingming, "姓名五格"), (.astrology, "西方占星"), (.tarot, "塔罗牌")
        ]
        XCTAssertEqual(Set(names.map(\.0)), Set(OracleMethod.allCases))
        for (method, name) in names {
            for verb in ["计算", "分析", "试试", "算算", "看看"] {
                let question = "请用\(name)\(verb)今晚的运势"
                XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: question), [method], question)
                XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: question), [method], question)
                XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: question, requiresAdditiveWording: true).isEmpty, question)
                XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: question, run: reading(), pendingPlan: nil), question)
                XCTAssertFalse(ReadingContinuationPolicy.isMethodOnlyRequest(question), question)
            }
        }
    }

    func testTarotActivationRequestsKeepBareMethodCommandsDistinctFromANewSubject() {
        let retry = "你再用塔罗牌再试试呢？"
        XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: retry), [.tarot])
        XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: retry, requiresAdditiveWording: true), [.tarot])
        XCTAssertTrue(ReadingContinuationPolicy.isMethodOnlyRequest(retry))
        XCTAssertFalse(ReadingContinuationPolicy.explicitlyRequestsNewReading(retry))

        let tonight = "用塔罗牌计算今晚的运势"
        XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: tonight), [.tarot])
        XCTAssertFalse(ReadingContinuationPolicy.isMethodOnlyRequest(tonight))
        for question in ["请用塔罗牌计算吧", "你用塔罗牌仔细分析一下", "再用八字试一试呢", "请用紫微斗数算算吧",
                         "再用小六壬试试看", "再用梅花易数分析一下", "再用塔罗牌再试试呢"] {
            XCTAssertTrue(ReadingContinuationPolicy.isMethodOnlyRequest(question), question)
            XCTAssertFalse(ReadingContinuationPolicy.requestedCalculationMethods(in: question).isEmpty, question)
        }
    }

    func testActivationTroubleshootingAndMethodExplanationsDoNotAuthorizeCalculation() {
        for question in ["为什么不启动塔罗牌呢？", "现在无法激活塔罗牌", "其他方法能不能正常激活？",
                         "不要用塔罗牌计算", "不用再用塔罗牌试试", "别用八字分析",
                         "如何用八字计算？", "怎样用塔罗牌分析？", "你再用塔罗牌怎么计算？",
                         "用塔罗牌计算是什么意思？", "我想了解用塔罗牌计算的步骤", "请解释用塔罗牌计算运势的原理"] {
            XCTAssertTrue(ReadingContinuationPolicy.requestedCalculationMethods(in: question).isEmpty, question)
            XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: question).isEmpty, question)
            XCTAssertFalse(ReadingContinuationPolicy.isMethodOnlyRequest(question), question)
        }
        XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: "不用塔罗牌计算，改用八字分析我的工作"), [.bazi])
    }

    func testExplicitMethodCommandsRemainAvailableAfterFreshScopeIsExcludedFromSupplements() {
        for (question, method) in [("换个问题，用塔罗牌计算明天的工作", OracleMethod.tarot),
                                   ("重新起卦，再用六爻计算", .liuyao),
                                   ("再用塔罗抽三张牌", .tarot),
                                   ("New question: use Tarot to examine tomorrow's interview.", .tarot),
                                   ("Please redraw. Use Tarot.", .tarot)] {
            XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: question).isEmpty, question)
            XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: question), [method], question)
        }
    }

    func testPreparationConsultationsDoNotStartCalculationsButSeparateCommandsStillDo() {
        for question in ["我先问问，用塔罗算要准备什么资料？", "我先问问用塔罗计算要准备什么",
                         "用八字算需要出生时间吗？", "用塔罗要不要提供生日？", "为什么需要排盘性别？",
                         "塔罗是干什么的？", "八字怎么算？", "我只是问问，不是现在算。",
                         "先别发起抽牌，告诉我塔罗和六爻有什么区别。"] {
            XCTAssertTrue(ReadingContinuationPolicy.isMethodConsultation(question), question)
            XCTAssertTrue(ReadingContinuationPolicy.requestedCalculationMethods(in: question).isEmpty, question)
            XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: question).isEmpty, question)
            XCTAssertFalse(ReadingContinuationPolicy.isMethodOnlyRequest(question), question)
        }
        for question in ["先解释塔罗是什么，然后用八字算算今晚的运势", "性别是必填吗？只先用八字算算"] {
            XCTAssertFalse(ReadingContinuationPolicy.isMethodConsultation(question), question)
            XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: question), [.bazi], question)
        }
        XCTAssertFalse(ReadingContinuationPolicy.isMethodConsultation("用塔罗看看我下周面试应该准备什么材料"))
        XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: "用塔罗看看我下周面试应该准备什么材料"), [.tarot])
    }

    func testParallelMethodCommandsAndOnlySelectionsRespectExplicitExclusions() {
        let cases: [(String, [OracleMethod])] = [
            ("用塔罗和八字一起看看", [.bazi, .tarot]),
            ("请用塔罗、八字、占星一起分析", [.bazi, .astrology, .tarot]),
            ("用八字和紫微一起排盘", [.bazi, .ziwei]),
            ("只要塔罗不要八字", [.tarot]),
            ("只用塔罗，不要八字", [.tarot]),
            ("用塔罗和八字一起看看，不要八字", [.tarot]),
            ("先不抽了，改用梅花", [.meihua]),
            ("不用旧方法，换成小六壬", [.xiaoliuren])
        ]
        for (question, expected) in cases {
            XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: question), expected, question)
            XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: question, run: reading(), pendingPlan: nil), question)
        }
        for question in ["用塔罗和八字一起看看", "只要塔罗不要八字", "只用塔罗，不要八字"] {
            XCTAssertTrue(ReadingContinuationPolicy.isMethodOnlyRequest(question), question)
        }
        for question in ["不要用塔罗和八字一起看看", "塔罗和八字有什么区别", "请解释只用塔罗是什么意思"] {
            XCTAssertTrue(ReadingContinuationPolicy.requestedCalculationMethods(in: question).isEmpty, question)
        }
    }

    func testRejectingOldCardsAndRequestingNewOnesRedrawsWithoutChangingTheQuestion() {
        for question in ["别用旧牌，换一组新的", "不要旧牌再用塔罗看看", "请别用旧牌，重新用塔罗算算吧"] {
            XCTAssertTrue(ReadingContinuationPolicy.explicitlyRequestsNewReading(question), question)
            XCTAssertTrue(ReadingContinuationPolicy.isBareRecastRequest(question), question)
            XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: question).isEmpty, question)
            XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: question, run: reading(method: .tarot), pendingPlan: nil), question)
        }
        XCTAssertFalse(ReadingContinuationPolicy.isBareRecastRequest("别用旧牌，再用塔罗看看我下周的面试"))
        for question in ["不要重抽", "别用旧牌，也不要重新抽", "不是不要旧牌，只解释原牌阵"] {
            XCTAssertFalse(ReadingContinuationPolicy.explicitlyRequestsNewReading(question), question)
        }
    }

    func testMixedSupplementCommandsRecognizeLaterNamedCalculations() {
        for question in ["补算八字，再帮我算一下占星", "加上八字，然后也算一下占星", "用八字看看，再帮我算一下占星", "不用重新起卦，补算八字，再帮我算一下占星"] {
            XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: question), [.bazi, .astrology], question)
            XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: question, run: reading(), pendingPlan: nil), question)
        }
        for question in ["重新起卦，再加上八字", "重抽三张牌，再用占星算一下", "换个问题，加上八字", "加上八字，再用塔罗抽三张牌"] {
            XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: question).isEmpty, question)
            XCTAssertTrue(ReadingContinuationPolicy.explicitlyRequestsNewReading(question), question)
        }
    }

    func testMethodSelectionAndExistingReadingAdditionsHaveDifferentScopes() {
        let newTopic = "不用八字，用塔罗看看我下周的面试会不会顺利"
        XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: newTopic), [.tarot])
        XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: newTopic, requiresAdditiveWording: true).isEmpty)
        XCTAssertFalse(ReadingContinuationPolicy.isMethodOnlyRequest(newTopic))
        XCTAssertTrue(ReadingContinuationPolicy.isMethodOnlyRequest("请用塔罗看看吧"))
        XCTAssertFalse(ReadingContinuationPolicy.isMethodOnlyRequest("不用塔罗看看"))
        let supplement = "不用八字，加上塔罗，再帮我算一下占星"
        XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: supplement, requiresAdditiveWording: true), [.tarot])
        XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: supplement), [.astrology, .tarot])
        XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: "解释这张牌并补算八字", requiresAdditiveWording: true), [.bazi])
        XCTAssertTrue(ReadingContinuationPolicy.explicitlyRequestsNewReading("我想问一个新问题，看看面试"))
        XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: "我想问一个新问题，加上塔罗").isEmpty)
    }

    func testBareMethodChangesRequireAnAffirmativeSwitchWithoutANewSubject() {
        let commands: [(String, [OracleMethod])] = [
            ("改用塔罗", [.tarot]), ("换成紫微", [.ziwei]), ("那就换成紫薇吧", [.ziwei]),
            ("请把方法改用 Tarot。", [.tarot]), ("这次改用八字和占星看看", [.bazi, .astrology])
        ]
        for (question, methods) in commands {
            XCTAssertEqual(ReadingContinuationPolicy.bareMethodChange(in: question), methods, question)
        }
        for question in ["不要改用塔罗", "不只换成塔罗", "不是只改用紫微", "换成塔罗，看看下周面试", "改用紫微看看她的事业", "换成李岚", "用塔罗看看", "换成塔罗或八字"] {
            XCTAssertTrue(ReadingContinuationPolicy.bareMethodChange(in: question).isEmpty, question)
        }
    }

    func testSavedTarotExplanationGuardLeavesNewAndMixedRequestsToPlanning() {
        for question in ["第二张牌为什么是逆位？", "能解释一下建议牌和现状牌的关系吗？", "不用补牌，只解释建议牌。", "不用八字，继续解释原结果"] {
            XCTAssertTrue(ReadingContinuationPolicy.isSavedTarotExplanation(question), question)
        }
        for question in ["用塔罗看看我下周的面试会不会顺利", "第二张牌为什么是逆位，我下周的面试会怎样？",
                         "解释一下这张牌并加抽一张", "解释这张牌并补算八字", "不要解释这张牌", "换个新问题，解释一下这张牌"] {
            XCTAssertFalse(ReadingContinuationPolicy.isSavedTarotExplanation(question), question)
        }
    }

    func testPlainChangeOfTopicDoesNotFallBackToTheSavedReading() {
        let saved = reading()
        for question in ["我最近和对象总吵架，还能走下去吗？", "那感情呢？", "下周要出差，路上会顺利吗？"] {
            XCTAssertFalse(ReadingContinuationPolicy.shouldReuse(question: question, run: saved, pendingPlan: nil), question)
        }
        for question in ["那我接下来该怎么做？", "面试那天该注意什么？", "这部分具体是什么意思？"] {
            XCTAssertTrue(ReadingContinuationPolicy.shouldReuse(question: question, run: saved, pendingPlan: nil), question)
        }
    }

    func testParticipantIntentKeepsTheReplacementAndExcludesNegatedNames() {
        var chen = OracleProfile(); chen.name = "陈平"
        var li = OracleProfile(); li.name = "李岚"
        let directory = [chen, li]
        let replacement = ReadingContinuationPolicy.participantIntent(in: "不看陈平了，换成李岚，看看她的工作", profiles: directory)
        XCTAssertEqual(replacement.names, ["李岚"])
        XCTAssertEqual(replacement.excludedNames, ["陈平"])
        XCTAssertFalse(replacement.isGroup)
        let negated = ReadingContinuationPolicy.participantIntent(in: "别换成李岚，继续看陈平", profiles: directory)
        XCTAssertEqual(negated.names, ["陈平"])
        XCTAssertEqual(negated.excludedNames, ["李岚"])
        XCTAssertFalse(ReadingContinuationPolicy.explicitlyChangesScope("别换成李岚，继续看陈平", profiles: directory))
        XCTAssertTrue(ReadingContinuationPolicy.explicitlyChangesScope("不看陈平了，换成李岚，看看她的工作", profiles: directory))
    }

    func testSelfAndOtherRequireAnExplicitJointEvaluationRatherThanAGroupEvent() {
        var other = OracleProfile(); other.name = "李岚"
        let directory = [other]
        let couple = ReadingContinuationPolicy.participantIntent(in: "我和李岚合不合", profiles: directory)
        XCTAssertEqual(couple.names, ["李岚"])
        XCTAssertTrue(couple.includesSelf)
        XCTAssertTrue(couple.isGroup)
        XCTAssertFalse(ReadingContinuationPolicy.participantIntent(in: "我想问李岚的工作", profiles: directory).includesSelf)
        XCTAssertFalse(ReadingContinuationPolicy.participantIntent(in: "我们两人周末出行，只用小六壬", profiles: directory).isGroup)
        XCTAssertTrue(ReadingContinuationPolicy.participantIntent(in: "我和朋友的关系怎么样", profiles: directory).isGroup)
    }

    func testColloquialFriendshipAndPartnershipRemainGroupReadings() {
        var other = OracleProfile(); other.name = "李岚"
        XCTAssertTrue(ReadingContinuationPolicy.participantIntent(in: "我们一起用塔罗看看友情", profiles: []).isGroup)
        XCTAssertTrue(ReadingContinuationPolicy.participantIntent(in: "想用塔罗看看我们两人的关系会怎么发展？", profiles: []).isGroup)
        let partner = ReadingContinuationPolicy.participantIntent(in: "那我和李岚适合合伙吗？也只用八字。", profiles: [other])
        XCTAssertEqual(partner.names, ["李岚"])
        XCTAssertTrue(partner.includesSelf)
        XCTAssertTrue(partner.isGroup)
    }

    func testNamedUnstoredColleagueStillRefersToAnotherPerson() {
        let colleague = ReadingContinuationPolicy.participantIntent(in: "只用八字看看我同事王安的事业", profiles: [])
        XCTAssertTrue(colleague.refersToOther)
        XCTAssertFalse(colleague.includesSelf)
        XCTAssertFalse(colleague.isGroup)
        let ordinary = ReadingContinuationPolicy.participantIntent(in: "我想问这次出行如何", profiles: [])
        XCTAssertFalse(ordinary.includesSelf)
        XCTAssertFalse(ordinary.refersToOther)
    }

    func testOnlyExplicitScopeCommandsCanDisplaceAPendingDraw() {
        var saved = reading()
        var old = OracleProfile(); old.name = "陈平"
        var other = OracleProfile(); other.name = "李岚"
        saved.input.participants = [old]
        let profiles = [old, other]
        XCTAssertEqual(ReadingContinuationPolicy.scopeChange(question: "李岚最近工作怎么样？", run: saved, profiles: profiles), .inferred)
        XCTAssertEqual(ReadingContinuationPolicy.scopeChange(question: "换成李岚", run: saved, profiles: profiles), .explicit)
        XCTAssertEqual(ReadingContinuationPolicy.scopeChange(question: "换个话题，我想问恋爱", run: nil, profiles: profiles), .explicit)
        XCTAssertEqual(ReadingContinuationPolicy.scopeChange(question: "换成我", run: nil, profiles: profiles), .explicit)
        XCTAssertEqual(ReadingContinuationPolicy.scopeChange(question: "改看我同事", run: nil, profiles: profiles), .explicit)
        XCTAssertEqual(ReadingContinuationPolicy.scopeChange(question: "另问个事", run: nil, profiles: profiles), .explicit)
        XCTAssertEqual(ReadingContinuationPolicy.scopeChange(question: "那感情呢？", run: nil, profiles: profiles), .none)
        XCTAssertEqual(ReadingContinuationPolicy.scopeChange(question: "不用换话题，继续讲刚才的", run: saved, profiles: profiles), .none)
        XCTAssertEqual(ReadingContinuationPolicy.scopeChange(question: "不要换成李岚，陈平呢？", run: saved, profiles: profiles), .none)
    }

    private func completeReading() -> OracleRun {
        var run = reading()
        run.input.castingDate = ISO8601DateFormatter().date(from: "2026-11-03T04:00:00Z")!
        run.input.numbers = [8, 8, 6]
        run.input.profile.name = "王明"
        run.input.profile.familyName = "王"; run.input.profile.givenName = "明"
        run.input.profile.sex = "男"
        run.input.profile.birthDate = ISO8601DateFormatter().date(from: "1990-05-17T04:00:00Z")!
        run.input.profile.birthTimeZoneID = "Asia/Shanghai"
        run.input.profile.currentTimeZoneID = "Asia/Shanghai"
        run.input.profile.birthLatitude = 31.23; run.input.profile.birthLongitude = 121.47
        run.input.profile.currentPlace = "上海市黄浦区"
        run.input.profile.currentLatitude = 31.23; run.input.profile.currentLongitude = 121.47
        run.input.tarotDraws = zip(["major-00", "cups-01", "swords-14"], TarotDeck.positions).map {
            TarotDraw(cardID: $0.0, isReversed: false, position: $0.1)
        }
        run.plan.methods = OracleMethod.allCases
        run.results = OracleMethod.allCases.map { method in
            var result = OracleResult(method: method, headline: "\(method.rawValue)已保存", rows: [])
            if method.usesPersonalProfile {
                result.participantID = run.input.profile.id; result.participantName = "王明"
            }
            return result
        }
        return run
    }

    private func assertInvalidates(_ expected: Set<OracleMethod>, from run: OracleRun? = nil,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  changing: (inout OracleInput) -> Void) {
        let original = run ?? completeReading()
        var candidate = original.input
        changing(&candidate)
        let reused = ReadingContinuationPolicy.reusableResults(from: original, for: candidate, methods: OracleMethod.allCases)
        let previouslyAvailable = Set(original.results.filter { $0.status == .complete || $0.status == .partial }.map(\.method))
        XCTAssertEqual(previouslyAvailable.subtracting(reused.map(\.method)), expected, file: file, line: line)
        for result in reused {
            XCTAssertTrue(original.results.contains { $0.id == result.id }, file: file, line: line)
        }
    }

    func testUnrelatedProfileChangesKeepResultsAndRefreshParticipantNames() {
        assertInvalidates([]) {
            $0.profile.name = "新的显示姓名"; $0.profile.displayName = "备注"
            $0.profile.birthPlace = "更新地点文字"; $0.profile.currentPlace = "更新当前地点文字"
            $0.profile.updatedAt = Date()
        }
        let original = completeReading()
        var candidate = original.input; candidate.profile.name = "新的显示姓名"
        let reused = ReadingContinuationPolicy.reusableResults(from: original, for: candidate, methods: [.bazi])
        XCTAssertEqual(reused.first?.participantName, "新的显示姓名")
        XCTAssertEqual(original.results.first?.participantName, "王明")
    }

    func testBirthEditsInvalidateOnlyMethodsThatUseThoseFields() {
        assertInvalidates([.xingming]) { $0.profile.familyName = "李" }
        assertInvalidates([.xingming]) { $0.profile.unknownFields.insert(.givenName) }
        assertInvalidates([.bazi, .chenggu, .ziwei, .astrology]) { $0.profile.birthDate = $0.profile.birthDate?.addingTimeInterval(86400) }
        assertInvalidates([.bazi, .chenggu, .ziwei, .astrology]) { $0.profile.birthTimeKnown = false }
        assertInvalidates([.bazi, .chenggu, .ziwei, .astrology]) { $0.profile.unknownFields.insert(.birthTimeZone) }
        assertInvalidates([.bazi, .ziwei]) { $0.profile.sex = "女" }
        assertInvalidates([.bazi, .chenggu, .ziwei, .astrology]) { $0.profile.birthLongitude = 120 }
        assertInvalidates([.bazi, .chenggu, .ziwei, .astrology]) { $0.profile.unknownFields.insert(.birthCoordinates) }
        assertInvalidates([.bazi, .chenggu, .ziwei]) { $0.profile.unknownFields.insert(.birthPlace) }
        assertInvalidates([.bazi, .chenggu, .ziwei]) { $0.profile.declaredUnknownFields = [.birthPlace] }
    }

    func testUnknownBirthTimeUsesTheCalendarDayButStillDependsOnBirthCoordinates() {
        var original = completeReading(); original.input.profile.birthTimeKnown = false
        // Ziwei cannot have a valid saved chart without a known time.
        original.results.removeAll { $0.method == .ziwei }
        assertInvalidates([], from: original) {
            $0.profile.birthDate = $0.profile.birthDate?.addingTimeInterval(3600)
            $0.profile.sex = "女"
        }
        assertInvalidates([.bazi, .chenggu], from: original) { $0.profile.birthLatitude = 40 }
        assertInvalidates([.bazi, .chenggu, .astrology], from: original) {
            $0.profile.birthDate = $0.profile.birthDate?.addingTimeInterval(86400)
        }
    }

    func testCastingInputsInvalidateOnlyAffectedMethods() {
        // Three supplied numbers make this Mei Hua result independent of time.
        assertInvalidates([.ziwei, .liuyao, .qimen, .xiaoliuren, .astrology]) { $0.castingDate.addTimeInterval(3600) }
        assertInvalidates([.ziwei, .liuyao, .qimen, .xiaoliuren]) { $0.profile.currentTimeZoneID = "Asia/Tokyo" }
        assertInvalidates([.qimen, .xiaoliuren]) {
            $0.profile.currentDistrictCode = "310115"
            $0.profile.currentLatitude = 31.22; $0.profile.currentLongitude = 121.53
        }
        assertInvalidates([.meihua]) { $0.numbers = [1, 2, 3] }
        assertInvalidates([.liuyao]) { $0.manualLines = [7, 7, 7, 7, 7, 7] }
        assertInvalidates([.tarot]) { $0.tarotDraws?[0].isReversed = true }
        assertInvalidates([.tarot]) {
            $0.tarotClarificationRounds = [.init(request: .init(focus: "进一步理解建议"),
                draw: .init(cardID: "major-01", isReversed: true, position: TarotDeck.clarificationPosition))]
        }
        // Saved manual lines, selected cards and deterministic calendar methods do not use seed.
        assertInvalidates([]) { $0.seed = 100 }
        var simulated = completeReading(); simulated.input.manualLines = []
        assertInvalidates([.liuyao], from: simulated) { $0.seed = 100 }
        assertInvalidates([.liuyao], from: simulated) { $0.castingStyle = "yarrow" }
    }

    func testTwoNumberMeihuaStillDependsOnTheSolarCastingPlaceAndTime() {
        var original = completeReading()
        original.input.numbers = [8, 8]
        assertInvalidates([.ziwei, .liuyao, .meihua, .qimen, .xiaoliuren, .astrology], from: original) {
            $0.castingDate.addTimeInterval(3600)
        }
        assertInvalidates([.meihua, .qimen, .xiaoliuren], from: original) {
            $0.profile.currentLongitude = 120
        }
        assertInvalidates([.meihua, .qimen, .xiaoliuren], from: original) {
            $0.profile.declaredUnknownFields = [.currentLocation]
        }
    }

    func testReuseIsPerParticipantAndCannotTransferChartsToANewUUID() {
        var original = completeReading()
        let first = original.input.profile
        var second = first; second.id = UUID(); second.name = "李四"
        original.input.participants = [first, second]
        var secondResult = OracleResult(method: .bazi, headline: "李四的盘", rows: [])
        secondResult.participantID = second.id; secondResult.participantName = second.resolvedName
        original.results.append(secondResult)
        var candidate = original.input
        candidate.participants?[0].birthDate = first.birthDate?.addingTimeInterval(86400)
        let reused = ReadingContinuationPolicy.reusableResults(from: original, for: candidate, methods: [.bazi])
        XCTAssertEqual(reused.map(\.participantID), [second.id])
        XCTAssertEqual(reused.map(\.id), [secondResult.id])
        candidate.participants = [OracleProfile()]
        XCTAssertTrue(ReadingContinuationPolicy.reusableResults(from: original, for: candidate, methods: [.bazi]).isEmpty)
    }

    func testLegacyUnlabelledResultRequiresExactlyOneOriginalParticipant() {
        var original = completeReading()
        original.results = [OracleResult(method: .bazi, headline: "旧版单人盘", rows: [])]
        let reused = ReadingContinuationPolicy.reusableResults(from: original, for: original.input, methods: [.bazi])
        XCTAssertEqual(reused.first?.participantID, original.input.profile.id)
        XCTAssertEqual(reused.first?.id, original.results.first?.id)
        var second = original.input.profile; second.id = UUID()
        original.input.participants = [original.input.profile, second]
        XCTAssertTrue(ReadingContinuationPolicy.reusableResults(from: original, for: original.input, methods: [.bazi]).isEmpty)
    }

    func testFailedUnavailableAndUnselectedMethodsNeverBecomeReusableResults() {
        var original = completeReading()
        original.results[0].status = .failed; original.results[1].status = .unavailable
        original.results[2].status = .partial
        let reused = ReadingContinuationPolicy.reusableResults(from: original, for: original.input, methods: [.bazi, .ziwei, .liuyao])
        XCTAssertEqual(reused.map(\.method), [.liuyao])
        XCTAssertTrue(ReadingContinuationPolicy.reusableResults(from: original, for: original.input, methods: []).isEmpty)
    }
}

extension ReadingContinuationTests {
    func testEnglishCommandsPreserveReadingScopeAndRespectNegation() {
        XCTAssertTrue(ReadingContinuationPolicy.isBareRecastRequest("Please redraw the cards."))
        XCTAssertFalse(ReadingContinuationPolicy.explicitlyRequestsNewReading("Don't redraw the cards."))
        XCTAssertTrue(ReadingContinuationPolicy.explicitlyChangesScope("Let's switch topics."))
        XCTAssertTrue(ReadingContinuationPolicy.isSavedTarotExplanation("Can you explain the Advice card without drawing again?"))
        XCTAssertEqual(ReadingContinuationPolicy.requestedAdditionalMethods(in: "Please also use BaZi.", requiresAdditiveWording: true), [.bazi])
        XCTAssertTrue(ReadingContinuationPolicy.requestedAdditionalMethods(in: "Why use BaZi?", requiresAdditiveWording: true).isEmpty)
        XCTAssertEqual(EnglishConversation.requestedMethods(in: "Use only Ba Zi.", additive: false), [.bazi])
        XCTAssertEqual(EnglishConversation.requestedMethods(in: "You must use Tarot.", additive: false), [.tarot])
        XCTAssertTrue(EnglishConversation.methods(in: "Don’t use Tarot.").isEmpty)
        XCTAssertEqual(EnglishConversation.clarifierFocus("Could you draw one clarifying card about my next step?"), "my next step")
        XCTAssertNil(EnglishConversation.clarifierFocus("Please don't draw a clarifier."))
        XCTAssertEqual(EnglishConversation.replyLanguage(in: "Please answer in English."), .english)
    }

    func testExplicitLanguageRequestsAllowObjectsAndApplyOnlyToTheCurrentMessage() {
        for question in ["Please explain the advice card in English. Do not draw more cards.",
                         "Could you please explain the Advice card in English?", "Please use English to explain this card.",
                         "Reply to me in English.", "请用英文再解释一下建议牌", "请英文回答", "English please"] {
            XCTAssertEqual(EnglishConversation.replyLanguage(in: question), .english, question)
        }
        for question in ["用中文再说简单点", "请用中文再说一遍", "请中文回答", "Please explain the Advice card in Chinese.",
                         "Please use simplified Chinese to explain the advice."] {
            XCTAssertEqual(EnglishConversation.replyLanguage(in: question), .simplifiedChinese, question)
        }
        XCTAssertEqual(EnglishConversation.replyLanguage(in: "Please explain in English, then reply in Chinese."), .simplifiedChinese)
        XCTAssertEqual(EnglishConversation.replyLanguage(in: "不用英文，改用中文解释一下"), .simplifiedChinese)
        XCTAssertEqual(EnglishConversation.replyLanguage(in: "用中文再说简单点"), .simplifiedChinese)
        XCTAssertNil(EnglishConversation.replyLanguage(in: "建议牌和现状牌有什么关系？"))
    }

    func testNegatedQuotedAndDescriptiveLanguageMentionsDoNotSelectAReplyLanguage() {
        for question in ["Please answer not in English.", "请不要用英文回答", "Don't explain this in English.",
                         "Please explain why we should not reply in English.", "Please do not explain in English.",
                         "I study English.", "My friend explained the Advice card in English.", "英文水平怎么样？",
                         "Explain what ‘in English’ means.", "She said ‘Please explain in English’. What did she mean?"] {
            XCTAssertNil(EnglishConversation.replyLanguage(in: question), question)
        }
    }
}
