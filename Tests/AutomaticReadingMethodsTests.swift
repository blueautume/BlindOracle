import XCTest
@testable import BlindOracle

final class AutomaticReadingMethodsTests: XCTestCase {
    private let available = Set(OracleMethod.allCases)

    func testRecentCareerChoicesUseRelevantEventMethodsWithoutPersonalCharts() {
        for question in [
            "最近的工作，该进还是该守？",
            "现在转岗，还是继续待在原团队？",
            "Should I accept the offer or stay in my role?"
        ] {
            let selected = AutomaticReadingMethods.select(question: question, proposed: OracleMethod.allCases, available: available)
            XCTAssertEqual(Set(selected), [.tarot, .liuyao], question)
            XCTAssertFalse(selected.contains(where: \.usesPersonalProfile), question)
        }
    }

    func testNearTermProgressAndActionTimingUseDifferentCapabilities() {
        let progress = AutomaticReadingMethods.select(question: "接下来两周工作进展如何？", available: available)
        XCTAssertEqual(Set(progress), [.meihua, .xiaoliuren])
        let timing = AutomaticReadingMethods.select(question: "什么时候跟主管提出转岗最合适？", available: available)
        XCTAssertEqual(Set(timing), [.qimen, .meihua])
        let weeks = AutomaticReadingMethods.select(question: "未来几周，我的工作会有什么变化？", available: available)
        XCTAssertEqual(Set(weeks), [.meihua, .xiaoliuren])
        let specificPeriod = AutomaticReadingMethods.select(question: "我的这份合同还有五年；接下来两周工作进展如何？", available: available)
        XCTAssertEqual(Set(specificPeriod), [.meihua, .xiaoliuren])
        let englishTiming = AutomaticReadingMethods.select(question: "When should I bring up a transfer?", available: available)
        XCTAssertEqual(Set(englishTiming), [.qimen, .meihua])
    }

    func testLongCareerCyclesAndCurrentPersonalPhaseUseRelevantCharts() {
        let long = AutomaticReadingMethods.select(question: "未来五年我的事业发展趋势怎么样？",
                                                  proposed: [.tarot, .xingming], available: available)
        XCTAssertEqual(Set(long), [.bazi, .ziwei])
        let annual = AutomaticReadingMethods.select(question: "明年我的工作机会和财运走向如何？", available: available)
        XCTAssertEqual(Set(annual), [.bazi, .ziwei])
        let current = AutomaticReadingMethods.select(question: "我现阶段处在什么个人周期？", available: available)
        XCTAssertEqual(Set(current), [.astrology, .bazi])
        let careerTracks = AutomaticReadingMethods.select(question: "未来三年适合继续管理还是转技术？", available: available)
        XCTAssertEqual(Set(careerTracks), [.bazi, .ziwei])
    }

    func testGenuinelyMixedQuestionRetainsStrongMethodsFromBothHorizons() {
        let question = "未来五年我的事业趋势如何；眼下这份工作，该进还是该守？"
        let selected = AutomaticReadingMethods.select(question: question, proposed: [.qimen], available: available)
        XCTAssertEqual(Set(selected), [.bazi, .ziwei, .liuyao, .tarot])
        XCTAssertEqual(selected.count, 4)
        let partial = AutomaticReadingMethods.select(question: question, available: [.liuyao, .astrology])
        XCTAssertEqual(Set(partial), [.liuyao, .astrology])
        let threeHorizons = AutomaticReadingMethods.select(
            question: "我想判断这周该不该接新工作，还想了解入职后三个月能否适应，以及未来五年对事业和收入的影响。",
            available: available
        )
        XCTAssertEqual(Set(threeHorizons), [.liuyao, .tarot, .meihua, .xiaoliuren, .bazi, .ziwei])
    }

    func testWideCoverageIsAllowedWhenSeveralDistinctQuestionsSupportIt() {
        let question = """
        看未来五年事业的方向；也看我目前处在什么人生阶段；
        这份合作该不该接；近期项目进展如何；什么时候提出方案最合适；
        分析这个笔名是否合适；我也想看骨重与传统命诗。
        """
        let selected = AutomaticReadingMethods.select(question: question, available: available)
        XCTAssertEqual(Set(selected), available)
        XCTAssertEqual(selected.count, available.count)

        let overview = AutomaticReadingMethods.select(question: "全面看看我未来五年事业、财务和婚姻的趋势。", available: available)
        XCTAssertEqual(Set(overview), [.bazi, .ziwei])
    }

    func testNamingIsIndependentOfGenericDecisions() {
        let selected = AutomaticReadingMethods.select(question: "李岚这个名字适合做笔名吗？",
                                                      proposed: OracleMethod.allCases, available: available)
        XCTAssertEqual(selected, [.xingming])
    }

    func testUnknownPhrasingRetainsAFiniteValidPlannerProposal() {
        let selected = AutomaticReadingMethods.select(question: "这件事想请你看看。",
            proposed: [.xingming, .chenggu, .tarot, .tarot, .meihua, .qimen, .liuyao, .astrology],
            available: available.subtracting([.qimen]))
        XCTAssertEqual(selected, [.tarot, .meihua, .liuyao])
        XCTAssertTrue(AutomaticReadingMethods.select(question: "这件事想请你看看。", available: available).isEmpty)
    }

    func testAvailabilityAndNegatedOrQuotedQuestionsAreRespected() {
        let question = "最近的工作，该进还是该守？"
        XCTAssertEqual(AutomaticReadingMethods.select(question: question, available: [.liuyao]), [.liuyao])
        XCTAssertEqual(AutomaticReadingMethods.select(question: question, available: [.meihua, .bazi]), [.meihua])
        XCTAssertTrue(AutomaticReadingMethods.select(question: question, available: [.bazi]).isEmpty)
        let notLongTerm = AutomaticReadingMethods.select(question: "先别看长期事业趋势；只问这份合作该不该接？", available: available)
        XCTAssertEqual(Set(notLongTerm), [.liuyao, .tarot])
        let quote = AutomaticReadingMethods.select(question: "我朋友问了「未来五年的事业趋势如何」，我只想看项目近期进展。", available: available)
        XCTAssertEqual(Set(quote), [.meihua, .xiaoliuren])
    }
}
