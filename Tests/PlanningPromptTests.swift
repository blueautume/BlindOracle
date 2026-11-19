import XCTest
@testable import BlindOracle

final class PlanningPromptTests: XCTestCase {
    func testCareerExamplesChooseByQuestionAndShowAValidMultiMethodPlan() throws {
        let prompt = PlanningPrompt.system(catalog: "[]", language: .simplifiedChinese)
        let example = try XCTUnwrap(prompt.split(separator: "\n").first { $0.hasPrefix("JSON示例 ") })
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(example.dropFirst("JSON示例 ".count).utf8)) as? [String: Any])
        let understanding = try XCTUnwrap(plan["understanding"] as? [String: Any])
        let execution = try XCTUnwrap(understanding["execution"] as? [String: Any])
        XCTAssertEqual(plan["action"] as? String, "intake")
        XCTAssertEqual(plan["methods"] as? [String], [OracleMethod.liuyao.rawValue, OracleMethod.tarot.rawValue])
        XCTAssertEqual(understanding["resolvedQuestion"] as? String, "最近的工作，该进还是该守？")
        XCTAssertEqual(execution["operation"] as? String, "calculate")
        XCTAssertEqual(execution["evidence"] as? String, understanding["resolvedQuestion"] as? String)
        XCTAssertTrue(prompt.contains("未来三年适合继续管理还是转技术？"))
        XCTAssertTrue(prompt.contains("优先考虑八字和紫微对长期职业阶段与角色的线索"))
    }

    func testMethodBreadthAndFollowUpGuidanceKeepExistingDataBoundaries() {
        let catalog = #"[{"method":"bazi"},{"method":"tarot"}]"#
        let prompt = PlanningPrompt.system(catalog: catalog, language: .english)
        for rule in [
            "直接选择最相关的方法，返回非空methods",
            "互补视角或独立交叉验证",
            "不设固定数量",
            "每个目录方法都有实质贡献时可以全选",
            "明确指定的方法决定本轮范围",
            "别请用户先挑一种方法",
            "准确引用的已有结果重新判断coverage",
            "只补缺的部分并复用已有结果",
            "明确重抽、重起时operation为recast",
            "clarify的note只问事项或对象",
            "不输出profileUpdates",
            "natural English"
        ] {
            XCTAssertTrue(prompt.contains(rule), rule)
        }
        XCTAssertTrue(prompt.hasSuffix(catalog))
    }
}
