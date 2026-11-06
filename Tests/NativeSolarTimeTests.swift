import XCTest
@testable import BlindOracle

final class NativeSolarTimeTests: XCTestCase {
    private func input(_ stamp: String = "2026-06-05T09:30:00+08:00", longitude: Double = 120) -> OracleInput {
        var profile = OracleProfile()
        profile.birthDate = ISO8601DateFormatter().date(from: stamp)!
        profile.birthTimeKnown = true
        profile.birthTimeZoneID = "Asia/Shanghai"
        profile.birthLatitude = 30
        profile.birthLongitude = longitude
        profile.currentTimeZoneID = "Asia/Shanghai"
        profile.currentLatitude = 30
        profile.currentLongitude = longitude
        return OracleInput(question: "时间口径测试", profile: profile,
                           castingDate: profile.birthDate!, seed: 42)
    }
    private func result(_ plugin: any OraclePlugin, _ input: OracleInput) async throws -> OracleResult {
        try await AppLanguage.$override.withValue(.simplifiedChinese) {
            try await plugin.calculate(input)
        }
    }
    private func value(_ result: OracleResult, _ label: String) -> String? {
        result.rows.first { $0.label == label }?.value
    }

    func testAllFourVersionTheirSuccessAndUnavailableResults() async throws {
        let plugins: [any OraclePlugin] = [QimenPlugin(), ChengguPlugin(), MeihuaPlugin(), XiaoliurenPlugin()]
        for plugin in plugins {
            XCTAssertEqual(plugin.descriptor.version, "2.0.0")
            let valid = try await result(plugin, input())
            XCTAssertEqual(valid.version, plugin.descriptor.version)
            XCTAssertNotEqual(valid.status, .unavailable)
            let missing = OracleInput(question: "", profile: OracleProfile())
            let unavailable = try await result(plugin, missing)
            XCTAssertEqual(unavailable.status, .unavailable)
            XCTAssertEqual(unavailable.version, plugin.descriptor.version)
            XCTAssertTrue(unavailable.rows.isEmpty)
        }
    }

    func testCastingNeverBorrowsBirthCoordinatesAndBirthNeverBorrowsCastingCoordinates() async throws {
        var request = input()
        request.profile.currentLatitude = nil
        request.profile.currentLongitude = nil
        let castingPlugins: [any OraclePlugin] = [QimenPlugin(), MeihuaPlugin(), XiaoliurenPlugin()]
        for plugin in castingPlugins {
            let missing = try await result(plugin, request)
            XCTAssertEqual(missing.status, .unavailable)
        }
        request = input()
        request.profile.birthLatitude = nil
        request.profile.birthLongitude = nil
        let missingBirthplace = try await result(ChengguPlugin(), request)
        XCTAssertEqual(missingBirthplace.status, .unavailable)
    }

    func testInvalidOrWithdrawnCoordinatesDoNotFallBackToMeridian() async throws {
        let invalidLongitudes: [Double] = [.nan, .infinity, 181]
        for longitude in invalidLongitudes {
            var request = input()
            request.profile.currentLongitude = longitude
            request.profile.birthLongitude = longitude
            let plugins: [any OraclePlugin] = [QimenPlugin(), MeihuaPlugin(), XiaoliurenPlugin(), ChengguPlugin()]
            for plugin in plugins {
                let invalid = try await result(plugin, request)
                XCTAssertEqual(invalid.status, .unavailable)
            }
        }
        var casting = input()
        casting.profile.declaredUnknownFields = [.currentLocation]
        let withdrawnCasting = try await result(QimenPlugin(), casting)
        XCTAssertEqual(withdrawnCasting.status, .unavailable)
        var birth = input()
        birth.profile.declaredUnknownFields = [.birthCoordinates]
        let withdrawnBirth = try await result(ChengguPlugin(), birth)
        XCTAssertEqual(withdrawnBirth.status, .unavailable)
    }

    func testQimenUsesPhysicalSolarTermAtItsSecondBoundaryAcrossLongitudes() async throws {
        // The reference term is a physical UTC+8 ephemeris entry. Locations
        // deliberately put the solar clock on opposite sides of midnight.
        let term = Solar(year: 2026, month: 6, day: 6, hour: 12).lunar.prevJieQi.solar
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 28_800)!
        let boundary = try XCTUnwrap(calendar.date(from: DateComponents(
            year: term.year, month: term.month, day: term.day,
            hour: term.hour, minute: term.minute, second: term.second)))
        for longitude in [80.0, 140.0] {
            var request = input(longitude: longitude)
            request.castingDate = boundary.addingTimeInterval(-1)
            let before = try await result(QimenPlugin(), request)
            request.castingDate = boundary.addingTimeInterval(1)
            let after = try await result(QimenPlugin(), request)
            XCTAssertEqual(value(before, "节气 / 三元")?.components(separatedBy: " · ").first, "小满")
            XCTAssertEqual(value(after, "节气 / 三元")?.components(separatedBy: " · ").first, "芒种")
            XCTAssertNotEqual(value(before, "上次交节"), value(after, "上次交节"))
            XCTAssertTrue(value(after, "局数")?.hasPrefix("阳遁") == true)
        }
    }

    func testQimenKeepsPhysicalYearMonthWhileApparentDayChanges() async throws {
        let west = try await result(QimenPlugin(), input("2026-06-05T23:30:00+08:00", longitude: 80))
        let east = try await result(QimenPlugin(), input("2026-06-05T23:30:00+08:00", longitude: 140))
        let westPillars = try XCTUnwrap(value(west, "四柱")).split(separator: " ")
        let eastPillars = try XCTUnwrap(value(east, "四柱")).split(separator: " ")
        XCTAssertEqual(Array(westPillars.prefix(2)), Array(eastPillars.prefix(2)))
        XCTAssertNotEqual(westPillars[2], eastPillars[2])
        XCTAssertEqual(value(west, "上次交节"), value(east, "上次交节"))
        XCTAssertTrue(value(west, "子时规则")?.contains("子初换干") == true)
        XCTAssertNotNil(value(west, "均时差"))
        XCTAssertNotNil(value(west, "原始钟表时间"))
    }

    func testMeihuaThreeNumbersWorkWithoutAnyUsableTimeOrPlace() async throws {
        var request = input()
        request.numbers = [8, 8, 6]
        request.castingDate = Date(timeIntervalSince1970: .nan)
        request.profile.currentTimeZoneID = "Invalid/Zone"
        request.profile.currentLatitude = nil
        request.profile.currentLongitude = nil
        let cast = try await result(MeihuaPlugin(), request)
        XCTAssertNotEqual(cast.status, .unavailable)
        XCTAssertEqual(value(cast, "本卦"), "坤为地")
        XCTAssertEqual(value(cast, "变卦"), "山地剥")
        XCTAssertEqual(value(cast, "动爻"), "第6爻（自下而上）")
        XCTAssertNil(value(cast, "真太阳时"))
        XCTAssertNil(value(cast, "原始钟表时间"))
    }

    func testWithdrawnNumbersDoNotReuseThreeNumberMode() async throws {
        var request = input()
        request.numbers = [8, 8, 6]
        request.profile.declaredUnknownFields = [.numbers, .currentLocation]
        let cast = try await result(MeihuaPlugin(), request)
        XCTAssertEqual(cast.status, .unavailable)
    }

    func testMeihuaTwoNumbersUseSolarHourButKeepOriginalHexagram() async throws {
        var west = input(longitude: 90)
        west.numbers = [1, 1]
        var east = input(longitude: 120)
        east.numbers = [1, 1]
        let a = try await result(MeihuaPlugin(), west)
        let b = try await result(MeihuaPlugin(), east)
        XCTAssertEqual(value(a, "本卦"), "乾为天")
        XCTAssertEqual(value(a, "本卦"), value(b, "本卦"))
        XCTAssertEqual(value(a, "动爻"), "第1爻（自下而上）")
        XCTAssertEqual(value(b, "动爻"), "第2爻（自下而上）")
        XCTAssertNotEqual(value(a, "变卦"), value(b, "变卦"))
    }

    func testMeihuaIncludesEquationOfTimeEvenAtStandardMeridian() async throws {
        var request = input("2026-11-03T10:50:00+08:00")
        request.numbers = [1, 1]
        let cast = try await result(MeihuaPlugin(), request)
        // Positive November EOT crosses11:00 at longitude120, into Wu.
        XCTAssertEqual(value(cast, "动爻"), "第3爻（自下而上）")
        XCTAssertNotNil(value(cast, "均时差"))
    }

    func testTimeMeihuaAndXiaoliurenCrossApparentMidnightAtLunarNewYear() async throws {
        let early = input("2024-02-10T00:00:00+08:00")
        let late = input("2024-02-10T00:30:00+08:00")
        let plumBefore = try await result(MeihuaPlugin(), early)
        let plumAfter = try await result(MeihuaPlugin(), late)
        XCTAssertTrue(value(plumBefore, "起数过程")?.contains("农历月12＋日30") == true)
        XCTAssertTrue(value(plumAfter, "起数过程")?.contains("农历月1＋日1") == true)
        XCTAssertNotEqual(value(plumBefore, "本卦"), value(plumAfter, "本卦"))
        let before = try await result(XiaoliurenPlugin(), early)
        let after = try await result(XiaoliurenPlugin(), late)
        XCTAssertEqual(value(before, "月宫"), "空亡")
        XCTAssertEqual(value(before, "日宫"), "小吉")
        XCTAssertEqual(value(before, "时宫"), "小吉")
        XCTAssertEqual(value(after, "月宫"), "大安")
        XCTAssertEqual(value(after, "日宫"), "大安")
        XCTAssertEqual(value(after, "时宫"), "大安")
    }

    func testXiaoliurenZiHourDoesNotAdvanceLunarDayAt23() async throws {
        let night = try await result(XiaoliurenPlugin(), input("2024-02-09T23:30:00+08:00"))
        let afterCivilMidnight = try await result(XiaoliurenPlugin(), input("2024-02-10T00:00:00+08:00"))
        for label in ["月宫", "日宫", "时宫"] {
            XCTAssertEqual(value(night, label), value(afterCivilMidnight, label))
        }
    }

    func testChengguBirthSolarMidnightUsesPreviousLunarDate() async throws {
        let before = try await result(ChengguPlugin(), input("1971-01-27T00:00:00+08:00"))
        let after = try await result(ChengguPlugin(), input("1971-01-27T00:30:00+08:00"))
        // 1946 table: GengXu9 + month12(5) + day30(6) + Zi16 =36.
        XCTAssertEqual(value(before, "总骨重"), "3两6钱")
        XCTAssertTrue(value(before, "农历日期")?.contains("腊月三十") == true)
        // XinHai17 + month1(6) + day1(5) + Zi16 =44.
        XCTAssertEqual(value(after, "总骨重"), "4两4钱")
    }

    func testChengguUnknownClockEnumeratesCoupledDatesInsteadOfChoosingNoon() async throws {
        var morning = input("1971-01-26T00:05:00+08:00")
        morning.profile.birthTimeKnown = false
        var noon = morning
        noon.profile.birthDate = ISO8601DateFormatter().date(from: "1971-01-26T12:00:00+08:00")!
        let a = try await result(ChengguPlugin(), morning)
        let b = try await result(ChengguPlugin(), noon)
        XCTAssertEqual(a.status, .partial)
        // Jan25 lunar12/29 + Zi gives46; Jan26 lunar12/30 has26...36.
        XCTAssertEqual(value(a, "可能总重"), "2两6钱 至 4两6钱")
        XCTAssertEqual(value(a, "可能总重"), value(b, "可能总重"))
        XCTAssertTrue(value(a, "农历候选日期")?.contains("廿九") == true)
        XCTAssertTrue(value(a, "农历候选日期")?.contains("三十") == true)
        XCTAssertNil(value(a, "真太阳时"))
        XCTAssertNil(value(a, "原始钟表时间"))
        XCTAssertFalse(a.rows.contains { $0.label.contains("原诗") })
    }

    func testChengguKeepsLunarYearAndRegularMonthWeightInLeapMonth() async throws {
        let afterSpring = try await result(ChengguPlugin(), input("2026-02-05T12:00:00+08:00"))
        XCTAssertTrue(value(afterSpring, "农历日期")?.hasPrefix("乙巳年") == true)
        let ordinary = try await result(ChengguPlugin(), input("2023-02-20T12:00:00+08:00"))
        let leap = try await result(ChengguPlugin(), input("2023-03-22T12:00:00+08:00"))
        XCTAssertEqual(value(ordinary, "月骨重"), value(leap, "月骨重"))
        XCTAssertTrue(value(leap, "农历日期")?.contains("闰二") == true)
    }
}
