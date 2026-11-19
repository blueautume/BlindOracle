import XCTest
@testable import BlindOracle

final class ProfileEditRequestTests: XCTestCase {
    func testBirthdayCorrectionOnlyIdentifiesTheFieldAndOwner() throws {
        var person = OracleProfile()
        person.name = "周宁"
        let first = try XCTUnwrap(ProfileEditRequest.recognize("把我的生日改成1993年4月19日", profiles: [person], selfProfileID: person.id))
        let second = try XCTUnwrap(ProfileEditRequest.recognize("把我的生日改成1988年6月8日", profiles: [person], selfProfileID: person.id))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.fields, [.birthDate])
        XCTAssertEqual(first.target, .selfProfile)
        XCTAssertNil(first.readingQuestion)
    }

    func testExactNameAndAliasKeepDistinctRecordsForSelection() throws {
        var first = OracleProfile()
        first.name = "王宁"
        first.alias = "小王"
        var second = OracleProfile()
        second.name = "王宁"
        var longer = OracleProfile()
        longer.name = "王宁远"
        let people = [first, second, longer]

        XCTAssertEqual(ProfileEditRequest.recognize("把王宁的出生地改成上海", profiles: people, selfProfileID: nil)?.target, .profiles([first.id, second.id]))
        XCTAssertEqual(ProfileEditRequest.recognize("修改小王的出生时间和出生地", profiles: people, selfProfileID: nil)?.fields, [.birthTime, .birthPlace])
        XCTAssertEqual(ProfileEditRequest.recognize("修改小王的出生时间和出生地", profiles: people, selfProfileID: nil)?.target, .profiles([first.id]))
        XCTAssertEqual(ProfileEditRequest.recognize("王宁远的出生地时区填错了", profiles: people, selfProfileID: nil)?.fields, [.birthTimeZone])
        XCTAssertEqual(ProfileEditRequest.recognize("王宁远的出生地时区填错了", profiles: people, selfProfileID: nil)?.target, .profiles([longer.id]))
        XCTAssertEqual(ProfileEditRequest.recognize("把陌生人的生日改成1990年1月1日", profiles: people, selfProfileID: first.id)?.target, .unspecified)
    }

    func testPoliteEditRequestIsRecognizedButConsultationAndQuotedTextAreIgnored() throws {
        var person = OracleProfile()
        person.name = "Alex Lee"
        let recognized = try XCTUnwrap(ProfileEditRequest.recognize("Could you update Alex Lee’s time of birth?", profiles: [person], selfProfileID: nil))
        XCTAssertEqual(recognized.fields, [.birthTime])
        XCTAssertEqual(recognized.target, .profiles([person.id]))
        XCTAssertEqual(ProfileEditRequest.recognize("能帮我把我的生日改成1990年1月1日吗？", profiles: [], selfProfileID: nil)?.target, .selfProfile)

        for text in [
            "假设把我的生日改成某天",
            "不要帮我把生日改成1990年1月1日",
            "怎么把我的生日改成公历？",
            "她说：把我的生日改成某天",
            "「把我的生日改成某天」",
            "我的生日改成1990年1月1日会不会影响运势？",
            "我的生日是1990年1月1日",
            "帮我记住张三",
            "What happens if I change my birthday?"
        ] {
            XCTAssertNil(ProfileEditRequest.recognize(text, profiles: [], selfProfileID: nil), text)
        }
    }

    func testOnlySeparateRecastTextContinuesTheReading() throws {
        let request = try XCTUnwrap(ProfileEditRequest.recognize(
            "我的出生时间填错了，应该是下午两点，然后重新算一下", profiles: [], selfProfileID: nil
        ))
        XCTAssertEqual(request.fields, [.birthTime])
        XCTAssertEqual(request.readingQuestion, "重新算一下")
        XCTAssertTrue(request.startsNewReading)
        XCTAssertTrue(ReadingContinuationPolicy.isBareRecastRequest(try XCTUnwrap(request.readingQuestion)))
    }

    func testExistingNamedPersonCanBeIdentifiedAcrossClauses() throws {
        var person = OracleProfile()
        person.name = "陈平"
        let correction = try XCTUnwrap(ProfileEditRequest.recognize(
            "陈平，出生日期更正为1990-01-02，是真实资料，请保存。", profiles: [person], selfProfileID: nil
        ))
        XCTAssertEqual(correction.fields, [.birthDate])
        XCTAssertEqual(correction.target, .profiles([person.id]))
        XCTAssertNil(correction.readingQuestion)

        let recast = try XCTUnwrap(ProfileEditRequest.recognize(
            "陈平出生时间为09:30，重新起卦", profiles: [person], selfProfileID: nil
        ))
        XCTAssertEqual(recast.fields, [.birthTime])
        XCTAssertEqual(recast.target, .profiles([person.id]))
        XCTAssertEqual(recast.readingQuestion, "重新起卦")
    }

    func testCompletionPlusRecastHasNoNewPersonOrTopic() {
        for text in [
            "现在补充了重新算一下",
            "刚才已经补齐了出生资料，麻烦你重算",
            "资料已补充好，请再算一遍",
            "填好了资料，重算一下",
            "我已经补充资料了，重新算一下"
        ] {
            XCTAssertTrue(ReadingContinuationPolicy.isBareRecastRequest(text), text)
            XCTAssertNil(ProfileEditRequest.recognize(text, profiles: [], selfProfileID: nil), text)
        }
        for text in ["假如补好资料再算一下", "现在补充了张三的资料重新算一下", "资料已补齐，重新算一下我的事业"] {
            XCTAssertFalse(ReadingContinuationPolicy.isBareRecastRequest(text), text)
        }
    }

    func testAWithdrawnBirthClockOpensTheRecordedFieldWithoutSupplyingAValue() throws {
        let request = try XCTUnwrap(ProfileEditRequest.recognize(
            "我不知道几点出生，之前那个八点半不准。", profiles: [], selfProfileID: nil
        ))
        XCTAssertEqual(request.target, .selfProfile)
        XCTAssertEqual(request.fields, [.birthTime])
        XCTAssertNil(request.readingQuestion)
        XCTAssertNil(ProfileEditRequest.recognize("如果我不记得几点出生怎么办？", profiles: [], selfProfileID: nil))
    }

    func testReviewingWithUpdatedInputsIsDistinctFromRedrawing() throws {
        var person = OracleProfile()
        person.name = "陈平"
        let request = try XCTUnwrap(ProfileEditRequest.recognize(
            "陈平出生时间为10:30，按新资料看看", profiles: [person], selfProfileID: nil
        ))
        XCTAssertEqual(request.target, .profiles([person.id]))
        XCTAssertEqual(request.fields, [.birthTime])
        let tail = try XCTUnwrap(request.readingQuestion)
        XCTAssertEqual(tail, "按新资料看看")
        XCTAssertTrue(ProfileEditRequest.usesUpdatedDetails(tail))
        XCTAssertFalse(ReadingContinuationPolicy.isBareRecastRequest(tail))
        XCTAssertFalse(ProfileEditRequest.usesUpdatedDetails("按新资料重新起卦"))
    }
}
