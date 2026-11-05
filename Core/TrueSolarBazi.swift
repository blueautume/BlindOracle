import Foundation

/// UTC calendar components of the returned Date are the apparent solar clock,
/// never the physical instant that must be compared with a solar term.
enum TrueSolarTime {
    /// NOAA/Meeus Julian-century formula: apparent minus mean solar time.
    /// https://gml.noaa.gov/grad/solcalc/main.js — calcEquationOfTime
    static func equationOfTimeMinutes(at date: Date) -> Double {
        let jd = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545) / 36_525
        let radians = Double.pi / 180
        let longitude = (280.46646 + t * (36_000.76983 + t * 0.0003032))
            .truncatingRemainder(dividingBy: 360) * radians
        let anomaly = (357.52911 + t * (35_999.05029 - 0.0001537 * t)) * radians
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let seconds = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))
        let meanObliquity = 23 + (26 + seconds / 60) / 60
        let omega = (125.04 - 1934.136 * t) * radians
        let obliquity = (meanObliquity + 0.00256 * cos(omega)) * radians
        let y = pow(tan(obliquity / 2), 2)
        let equation = y * sin(2 * longitude) - 2 * eccentricity * sin(anomaly)
            + 4 * eccentricity * y * sin(anomaly) * cos(2 * longitude)
            - 0.5 * y * y * sin(4 * longitude)
            - 1.25 * eccentricity * eccentricity * sin(2 * anomaly)
        return 4 * equation / radians
    }

    /// East-positive longitude, 4 minutes/degree. DST is already in the instant.
    static func apparentDate(at instant: Date, longitude: Double) -> Date {
        instant.addingTimeInterval(longitude * 240 + equationOfTimeMinutes(at: instant) * 60)
    }
}

enum BaziBirthLocation {
    private static let districtsByID: [String: ChinaDistrict] = {
        let catalog = ChinaDistrictCatalog.shared
        var pending = catalog.provinces
        var result: [String: ChinaDistrict] = [:]
        while let district = pending.popLast() {
            result[district.id] = district
            pending.append(contentsOf: catalog.children(of: district))
        }
        return result
    }()

    /// Only a specifically selected district can restore a missing legacy pair.
    /// Withdrawals, invalid/partial points and current location never supply it.
    static func coordinates(for profile: OracleProfile) -> (latitude: Double, longitude: Double)? {
        let withdrawn = profile.declaredUnknownFields ?? profile.unknownFields
        guard !withdrawn.contains(.birthPlace), !withdrawn.contains(.birthCoordinates) else { return nil }
        if let latitude = profile.birthLatitude, let longitude = profile.birthLongitude {
            guard !profile.unknownFields.contains(.birthCoordinates), !profile.unknownFields.contains(.birthPlace),
                  latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            return (latitude, longitude)
        }
        guard profile.birthLatitude == nil, profile.birthLongitude == nil,
              let code = profile.birthDistrictCode, let district = districtsByID[code],
              let latitude = district.latitude, let longitude = district.longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return (latitude, longitude)
    }
}

struct BaziCalculation: Sendable {
    let result: OracleResult
    /// Original Chinese four pillars, independent of the interface language.
    let rawPillars: String?
    let previewPlaceholder: String
}

/// Previews and formal readings share one uninterrupted actor calculation.
/// LunarSwift reference objects never escape to the UI or another actor.
actor TrueSolarBaziEngine {
    static let shared = TrueSolarBaziEngine()
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let termZone = TimeZone(secondsFromGMT: 28_800)!

    func calculate(profile: OracleProfile) async -> BaziCalculation {
        guard !profile.unknownFields.contains(.birthDate),
              profile.declaredUnknownFields?.contains(.birthDate) != true,
              let birth = profile.birthDate, birth.timeIntervalSince1970.isFinite else {
            return unavailable(L10n.text("请先填写出生日期。", "Enter a birth date first."))
        }
        guard !profile.unknownFields.contains(.birthTimeZone),
              profile.declaredUnknownFields?.contains(.birthTimeZone) != true,
              let zone = TimeZone(identifier: profile.birthTimeZoneID) else {
            return unavailable(L10n.text("出生时区不确定，暂无法计算真太阳时八字。", "The birth time zone is uncertain. The apparent-solar chart cannot be calculated."))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard (1900...2100).contains(calendar.component(.year, from: birth)) else {
            return unavailable(L10n.text("出生日期须在1900–2100年之间。", "The birth date must be between 1900 and 2100."))
        }
        guard let point = BaziBirthLocation.coordinates(for: profile) else {
            return unavailable(L10n.text("请先选择出生地；真太阳时八字需要已确认的出生地经纬度。", "Choose a birthplace first. Confirmed birth coordinates are needed for the apparent-solar chart."))
        }
        let hasTime = profile.birthTimeKnown && !profile.unknownFields.contains(.birthTime)
            && profile.declaredUnknownFields?.contains(.birthTime) != true
        if !hasTime {
            return uncertainTime(profile: profile, birth: birth, longitude: point.longitude, calendar: calendar)
        }
        return complete(profile: profile, birth: birth, longitude: point.longitude)
    }

    private func complete(profile: OracleProfile, birth: Date, longitude: Double) -> BaziCalculation {
        // Solar terms are tabulated at fixed UTC+8, not historical Shanghai DST.
        let physical = solar(birth, zone: termZone).lunar
        let termChart = physical.eightChar
        termChart.sect = 2
        let apparent = TrueSolarTime.apparentDate(at: birth, longitude: longitude)
        let apparentSolar = solar(apparent, zone: utc)
        let solarChart = apparentSolar.lunar.eightChar
        solarChart.sect = 2
        let year = termChart.year, month = termChart.month
        let day = solarChart.day, hour = solarChart.time
        let pillars = [year, month, day, hour]
        let dayMaster = String(day.prefix(1))
        let equation = TrueSolarTime.equationOfTimeMinutes(at: birth)
        let civilOffset = Double(TimeZone(identifier: profile.birthTimeZoneID)!.secondsFromGMT(for: birth)) / 60
        let longitudeCorrection = longitude * 4 - civilOffset
        var rows: [OracleRow] = [
            .init(L10n.text("排盘口径", "Chart rules"), rules),
            .init(L10n.text("公历", "Gregorian date"), solar(birth, zone: TimeZone(identifier: profile.birthTimeZoneID)!).ymdhms + " · " + profile.birthTimeZoneID),
            .init(L10n.text("真太阳时", "Apparent solar time"), apparentSolar.ymdhms),
            .init(L10n.text("出生经度", "Birth longitude"), String(format: "%.6f°", longitude)),
            .init(L10n.text("经度及时制校正", "Longitude and civil-offset correction"), String(format: "%+.3f min", longitudeCorrection)),
            .init(L10n.text("均时差", "Equation of time"), String(format: "%+.3f min", equation)),
            .init(L10n.text("农历", "Lunar date"), NativeCalendar.lunarDate(physical)),
            .init(L10n.text("年柱", "Year pillar"), decoratedPillar(year)),
            .init(L10n.text("月柱", "Month pillar"), decoratedPillar(month)),
            .init(L10n.text("日柱", "Day pillar"), decoratedPillar(day)),
            .init(L10n.text("时柱", "Hour pillar"), decoratedPillar(hour)),
            .init(L10n.text("日主", "Day Master"), NativeCalendar.stemBranch(dayMaster)),
            .init(L10n.text("天干十神", "Ten Gods of the heavenly stems"),
                  L10n.text("年：\(god(dayMaster, year)) / 月：\(god(dayMaster, month)) / 时：\(god(dayMaster, hour))",
                            "Year: \(englishGod(god(dayMaster, year))) / Month: \(englishGod(god(dayMaster, month))) / Hour: \(englishGod(god(dayMaster, hour)))")),
            .init(L10n.text("地支藏干", "Hidden stems of the earthly branches"),
                  zip([L10n.text("年", "Year"), L10n.text("月", "Month"), L10n.text("日", "Day"), L10n.text("时", "Hour")], pillars)
                    .map { label, value in "\(label)：\(NativeCalendar.stemBranch(hiddenStems(value)))" }.joined(separator: " / ")),
            .init(L10n.text("日柱旬空", "Day pillar void branches"), NativeCalendar.stemBranch(LunarUtil.getXunKong(ganZhi: day)))
        ]
        var counts = Dictionary(uniqueKeysWithValues: NativeCalendar.elements.map { ($0, 0) })
        for element in pillars.map(elements).joined() { counts[String(element), default: 0] += 1 }
        rows.append(.init(L10n.text("五行表层计数", "Unweighted Five Element counts"),
                          NativeCalendar.elements.enumerated().map { "\(NativeCalendar.element($0.offset)) \(counts[$0.element] ?? 0)" }.joined(separator: " · ")))
        var limitations = baseLimitations
        let hasGender = !profile.unknownFields.contains(.gender)
            && profile.declaredUnknownFields?.contains(.gender) != true && ["男", "女"].contains(profile.sex)
        if hasGender {
            // Preserve the actual birth-to-Jie interval and physical month pillar.
            let yun = termChart.getYun(gender: profile.sex == "男" ? 1 : 0, sect: 2)
            rows.append(.init(L10n.text("起运", "Luck cycle start"),
                              L10n.text("\(yun.startYear)年\(yun.startMonth)月\(yun.startDay)日后 · \(yun.forward ? "顺排" : "逆排")",
                                        "In \(yun.startYear) years, \(yun.startMonth) months, \(yun.startDay) days · \(yun.forward ? "forward" : "backward")")))
            rows.append(.init(L10n.text("交运公历", "Gregorian cycle start"), yun.startSolar.ymdhms + " · UTC+08:00"))
            for item in yun.getDaYun(n: 9).dropFirst() {
                rows.append(.init(L10n.text("大运 \(item.startYear)–\(item.endYear)", "Luck cycle \(item.startYear)–\(item.endYear)"),
                                  L10n.text("\(item.ganZhi) · 虚岁\(item.startAge)–\(item.endAge)", "\(NativeCalendar.stemBranch(item.ganZhi)) · East Asian age \(item.startAge)–\(item.endAge)")))
            }
        } else {
            limitations.append(L10n.text("排盘性别未确定，本次未输出起运与大运。", "Chart gender is unknown, so luck cycles and their start are unavailable."))
        }
        let result = OracleResult(method: .bazi, version: "2.0.0", status: hasGender ? .complete : .partial,
                                  headline: pillars.map { NativeCalendar.stemBranch($0) }.joined(separator: " "), rows: rows,
                                  evidence: [.init(id: "bazi-day-master", statement: L10n.text("真太阳时日主\(dayMaster)，实际交节月支\(month.suffix(1))；未把缺少某行等同于需要补某行。", "The apparent-solar Day Master is \(NativeCalendar.stemBranch(dayMaster)); the month branch follows the actual solar-term instant. A missing element alone does not imply a need to add it."), topic: "personal")],
                                  limitations: limitations, provenance: provenance)
        return BaziCalculation(result: result, rawPillars: pillars.joined(separator: " "), previewPlaceholder: "")
    }

    private func uncertainTime(profile: OracleProfile, birth: Date, longitude: Double, calendar: Calendar) -> BaziCalculation {
        guard let interval = calendar.dateInterval(of: .day, for: birth) else {
            return unavailable(L10n.text("无法确认出生日期在当地时区的范围。", "The birth date's range in its local time zone cannot be confirmed."))
        }
        let first = interval.start, last = interval.end.addingTimeInterval(-1)
        let early = solar(first, zone: termZone).lunar.eightChar
        let late = solar(last, zone: termZone).lunar.eightChar
        early.sect = 2; late.sect = 2
        let firstApparent = TrueSolarTime.apparentDate(at: first, longitude: longitude)
        let lastApparent = TrueSolarTime.apparentDate(at: last, longitude: longitude)
        var solarCalendar = Calendar(identifier: .gregorian)
        solarCalendar.timeZone = utc
        var cursor = solarCalendar.startOfDay(for: firstApparent)
        let lastDay = solarCalendar.startOfDay(for: lastApparent)
        var days: [String] = []
        while cursor <= lastDay {
            let chart = solar(cursor, zone: utc).lunar.eightChar
            chart.sect = 2
            if !days.contains(chart.day) { days.append(chart.day) }
            guard let next = solarCalendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let rows: [OracleRow] = [
            .init(L10n.text("排盘口径", "Chart rules"), rules),
            .init(L10n.text("公历日期", "Gregorian date"), solar(birth, zone: calendar.timeZone).ymd + " · " + profile.birthTimeZoneID),
            .init(L10n.text("真太阳日期范围", "Apparent-solar date range"), solar(firstApparent, zone: utc).ymd + " – " + solar(lastApparent, zone: utc).ymd),
            .init(L10n.text("年柱", "Year pillar"), candidates(early.year, late.year)),
            .init(L10n.text("月柱", "Month pillar"), candidates(early.month, late.month)),
            .init(L10n.text("日柱", "Day pillar"), days.map { NativeCalendar.stemBranch($0) }.joined(separator: L10n.text(" / 候选 ", " / possible "))),
            .init(L10n.text("时柱", "Hour pillar"), L10n.text("未知，未计算", "Unknown"))
        ]
        let placeholder = L10n.text("出生时辰不确定，完整八字待定。", "Birth time is uncertain; the complete Four Pillars are pending.")
        let result = OracleResult(method: .bazi, version: "2.0.0", status: .partial,
                                  headline: (early.year != late.year || early.month != late.month) ? L10n.text("出生在交节日 · 四柱候选待定", "Solar-term transition date · pillar candidates remain uncertain") : placeholder,
                                  rows: rows,
                                  evidence: [.init(id: "bazi-unknown-time", statement: L10n.text("按出生地民用日期的完整实际时间范围枚举真太阳日期；未用保存的中午或其他占位时刻代替真实出生时辰。", "The full actual interval of the local civil date determines the possible apparent-solar dates. A saved noon or other placeholder is never treated as the real birth time."), strength: 0.1, topic: "uncertainty")],
                                  limitations: [placeholder, L10n.text("日柱可能随真太阳日期跨日而变化；未输出时柱、五行单一计数、起运或大运。", "The day pillar can change across apparent-solar midnight. No hour pillar, single element count, or luck cycles are provided.")] + baseLimitations,
                                  provenance: provenance)
        return BaziCalculation(result: result, rawPillars: nil, previewPlaceholder: placeholder)
    }

    private func unavailable(_ message: String) -> BaziCalculation {
        var result = NativeCalendar.unavailable(.bazi, message)
        result.version = "2.0.0"
        return BaziCalculation(result: result, rawPillars: nil, previewPlaceholder: message)
    }

    /// Input range validation happens before this helper; corrected clock dates
    /// may cross 1899-12-31 or 2101-01-01 and remain valid calculation coordinates.
    private func solar(_ date: Date, zone: TimeZone) -> Solar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return Solar(year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!, second: c.second!)
    }

    private func candidates(_ first: String, _ last: String) -> String {
        first == last ? NativeCalendar.stemBranch(first)
            : L10n.text("交节前\(first) / 交节后\(last)", "Before: \(NativeCalendar.stemBranch(first)) / after: \(NativeCalendar.stemBranch(last))")
    }
    private func elements(_ pillar: String) -> String {
        (LunarUtil.WU_XING_GAN[String(pillar.prefix(1))] ?? "") + (LunarUtil.WU_XING_ZHI[String(pillar.suffix(1))] ?? "")
    }
    private func decoratedPillar(_ pillar: String) -> String {
        "\(NativeCalendar.stemBranch(pillar)) · \(NativeCalendar.fiveElements(elements(pillar))) · \(NativeCalendar.pinyin(LunarUtil.NAYIN[pillar] ?? ""))"
    }
    private func hiddenStems(_ pillar: String) -> String {
        LunarUtil.ZHI_HIDE_GAN[String(pillar.suffix(1))]?.joined() ?? ""
    }
    private func god(_ dayMaster: String, _ pillar: String) -> String {
        LunarUtil.SHI_SHEN[dayMaster + String(pillar.prefix(1))] ?? ""
    }
    private func englishGod(_ value: String) -> String {
        ["比肩": "Peer", "劫财": "Rob Wealth", "食神": "Eating God", "伤官": "Hurting Officer", "正财": "Direct Wealth", "偏财": "Indirect Wealth", "正官": "Direct Officer", "七杀": "Seven Killings", "正印": "Direct Resource", "偏印": "Indirect Resource"][value] ?? value
    }
    private var rules: String {
        L10n.text("真太阳时定日/时柱 · 实际立春换年/十二节换月 · sect 2 零点换日", "Apparent solar time for day/hour · actual Start of Spring and solar-term instants for year/month · sect 2 midnight day boundary")
    }
    private var baseLimitations: [String] {
        [L10n.text("五行计数为未加权的天干地支本气计数，不直接判断日主强弱或喜用神。", "Element counts are unweighted primary stem/branch counts. They do not determine Day Master strength or favorable elements."),
         L10n.text("真太阳时按出生经度与NOAA/Meeus均时差本地计算；地区坐标是代表点，临近换日、时辰或交节边界时需核对出生地点和原始钟表记录。", "Apparent solar time uses birth longitude and the on-device NOAA/Meeus equation of time. Area coordinates are representative points; verify the original birthplace and clock record near day, hour or term boundaries.")]
    }
    private var provenance: String {
        "6tail/lunar-swift MIT · NOAA/Meeus equation of time · on-device apparent-solar day/hour + fixed UTC+08:00 physical solar terms"
    }
}
