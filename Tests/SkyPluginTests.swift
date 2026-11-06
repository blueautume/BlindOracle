import XCTest
@testable import BlindOracle

@MainActor
final class SkyPluginTests: XCTestCase {
    private func sample() -> OracleInput {
        var profile = OracleProfile()
        profile.sex = "男"
        profile.birthTimeZoneID = "Asia/Shanghai"
        profile.birthDate = ISO8601DateFormatter().date(from: "1990-05-17T04:00:00Z")!
        profile.birthLatitude = 31.2304
        profile.birthLongitude = 121.4737
        return OracleInput(question: "今年事业如何", profile: profile,
            castingDate: ISO8601DateFormatter().date(from: "2026-11-02T04:00:00Z")!, seed: 123)
    }

    func testZiweiFixtureAndReproducibility() async throws {
        let first = try await ziwei(sample())
        let second = try await ziwei(sample())
        XCTAssertEqual(first.status, .complete)
        XCTAssertEqual(first.rows, second.rows)
        XCTAssertTrue(first.headline.contains("土五局"))
        XCTAssertTrue(first.headline.contains("命宫亥"))
        XCTAssertTrue(first.headline.contains("巨门"))
        // 04:00Z was 13:00 on Shanghai's historical DST clock. The natal
        // solar clock at 121.4737 E is shortly after noon, in Wu rather than Wei.
        XCTAssertTrue(value(first, "原始钟表时间")?.contains("1990-05-17 13:00:00 · Asia/Shanghai") == true)
        XCTAssertTrue(value(first, "真太阳时")?.hasPrefix("1990-05-17 12:") == true)
        XCTAssertEqual(value(first, "本命太阳时辰"), "午时")
        XCTAssertEqual(first.version, "2.0.0+iztro.2.6.3")
        XCTAssertEqual(first.rows.filter { $0.label.contains("（") }.count, 12)
        XCTAssertTrue(first.rows.contains { $0.label == "流年四化" && $0.value.contains("天同化禄") })
    }

    func testZiweiDoesNotInventUnknownBirthTimeOrGender() async throws {
        var input = sample()
        input.profile.birthTimeKnown = false
        let uncertainTime = try await ZiweiPlugin().calculate(input)
        XCTAssertEqual(uncertainTime.status, .unavailable)
        XCTAssertTrue(uncertainTime.rows.isEmpty)
        input.profile.birthTimeKnown = true
        input.profile.sex = "未提供"
        let uncertainGender = try await ZiweiPlugin().calculate(input)
        XCTAssertEqual(uncertainGender.status, .unavailable)
    }

    func testZiweiCorrectsTheWholeSolarDateAndDoesNotAddAnotherLateZiDay() async throws {
        // NOAA's independent reference for this instant is +16.492216 minutes.
        // The same instant at 165 E is Nov 3 23:16:29; at 180 E it is Nov 4
        // 00:16:29. The caller must pass those dates and indices 12 / 0 as-is.
        let cases: [(Double, String, [Int], String)] = [
            (165, "2026-11-03 23:16:29", [2026, 11, 3], "晚子时"),
            (180, "2026-11-04 00:16:29", [2026, 11, 4], "早子时"),
        ]
        for (longitude, solarClock, calendarDate, hour) in cases {
            let input = input("2026-11-03T12:00:00Z", longitude: longitude)
            let result = try await ziwei(input)
            XCTAssertEqual(result.status, .complete)
            XCTAssertEqual(value(result, "真太阳时"), solarClock)
            XCTAssertEqual(chartDate(result), calendarDate)
            XCTAssertEqual(value(result, "本命太阳时辰"), hour)
        }
    }

    func testZiweiSolarClockCanMoveToThePreviousCivilDate() async throws {
        let result = try await ziwei(input("2026-01-02T01:00:00+08:00", longitude: 75))
        XCTAssertEqual(result.status, .complete)
        // Fixed NOAA reference: previous solar day, not the saved civil Jan 2.
        XCTAssertEqual(value(result, "真太阳时"), "2026-01-01 21:56:20")
        XCTAssertEqual(chartDate(result), [2026, 1, 1])
        XCTAssertEqual(value(result, "本命太阳时辰"), "亥时")
    }

    func testZiweiHistoricalDaylightSavingIsRemovedExactlyOnce() async throws {
        let result = try await ziwei(input("1988-06-15T12:00:00+09:00", longitude: 116.4))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(value(result, "原始钟表时间"), "1988-06-15 12:00:00 · Asia/Shanghai")
        XCTAssertEqual(value(result, "真太阳时"), "1988-06-15 10:45:11")
        XCTAssertEqual(value(result, "本命太阳时辰"), "巳时")
        XCTAssertEqual(value(result, "经度及时制校正"), "-74.400 min")
    }

    func testZiweiRequiresItsBirthplaceInsteadOfCurrentCoordinatesOrAPlaceName() async throws {
        var input = sample()
        input.profile.birthLatitude = nil
        input.profile.birthLongitude = nil
        input.profile.birthPlace = "上海市"
        input.profile.currentLatitude = 31.2304
        input.profile.currentLongitude = 121.4737
        let result = try await ziwei(input)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(result.headline.contains("出生地"))
        XCTAssertTrue(ZiweiPlugin().descriptor.requiredFields.contains(.birthCoordinates))
        XCTAssertEqual(result.version, ZiweiPlugin.algorithmVersion)
    }

    func testZiweiDoesNotRestoreWithdrawnPartialOrInvalidBirthCoordinates() async throws {
        let points: [(Double?, Double?)] = [(nil, 116.4), (39.9, nil), (Double.nan, 116.4),
            (39.9, Double.infinity), (91, 116.4), (39.9, 181)]
        for (latitude, longitude) in points {
            var input = sample()
            input.profile.birthDistrictCode = "110108"
            input.profile.birthLatitude = latitude
            input.profile.birthLongitude = longitude
            let result = try await ziwei(input)
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertTrue(result.rows.isEmpty)
        }
        for field in [OracleField.birthPlace, .birthCoordinates] {
            var input = sample()
            input.profile.birthDistrictCode = "110108"
            input.profile.declaredUnknownFields = [field]
            let result = try await ziwei(input)
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertTrue(result.rows.isEmpty)
        }
    }

    func testZiweiCanRestoreAnUnwithdrawnLegacyDistrictPoint() async throws {
        var coded = sample()
        coded.profile.birthDistrictCode = "110108"
        coded.profile.birthLatitude = nil
        coded.profile.birthLongitude = nil
        coded.profile.unknownFields.insert(.birthCoordinates)
        coded.profile.declaredUnknownFields = []
        var explicit = coded
        explicit.profile.birthLatitude = 40.03102
        explicit.profile.birthLongitude = 116.22108
        explicit.profile.unknownFields.remove(.birthCoordinates)
        let restored = try await ziwei(coded)
        let direct = try await ziwei(explicit)
        XCTAssertEqual(restored.status, .complete)
        XCTAssertEqual(restored.rows, direct.rows)
    }

    func testZiweiHonorsExplicitUnknownBirthFieldsEvenWithStoredValues() async throws {
        for field in [OracleField.birthDate, .birthTime, .birthTimeZone, .gender] {
            var input = sample()
            input.profile.declaredUnknownFields = [field]
            let result = try await ziwei(input)
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertTrue(result.rows.isEmpty)
            XCTAssertEqual(result.version, ZiweiPlugin.algorithmVersion)
        }
    }

    func testZiweiKeepsThePhysicalInstantAndHoroscopeCivilClockSeparate() async throws {
        var original = sample()
        let baseline = try await ziwei(original)
        // A different display zone for the same physical instant must not
        // move the birthplace's solar clock or the natal palace structure.
        original.profile.birthTimeZoneID = "UTC"
        let otherBirthZone = try await ziwei(original)
        XCTAssertEqual(baseline.headline, otherBirthZone.headline)
        XCTAssertEqual(value(baseline, "真太阳时"), value(otherBirthZone, "真太阳时"))
        XCTAssertEqual(palaces(baseline), palaces(otherBirthZone))
        var withoutCurrentPoint = sample()
        withoutCurrentPoint.profile.currentLatitude = nil
        withoutCurrentPoint.profile.currentLongitude = nil
        withoutCurrentPoint.profile.declaredUnknownFields = [.currentLocation]
        let currentPointUnknown = try await ziwei(withoutCurrentPoint)
        XCTAssertEqual(currentPointUnknown.status, .complete)
        XCTAssertEqual(currentPointUnknown.rows, baseline.rows)
        XCTAssertTrue(value(baseline, "时间口径")?.contains("不作目标真太阳时校正") == true)
        XCTAssertTrue(value(baseline, "运限查询民用时间")?.contains("Asia/Shanghai") == true)
        withoutCurrentPoint.profile.currentTimeZoneID = "UTC"
        let utcTarget = try await ziwei(withoutCurrentPoint)
        XCTAssertEqual(value(baseline, "本命太阳时辰"), value(utcTarget, "本命太阳时辰"))
        XCTAssertEqual(palaces(baseline), palaces(utcTarget))
        // Foundation canonicalizes the UTC alias to GMT on Apple platforms.
        // Assert the actual zero-offset civil clock as well as its canonical name.
        let zeroOffsetZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(value(utcTarget, "运限查询民用时间"), "2026-11-02 04:00 · " + zeroOffsetZone.identifier)
        XCTAssertNotEqual(value(baseline, "运限查询民用时间"), value(utcTarget, "运限查询民用时间"))
    }

    func testZiweiDoesNotClampSolarDatesAtTheOriginalSupportedYearBoundaries() async throws {
        for (instant, longitude, expectedYear) in [("1900-01-01T01:00:00+08:00", 75.0, 1899),
            ("2100-12-31T23:30:00+08:00", 135.0, 2101)] {
            let result = try await ziwei(input(instant, longitude: longitude))
            if result.status == .complete {
                XCTAssertTrue(value(result, "真太阳时")?.hasPrefix("\(expectedYear)-") == true)
                XCTAssertEqual(chartDate(result).first, expectedYear)
            } else {
                XCTAssertEqual(result.status, .unavailable)
                XCTAssertTrue(result.headline.contains("\(expectedYear)-"))
                XCTAssertTrue(result.headline.contains("边界"))
                XCTAssertTrue(result.rows.isEmpty)
            }
            XCTAssertEqual(result.version, ZiweiPlugin.algorithmVersion)
        }
    }

    func testWesternProducesTenPositionsAndExplicitEqualHouses() async throws {
        let result = try await WesternAstrologyPlugin().calculate(sample())
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.rows.filter { $0.label.hasPrefix("本命") && !$0.label.contains("相位") }.count, 10)
        XCTAssertEqual(result.rows.filter { $0.label.contains("宫宫头") }.count, 12)
        XCTAssertTrue(result.rows.contains { $0.label == "宫制" && $0.value.contains("等宫制") })
        XCTAssertTrue(result.rows.contains { $0.label == "本命太阳" && $0.value.contains("金牛") })
    }

    func testUnknownTimeProducesDailyIntervalsWithoutHouseOrEvidence() async throws {
        var input = sample()
        input.profile.birthTimeKnown = false
        let result = try await WesternAstrologyPlugin().calculate(input)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.version, WesternAstrologyPlugin().descriptor.version)
        XCTAssertEqual(result.rows.count, 11)
        XCTAssertTrue(result.evidence.isEmpty)
        XCTAssertFalse(result.rows.contains { $0.label.contains("上升") || $0.label.contains("宫头") })
    }

    func testMissingCoordinatesDoesNotBorrowCurrentLocation() async throws {
        var input = sample()
        input.profile.birthLatitude = nil
        input.profile.birthLongitude = nil
        input.profile.currentLatitude = 31.2
        input.profile.currentLongitude = 121.5
        let result = try await WesternAstrologyPlugin().calculate(input)
        XCTAssertEqual(result.status, .partial)
        XCTAssertFalse(result.rows.contains { $0.label.contains("上升") || $0.label.contains("宫头") })
    }

    func testExplicitlyUnknownCoordinatesIgnorePreviouslySavedValues() async throws {
        var input = sample()
        input.profile.unknownFields.insert(.birthCoordinates)
        let result = try await WesternAstrologyPlugin().calculate(input)
        XCTAssertEqual(result.status, .partial)
        XCTAssertFalse(result.rows.contains { $0.label.contains("上升") || $0.label.contains("宫头") })
        XCTAssertEqual(result.rows.filter { $0.label.hasPrefix("本命") && !$0.label.contains("相位") }.count, 10)
    }

    func testUnknownTimezoneDoesNotReusePreviouslySavedIdentifier() async throws {
        var input = sample()
        input.profile.unknownFields.insert(.birthTimeZone)
        let ziwei = try await ZiweiPlugin().calculate(input)
        let astrology = try await WesternAstrologyPlugin().calculate(input)
        XCTAssertEqual(ziwei.status, .unavailable)
        XCTAssertEqual(astrology.status, .unavailable)
        XCTAssertTrue(ziwei.rows.isEmpty)
        XCTAssertTrue(astrology.rows.isEmpty)
    }

    func testAngleWrapAndLateZiHour() {
        XCTAssertEqual(SkyMath.separation(359, 1), 2, accuracy: 0.00001)
        XCTAssertEqual(SkyMath.normalize(-1), 359, accuracy: 0.00001)
        XCTAssertEqual(SkyMath.timeIndex(hour: 0), 0)
        XCTAssertEqual(SkyMath.timeIndex(hour: 1), 1)
        XCTAssertEqual(SkyMath.timeIndex(hour: 22), 11)
        XCTAssertEqual(SkyMath.timeIndex(hour: 23), 12)
    }
    func testEnglishSkyChartsPreserveTimeAndEvidenceIdentity() async throws {
        let ziwei = ZiweiPlugin()
        let astrology = WesternAstrologyPlugin()
        let input = sample()
        let chinese = try await AppLanguage.$override.withValue(.simplifiedChinese) {
            (try await ziwei.calculate(input), try await astrology.calculate(input))
        }
        let english = try await AppLanguage.$override.withValue(.english) {
            XCTAssertTrue(ziwei.descriptor.summary.contains("on device"))
            return (try await ziwei.calculate(input), try await astrology.calculate(input))
        }
        XCTAssertEqual(english.0.evidence.map(\.id), chinese.0.evidence.map(\.id))
        XCTAssertEqual(english.1.evidence.map(\.id), chinese.1.evidence.map(\.id))
        XCTAssertTrue(english.0.headline.contains("Earth 5 configuration"))
        XCTAssertEqual(english.0.rows.first { $0.label == "Natal solar hour" }?.value, "Wu hour")
        XCTAssertTrue(english.0.rows.first { $0.label == "Original civil time" }?.value.contains("13:00:00 · Asia/Shanghai") == true)
        XCTAssertTrue(english.0.rows.first { $0.label == "Time conventions" }?.value.contains("without a target solar-time correction") == true)
        XCTAssertTrue(english.1.rows.first { $0.label == "Natal Sun" }?.value.hasPrefix("Taurus ") == true)
        XCTAssertEqual(english.1.rows.filter { $0.label.hasSuffix(" cusp") }.count, 12)
    }

    private func input(_ instant: String, longitude: Double) -> OracleInput {
        var input = sample()
        input.profile.birthDate = ISO8601DateFormatter().date(from: instant)!
        input.profile.birthLatitude = 30
        input.profile.birthLongitude = longitude
        return input
    }

    private func ziwei(_ input: OracleInput) async throws -> OracleResult {
        try await AppLanguage.$override.withValue(.simplifiedChinese) {
            try await ZiweiPlugin().calculate(input)
        }
    }
    private func value(_ result: OracleResult, _ label: String) -> String? {
        result.rows.first { $0.label == label }?.value
    }
    private func chartDate(_ result: OracleResult) -> [Int] {
        value(result, "本命排盘公历")?.split(separator: "-").compactMap { Int($0) } ?? []
    }
    private func palaces(_ result: OracleResult) -> [OracleRow] {
        result.rows.filter { $0.label.contains("（") }
    }
}
