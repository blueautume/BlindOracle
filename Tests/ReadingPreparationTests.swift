import XCTest
@testable import BlindOracle

final class ReadingPreparationTests: XCTestCase {
    private func profile(_ name: String = "张三") -> OracleProfile {
        var person = OracleProfile()
        person.name = name; person.sex = "男"
        person.birthDate = ISO8601DateFormatter().date(from: "1990-01-02T08:30:00+08:00")
        person.birthDateText = "1990-01-02"; person.birthTimeText = "08:30"
        person.birthTimeKnown = true; person.birthTimeZoneID = "Asia/Shanghai"
        person.birthLatitude = 39.9; person.birthLongitude = 116.4
        person.declaredUnknownFields = []
        return person
    }

    private func plan(_ methods: [OracleMethod], mandatory: [OracleMethod] = []) -> OraclePlan {
        var plan = OraclePlan(intent: "测试资料准备", subject: "本人", methods: methods, requiredFields: [], note: "", question: "接下来如何安排？")
        plan.mandatoryMethods = mandatory
        return plan
    }

    private var descriptors: [OraclePluginDescriptor] {
        OracleMethod.allCases.map { method in
            let fields: [OracleField]
            switch method {
            case .bazi: fields = [.birthDate, .birthTimeZone, .birthCoordinates]
            case .chenggu, .astrology: fields = [.birthDate, .birthTimeZone]
            case .ziwei: fields = [.birthDate, .birthTime, .gender, .birthTimeZone]
            case .xingming: fields = [.surname, .givenName]
            default: fields = []
            }
            return OraclePluginDescriptor(method: method, version: "test", summary: "", requiredFields: fields,
                optionalFields: [], supportedQuestions: [], outputDescription: "", limitations: [], source: "test", license: "test")
        }
    }

    private func emptyNamedProfile() throws -> OracleProfile {
        try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "张三")], to: []).profiles.first)
    }

    func testMandatoryZiweiBlocksEntirePlanInsteadOfRunningAnAvailableAlternative() throws {
        let person = try emptyNamedProfile()
        let report = ReadingPreparationPolicy.evaluate(plan: plan([.ziwei, .meihua], mandatory: [.ziwei]), participants: [person], descriptors: descriptors)
        XCTAssertTrue(report.strictBlocked)
        XCTAssertFalse(report.canProceed)
        XCTAssertEqual(report.blockedMandatoryMethods, [.ziwei])
        XCTAssertTrue(report.runnableMethods.isEmpty)
        XCTAssertTrue(report.assessments.first { $0.method == .meihua }?.canExecute == true)
        XCTAssertEqual(Set(report.assessments.first { $0.method == .ziwei }?.blocking.map(\.field) ?? []), Set([.birthDate, .birthTimeZone, .birthTime, .gender]))
        XCTAssertTrue(report.summary.contains("暂不开始，也不改用其他方法"))
    }

    func testMixedPlanOmitsUnavailableMethodAndExplainsWhoseDataWasMissing() throws {
        let person = try emptyNamedProfile()
        let report = ReadingPreparationPolicy.evaluate(plan: plan([.ziwei, .meihua]), participants: [person], descriptors: descriptors)
        XCTAssertFalse(report.strictBlocked)
        XCTAssertTrue(report.canProceed)
        XCTAssertEqual(report.runnableMethods, [.meihua])
        XCTAssertEqual(report.omissions.count, 1)
        XCTAssertEqual(report.omissions.first?.participantID, person.id)
        XCTAssertEqual(report.omissions.first?.method, .ziwei)
        XCTAssertTrue(report.summary.contains("暂不纳入张三的紫微斗数"))
    }

    func testBirthplaceNeverReplacesMissingBirthTimezoneForBirthBasedMethods() {
        var person = profile()
        person.birthPlace = "北京"; person.unknownFields.insert(.birthTimeZone)
        person.declaredUnknownFields = []
        let report = ReadingPreparationPolicy.evaluate(plan: plan([.bazi, .chenggu, .astrology]), participants: [person], descriptors: descriptors)
        XCTAssertEqual(report.runnableMethods, [.xiaoliuren])
        XCTAssertEqual(report.omissions.map(\.method), [.bazi, .chenggu, .astrology])
        XCTAssertTrue(report.assessments.filter { $0.method != .xiaoliuren }.allSatisfy { $0.blocking.contains { $0.field == .birthTimeZone } })
        XCTAssertEqual(report.questions.filter { $0.field == .birthTimeZone }.count, 1)
        XCTAssertTrue(report.summary.contains("出生时区未确定"))
    }

    func testExplicitUnknownTimeAllowsMandatoryBaziChengguAndAstrologyPartialResults() {
        var person = profile()
        person.birthTimeKnown = false; person.unknownFields.insert(.birthTime)
        person.declaredUnknownFields = [.birthTime]
        let requested: [OracleMethod] = [.bazi, .chenggu, .astrology]
        let report = ReadingPreparationPolicy.evaluate(plan: plan(requested, mandatory: requested), participants: [person], descriptors: descriptors)
        XCTAssertTrue(report.canProceed)
        XCTAssertEqual(Set(report.runnableMethods), Set(requested))
        XCTAssertTrue(report.omissions.isEmpty)
        XCTAssertFalse(report.questions.contains { $0.field == .birthTime })
        XCTAssertTrue(report.assessments.first { $0.method == .bazi }?.limitations.joined().contains("必要候选") == true)
        XCTAssertTrue(report.assessments.first { $0.method == .chenggu }?.limitations.joined().contains("范围") == true)
        XCTAssertTrue(report.assessments.first { $0.method == .astrology }?.limitations.joined().contains("全天星位区间") == true)
        person.birthLatitude = nil; person.birthLongitude = nil; person.sex = "未提供"
        let stillPartial = ReadingPreparationPolicy.evaluate(plan: plan([.bazi, .astrology]), participants: [person], descriptors: descriptors)
        XCTAssertEqual(stillPartial.runnableMethods, [.astrology])
        XCTAssertEqual(stillPartial.questions.map(\.field), [.birthCoordinates])
        XCTAssertEqual(stillPartial.assessments.first { $0.method == .bazi }?.blocking.map(\.field), [.birthCoordinates])
        // Unknown time can omit houses, but a true-solar BaZi chart still needs
        // its birthplace longitude to determine possible solar dates.
    }

    func testExplicitUnknownTimeStillBlocksMandatoryZiweiWithoutRepeatingTheQuestion() {
        var person = profile()
        person.birthTimeKnown = false; person.unknownFields.insert(.birthTime)
        person.declaredUnknownFields = [.birthTime]
        let report = ReadingPreparationPolicy.evaluate(plan: plan([.ziwei], mandatory: [.ziwei]), participants: [person], descriptors: descriptors)
        XCTAssertTrue(report.strictBlocked)
        XCTAssertFalse(report.canProceed)
        XCTAssertEqual(report.missing.first?.explicitlyUnknownFields, [.birthTime])
        XCTAssertFalse(report.questions.contains { $0.field == .birthTime })
        XCTAssertTrue(report.omissions.isEmpty) // A mandated method stays requested, not silently skipped.
    }

    func testUnknownGenderIsOptionalForBaziButBlockingForZiwei() {
        var person = profile(); person.sex = "未提供"
        person.unknownFields.insert(.gender); person.declaredUnknownFields = [.gender]
        let bazi = ReadingPreparationPolicy.evaluate(plan: plan([.bazi], mandatory: [.bazi]), participants: [person], descriptors: descriptors)
        XCTAssertTrue(bazi.canProceed)
        XCTAssertTrue(bazi.assessments.first?.limitations.joined().contains("不输出起运与大运") == true)
        let ziwei = ReadingPreparationPolicy.evaluate(plan: plan([.ziwei], mandatory: [.ziwei]), participants: [person], descriptors: descriptors)
        XCTAssertTrue(ziwei.strictBlocked)
        XCTAssertEqual(ziwei.assessments.first?.blocking.map(\.field), [.gender])
    }

    func testAstrologyWithoutCoordinatesIsPartialAndHighLatitudeDoesNotPromptForCoordinatesAgain() {
        var person = profile(); person.birthLatitude = nil; person.birthLongitude = nil
        let report = ReadingPreparationPolicy.evaluate(plan: plan([.astrology], mandatory: [.astrology]), participants: [person], descriptors: descriptors)
        XCTAssertTrue(report.canProceed)
        XCTAssertEqual(report.assessments.first?.optionalGaps.map(\.field), [.birthCoordinates])
        XCTAssertTrue(report.summary.contains("不计算上升点与宫位"))
        person.birthLatitude = 70; person.birthLongitude = 10
        let high = ReadingPreparationPolicy.evaluate(plan: plan([.astrology], mandatory: [.astrology]), participants: [person], descriptors: descriptors)
        XCTAssertTrue(high.canProceed)
        XCTAssertFalse(high.questions.contains { $0.field == .birthCoordinates })
        XCTAssertTrue(high.summary.contains("高纬度"))
    }

    func testMixedPersonalMethodKeepsReadyPersonAndRecordsOtherPersonOmission() {
        let first = profile()
        var second = profile("李四"); second.birthDate = nil; second.birthDateText = nil
        let report = ReadingPreparationPolicy.evaluate(plan: plan([.bazi]), participants: [first, second], descriptors: descriptors)
        XCTAssertEqual(report.assessments.map(\.canExecute), [true, false])
        XCTAssertEqual(report.runnableMethods, [.bazi])
        XCTAssertEqual(report.omissions.first?.participantID, second.id)
        XCTAssertEqual(report.omissions.first?.participantName, "李四")
        let strict = ReadingPreparationPolicy.evaluate(plan: plan([.bazi], mandatory: [.bazi]), participants: [first, second], descriptors: descriptors)
        XCTAssertTrue(strict.strictBlocked)
        XCTAssertTrue(strict.runnableMethods.isEmpty)
    }

    func testPersonalMethodsRequireSelectedProfileWhileTarotNeedsOnlyLaterInteraction() {
        let personal = ReadingPreparationPolicy.evaluate(plan: plan([.bazi], mandatory: [.bazi]), participants: [], descriptors: descriptors)
        XCTAssertTrue(personal.strictBlocked)
        XCTAssertEqual(personal.questions.first?.field, .name)
        XCTAssertNil(personal.assessments.first?.participantID)
        let tarot = ReadingPreparationPolicy.evaluate(plan: plan([.tarot], mandatory: [.tarot]), participants: [], descriptors: descriptors)
        XCTAssertTrue(tarot.canProceed)
        XCTAssertTrue(tarot.missing.isEmpty)
        XCTAssertTrue(tarot.assessments.first?.requiresUserInteraction == true)
        var anonymous = profile(); anonymous.name = nil
        let ready = ReadingPreparationPolicy.evaluate(plan: plan([.bazi]), participants: [anonymous], descriptors: descriptors)
        XCTAssertEqual(ready.runnableMethods, [.bazi])
        XCTAssertEqual(ready.assessments.first?.participantName, anonymous.anonymousCode)
        XCTAssertTrue(ready.assessments.first?.blocking.isEmpty == true)
    }

    func testBlankAnonymousProfileFallsBackOnlyToAvailableEventMethodForFlexiblePlans() {
        let anonymous = OracleProfile(alias: "占问人")
        let selected: [OracleMethod] = [.ziwei, .xingming]
        let report = ReadingPreparationPolicy.evaluate(plan: plan(selected), participants: [anonymous], descriptors: descriptors)
        XCTAssertTrue(report.canProceed)
        XCTAssertEqual(report.runnableMethods, [.xiaoliuren])
        XCTAssertEqual(report.omissions.map(\.method), selected)
        XCTAssertTrue(report.omissions.allSatisfy { $0.participantID == anonymous.id && $0.participantName == "占问人" })
        XCTAssertEqual(report.assessments.first { $0.method == .xingming }?.blocking.map(\.field), [.surname, .givenName])
        let noFallback = ReadingPreparationPolicy.evaluate(plan: plan(selected), participants: [anonymous],
            descriptors: descriptors.filter { $0.method != .xiaoliuren })
        XCTAssertFalse(noFallback.canProceed)
        let strict = ReadingPreparationPolicy.evaluate(plan: plan(selected, mandatory: [.xingming]),
            participants: [anonymous], descriptors: descriptors)
        XCTAssertTrue(strict.strictBlocked)
        XCTAssertTrue(strict.runnableMethods.isEmpty)
    }

    func testMissingPluginIsExplicitlyUnavailableAndMandatoryMethodCannotDisappearFromPlan() {
        let missingPlugin = ReadingPreparationPolicy.evaluate(plan: plan([.bazi]), participants: [profile()], descriptors: [])
        XCTAssertTrue(missingPlugin.runnableMethods.isEmpty)
        XCTAssertTrue(missingPlugin.omissions.first?.reason.contains("尚未加载") == true)
        let dropped = ReadingPreparationPolicy.evaluate(plan: plan([.meihua], mandatory: [.bazi]), participants: [], descriptors: descriptors)
        XCTAssertTrue(dropped.assessments.contains { $0.method == .bazi })
        XCTAssertTrue(dropped.strictBlocked)
        XCTAssertFalse(dropped.canProceed)
    }

    func testInvalidBirthDateAndTimezoneAreNotTreatedAsUsableDefaults() {
        var person = profile()
        person.birthDate = ISO8601DateFormatter().date(from: "1800-01-01T12:00:00Z")
        person.birthTimeZoneID = "Not/AZone"
        let report = ReadingPreparationPolicy.evaluate(plan: plan([.bazi], mandatory: [.bazi]), participants: [person], descriptors: descriptors)
        XCTAssertFalse(report.canProceed)
        XCTAssertEqual(report.assessments.first?.blocking.map(\.state), [.invalid, .invalid])
        XCTAssertEqual(Set(report.questions.map(\.field)), Set([.birthDate, .birthTimeZone]))
    }

    func testUniformNameIsNeverAutomaticallySplitForXingming() {
        var person = profile()
        let report = ReadingPreparationPolicy.evaluate(plan: plan([.xingming], mandatory: [.xingming]), participants: [person], descriptors: descriptors)
        XCTAssertFalse(report.canProceed)
        XCTAssertEqual(report.missing.first?.fields, [.surname, .givenName])
        person.familyName = "张"; person.givenName = "三"
        XCTAssertTrue(ReadingPreparationPolicy.evaluate(plan: plan([.xingming], mandatory: [.xingming]), participants: [person], descriptors: descriptors).canProceed)
        person.givenName = "一二三四五"
        XCTAssertEqual(ReadingPreparationPolicy.evaluate(plan: plan([.xingming]), participants: [person], descriptors: descriptors).assessments.first?.blocking.first?.state, .invalid)
    }

    func testMandatoryDescriptorRequirementsAreHonoredButMixedUsesActualGuardMinimum() {
        var catalog = descriptors
        let index = catalog.firstIndex { $0.method == .bazi }!
        catalog[index].requiredFields.append(.birthPlace)
        let person = profile()
        let strict = ReadingPreparationPolicy.evaluate(plan: plan([.bazi], mandatory: [.bazi]), participants: [person], descriptors: catalog)
        XCTAssertEqual(strict.assessments.first?.blocking.map(\.field), [.birthPlace])
        let mixed = ReadingPreparationPolicy.evaluate(plan: plan([.bazi]), participants: [person], descriptors: catalog)
        XCTAssertTrue(mixed.canProceed)
        XCTAssertFalse(mixed.questions.contains { $0.field == .birthPlace })
        var event = plan([.meihua]); event.requiredFields = [.birthDate, .birthTimeZone]
        XCTAssertTrue(ReadingPreparationPolicy.evaluate(plan: event, participants: [], descriptors: descriptors).canProceed)
    }

    func testUnprovidedAndDeclaredUnknownAreDistinctAndRepeatedFieldQuestionsAreDeduplicated() throws {
        var person = try emptyNamedProfile()
        let fresh = ReadingPreparationPolicy.evaluate(plan: plan([.bazi, .ziwei]), participants: [person], descriptors: descriptors)
        XCTAssertEqual(fresh.questions.filter { $0.field == .birthDate }.count, 1)
        XCTAssertEqual(fresh.questions.filter { $0.field == .birthTimeZone }.count, 1)
        XCTAssertTrue(fresh.missing.first?.explicitlyUnknownFields.isEmpty == true)
        person.declaredUnknownFields = [.birthTimeZone]
        let declared = ReadingPreparationPolicy.evaluate(plan: plan([.bazi]), participants: [person], descriptors: descriptors)
        XCTAssertTrue(declared.missing.first?.explicitlyUnknownFields.contains(.birthTimeZone) == true)
        XCTAssertFalse(declared.questions.contains { $0.field == .birthTimeZone })
        person.declaredUnknownFields = nil
        let legacy = ReadingPreparationPolicy.evaluate(plan: plan([.bazi]), participants: [person], descriptors: descriptors)
        XCTAssertTrue(legacy.questions.isEmpty)
        let override = ReadingPreparationPolicy.evaluate(plan: plan([.bazi]), participants: [person], descriptors: descriptors, explicitlyUnknownFields: [person.id: []])
        XCTAssertTrue(override.questions.contains { $0.field == .birthTimeZone })
    }

    func testExplicitUnknownMapOverridesStaleStoredValueInBlockingAndSummary() {
        let person = profile()
        let report = ReadingPreparationPolicy.evaluate(plan: plan([.bazi], mandatory: [.bazi]), participants: [person], descriptors: descriptors,
            explicitlyUnknownFields: [person.id: [.birthTimeZone]])
        XCTAssertTrue(report.strictBlocked)
        XCTAssertEqual(report.assessments.first?.blocking.first?.state, .explicitlyUnknown)
        XCTAssertTrue(report.summary.contains("出生时区未确定"))
        XCTAssertFalse(report.summary.contains("Asia/Shanghai"))
        XCTAssertFalse(report.questions.contains { $0.field == .birthTimeZone })
    }

    func testOmissionAndPreparationStageCanRoundTripInPendingPlan() throws {
        var pending = plan([.bazi, .meihua])
        pending.preparationStage = .confirming
        pending.omittedMethods = [OracleMethodOmission(method: .bazi, reason: "出生时区未确定", participantID: UUID(), participantName: "张三")]
        let restored = try JSONDecoder().decode(OraclePlan.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(restored.preparationStage, .confirming)
        XCTAssertEqual(restored.omittedMethods, pending.omittedMethods)
    }
}
