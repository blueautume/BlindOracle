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
    private static let englishNotes: [String: String] = {
        guard let url = NativeCalendar.resource("chenggu-english-notes", extension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return notes
    }()

    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.chenggu, summary: L10n.text("固定采用1946《大雜字不求人》录文表，将农历年、月、日、时骨重相加。", "Adds the lunar year, month, day and hour weights from a fixed 1946 reference table."),
            required: [.birthDate, .birthTimeZone], optional: [.birthTime], questions: [L10n.text("传统文化参考", "Traditional culture"), L10n.text("长期阶段", "Long-term phases")],
            output: L10n.text("四项骨重、总骨重与对应公版原诗；时辰未知时输出可能范围。", "Shows four component weights, their total and the matching public-domain verse. With an unknown birth time, it shows a range."),
            limitations: [L10n.text("采用农历年干支，不以立春换称骨年。闰月沿用本月，不混入其他表版本。", "The year follows the lunar cycle. A leap month uses its regular month weight. All weights come from the same source edition."), L10n.text("本版2两1原诗缺文，保留缺文，不补造。", "The source has no verse for 2 liang 1 qian."), L10n.text("原诗只是历史文本，不能用作寿命、疾病、亲属结局等现实判断。", "Verses are historical texts and cannot determine a person's lifespan, health or family outcomes.")],
            source: L10n.text("1946《大雜字不求人》公版扫描 / DHCPSV/zhishi-bazi MIT录文", "Public-domain scan of the 1946 Da Zazi Bu Qiuren / DHCPSV/zhishi-bazi transcription (MIT)"), license: L10n.text("传统公版数表与歌诀；录文参考MIT", "Public-domain tables and verses · transcription reference (MIT)"))
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard !input.profile.unknownFields.contains(.birthTimeZone) else {
            return NativeCalendar.unavailable(.chenggu, L10n.text("出生时区已标为不确定，无法确认农历日界，未使用旧时区。", "The birth time zone is marked uncertain, so the lunar day boundary cannot be established."))
        }
        guard !input.profile.unknownFields.contains(.birthDate), let birth = input.profile.birthDate, let solar = NativeCalendar.solar(birth, timeZoneID: input.profile.birthTimeZoneID) else {
            return NativeCalendar.unavailable(.chenggu, L10n.text("需要1900–2100年内的出生日期。", "A birth date in 1900–2100 is required."))
        }
        guard let url = NativeCalendar.resource("chenggu-1946", extension: "json"),
              let data = try? Data(contentsOf: url), let tables = try? JSONDecoder().decode(Tables.self, from: data),
              tables.year_weights.count == 60, tables.month_weights.count == 12,
              tables.day_weights.count == 30, tables.hour_weights.count == 12 else {
            return NativeCalendar.unavailable(.chenggu, L10n.text("本地称骨表未正确安装，未调用远程数据或补造结果。", "The local weight table could not be loaded."))
        }
        let lunar = solar.lunar
        let yearIndex = NativeCalendar.mod(lunar.year - 4, 60)
        let a = tables.year_weights[yearIndex], b = tables.month_weights[abs(lunar.month) - 1], c = tables.day_weights[lunar.day - 1]
        let hasTime = input.profile.birthTimeKnown && !input.profile.unknownFields.contains(.birthTime)
        var rows: [OracleRow] = [.init(L10n.text("表版本", "Table edition"), L10n.text(tables.version, "1946 Da Zazi Bu Qiuren · v1.0")), .init(L10n.text("农历日期", "Lunar date"), L10n.text("\(lunar.yearInGanZhi)年\(lunar.monthInChinese)月\(lunar.dayInChinese)", "\(NativeCalendar.stemBranch(lunar.yearInGanZhi)) year · \(NativeCalendar.lunarDate(lunar, includeYear: false))")),
                                 .init(L10n.text("年骨重", "Year weight"), Self.weight(a)), .init(L10n.text("月骨重", "Month weight"), Self.weight(b)), .init(L10n.text("日骨重", "Day weight"), Self.weight(c))]
        var limitations = [L10n.text(tables.variant_note, "This edition uses 8 qian for the Ji Chou year, 7 for the Gui Hai year, and 15 for lunar day 20. Other editions may differ."), L10n.text("称骨文字仅作传统文化材料，不代表人的价值、能力或真实命运。", "This traditional text cannot measure anyone's worth or abilities or predict their future.")]
        if !hasTime {
            let low = a + b + c + (tables.hour_weights.min() ?? 0)
            let high = a + b + c + (tables.hour_weights.max() ?? 0)
            rows.append(.init(L10n.text("时骨重", "Hour weight"), L10n.text("时辰未知，未取单一值", "Unknown, so there is no single value")))
            rows.append(.init(L10n.text("可能总重", "Possible total weight"), L10n.text("\(Self.weight(low)) 至 \(Self.weight(high))", "\(Self.weight(low)) to \(Self.weight(high))")))
            limitations.append(L10n.text("时辰不确定，未选择某一首评诗。", "The birth time is unknown, so no individual verse was selected."))
            return OracleResult(method: .chenggu, status: .partial, headline: L10n.text("时辰未定 · \(Self.weight(low))–\(Self.weight(high))", "Birth time unknown · \(Self.weight(low))–\(Self.weight(high))"), rows: rows, limitations: limitations,
                provenance: L10n.text("本地称骨表 · 1946《大雜字不求人》录文", "On-device bone weight table · 1946 Da Zazi Bu Qiuren"))
        }
        let d = tables.hour_weights[lunar.timeZhiIndex], total = a + b + c + d
        rows.append(.init(L10n.text("时骨重", "Hour weight"), L10n.text("\(lunar.timeZhi)时 · \(Self.weight(d))", "\(NativeCalendar.stemBranch(lunar.timeZhi)) hour · \(Self.weight(d))")))
        rows.append(.init(L10n.text("总骨重", "Total weight"), Self.weight(total)))
        if let poem = tables.poems[String(total)] {
            let original = poem.joined(separator: "\n")
            let note = Self.englishNotes[String(total)]
            let english = note.map { $0 + "\n\nClassical Chinese:\n" + original } ?? original
            let label = note == nil ? "Historical verse · classical Chinese" : "Historical verse"
            rows.append(.init(L10n.text("历史原诗（非现实判定）", label), L10n.text(original, english)))
        }
        else { rows.append(.init(L10n.text("原诗", "Original verse"), L10n.text("所据刊本此项缺文，未补写", "The reference edition contains no verse for this weight."))); limitations.append(L10n.text("该骨重原诗缺文。", "The original verse is missing for this weight.")) }
        limitations += NativeCalendar.timezoneLimit(input.profile.birthTimeZoneID, date: birth)
        return OracleResult(method: .chenggu, status: tables.poems[String(total)] == nil || limitations.count > 2 ? .partial : .complete,
            headline: Self.weight(total), rows: rows,
            evidence: [.init(id: "chenggu-cultural", statement: L10n.text("本地称骨合计为\(Self.weight(total))。该数值只作为传统文化附录，不参与现实事件的吉凶投票。", "The on-device table gives a total of \(Self.weight(total)). This is a historical reference and does not predict real outcomes."), strength: 0.05, topic: "cultural")],
            limitations: limitations, provenance: L10n.text("本地称骨表 · 1946《大雜字不求人》录文", "On-device bone weight table · 1946 Da Zazi Bu Qiuren"))
    }
    private static func weight(_ qian: Int) -> String { L10n.text("\(qian / 10)两\(qian % 10)钱", "\(qian / 10) liang \(qian % 10) qian") }
}
