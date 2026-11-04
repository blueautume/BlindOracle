import XCTest
@testable import BlindOracle

/// Legacy scoped-answer parsing remains compatible with saved preparations;
/// new reading entry and submission behavior is covered by FormIntakeTests.
final class ConversationalIntakeTests: XCTestCase {
    private func person(_ name: String = "张三") throws -> OracleProfile {
        try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: name, sex: "男", birthDate: "1995-01-02", birthTime: "08:30", birthTimeZoneID: "Asia/Shanghai")], to: []).profiles.first)
    }

    private func plan(_ field: OracleField, person: OracleProfile) -> OraclePlan {
        var plan = OraclePlan(intent: "兼容资料", subject: "他人", methods: [.bazi], requiredFields: [], note: "", question: "看看张三的事业")
        plan.requestedProfileID = person.id; plan.requestedFields = [field]
        return plan
    }

    func testNaturalConfirmationRequiresAnUnambiguousAffirmativeAnswer() {
        XCTAssertTrue(ConversationalIntake.isConfirmation("没有问题，开始解析。"))
        XCTAssertTrue(ConversationalIntake.isConfirmation("确认，开始"))
        XCTAssertFalse(ConversationalIntake.isConfirmation("没有问题吗？"))
        XCTAssertFalse(ConversationalIntake.isConfirmation("没问题，先别开始"))
        XCTAssertFalse(ConversationalIntake.isConfirmation("出生时间有问题，改成09:45"))
    }

    func testScopedDateAnswerCanIncludeChineseClockAndExplicitBeijingTime() throws {
        let person = try person()
        let answer = ConversationalIntake.answer("1995年1月2日早上八点半，北京时间", plan: plan(.birthDate, person: person), profiles: [person])
        let saved = try XCTUnwrap(ProfileDirectory.applying(answer.updates, to: [person]).profiles.first)
        XCTAssertEqual(saved.birthDateText, "1995-01-02")
        XCTAssertEqual(saved.birthTimeText, "08:30")
        XCTAssertEqual(saved.birthTimeZoneID, "Asia/Shanghai")
        XCTAssertEqual(saved.id, person.id)
    }

    func testExplicitNameStatementUsesCanonicalNameInsteadOfIncludingWoJiaoPrefix() {
        var plan = OraclePlan(intent: "兼容姓名", subject: "本人", methods: [.bazi], requiredFields: [], note: "", question: "事业")
        plan.requestedFields = [.name]
        let text = "我叫张三"
        let scoped = ConversationalIntake.answer(text, plan: plan, profiles: [])
        let explicit = ProfileDirectory.parseExplicitUpdates(in: text, profiles: [])
        let people = ProfileDirectory.applying(explicit + scoped.updates, to: []).profiles
        XCTAssertEqual(people.map(\.resolvedName), ["张三"])
    }

    func testAmbiguousClockDoesNotSaveUntilPeriodIsKnownAndPreservesHalfHour() throws {
        let person = try person()
        var plan = plan(.birthTime, person: person)
        let ambiguous = ConversationalIntake.answer("8点半", plan: plan, profiles: [person])
        XCTAssertTrue(ambiguous.updates.isEmpty)
        XCTAssertTrue(ambiguous.clarification?.contains("上午") == true)
        XCTAssertEqual(ambiguous.pendingAnswer, "8点半")
        plan.pendingAnswer = ambiguous.pendingAnswer
        let resolved = ConversationalIntake.answer("早上", plan: plan, profiles: [person])
        XCTAssertNil(resolved.clarification)
        XCTAssertEqual(resolved.updates.first?.birthTime, "08:30")
        XCTAssertEqual(resolved.updates.first?.id, person.id)
    }

    func testLunarDateCannotBeStoredAsTheSameGregorianDigits() throws {
        let person = try person()
        let answer = ConversationalIntake.answer("农历1995年1月2日", plan: plan(.birthDate, person: person), profiles: [person])
        XCTAssertTrue(answer.updates.allSatisfy { $0.birthDate == nil })
        let saved = try XCTUnwrap(ProfileDirectory.applying(answer.updates, to: [person]).profiles.first)
        XCTAssertEqual(saved.birthDateText, person.birthDateText)
        XCTAssertEqual(saved.birthDate, person.birthDate)
    }

    func testNamedAnswerForAnotherPersonCannotOverwriteThePendingPerson() throws {
        let selected = try person(), other = try person("李四")
        let answer = ConversationalIntake.answer("李四出生日期2000-01-02", plan: plan(.birthDate, person: selected), profiles: [selected, other])
        XCTAssertTrue(answer.updates.isEmpty)
    }

    func testUnknownAnswerMarksOnlyTheRequestedFieldForTheSelectedPerson() throws {
        let person = try person()
        let answer = ConversationalIntake.answer("不确定", plan: plan(.birthTime, person: person), profiles: [person])
        XCTAssertEqual(answer.updates.count, 1)
        XCTAssertEqual(answer.updates.first?.id, person.id)
        XCTAssertEqual(answer.updates.first?.unknownFields, [.birthTime])
        XCTAssertEqual(answer.updates.first?.birthTimeKnown, false)
        XCTAssertNil(answer.updates.first?.birthDate)
        XCTAssertNil(answer.updates.first?.birthPlace)
    }

    func testScopedCoordinatesKeepLatitudeAndLongitudeInTheirOwnFields() throws {
        let person = try person()
        let answer = ConversationalIntake.answer("31.2304，121.4737", plan: plan(.birthCoordinates, person: person), profiles: [person])
        XCTAssertEqual(answer.updates.first?.id, person.id)
        XCTAssertEqual(answer.updates.first?.birthLatitude, 31.2304)
        XCTAssertEqual(answer.updates.first?.birthLongitude, 121.4737)
    }

    func testIndependentSurnameAndGivenNameAnswersDoNotChangeTheUnifiedName() throws {
        let person = try person()
        let surname = ConversationalIntake.answer("张", plan: plan(.surname, person: person), profiles: [person])
        let given = ConversationalIntake.answer("三", plan: plan(.givenName, person: person), profiles: [person])
        let saved = try XCTUnwrap(ProfileDirectory.applying(surname.updates + given.updates, to: [person]).profiles.first)
        XCTAssertEqual(saved.resolvedName, "张三")
        XCTAssertEqual(saved.familyName, "张")
        XCTAssertEqual(saved.givenName, "三")
    }
}

extension ConversationalIntakeTests {
    func testEnglishProfileFactsAreGroundedAndUnknownTimeDoesNotInventAValue() {
        let message = "Alice Jones was born on June 2, 1995 at 8:30 PM; Bob Smith, birth time: unknown"
        let parsed = ProfileDirectory.parseExplicitUpdates(in: message, profiles: [])
        let alice = parsed.first { $0.name == "Alice Jones" }
        XCTAssertEqual(alice?.birthDate, "1995-06-02")
        XCTAssertEqual(alice?.birthTime, "20:30")
        let bob = parsed.first { $0.name == "Bob Smith" }
        XCTAssertEqual(bob?.birthTimeKnown, false)
        XCTAssertEqual(bob?.unknownFields, [.birthTime])

        let grounded = ProfileDirectory.groundedUpdates([
            ProfileUpdate(name: "Alice Jones", birthDate: "1995-06-02", birthTime: "20:30", birthTimeZoneID: "America/New_York"),
            ProfileUpdate(name: "Bob Smith", birthTime: "20:30", birthTimeKnown: false, unknownFields: [.birthTime])
        ], in: message, profiles: [])
        XCTAssertEqual(grounded.first { $0.name == "Alice Jones" }?.birthDate, "1995-06-02")
        XCTAssertNil(grounded.first { $0.name == "Alice Jones" }?.birthTimeZoneID)
        XCTAssertNil(grounded.first { $0.name == "Bob Smith" }?.birthTime)
        XCTAssertEqual(grounded.first { $0.name == "Bob Smith" }?.birthTimeKnown, false)
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "Was Alice Jones born on June 2, 1995?", profiles: []).isEmpty)
        var existing = OracleProfile(); existing.name = "Alice Jones"
        let otherPerson = ProfileDirectory.groundedUpdates([
            ProfileUpdate(id: existing.id, name: "Alice Jones", birthDate: "1995-06-02")
        ], in: "My sister was born on June 2, 1995.", profiles: [existing], contextIDs: [existing.id])
        XCTAssertTrue(otherPerson.isEmpty)
        XCTAssertTrue(ConversationalIntake.isUnknown("I don’t know."))
        XCTAssertTrue(ConversationalIntake.isConfirmation("Confirm and start."))
        XCTAssertFalse(ConversationalIntake.isConfirmation("Confirm and start?"))
    }
}
