import XCTest
@testable import BlindOracle

final class NativePluginTests: XCTestCase {
    private func input(casting: String = "2026-06-05T16:52:00+08:00") -> OracleInput {
        var profile = OracleProfile()
        profile.displayName = "测试资料"
        profile.familyName = "王"
        profile.givenName = "小明"
        profile.sex = "男"
        profile.birthDate = ISO8601DateFormatter().date(from: "1971-01-27T00:00:00+08:00")!
        profile.birthTimeZoneID = "Asia/Shanghai"
        profile.currentTimeZoneID = "Asia/Shanghai"
        return OracleInput(question: "下一阶段如何安排？", profile: profile,
                           castingDate: ISO8601DateFormatter().date(from: casting)!, seed: 42)
    }
    private func value(_ result: OracleResult, _ label: String) -> String? { result.rows.first { $0.label == label }?.value }

    func testEightCharUpstreamGoldenFixture() async throws {
        var request = input()
        request.profile.birthDate = ISO8601DateFormatter().date(from: "2005-12-23T08:37:00+08:00")!
        let result = try await BaziPlugin().calculate(request)
        XCTAssertTrue(result.headline.contains("乙酉 戊子 辛巳 壬辰"))
    }
    func testUnknownBirthTimeDoesNotInventHourOrFortune() async throws {
        var request = input()
        request.profile.birthTimeKnown = false
        let result = try await BaziPlugin().calculate(request)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(value(result, "时柱"), "未知，未计算")
        XCTAssertFalse(result.rows.contains { $0.label.hasPrefix("大运") })
    }
    func testMeihuaThreeNumbersAndChangedLine() async throws {
        var request = input()
        request.numbers = [8, 8, 6]
        let result = try await MeihuaPlugin().calculate(request)
        XCTAssertEqual(value(result, "本卦"), "坤为地")
        XCTAssertEqual(value(result, "变卦"), "山地剥")
        XCTAssertEqual(value(result, "动爻"), "第6爻（自下而上）")
    }
    func testAll64HexagramsMapToPalaceAndValidShi() {
        for bits in 0..<64 {
            let palace = LiuyaoPlugin.palace(bits)
            XCTAssertTrue((0..<8).contains(palace.trigram))
            XCTAssertTrue((1...6).contains(palace.shi))
            XCTAssertFalse(NativeHexagrams.name(bits).isEmpty)
        }
        XCTAssertEqual(LiuyaoPlugin.palace(63).trigram, 7)
        XCTAssertEqual(LiuyaoPlugin.palace(63).shi, 6)
    }
    func testManualLiuyaoNajiaAndShiYing() async throws {
        var request = input()
        request.manualLines = [7,7,7,7,7,7]
        let result = try await LiuyaoPlugin().calculate(request)
        XCTAssertEqual(value(result, "本卦"), "乾为天")
        XCTAssertEqual(value(result, "世应"), "世爻6 / 应爻3")
        XCTAssertTrue(value(result, "初爻")?.contains("甲子水 · 子孙") == true)
        XCTAssertTrue(value(result, "上爻")?.contains("壬戌土 · 父母") == true)
    }
    func testInvalidManualLiuyaoRejected() async throws {
        var request = input()
        request.manualLines = [1,2,3]
        let result = try await LiuyaoPlugin().calculate(request)
        XCTAssertEqual(result.status, .unavailable)
    }
    func testSeededCastingIsReproducible() async throws {
        let request = input()
        let a = try await LiuyaoPlugin().calculate(request)
        let b = try await LiuyaoPlugin().calculate(request)
        XCTAssertEqual(value(a, "爻值（初→上）"), value(b, "爻值（初→上）"))
    }
    func testXiaoliurenNewYearMidnight() async throws {
        let result = try await XiaoliurenPlugin().calculate(input(casting: "2024-02-10T00:00:00+08:00"))
        XCTAssertEqual(value(result, "月宫"), "大安")
        XCTAssertEqual(value(result, "日宫"), "大安")
        XCTAssertEqual(value(result, "时宫"), "大安")
    }
    func testQimenExactSolarTermChartBeforeBoundary() async throws {
        let result = try await QimenPlugin().calculate(input())
        XCTAssertEqual(value(result, "局数"), "阳遁5局")
        XCTAssertEqual(value(result, "节气 / 三元"), "小满 · 上元")
        XCTAssertTrue(value(result, "值符")?.contains("天柱") == true)
        XCTAssertTrue(value(result, "值使")?.contains("惊门 → 7宫") == true)
        XCTAssertTrue(value(result, "兑7宫")?.contains("地庚 / 天庚 · 天柱 · 惊门 · 值符") == true)
    }
    func testQimenSolarTermChangesAtActualTime() async throws {
        // HKO Almanac 2026: Corn on Ear, June 5 23:48 (UTC+8).
        // Upstream qfdk's whole-day(true) lookup changes at 00:00; we intentionally
        // use the actual term time, avoiding a nearly-24-hour premature change.
        let before = try await QimenPlugin().calculate(input(casting: "2026-06-05T23:47:00+08:00"))
        let after = try await QimenPlugin().calculate(input(casting: "2026-06-05T23:49:00+08:00"))
        XCTAssertEqual(value(before, "节气 / 三元"), "小满 · 上元")
        XCTAssertEqual(value(after, "节气 / 三元"), "芒种 · 上元")
        XCTAssertEqual(value(after, "局数"), "阳遁6局")
    }
    func testChengguBundledTable() async throws {
        let result = try await ChengguPlugin().calculate(input())
        XCTAssertEqual(value(result, "总骨重"), "4两4钱")
        XCTAssertNotNil(value(result, "历史原诗（非现实判定）"))
    }
    func testKangxiNameCountsAndSource() async throws {
        let result = try await XingmingPlugin().calculate(input())
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(value(result, "总格"), "15 · 土")
        XCTAssertEqual(value(result, "逐字笔画"), "王 4 / 小 3 / 明 8")
        XCTAssertTrue(value(result, "笔画口径")?.contains("康熙") == true)
    }
    func testUnsupportedNameCharacterDoesNotGuess() async throws {
        var request = input()
        request.profile.givenName = "🌙"
        let result = try await XingmingPlugin().calculate(request)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertTrue(result.limitations.joined().contains("缺少"))
    }
    func testExplicitUnknownSurnameDoesNotReuseSavedName() async throws {
        var request = input()
        request.profile.unknownFields.insert(.surname)
        let result = try await XingmingPlugin().calculate(request)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertTrue(result.limitations.joined().contains("旧姓名"))
    }
    func testExplicitUnknownGenderDoesNotReuseSavedGenderForFortune() async throws {
        var request = input()
        request.profile.unknownFields.insert(.gender)
        let result = try await BaziPlugin().calculate(request)
        XCTAssertFalse(result.rows.contains { $0.label.hasPrefix("大运") })
    }
    func testUnknownBirthTimezoneDoesNotReuseSavedTimezone() async throws {
        var request = input()
        request.profile.unknownFields.insert(.birthTimeZone)
        let bazi = try await BaziPlugin().calculate(request)
        let chenggu = try await ChengguPlugin().calculate(request)
        XCTAssertEqual(bazi.status, .unavailable)
        XCTAssertTrue(bazi.rows.isEmpty)
        XCTAssertEqual(chenggu.status, .unavailable)
        XCTAssertTrue(chenggu.rows.isEmpty)
    }
    func testUnknownTimeOnSolarTermDateShowsAlternatives() async throws {
        var request = input()
        request.profile.birthDate = ISO8601DateFormatter().date(from: "2026-02-04T12:00:00+08:00")!
        request.profile.birthTimeKnown = false
        let result = try await BaziPlugin().calculate(request)
        XCTAssertEqual(result.status, .partial)
        XCTAssertTrue(value(result, "月柱")?.contains("交节前") == true)
        XCTAssertEqual(value(result, "时柱"), "未知，未计算")
        XCTAssertFalse(result.rows.contains { $0.label.hasPrefix("大运") })
    }
    func testAllDateBasedPluginsRejectOutOfRange() async throws {
        var request = input()
        let outside = ISO8601DateFormatter().date(from: "1800-01-01T00:00:00+08:00")!
        request.profile.birthDate = outside
        request.castingDate = outside
        for plugin in NativePlugins.all where plugin.descriptor.method != .xingming {
            let result = try await plugin.calculate(request)
            XCTAssertEqual(result.status, .unavailable, "\(plugin.descriptor.method)")
        }
    }
    func testManualLiuyaoMovingLinesFlipOnlyThoseLines() async throws {
        var request = input()
        request.manualLines = [9,7,7,7,7,6]
        let result = try await LiuyaoPlugin().calculate(request)
        // Original bottom-to-top: 111110 (泽天夬); flip initial and upper lines -> 011111 (天风姤).
        XCTAssertEqual(value(result, "本卦"), "泽天夬")
        XCTAssertEqual(value(result, "变卦"), "天风姤")
    }
    func testClassicalArchiveHas64JudgmentsAnd384Lines() {
        XCTAssertEqual(NativeHexagrams.classicalTexts.count, 64)
        XCTAssertEqual(NativeHexagrams.classicalTexts.values.reduce(0) { $0 + $1.lines.count }, 384)
        XCTAssertTrue(NativeHexagrams.classicalTexts.values.allSatisfy { !$0.judgment.isEmpty && $0.lines.allSatisfy { !$0.isEmpty } })
    }
    func testLiuyaoIncludesActualClassicalTexts() async throws {
        var request = input()
        request.manualLines = [9,7,7,7,7,7]
        let result = try await LiuyaoPlugin().calculate(request)
        XCTAssertTrue(value(result, "本卦卦辞")?.contains("元，亨，利，貞") == true)
        XCTAssertTrue(value(result, "动爻第1爻爻辞")?.contains("潛龍，勿用") == true)
        XCTAssertTrue(value(result, "变卦卦辞")?.contains("女壯") == true)
    }
    func testAllMovingQianIncludesSixLinesAndUseNine() async throws {
        var request = input()
        request.manualLines = [9,9,9,9,9,9]
        let result = try await LiuyaoPlugin().calculate(request)
        XCTAssertEqual(result.rows.filter { $0.label.hasPrefix("动爻第") }.count, 6)
        XCTAssertTrue(value(result, "乾坤全变特别用辞")?.contains("見群龍無首") == true)
        XCTAssertEqual(value(result, "变卦"), "坤为地")
    }
    func testMeihuaIncludesClassicalTextForMovingLine() async throws {
        var request = input()
        request.numbers = [1,1,1]
        let result = try await MeihuaPlugin().calculate(request)
        XCTAssertTrue(value(result, "动爻第1爻爻辞")?.contains("潛龍，勿用") == true)
        XCTAssertTrue(value(result, "变卦卦辞")?.contains("姤卦") == true)
    }
    func testYarrowDistributionMatchesClassicalRemainderClasses() {
        var rng = OracleSeededRandom(seed: 0x594152524F57)
        var counts = [6:0, 7:0, 8:0, 9:0]
        let size = 160_000
        for _ in 0..<size { counts[LiuyaoPlugin.yarrowLine(using: &rng), default: 0] += 1 }
        for (value, expected) in [6:1.0/16, 7:5.0/16, 8:7.0/16, 9:3.0/16] {
            XCTAssertEqual(Double(counts[value] ?? 0) / Double(size), expected, accuracy: 0.008)
        }
    }
    func testYarrowStyleReproducibleAndTraceIsValid() async throws {
        var request = input()
        request.castingStyle = "yarrow"
        let a = try await LiuyaoPlugin().calculate(request)
        let b = try await LiuyaoPlugin().calculate(request)
        XCTAssertEqual(value(a, "爻值（初→上）"), value(b, "爻值（初→上）"))
        XCTAssertTrue(value(a, "起卦方式")?.contains("大衍") == true)
        XCTAssertEqual(value(a, "蓍草三变归奇过程")?.components(separatedBy: "\n").count, 6)
    }
    func testKangxiSpecificGlyphsAndCompatibilityCharacters() {
        XCTAssertEqual(XingmingPlugin.kangxiCount("清"), 12)
        XCTAssertEqual(XingmingPlugin.kangxiCount("華"), 14)
        XCTAssertEqual(XingmingPlugin.kangxiCount("陳"), 16)
        XCTAssertEqual(XingmingPlugin.kangxiCount("張"), 11)
        XCTAssertEqual(XingmingPlugin.kangxiCount("朗"), 11)
        XCTAssertEqual(XingmingPlugin.kangxiCount("朗"), 10)
        XCTAssertEqual(XingmingPlugin.kangxiCount("廊"), 12)
        XCTAssertEqual(XingmingPlugin.kangxiCount("廊"), 13)
    }
    func testSimplifiedNameProducesUnconfirmedTraditionalCandidate() async throws {
        var request = input()
        request.profile.familyName = "张"
        request.profile.givenName = "华"
        let result = try await XingmingPlugin().calculate(request)
        XCTAssertEqual(result.status, .partial)
        XCTAssertTrue(value(result, "计算字形")?.contains("張 · 華") == true)
        XCTAssertTrue(value(result, "逐字笔画")?.contains("張 11 / 華 14") == true)
        XCTAssertTrue(value(result, "输入字形原表笔画")?.contains("张 7") == true)
    }
}
