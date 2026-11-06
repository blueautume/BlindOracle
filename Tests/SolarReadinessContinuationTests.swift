import XCTest
@testable import BlindOracle

final class SolarReadinessContinuationTests: XCTestCase {
    private var descriptors: [OraclePluginDescriptor] { PluginRegistry().descriptors }
    private func plan(_ methods: [OracleMethod]) -> OraclePlan {
        var value = OraclePlan(intent: "test", subject: "事件", methods: methods, requiredFields: [], note: "", question: "test")
        value.mandatoryMethods = methods
        return value
    }
    private func location() -> OracleProfile {
        var profile = OracleProfile()
        profile.currentLatitude = 39.9; profile.currentLongitude = 116.4
        profile.currentPlace = "北京"; profile.currentTimeZoneID = "Asia/Shanghai"
        profile.birthDate = ISO8601DateFormatter().date(from: "1990-01-02T08:30:00+08:00")
        profile.birthLatitude = 39.9; profile.birthLongitude = 116.4
        profile.sex = "男"
        return profile
    }

    func testCastingMethodsNeedAnIndependentPlaceEvenWithoutParticipants() {
        for method in [OracleMethod.qimen, .xiaoliuren, .meihua] {
            let missing = ReadingPreparationPolicy.evaluate(plan: plan([method]), participants: [], descriptors: descriptors)
            XCTAssertFalse(missing.canProceed)
            XCTAssertEqual(missing.assessments.first?.blocking.first?.field, .currentLocation)
            let ready = ReadingPreparationPolicy.evaluate(plan: plan([method]), participants: [], descriptors: descriptors, castingProfile: location())
            XCTAssertTrue(ready.canProceed)
            XCTAssertTrue(ready.missing.isEmpty)
        }
    }

    func testThreeNumbersNeedNeitherPlaceNorBirthDataButTwoNumbersNeedPlace() {
        let p = plan([.meihua])
        XCTAssertTrue(ReadingPreparationPolicy.evaluate(plan: p, participants: [], descriptors: descriptors, numbers: [8, 8, 6]).canProceed)
        XCTAssertFalse(ReadingPreparationPolicy.evaluate(plan: p, participants: [], descriptors: descriptors, numbers: [8, 8]).canProceed)
        XCTAssertTrue(ReadingPreparationPolicy.evaluate(plan: p, participants: [], descriptors: descriptors, castingProfile: location(), numbers: [8, 8]).canProceed)
    }

    func testSuppliedGlobalPlaceIsNotReplacedByAnotherPersonsBirthplace() {
        var person = location(); person.currentLongitude = 75
        var withdrawn = location(); withdrawn.declaredUnknownFields = [.currentLocation]
        let result = ReadingPreparationPolicy.evaluate(plan: plan([.qimen]), participants: [person], descriptors: descriptors, castingProfile: withdrawn)
        XCTAssertFalse(result.canProceed)
        XCTAssertEqual(result.assessments.first?.blocking.first?.state, .explicitlyUnknown)
    }

    func testZiweiAndChengguRequireBirthCoordinatesIndependentlyOfCastingPlace() {
        var person = location(); person.birthLatitude = nil; person.birthLongitude = nil
        for method in [OracleMethod.ziwei, .chenggu] {
            let result = ReadingPreparationPolicy.evaluate(plan: plan([method]), participants: [person], descriptors: descriptors, castingProfile: location())
            XCTAssertFalse(result.canProceed)
            XCTAssertTrue(result.assessments.first?.blocking.contains { $0.field == .birthCoordinates } == true)
        }
    }

    func testLegacyBirthDistrictRestorationAndWithdrawalAgreeWithCalculationReadiness() {
        var person = location()
        person.birthLatitude = nil; person.birthLongitude = nil; person.birthDistrictCode = "110101"
        for field in [OracleField.birthPlace, .birthCoordinates] {
            person.unknownFields = [field]
            for method in [OracleMethod.bazi, .ziwei, .chenggu] {
                person.declaredUnknownFields = []
                let ready = ReadingPreparationPolicy.evaluate(plan: plan([method]), participants: [person], descriptors: descriptors)
                XCTAssertTrue(ready.canProceed)
                person.declaredUnknownFields = [field]
                let result = ReadingPreparationPolicy.evaluate(plan: plan([method]), participants: [person], descriptors: descriptors)
                XCTAssertFalse(result.canProceed)
                XCTAssertTrue(result.assessments.first?.blocking.contains { $0.field == .birthCoordinates } == true)
            }
        }
    }

    private func run(method: OracleMethod, numbers: [Int] = []) -> OracleRun {
        let input = OracleInput(question: "test", profile: location(), numbers: numbers)
        var run = OracleRun(input: input, plan: plan([method]))
        run.results = [OracleResult(method: method, version: "2.0.0", headline: "saved", rows: [.init("saved", "unchanged")])]
        return run
    }

    func testChangedCastingCoordinatesInvalidateTimeDependentResults() {
        for method in [OracleMethod.qimen, .xiaoliuren, .meihua] {
            let saved = run(method: method, numbers: method == .meihua ? [8, 8] : [])
            var candidate = saved.input; candidate.profile.currentLongitude = 75
            XCTAssertTrue(ReadingContinuationPolicy.reusableResults(from: saved, for: candidate, methods: [method]).isEmpty)
            XCTAssertEqual(saved.results.first?.rows, [.init("saved", "unchanged")])
        }
    }

    func testThreeNumberResultSurvivesUnrelatedTimeAndLocationChanges() {
        let saved = run(method: .meihua, numbers: [8, 8, 6])
        var candidate = saved.input
        candidate.castingDate = candidate.castingDate.addingTimeInterval(86_400)
        candidate.profile.currentLongitude = 75; candidate.profile.currentTimeZoneID = "UTC"
        XCTAssertEqual(ReadingContinuationPolicy.reusableResults(from: saved, for: candidate, methods: [.meihua]).first?.id, saved.results.first?.id)
        candidate.numbers[2] = 5
        XCTAssertTrue(ReadingContinuationPolicy.reusableResults(from: saved, for: candidate, methods: [.meihua]).isEmpty)
    }

    func testChangedBirthLongitudeInvalidatesZiweiAndChengguWhileHistoryStaysIntact() {
        for method in [OracleMethod.ziwei, .chenggu] {
            let saved = run(method: method)
            var candidate = saved.input; candidate.profile.birthLongitude = 75
            XCTAssertTrue(ReadingContinuationPolicy.reusableResults(from: saved, for: candidate, methods: [method]).isEmpty)
            XCTAssertEqual(saved.input.profile.birthLongitude, 116.4)
            XCTAssertEqual(saved.results.first?.version, "2.0.0")
        }
    }

    func testOldPlanDecodesWithoutNewCastingDraftAndNewDraftRoundTrips() throws {
        var p = plan([.qimen]); p.castingProfile = location()
        let encoder = JSONEncoder(); let decoder = JSONDecoder()
        let data = try encoder.encode(p)
        XCTAssertEqual(try decoder.decode(OraclePlan.self, from: data).castingProfile, p.castingProfile)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "castingProfile")
        XCTAssertNil(try decoder.decode(OraclePlan.self, from: JSONSerialization.data(withJSONObject: old)).castingProfile)
    }

    func testDeclaredOnlyRetractionsInvalidateOldResultsEvenBeforeUnknownMarkersNormalize() {
        let numbers = run(method: .meihua, numbers: [8, 8, 6])
        var candidate = numbers.input; candidate.profile.declaredUnknownFields = [.numbers]
        XCTAssertTrue(ReadingContinuationPolicy.reusableResults(from: numbers, for: candidate, methods: [.meihua]).isEmpty)
        for method in [OracleMethod.bazi, .ziwei, .chenggu] {
            let saved = run(method: method)
            for field in [OracleField.birthDate, .birthTime, .birthTimeZone, .birthCoordinates] {
                var next = saved.input; next.profile.declaredUnknownFields = [field]
                XCTAssertTrue(ReadingContinuationPolicy.reusableResults(from: saved, for: next, methods: [method]).isEmpty)
            }
        }
    }
}
