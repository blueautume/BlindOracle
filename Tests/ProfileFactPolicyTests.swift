import XCTest
@testable import BlindOracle

final class ProfileFactPolicyTests: XCTestCase {
    func testRealFactsAcrossFieldTypesMayBePersisted() {
        for text in [
            "姓名：王宁，性别：女，出生时区：Asia/Shanghai。",
            "请保存陈平的出生地：上海市黄浦区。",
            "我出生于1991-03-04，帮我看看事业。",
            "出生地纬度：31.23，经度：121.47。",
            "My name is Jane Doe. My gender is female.",
            "Please save my birth date as 1991-03-04 and my time zone as Asia/Tokyo.",
            "Birthplace: Shanghai. Latitude: 31.23. Longitude: 121.47."
        ] { XCTAssertTrue(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testQuotedScalarValuesAreNotMistakenForReportedProfileStatements() {
        for text in [
            "我叫“陈平”。", "我的姓名是「王宁」。", "出生时间为『08:30』。",
            "生日不是“1990-01-02”，更正为1991-03-04。",
            "My name is \"Jane Doe\".", "My name is 'Alex Lee'.",
            "Birthplace: \"Shanghai\". Time zone: `Asia/Shanghai`.",
            "My birth time is ‘08:30’."
        ] { XCTAssertTrue(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testDenyingOldFactsAndStatingRealCorrectionsDoesNotDisablePersistence() {
        for text in [
            "陈平不是1990-01-02出生，是1991-03-04出生。",
            "陈平，出生日期更正为1990-01-02，是真实资料，请保存。",
            "之前的出生地不对，更正为上海市黄浦区。",
            "不是男，性别更正为女。", "请把性别更新为女。", "出生时区不是UTC，实际为Asia/Shanghai。",
            "Birth time was not 8:30 am. The correct time is 9:45 am.",
            "The old birthplace is wrong. Update it to Taipei.",
            "My birth date is not 1990-01-02; the correct date is 1991-03-04."
        ] { XCTAssertTrue(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testActualUnknownAndRetractionStatementsMayBeSaved() {
        for text in [
            "我不确定出生时辰，撤回之前填写的08:30。",
            "陈平出生地未知，性别不详。", "我的生日不记得了，请标记为不确定。",
            "I don't know my birth time. Mark it unknown.",
            "My birthplace is unknown. Remove the old coordinates."
        ] { XCTAssertTrue(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testHypotheticalExamplesAndSimulationsNeverBecomeRealProfilePatches() {
        for text in [
            "假设：陈平，出生日期为1990-01-02。请按这个假设计算。",
            "如果出生地是香港，按这个条件排盘。",
            "假如性别改为女，结果有什么差别？",
            "比如姓名为林舟，出生时区为Asia/Tokyo。",
            "请用一组模拟档案演示，出生经度为121.47。",
            "这只是虚构人物，出生时间是08:30。",
            "Suppose my date of birth is 1990-01-02. Calculate that scenario.",
            "For example: name is Alex Lee; gender is male.",
            "Use this fictional profile: born in Shanghai.",
            "Let's simulate a person with time zone Asia/Taipei."
        ] { XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testReportedAndQuotedWholeStatementsCannotBePersisted() {
        for text in [
            "他说：“陈平，出生时间是08:30。”这是什么意思？",
            "原话是：姓名林舟，出生地上海。", "王宁说自己的出生时区是Asia/Shanghai。",
            "转述一段资料：性别男，出生时区Asia/Shanghai。",
            "“陈平出生于1990-01-02”", "「我叫林舟，出生地是上海」",
            "```姓名：林舟\n出生时区：Asia/Tokyo```",
            "\"Alex Lee, 1990-01-02, 08:30, Shanghai\"",
            "He said, \"My birthplace is Shanghai.\"",
            "According to the example, her birth date is 1990-01-02.",
            "\"My name is Alex Lee.\"", "\"Name: Alex Lee\"",
            "She wrote that her gender is female.", "Alex Lee said his birthplace is Shanghai."
        ] { XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testProfileConsultationAndUncertainQuestionsAreNotFacts() {
        for text in [
            "出生时区是什么意思？", "为什么需要性别？", "如何填写出生地？",
            "陈平的生日是不是1990-01-02？", "出生时间是08:30吗？",
            "我想知道为什么要保存姓名。", "请把出生时区解释一下。", "陈平大概是1990-01-02出生。",
            "What is my birth date?", "Why does the app need gender?",
            "Can you explain how the birth time is used?", "Was Alex born in Shanghai?",
            "Birth time: 08:30?", "My birthday is maybe March 4."
        ] { XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testMixedTruthAndNonFactMessagesStayOutOfPermanentProfiles() {
        for text in [
            "我叫陈平。假设我出生于另一个时区，计算结果。",
            "出生日期确认为1991-03-04，比如出生地改为香港会怎样？",
            "真实姓名是王宁；请解释“出生日期是1990-01-02”这句话。",
            "My name is Alex Lee. Suppose my birth time were 9 am.",
            "My gender is female; why does the birth time matter?"
        ] { XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testDeniedPersistenceDoesNotTurnAValueIntoAnAuthorizedPatch() {
        for text in [
            "不要把出生日期改成1990-01-02。", "不是让你保存姓名：林舟。",
            "Don't save this birth time: 08:30.", "Do not change the profile's gender to male.",
            "", "  \n  "
        ] { XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testBareNonPersistenceInstructionsBlockEveryProfileFieldInTheTurn() {
        for text in [
            "陈平，出生日期暂按1990-01-02计算，不更新档案。",
            "性别按女计算，不保存。", "出生地改用香港，不修改真实资料。",
            "姓名：林舟，不记录到人员档案。", "出生时区使用Asia/Tokyo，不再写入档案。",
            "经度按121.47计算，不做更新。", "出生时间08:30，不存档。",
            "不需要保存这组出生坐标。", "不要改档案，使用这个地点计算。",
            "Gender is female for the calculation. No changes to my profile.",
            "Use the new birth time without updates to the saved record.",
            "Leave my profile unchanged. Calculate with these coordinates."
        ] { XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testTemporaryAndOneOffValuesAreNotPermanentProfileFacts() {
        for text in [
            "出生日期暂定为1990-01-02。", "临时资料：性别为女，出生地为香港。",
            "出生时区暂用Asia/Tokyo。", "只用于本次计算，出生时间08:30。",
            "姓名仅供这次问事使用。", "本轮临时换成这个地点，不入档。",
            "暂以这组出生坐标排盘。", "这是临时姓名，不记入人员目录。",
            "Use a temporary birthplace of Taipei.", "Set the time zone provisionally to Asia/Tokyo.",
            "Use these coordinates for this calculation only.", "Only for this session, use the new birth time.",
            "For now, calculate with gender female.", "Use this name just this once."
        ] { XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: text), text) }
    }

    func testTemporaryValuesStillPermitAnExplicitCalculationWithoutProfilePersistence() {
        for raw in ["出生时间暂按08:30，计算这个方案，不更新档案。",
                    "Use a temporary birthplace. Compute this scenario without profile changes."] {
            let understanding = ConversationUnderstanding(relation: .continuation, resolvedQuestion: raw, referenceMessageID: UUID(),
                execution: .init(operation: .calculate, coverage: .changed, evidence: raw))
            XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: raw))
            XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding, rawQuestion: raw,
                proposedAction: "reply", hasRelatedRun: true), "intake")
        }
    }

    func testHypotheticalCalculationPermissionIsIndependentOfProfilePersistence() {
        let raw = "假设预算只有五千，计算这个方案。"
        let understanding = ConversationUnderstanding(relation: .continuation, resolvedQuestion: raw, referenceMessageID: UUID(),
            execution: .init(operation: .calculate, coverage: .changed, evidence: "计算这个方案"))
        XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: raw))
        XCTAssertEqual(ReadingExecutionPolicy.validatedAction(understanding: understanding, rawQuestion: raw,
            proposedAction: "reply", hasRelatedRun: true), "intake")
    }
}
