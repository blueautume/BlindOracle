import XCTest
@testable import BlindOracle

final class TrueSolarClockTests: XCTestCase {
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func person() -> OracleProfile {
        var value = OracleProfile()
        value.birthDate = instant("2026-01-02T01:00:00+08:00")
        value.birthLatitude = 39; value.birthLongitude = 75
        value.currentLatitude = 39; value.currentLongitude = 120
        return value
    }

    func testWesternBirthClockMovesToPreviousSolarDayWithoutChangingInstant() throws {
        let profile = person(); let clock = try TrueSolarClock.birth(profile: profile)
        XCTAssertEqual(clock.instant, profile.birthDate)
        XCTAssertEqual(clock.civilSolar.ymd, "2026-01-02")
        XCTAssertEqual(clock.apparentSolar.ymdhms, "2026-01-01 21:56:20")
        XCTAssertEqual(clock.physicalSolar.ymdhms, "2026-01-02 01:00:00")
        XCTAssertEqual(clock.apparentClockDate.timeIntervalSince(instant("2026-01-01T21:56:20Z")), 0.10275, accuracy: 0.02)
    }

    func testHistoricalDaylightSavingOffsetIsAppliedOnce() throws {
        var value = person(); value.birthDate = instant("1988-06-15T12:00:00+09:00")
        value.birthLongitude = 116.4
        let clock = try TrueSolarClock.birth(profile: value)
        XCTAssertEqual(clock.civilSolar.hour, 12)
        XCTAssertEqual(clock.physicalSolar.hour, 11)
        XCTAssertEqual(clock.apparentSolar.ymdhms, "1988-06-15 10:45:11")
        XCTAssertEqual(clock.longitudeCorrectionMinutes, -74.4, accuracy: 0.00001)
    }

    func testEquivalentPhysicalInstantInDifferentCivilZonesHasSameSolarFace() throws {
        var first = person(); var second = first
        first.birthTimeZoneID = "Asia/Shanghai"; second.birthTimeZoneID = "America/New_York"
        let a = try TrueSolarClock.birth(profile: first), b = try TrueSolarClock.birth(profile: second)
        XCTAssertEqual(a.apparentClockDate, b.apparentClockDate)
        XCTAssertNotEqual(a.civilSolar.ymdhms, b.civilSolar.ymdhms)
    }

    func testRawRangeIsValidatedBeforeSolarClockCrossesSupportedYear() throws {
        let clock = try TrueSolarClock.make(instant: instant("1900-01-01T00:10:00+08:00"), zoneID: "Asia/Shanghai", longitude: 75)
        XCTAssertEqual(clock.apparentSolar.year, 1899)
        XCTAssertThrowsError(try TrueSolarClock.make(instant: instant("1899-12-31T12:00:00+08:00"), zoneID: "Asia/Shanghai", longitude: 120))
    }

    func testCastingPlaceIsIndependentOfBirthCoordinatesAndRejectsWithdrawal() throws {
        var value = person(); let birth = try TrueSolarClock.birth(profile: value)
        let input = OracleInput(question: "test", profile: value, castingDate: value.birthDate!)
        let casting = try TrueSolarClock.casting(input: input)
        XCTAssertEqual(birth.longitude, 75); XCTAssertEqual(casting.longitude, 120)
        value.currentLatitude = nil; value.currentLongitude = nil
        XCTAssertThrowsError(try TrueSolarClock.casting(input: OracleInput(question: "test", profile: value)))
        value.currentLatitude = 39; value.currentLongitude = 120
        value.declaredUnknownFields = [.currentLocation]
        XCTAssertNil(TrueSolarClock.castingCoordinates(profile: value))
    }

    func testLegacyCastingDistrictRestoresOnlyAWhollyMissingUnwithdrawnPair() throws {
        var value = OracleProfile(); value.currentDistrictCode = "110101"
        XCTAssertNotNil(TrueSolarClock.castingCoordinates(profile: value))
        value.currentLatitude = 39
        XCTAssertNil(TrueSolarClock.castingCoordinates(profile: value))
        value.currentLatitude = nil; value.unknownFields.insert(.currentLocation)
        XCTAssertNil(TrueSolarClock.castingCoordinates(profile: value))
    }

    func testLegacyBirthDistrictRestoresMissingCoordinatesButNeverWithdrawnLocation() throws {
        var value = person()
        value.birthLatitude = nil; value.birthLongitude = nil; value.birthDistrictCode = "110101"
        XCTAssertNoThrow(try TrueSolarClock.birth(profile: value))
        for field in [OracleField.birthPlace, .birthCoordinates] {
            value.unknownFields = [field]; value.declaredUnknownFields = []
            XCTAssertNoThrow(try TrueSolarClock.birth(profile: value))
            value.declaredUnknownFields = nil // Older withdrawal without a separate declaration set.
            XCTAssertThrowsError(try TrueSolarClock.birth(profile: value))
            value.unknownFields = []; value.declaredUnknownFields = [field]
            XCTAssertThrowsError(try TrueSolarClock.birth(profile: value))
        }
    }

    func testInvalidLongitudeOrZoneAndNonfiniteInstantAreRejected() {
        for lon in [Double.nan, .infinity, -181, 181] {
            XCTAssertThrowsError(try TrueSolarClock.make(instant: Date(), zoneID: "Asia/Shanghai", longitude: lon))
        }
        XCTAssertThrowsError(try TrueSolarClock.make(instant: Date(), zoneID: "Invalid/Zone", longitude: 120))
        XCTAssertThrowsError(try TrueSolarClock.make(instant: Date(timeIntervalSince1970: .nan), zoneID: "UTC", longitude: 120))
    }

    @MainActor func testCoordinateOnlyFormSnapshotRemainsUsableForAllBirthSolarMethods() async throws {
        var profile = person(); profile.sex = "男"; profile.birthPlace = ""
        let saved = try ProfileFormDraft(profile: profile).validatedProfile()
        XCTAssertTrue(saved.unknownFields.contains(.birthPlace))
        XCTAssertFalse(saved.declaredUnknownFields?.contains(.birthPlace) == true)
        XCTAssertNoThrow(try TrueSolarClock.birth(profile: saved))
        let input = OracleInput(question: "test", profile: saved)
        let registry = PluginRegistry()
        for method in [OracleMethod.bazi, .ziwei, .chenggu] {
            var plan = OraclePlan(intent: "test", subject: "本人", methods: [method], requiredFields: [], note: "", question: "test")
            plan.mandatoryMethods = [method]
            XCTAssertTrue(ReadingPreparationPolicy.evaluate(plan: plan, participants: [saved], descriptors: registry.descriptors).canProceed)
            let result = try await XCTUnwrap(registry.plugin(method)).calculate(input)
            XCTAssertTrue([.complete, .partial].contains(result.status), method.rawValue)
        }
        for declaration in [Set<OracleField>([.birthPlace]), nil] {
            var withdrawn = saved; withdrawn.declaredUnknownFields = declaration
            XCTAssertNil(BaziBirthLocation.coordinates(for: withdrawn))
            XCTAssertThrowsError(try TrueSolarClock.birth(profile: withdrawn))
        }
    }

    func testUnknownBirthHourCandidatesIncludeBothSolarDatesAndOnlyReachableEdgeHours() throws {
        var value = person(); value.birthTimeKnown = false
        let candidates = try TrueSolarClock.birthHourCandidates(profile: value)
        let previous = candidates.filter { $0.ymd == "2026-01-01" }
        let current = candidates.filter { $0.ymd == "2026-01-02" }
        XCTAssertEqual(Set(previous.map { $0.lunar.timeZhiIndex }), Set([10, 11, 0]))
        XCTAssertEqual(Set(current.map { $0.lunar.timeZhiIndex }), Set(0...10))
        XCTAssertEqual(Set(candidates.map(\.ymd)), Set(["2026-01-01", "2026-01-02"]))
        XCTAssertEqual(Set(candidates.map { "\($0.ymd)-\($0.lunar.timeZhiIndex)" }).count, candidates.count)
    }

    func testUnknownHourCandidateCoverageHandlesHistoricalLongCivilDay() throws {
        var value = person(); value.birthDate = instant("2026-11-01T12:00:00-05:00")
        value.birthTimeZoneID = "America/New_York"; value.birthLongitude = -74
        let candidates = try TrueSolarClock.birthHourCandidates(profile: value)
        XCTAssertGreaterThanOrEqual(candidates.count, 12)
        XCTAssertLessThanOrEqual(candidates.count, 26)
    }
}
