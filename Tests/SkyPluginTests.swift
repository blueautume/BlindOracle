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
        let first = try await ZiweiPlugin().calculate(sample())
        let second = try await ZiweiPlugin().calculate(sample())
        XCTAssertEqual(first.status, .complete)
        XCTAssertEqual(first.rows, second.rows)
        XCTAssertTrue(first.headline.contains("土五局"))
        XCTAssertTrue(first.headline.contains("贪狼"))
        // Shanghai observed DST (UTC+9) on this birth date: 04:00Z is 13:00, not 12:00.
        XCTAssertTrue(first.rows.contains { $0.label == "时区与时辰" && $0.value.contains("未时") })
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
        XCTAssertEqual(english.0.rows.first { $0.label == "Time zone and hour" }?.value, "Asia/Shanghai · Wei hour")
        XCTAssertTrue(english.1.rows.first { $0.label == "Natal Sun" }?.value.hasPrefix("Taurus ") == true)
        XCTAssertEqual(english.1.rows.filter { $0.label.hasSuffix(" cusp") }.count, 12)
    }
}
