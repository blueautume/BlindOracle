import Foundation

struct BaziPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.bazi, summary: L10n.text("按出生资料计算四柱、十神、五行、藏干、纳音与大运。未知时辰只计算三柱。", "Calculates the Four Pillars, Ten Gods, Five Elements, hidden stems, Na Yin and luck cycles. With an unknown birth time, it calculates three pillars."),
            required: [.birthDate, .birthTimeZone], optional: [.birthTime, .gender],
            questions: [L10n.text("个人阶段", "Personal phases"), L10n.text("长期事业", "Long-term career"), L10n.text("关系", "Relationships"), L10n.text("自我梳理", "Self-reflection")],
            output: L10n.text("四柱、干支五行数量、十神、藏干、纳音、旬空；已知时辰与排盘性别时输出起运和八步大运。", "Four Pillars, Five Element counts, Ten Gods, hidden stems, Na Yin and void branches. Includes the start and eight luck cycles when birth time and chart gender are known."),
            limitations: [L10n.text("五行数量是未加权计数，不直接当作喜用神或日主强弱。", "The Five Element counts are unweighted and do not determine favorable elements or Day Master strength."), L10n.text("默认sect=2，晚子时日柱按次日零点换日；1900–2100年。", "Uses sect 2, with the day pillar changing at midnight during the late Zi hour. Supports 1900–2100."), L10n.text("时区未知不排盘；时辰未知且当日交节时列出年/月柱候选，不取单一值。", "A time zone is required. If birth time is unknown on a solar-term transition date, the possible year and month pillars are listed."), L10n.text("尚未实现神煞、格局和喜用神完整判断；不预测疾病、寿命或必然事件。", "Full Shen Sha, chart pattern and favorable-element analysis are unavailable. The chart does not predict illness, lifespan or inevitable events.")])
    }

    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard !input.profile.unknownFields.contains(.birthTimeZone) else {
            return NativeCalendar.unavailable(.bazi, L10n.text("出生时区已标为不确定，未使用保存的旧时区排盘。", "The birth time zone is marked uncertain. The saved time zone was not used."))
        }
        guard !input.profile.unknownFields.contains(.birthDate), let birth = input.profile.birthDate,
              let solar = NativeCalendar.solar(birth, timeZoneID: input.profile.birthTimeZoneID) else {
            return NativeCalendar.unavailable(.bazi, L10n.text("需要有效出生日期与时区；当前支持1900–2100年。", "A valid birth date and time zone are required. The supported years are 1900–2100."))
        }
        let lunar = solar.lunar
        let ec = lunar.eightChar
        ec.sect = 2
        let hasTime = input.profile.birthTimeKnown && !input.profile.unknownFields.contains(.birthTime)
        if !hasTime {
            let early = Solar(year: solar.year, month: solar.month, day: solar.day).lunar.eightChar
            let late = Solar(year: solar.year, month: solar.month, day: solar.day, hour: 23, minute: 59, second: 59).lunar.eightChar
            early.sect = 2
            late.sect = 2
            if early.year != late.year || early.month != late.month {
                return OracleResult(method: .bazi, status: .partial,
                    headline: L10n.text("出生在交节日 · 年/月柱待定", "Solar-term transition date · year/month pillars uncertain"),
                    rows: [
                        .init(L10n.text("排盘口径", "Chart rules"), L10n.text("立春换年 / 十二节换月 / sect 2 零点换日", "Year starts at Start of Spring / month changes at solar terms / sect 2 day changes at midnight")),
                        .init(L10n.text("公历日期", "Gregorian date"), solar.ymd + " · " + input.profile.birthTimeZoneID),
                        .init(L10n.text("年柱", "Year pillar"), early.year == late.year ? NativeCalendar.stemBranch(early.year) : L10n.text("交节前\(early.year) / 交节后\(late.year)", "Before: \(NativeCalendar.stemBranch(early.year)) / after: \(NativeCalendar.stemBranch(late.year))")),
                        .init(L10n.text("月柱", "Month pillar"), early.month == late.month ? NativeCalendar.stemBranch(early.month) : L10n.text("交节前\(early.month) / 交节后\(late.month)", "Before: \(NativeCalendar.stemBranch(early.month)) / after: \(NativeCalendar.stemBranch(late.month))")),
                        .init(L10n.text("日柱", "Day pillar"), NativeCalendar.stemBranch(early.day)), .init(L10n.text("时柱", "Hour pillar"), L10n.text("未知，未计算", "Unknown")),
                        .init(L10n.text("五行表层计数", "Unweighted Five Element counts"), L10n.text("年/月柱尚有候选，未取单一计数", "Multiple year or month pillars are possible, so no single count is shown."))
                    ],
                    evidence: [.init(id: "bazi-term-uncertain", statement: L10n.text("出生日期内发生交节，出生时间未知，不能固定年柱/月柱，未输出起运或喜用神。", "A solar term began on this date. Without the birth time, the year or month pillar is uncertain. The start of luck cycles and favorable elements are unavailable."), strength: 0.1, topic: "uncertainty")],
                    limitations: [L10n.text("出生时辰未知；本次显示当日交节前后的年/月柱候选，未用保存的默认时间替代真实出生时间。", "Birth time is unknown. The chart lists possible year and month pillars on each side of the solar-term boundary.")] + NativeCalendar.timezoneLimit(input.profile.birthTimeZoneID, date: birth),
                    provenance: L10n.text("6tail/lunar-swift MIT · 当日0:00至23:59交节不确定性检查", "6tail/lunar-swift (MIT) · solar-term transition checked across the birth date"))
            }
        }
        var rows: [OracleRow] = [
            .init(L10n.text("排盘口径", "Chart rules"), L10n.text("立春换年 / 十二节换月 / sect 2 晚子时零点换日", "Year starts at Start of Spring / month changes at solar terms / sect 2 day changes at midnight during the late Zi hour")),
            .init(L10n.text("公历", "Gregorian date"), (hasTime ? solar.ymdhms : solar.ymd + L10n.text("（时辰未知）", " (birth time unknown)")) + " · " + input.profile.birthTimeZoneID),
            .init(L10n.text("农历", "Lunar date"), NativeCalendar.lunarDate(lunar)),
            .init(L10n.text("年柱", "Year pillar"), pillar(ec.year, elements: ec.yearWuXing, naYin: ec.yearNaYin)),
            .init(L10n.text("月柱", "Month pillar"), pillar(ec.month, elements: ec.monthWuXing, naYin: ec.monthNaYin)),
            .init(L10n.text("日柱", "Day pillar"), pillar(ec.day, elements: ec.dayWuXing, naYin: ec.dayNaYin)),
            .init(L10n.text("时柱", "Hour pillar"), hasTime ? pillar(ec.time, elements: ec.timeWuXing, naYin: ec.timeNaYin) : L10n.text("未知，未计算", "Unknown")),
            .init(L10n.text("日主", "Day Master"), NativeCalendar.stemBranch(ec.dayGan)),
            .init(L10n.text("天干十神", "Ten Gods of the heavenly stems"), L10n.text("年：\(ec.yearShiShenGan) / 月：\(ec.monthShiShenGan)" + (hasTime ? " / 时：\(ec.timeShiShenGan)" : ""), "Year: \(tenGod(ec.yearShiShenGan)) / Month: \(tenGod(ec.monthShiShenGan))" + (hasTime ? " / Hour: \(tenGod(ec.timeShiShenGan))" : ""))),
            .init(L10n.text("地支藏干", "Hidden stems of the earthly branches"), L10n.text("年：\(ec.yearHideGan.joined()) / 月：\(ec.monthHideGan.joined()) / 日：\(ec.dayHideGan.joined())" + (hasTime ? " / 时：\(ec.timeHideGan.joined())" : ""), "Year: \(NativeCalendar.stemBranch(ec.yearHideGan.joined())) / Month: \(NativeCalendar.stemBranch(ec.monthHideGan.joined())) / Day: \(NativeCalendar.stemBranch(ec.dayHideGan.joined()))" + (hasTime ? " / Hour: \(NativeCalendar.stemBranch(ec.timeHideGan.joined()))" : ""))),
            .init(L10n.text("日柱旬空", "Day pillar void branches"), NativeCalendar.stemBranch(ec.dayXunKong))
        ]
        var counts: [String: Int] = ["木": 0, "火": 0, "土": 0, "金": 0, "水": 0]
        let fiveElements = ec.yearWuXing + ec.monthWuXing + ec.dayWuXing + (hasTime ? ec.timeWuXing : "")
        for character in fiveElements { counts[String(character), default: 0] += 1 }
        rows.append(.init(L10n.text("五行表层计数", "Unweighted Five Element counts"), NativeCalendar.elements.enumerated().map { "\(NativeCalendar.element($0.offset)) \(counts[$0.element] ?? 0)" }.joined(separator: " · ")))
        var limitations = [L10n.text("五行计数只包含天干地支本气，不含月令权重、透藏根气和合化；未自动确定喜用神。", "Element counts include only the primary stems and branches. They exclude seasonal weighting, hidden roots and transformations, and do not determine favorable elements.")]
        var evidence = [OracleEvidence(id: "bazi-day-master", statement: L10n.text("日主\(ec.dayGan)，月支\(ec.monthZhi)；按日主与月令组织长期观察，不将缺少某行等同于需要补某行。", "Day Master: \(NativeCalendar.stemBranch(ec.dayGan)). Month branch: \(NativeCalendar.stemBranch(ec.monthZhi)). Use these for reflection. A missing element alone does not imply a need to add it."), topic: "personal")]
        if hasTime && !input.profile.unknownFields.contains(.gender) && ["男", "女"].contains(input.profile.sex) {
            let yun = ec.getYun(gender: input.profile.sex == "男" ? 1 : 0, sect: 2)
            rows.append(.init(L10n.text("起运", "Luck cycle start"), L10n.text("\(yun.startYear)年\(yun.startMonth)月\(yun.startDay)日后 · \(yun.forward ? L10n.text("顺排", "forward") : L10n.text("逆排", "backward"))", "In \(yun.startYear) years, \(yun.startMonth) months, \(yun.startDay) days · \(yun.forward ? "forward" : "backward")")))
            rows.append(.init(L10n.text("交运公历", "Gregorian cycle start"), yun.startSolar.ymdhms))
            for item in yun.getDaYun(n: 9).dropFirst() {
                rows.append(.init(L10n.text("大运 \(item.startYear)–\(item.endYear)", "Luck cycle \(item.startYear)–\(item.endYear)"), L10n.text("\(item.ganZhi) · 虚岁\(item.startAge)–\(item.endAge)", "\(NativeCalendar.stemBranch(item.ganZhi)) · East Asian age \(item.startAge)–\(item.endAge)")))
            }
        } else {
            limitations.append(L10n.text("出生时辰或排盘性别未确定，本次未输出起运与大运。", "Birth time or chart gender is unknown, so the luck cycles and their start are unavailable."))
        }
        if !hasTime {
            limitations.append(L10n.text("时辰不确定：只保留三柱；若出生接近23:00/00:00，还需核对日柱边界。", "Only three pillars are shown because the birth time is unknown. A birth near 11 p.m. or midnight may require a day-boundary check."))
            limitations.append(L10n.text("若出生在交节当日，年柱或月柱也可能随未知时刻改变；此处按已记录日期时刻暂列参考。", "On solar-term transition dates, the year or month pillar may depend on the unknown birth time. Use the recorded date as a provisional reference."))
            evidence.append(.init(id: "bazi-unknown-time", statement: L10n.text("时柱缺失，对细节和时间节点的解释应保留更大不确定性。", "Without the hour pillar, details and timing are more uncertain."), topic: "uncertainty"))
        }
        limitations += NativeCalendar.timezoneLimit(input.profile.birthTimeZoneID, date: birth)
        return OracleResult(method: .bazi, status: hasTime && limitations.count == 1 ? .complete : .partial,
                            headline: [ec.year, ec.month, ec.day].map { NativeCalendar.stemBranch($0) }.joined(separator: " ") + " " + (hasTime ? NativeCalendar.stemBranch(ec.time) : L10n.text("时辰未定", "hour unknown")),
                            rows: rows, evidence: evidence, limitations: limitations,
                            provenance: L10n.text("6tail/lunar-swift MIT · 原生本地历法 / BlindOracle 三柱与资料完整性处理", "6tail/lunar-swift (MIT) · on-device calendar / BlindOracle three-pillar and input validation rules"))
    }
    private func pillar(_ value: String, elements: String, naYin: String) -> String {
        "\(NativeCalendar.stemBranch(value)) · \(NativeCalendar.fiveElements(elements)) · \(NativeCalendar.pinyin(naYin))"
    }

    private func tenGod(_ value: String) -> String {
        let titles = ["比肩": "Peer", "劫财": "Rob Wealth", "食神": "Eating God", "伤官": "Hurting Officer", "偏财": "Indirect Wealth", "正财": "Direct Wealth", "七杀": "Seven Killings", "正官": "Direct Officer", "偏印": "Indirect Resource", "正印": "Direct Resource"]
        return titles[value] ?? NativeCalendar.pinyin(value)
    }
}
