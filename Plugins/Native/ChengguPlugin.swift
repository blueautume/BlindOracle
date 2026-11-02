import Foundation

struct ChengguPlugin: OraclePlugin {
    private struct Tables: Decodable {
        let version: String
        let year_weights: [Int]
        let month_weights: [Int]
        let day_weights: [Int]
        let hour_weights: [Int]
        let poems: [String: [String]]
        let editorial_note: String
        let variant_note: String
    }
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.chenggu, summary: "固定采用1946《大雜字不求人》录文表，将农历年、月、日、时骨重相加。",
            required: [.birthDate, .birthTimeZone], optional: [.birthTime], questions: ["传统文化参考", "长期阶段"],
            output: "四项骨重、总骨重与对应公版原诗；时辰未知时输出可能范围。",
            limitations: ["采用农历年干支，不以立春换称骨年。闰月沿用本月，不混入其他表版本。", "本版2两1原诗缺文，保留缺文，不补造。", "原诗只是历史文本，不能用作寿命、疾病、亲属结局等现实判断。"],
            source: "1946《大雜字不求人》公版扫描 / DHCPSV/zhishi-bazi MIT录文", license: "传统公版数表与歌诀；录文参考MIT")
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard !input.profile.unknownFields.contains(.birthTimeZone) else {
            return NativeCalendar.unavailable(.chenggu, "出生时区已标为不确定，无法确认农历日界，未使用旧时区。")
        }
        guard !input.profile.unknownFields.contains(.birthDate), let birth = input.profile.birthDate, let solar = NativeCalendar.solar(birth, timeZoneID: input.profile.birthTimeZoneID) else {
            return NativeCalendar.unavailable(.chenggu, "需要1900–2100年内的出生日期。")
        }
        guard let url = NativeCalendar.resource("chenggu-1946", extension: "json"),
              let data = try? Data(contentsOf: url), let tables = try? JSONDecoder().decode(Tables.self, from: data),
              tables.year_weights.count == 60, tables.month_weights.count == 12,
              tables.day_weights.count == 30, tables.hour_weights.count == 12 else {
            return NativeCalendar.unavailable(.chenggu, "本地称骨表未正确安装，未调用远程数据或补造结果。")
        }
        let lunar = solar.lunar
        let yearIndex = NativeCalendar.mod(lunar.year - 4, 60)
        let a = tables.year_weights[yearIndex], b = tables.month_weights[abs(lunar.month) - 1], c = tables.day_weights[lunar.day - 1]
        let hasTime = input.profile.birthTimeKnown && !input.profile.unknownFields.contains(.birthTime)
        var rows: [OracleRow] = [.init("表版本", tables.version), .init("农历日期", "\(lunar.yearInGanZhi)年\(lunar.monthInChinese)月\(lunar.dayInChinese)"),
                                 .init("年骨重", Self.weight(a)), .init("月骨重", Self.weight(b)), .init("日骨重", Self.weight(c))]
        var limitations = [tables.variant_note, "称骨文字仅作传统文化材料，不代表人的价值、能力或真实命运。"]
        if !hasTime {
            let low = a + b + c + (tables.hour_weights.min() ?? 0)
            let high = a + b + c + (tables.hour_weights.max() ?? 0)
            rows.append(.init("时骨重", "时辰未知，未取单一值"))
            rows.append(.init("可能总重", "\(Self.weight(low)) 至 \(Self.weight(high))"))
            limitations.append("时辰不确定，未选择某一首评诗。")
            return OracleResult(method: .chenggu, status: .partial, headline: "时辰未定 · \(Self.weight(low))–\(Self.weight(high))", rows: rows, limitations: limitations,
                provenance: "本地称骨表 · 1946《大雜字不求人》录文")
        }
        let d = tables.hour_weights[lunar.timeZhiIndex], total = a + b + c + d
        rows.append(.init("时骨重", "\(lunar.timeZhi)时 · \(Self.weight(d))"))
        rows.append(.init("总骨重", Self.weight(total)))
        if let poem = tables.poems[String(total)] { rows.append(.init("历史原诗（非现实判定）", poem.joined(separator: "\n"))) }
        else { rows.append(.init("原诗", "所据刊本此项缺文，未补写")); limitations.append("该骨重原诗缺文。") }
        limitations += NativeCalendar.timezoneLimit(input.profile.birthTimeZoneID, date: birth)
        return OracleResult(method: .chenggu, status: tables.poems[String(total)] == nil || limitations.count > 2 ? .partial : .complete,
            headline: Self.weight(total), rows: rows,
            evidence: [.init(id: "chenggu-cultural", statement: "本地称骨合计为\(Self.weight(total))。该数值只作为传统文化附录，不参与现实事件的吉凶投票。", strength: 0.05, topic: "cultural")],
            limitations: limitations, provenance: "本地称骨表 · 1946《大雜字不求人》录文")
    }
    private static func weight(_ qian: Int) -> String { "\(qian / 10)两\(qian % 10)钱" }
}
