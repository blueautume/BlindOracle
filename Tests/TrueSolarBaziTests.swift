import XCTest
@testable import BlindOracle

final class TrueSolarBaziTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func profile(_ instant: String = "2026-01-02T01:00:00+08:00", longitude: Double = 75) -> OracleProfile {
        var person = OracleProfile()
        person.birthDate = date(instant)
        person.birthTimeKnown = true
        person.birthTimeZoneID = "Asia/Shanghai"
        person.birthPlace = "已确认的出生地"
        person.birthLatitude = 39.5
        person.birthLongitude = longitude
        person.sex = "男"
        return person
    }

    private func calculate(_ person: OracleProfile) async -> BaziCalculation {
        await AppLanguage.$override.withValue(.simplifiedChinese) {
            await TrueSolarBaziEngine.shared.calculate(profile: person)
        }
    }

    private func value(_ result: OracleResult, _ label: String) -> String? {
        result.rows.first { $0.label == label }?.value
    }

    private func pillars(_ calculation: BaziCalculation) throws -> [String] {
        let raw = try XCTUnwrap(calculation.rawPillars)
        let parts = raw.split(separator: " ").map(String.init)
        XCTAssertEqual(parts.count, 4)
        return parts
    }

    func testEquationOfTimeMatchesIndependentNOAAJavaScriptReferenceValues() {
        // Fixed outputs from executing the unmodified calcEquationOfTime
        // function in NOAA's official calculator, outside the Swift engine:
        // https://gml.noaa.gov/grad/solcalc/main.js
        let references: [(String, Double)] = [
            ("1900-01-01T12:00:00Z", -3.6623320178390935),
            ("2000-01-01T12:00:00Z", -3.3012588023605938),
            ("2026-02-11T12:00:00Z", -14.226179863880096),
            ("2026-06-21T12:00:00Z", -1.8242799980127842),
            ("2026-11-03T12:00:00Z", 16.492216222893628),
            ("2100-12-31T12:00:00Z", -2.8263164284887217),
        ]
        for (instant, expected) in references {
            XCTAssertEqual(TrueSolarTime.equationOfTimeMinutes(at: date(instant)), expected,
                           accuracy: 1e-7, instant)
        }
    }

    func testSupportedBirthYearsCanCorrectIntoTheAdjacentSolarYear() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cases: [(String, Double, Int, String)] = [
            ("1900-01-01T01:00:00+08:00", 75, 1899, "癸酉"),
            ("2100-12-31T23:30:00+08:00", 135, 2101, "戊申"),
        ]
        for (instant, longitude, solarYear, dayPillar) in cases {
            let person = profile(instant, longitude: longitude)
            let solarClock = TrueSolarTime.apparentDate(at: try XCTUnwrap(person.birthDate), longitude: longitude)
            XCTAssertEqual(calendar.component(.year, from: solarClock), solarYear)
            let calculation = await calculate(person)
            XCTAssertNotEqual(calculation.result.status, .unavailable, instant)
            XCTAssertEqual(try pillars(calculation)[2], dayPillar, instant)
        }
    }

    func testWestLongitudeCanMoveTheSolarClockIntoThePreviousDay() async throws {
        let person = profile()
        let solarClock = TrueSolarTime.apparentDate(at: try XCTUnwrap(person.birthDate), longitude: 75)
        // Independent execution of NOAA's main.js gives 21:56:20.10275 on
        // the previous solar date for 01:00 Beijing time at 75 E.
        XCTAssertEqual(solarClock.timeIntervalSince(date("2026-01-01T21:56:20Z")), 0.10275,
                       accuracy: 0.01)
        let west = try pillars(await calculate(person))
        XCTAssertEqual(west[2], "乙亥")
        XCTAssertEqual(west[3], "丁亥")
        let east = try pillars(await calculate(profile(longitude: 120)))
        XCTAssertEqual(east[2], "丙子")
        XCTAssertEqual(east[3], "戊子")
        XCTAssertEqual(Array(west.prefix(2)), Array(east.prefix(2)))
    }

    func testYearAndMonthChangeAtTheActualSpringTermInstantInWesternChina() async throws {
        // HKO Almanac 2026 gives Start of Spring on 4 February at 04:02 UTC+8.
        // Both solar clocks at 75 E remain before 04:00; using the corrected
        // clock to compare against an uncorrected term would miss this change.
        let before = try pillars(await calculate(profile("2026-02-04T04:01:00+08:00")))
        let after = try pillars(await calculate(profile("2026-02-04T04:03:00+08:00")))
        XCTAssertEqual(Array(before.prefix(2)), ["乙巳", "己丑"])
        XCTAssertEqual(Array(after.prefix(2)), ["丙午", "庚寅"])
    }

    func testMonthChangesAtTheActualJuneTermEvenWhenSolarClockIsEarlier() async throws {
        // HKO Almanac 2026: Corn on Ear begins 5 June at 23:48 UTC+8.
        let before = try pillars(await calculate(profile("2026-06-05T23:47:00+08:00")))
        let after = try pillars(await calculate(profile("2026-06-05T23:49:00+08:00")))
        XCTAssertEqual(before[0], "丙午")
        XCTAssertEqual(after[0], "丙午")
        XCTAssertEqual(before[1], "癸巳")
        XCTAssertEqual(after[1], "甲午")
    }

    func testHistoricalSummerTimeIsRemovedOnceUsingTheActualInstant() async throws {
        let person = profile("1988-06-15T12:00:00+09:00", longitude: 116.4)
        let instant = try XCTUnwrap(person.birthDate)
        XCTAssertEqual(TimeZone(identifier: "Asia/Shanghai")?.secondsFromGMT(for: instant), 9 * 3_600)
        let solarClock = TrueSolarTime.apparentDate(at: instant, longitude: 116.4)
        // Noon on the historical DST clock is 03:00 UTC. The local true solar
        // clock is 10:45:11.99301 from NOAA's unmodified main.js, not 11:45
        // and not an extra hour earlier.
        XCTAssertEqual(solarClock.timeIntervalSince(date("1988-06-15T10:45:11Z")), 0.99301,
                       accuracy: 0.01)
        let result = try pillars(await calculate(person))
        XCTAssertEqual(result[2], "辛丑")
        XCTAssertEqual(result[3], "癸巳")
    }

    func testUnknownBirthTimeKeepsPossibleSolarDatesAndDoesNotExposeAUniqueChart() async throws {
        var person = profile()
        person.birthTimeKnown = false
        person.unknownFields.insert(.birthTime)
        let first = await calculate(person)
        person.birthDate = date("2026-01-02T22:00:00+08:00")
        let second = await calculate(person)
        XCTAssertEqual(first.result.status, .partial)
        XCTAssertNil(first.rawPillars)
        XCTAssertEqual(first.result.rows, second.result.rows)
        let days = try XCTUnwrap(value(first.result, "日柱"))
        XCTAssertTrue(days.contains("乙亥"))
        XCTAssertTrue(days.contains("丙子"))
        XCTAssertTrue(value(first.result, "时柱")?.contains("未知") == true)
        XCTAssertFalse(first.result.rows.contains { $0.label.hasPrefix("大运") })
    }

    func testBirthCoordinatesAreRequiredAndCurrentLocationCannotSubstitute() async {
        var person = profile()
        person.birthLatitude = nil
        person.birthLongitude = nil
        person.currentLatitude = 39.9
        person.currentLongitude = 116.4
        person.currentPlace = "北京"
        let calculation = await calculate(person)
        XCTAssertEqual(calculation.result.status, .unavailable)
        XCTAssertNil(calculation.rawPillars)
        XCTAssertFalse(calculation.previewPlaceholder.isEmpty)
    }

    func testUnconfirmedBirthDateOrTimeZoneNeverUsesAStoredDefault() async {
        for field in [OracleField.birthDate, .birthTimeZone] {
            var person = profile()
            person.unknownFields.insert(field)
            let calculation = await calculate(person)
            XCTAssertEqual(calculation.result.status, .unavailable, field.rawValue)
            XCTAssertNil(calculation.rawPillars, field.rawValue)

        }
        var invalidZone = profile()
        invalidZone.birthTimeZoneID = "Not/AZone"
        let invalid = await calculate(invalidZone)
        XCTAssertEqual(invalid.result.status, .unavailable)
        XCTAssertNil(invalid.rawPillars)
    }

    func testWithdrawnCoordinatesOrPlaceNeverReuseAnOldDistrictOrCoordinatePair() async {
        for field in [OracleField.birthCoordinates, .birthPlace] {
            var person = profile()
            person.birthDistrictCode = "110108"
            person.unknownFields.insert(field)
            person.declaredUnknownFields = [field]
            let calculation = await calculate(person)
            XCTAssertEqual(calculation.result.status, .unavailable, field.rawValue)
            XCTAssertNil(calculation.rawPillars, field.rawValue)

            // Older records have only unknownFields to record a withdrawal.
            // A district code must not resurrect those missing coordinates.
            person.birthLatitude = nil
            person.birthLongitude = nil
            person.declaredUnknownFields = nil
            let legacy = await calculate(person)
            XCTAssertEqual(legacy.result.status, .unavailable, "legacy \(field.rawValue)")
            XCTAssertNil(legacy.rawPillars, "legacy \(field.rawValue)")
        }
    }

    func testDistrictCodeCanRestoreOnlyAnUnwithdrawnMissingCoordinatePair() async throws {
        var coded = profile()
        coded.birthDistrictCode = "110108"
        coded.birthLatitude = nil
        coded.birthLongitude = nil
        coded.unknownFields.insert(.birthCoordinates)
        coded.declaredUnknownFields = [] // Missing, rather than explicitly withdrawn.
        let restored = await calculate(coded)
        XCTAssertNotNil(restored.rawPillars)
        var explicit = coded
        explicit.birthLatitude = 40.03102
        explicit.birthLongitude = 116.22108
        explicit.unknownFields.remove(.birthCoordinates)
        let explicitResult = await calculate(explicit)
        XCTAssertEqual(restored.rawPillars, explicitResult.rawPillars)

        coded.birthDistrictCode = nil
        coded.birthPlace = "北京市海淀区"
        let textOnly = await calculate(coded)
        XCTAssertEqual(textOnly.result.status, .unavailable)
    }

    func testInvalidOrIncompleteCoordinatePairsAreNotReplacedByDistrictDefaults() async {
        let coordinates: [(Double?, Double?)] = [
            (nil, 116.4), (39.9, nil), (Double.nan, 116.4), (39.9, Double.infinity),
            (91, 116.4), (39.9, 181),
        ]
        for (latitude, longitude) in coordinates {
            var person = profile()
            person.birthDistrictCode = "110108"
            person.birthLatitude = latitude
            person.birthLongitude = longitude
            let calculation = await calculate(person)
            XCTAssertEqual(calculation.result.status, .unavailable)
            XCTAssertNil(calculation.rawPillars)
        }
    }

    func testCurrentLocationAndCastingInputsDoNotChangeTheBirthChart() async throws {
        var person = profile()
        let original = await calculate(person)
        person.currentPlace = "上海"
        person.currentLatitude = 31.2
        person.currentLongitude = 121.5
        person.currentTimeZoneID = "Asia/Tokyo"
        let moved = await calculate(person)
        XCTAssertEqual(original.rawPillars, moved.rawPillars)
        XCTAssertEqual(original.result.rows, moved.result.rows)
        var request = OracleInput(question: "工作", profile: person, seed: 1)
        let plugin = try await AppLanguage.$override.withValue(.simplifiedChinese) {
            try await BaziPlugin().calculate(request)
        }
        request.question = "关系"
        request.castingDate = date("2030-01-01T12:00:00Z")
        request.seed = 99
        let changedQuestion = try await AppLanguage.$override.withValue(.simplifiedChinese) {
            try await BaziPlugin().calculate(request)
        }
        XCTAssertEqual(plugin.rows, changedQuestion.rows)
    }

    func testPreviewAndPluginUseIdenticalPillarsAndAnalysis() async throws {
        let person = profile("2005-12-23T08:37:00+08:00", longitude: 120)
        let preview = await calculate(person)
        let plugin = try await AppLanguage.$override.withValue(.simplifiedChinese) {
            try await BaziPlugin().calculate(OracleInput(question: "工作", profile: person))
        }
        XCTAssertEqual(preview.rawPillars, "乙酉 戊子 辛巳 壬辰")
        XCTAssertEqual(plugin.headline, preview.result.headline)
        XCTAssertEqual(plugin.rows, preview.result.rows)
        XCTAssertEqual(plugin.limitations, preview.result.limitations)
        XCTAssertEqual(plugin.version, preview.result.version)
    }
}
