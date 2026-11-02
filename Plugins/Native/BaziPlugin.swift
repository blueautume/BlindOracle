import Foundation

struct BaziPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.bazi, summary: "按出生资料计算四柱、十神、五行、藏干、纳音与大运。未知时辰只计算三柱。",
            required: [.birthDate, .birthTimeZone], optional: [.birthTime, .gender],
            questions: ["个人阶段", "长期事业", "关系", "自我梳理"],
            output: "四柱、干支五行数量、十神、藏干、纳音、旬空；已知时辰与排盘性别时输出起运和八步大运。",
            limitations: ["五行数量是未加权计数，不直接当作喜用神或日主强弱。", "默认sect=2，晚子时日柱按次日零点换日；1900–2100年。", "时区未知不排盘；时辰未知且当日交节时列出年/月柱候选，不取单一值。", "尚未实现神煞、格局和喜用神完整判断；不预测疾病、寿命或必然事件。"])
    }

    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard !input.profile.unknownFields.contains(.birthTimeZone) else {
            return NativeCalendar.unavailable(.bazi, "出生时区已标为不确定，未使用保存的旧时区排盘。")
        }
        guard !input.profile.unknownFields.contains(.birthDate), let birth = input.profile.birthDate,
              let solar = NativeCalendar.solar(birth, timeZoneID: input.profile.birthTimeZoneID) else {
            return NativeCalendar.unavailable(.bazi, "需要有效出生日期与时区；当前支持1900–2100年。")
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
                    headline: "出生在交节日 · 年/月柱待定",
                    rows: [
                        .init("排盘口径", "立春换年 / 十二节换月 / sect 2 零点换日"),
                        .init("公历日期", solar.ymd + " · " + input.profile.birthTimeZoneID),
                        .init("年柱", early.year == late.year ? early.year : "交节前\(early.year) / 交节后\(late.year)"),
                        .init("月柱", early.month == late.month ? early.month : "交节前\(early.month) / 交节后\(late.month)"),
                        .init("日柱", early.day), .init("时柱", "未知，未计算"),
                        .init("五行表层计数", "年/月柱尚有候选，未取单一计数")
                    ],
                    evidence: [.init(id: "bazi-term-uncertain", statement: "出生日期内发生交节，出生时间未知，不能固定年柱/月柱，未输出起运或喜用神。", strength: 0.1, topic: "uncertainty")],
                    limitations: ["出生时辰未知；本次显示当日交节前后的年/月柱候选，未用保存的默认时间替代真实出生时间。"] + NativeCalendar.timezoneLimit(input.profile.birthTimeZoneID, date: birth),
                    provenance: "6tail/lunar-swift MIT · 当日0:00至23:59交节不确定性检查")
            }
        }
        var rows: [OracleRow] = [
            .init("排盘口径", "立春换年 / 十二节换月 / sect 2 晚子时零点换日"),
            .init("公历", (hasTime ? solar.ymdhms : solar.ymd + "（时辰未知）") + " · " + input.profile.birthTimeZoneID),
            .init("农历", "\(lunar.yearInChinese)年\(lunar.monthInChinese)月\(lunar.dayInChinese)"),
            .init("年柱", "\(ec.year) · \(ec.yearWuXing) · \(ec.yearNaYin)"),
            .init("月柱", "\(ec.month) · \(ec.monthWuXing) · \(ec.monthNaYin)"),
            .init("日柱", "\(ec.day) · \(ec.dayWuXing) · \(ec.dayNaYin)"),
            .init("时柱", hasTime ? "\(ec.time) · \(ec.timeWuXing) · \(ec.timeNaYin)" : "未知，未计算"),
            .init("日主", ec.dayGan),
            .init("天干十神", "年：\(ec.yearShiShenGan) / 月：\(ec.monthShiShenGan)" + (hasTime ? " / 时：\(ec.timeShiShenGan)" : "")),
            .init("地支藏干", "年：\(ec.yearHideGan.joined()) / 月：\(ec.monthHideGan.joined()) / 日：\(ec.dayHideGan.joined())" + (hasTime ? " / 时：\(ec.timeHideGan.joined())" : "")),
            .init("日柱旬空", ec.dayXunKong)
        ]
        var counts: [String: Int] = ["木": 0, "火": 0, "土": 0, "金": 0, "水": 0]
        let fiveElements = ec.yearWuXing + ec.monthWuXing + ec.dayWuXing + (hasTime ? ec.timeWuXing : "")
        for character in fiveElements { counts[String(character), default: 0] += 1 }
        rows.append(.init("五行表层计数", NativeCalendar.elements.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: " · ")))
        var limitations = ["五行计数只包含天干地支本气，不含月令权重、透藏根气和合化；未自动确定喜用神。"]
        var evidence = [OracleEvidence(id: "bazi-day-master", statement: "日主\(ec.dayGan)，月支\(ec.monthZhi)；按日主与月令组织长期观察，不将缺少某行等同于需要补某行。", topic: "personal")]
        if hasTime && !input.profile.unknownFields.contains(.gender) && ["男", "女"].contains(input.profile.sex) {
            let yun = ec.getYun(gender: input.profile.sex == "男" ? 1 : 0, sect: 2)
            rows.append(.init("起运", "\(yun.startYear)年\(yun.startMonth)月\(yun.startDay)日后 · \(yun.forward ? "顺排" : "逆排")"))
            rows.append(.init("交运公历", yun.startSolar.ymdhms))
            for item in yun.getDaYun(n: 9).dropFirst() {
                rows.append(.init("大运 \(item.startYear)–\(item.endYear)", "\(item.ganZhi) · 虚岁\(item.startAge)–\(item.endAge)"))
            }
        } else {
            limitations.append("出生时辰或排盘性别未确定，本次未输出起运与大运。")
        }
        if !hasTime {
            limitations.append("时辰不确定：只保留三柱；若出生接近23:00/00:00，还需核对日柱边界。")
            limitations.append("若出生在交节当日，年柱或月柱也可能随未知时刻改变；此处按已记录日期时刻暂列参考。")
            evidence.append(.init(id: "bazi-unknown-time", statement: "时柱缺失，对细节和时间节点的解释应保留更大不确定性。", topic: "uncertainty"))
        }
        limitations += NativeCalendar.timezoneLimit(input.profile.birthTimeZoneID, date: birth)
        return OracleResult(method: .bazi, status: hasTime && limitations.count == 1 ? .complete : .partial,
                            headline: "\(ec.year) \(ec.month) \(ec.day) \(hasTime ? ec.time : "时辰未定")",
                            rows: rows, evidence: evidence, limitations: limitations,
                            provenance: "6tail/lunar-swift MIT · 原生本地历法 / BlindOracle 三柱与资料完整性处理")
    }
}
