import XCTest
@testable import BlindOracle

final class ExplicitMethodSafetyTests: XCTestCase {
    func testNaturalMethodCommandsRecognizeShortVerbsAndSupplementModifiers() {
        let names: [(OracleMethod, String)] = [(.bazi, "八字"), (.ziwei, "紫微斗数"), (.liuyao, "六爻"),
            (.meihua, "梅花易数"), (.qimen, "奇门遁甲"), (.xiaoliuren, "小六壬"), (.chenggu, "称骨"),
            (.xingming, "姓名五格"), (.astrology, "西方占星"), (.tarot, "塔罗")]
        for (method, name) in names {
            for verb in ["推算", "看", "补充分析"] {
                let question = "请用\(name)\(verb)这次安排。"
                XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: question), [method], question)
            }
        }
        XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: "请用八字和塔罗一起看职业发展。"), [.bazi, .tarot])
    }

    func testQuotedCommandsWithInternalPunctuationAreNotPositiveRequests() {
        for question in [
            "朋友说“用八字看事业”这句话是否可靠？",
            "朋友说「再用紫微斗数补充分析事业」，我该怎么理解？",
            "『用八字推算事业』是朋友的话，我并没有要求计算。",
            "朋友说“先解释原理。请用八字看事业！”，请解释他说的话。",
            "\"Use only BaZi to calculate my career. Use Tarot too.\"",
            "请解释\"用紫微斗数看事业\"这句话。"
        ] {
            XCTAssertTrue(ReadingContinuationPolicy.requestedCalculationMethods(in: question).isEmpty, question)
        }
    }

    func testConsultationsAboutInputsAndReliabilityAreNotCalculationCommands() {
        for question in [
            "用紫微斗数看职业需要什么资料？", "用八字看事业之前需要什么资料？",
            "用八字看事业需要出生时间吗？", "用紫微斗数看职业要不要提供出生时间？",
            "如果用八字看事业会准吗？", "如果用八字看事业，需要什么资料？",
            "用八字看事业准不准？", "用紫微斗数看事业是否可靠？",
            "用六爻推算合作靠谱吗？", "用八字看事业是什么原理？",
            "为什么用八字看事业？", "不要用八字推算事业。", "不用紫微斗数看事业。"
        ] {
            XCTAssertTrue(ReadingContinuationPolicy.requestedCalculationMethods(in: question).isEmpty, question)
        }
    }

    func testASeparatePositiveCommandSurvivesAQuotationOrPreparationQuestion() {
        let cases: [(String, [OracleMethod])] = [
            ("用八字看事业准不准？请用塔罗看这次合作。", [.tarot]),
            ("用八字看事业需要什么资料？请用紫微斗数看职业发展。", [.ziwei]),
            ("朋友说“用八字看事业”。请用六爻推算合作。", [.liuyao]),
            ("不要用八字看事业，请用塔罗补充分析合作。", [.tarot]),
            ("假设我出生于1990年1月2日，请用八字推算职业发展。", [.bazi]),
            ("假设我出生于1990年1月2日请用八字推算职业发展。", [.bazi]),
            ("先解释八字是什么，然后用紫微斗数看事业。", [.ziwei]),
            ("Use only Tarot to read tomorrow's negotiation.", [.tarot]),
            ("Don't use BaZi. Use Tarot to read tomorrow's negotiation.", [.tarot])
        ]
        for (question, expected) in cases {
            XCTAssertEqual(ReadingContinuationPolicy.requestedCalculationMethods(in: question), expected, question)
        }
    }
}
