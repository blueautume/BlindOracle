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
        var value = NativeCalendar.descriptor(.chenggu, summary: L10n.text("固定采用1946《大雜字不求人》录文表，按出生地真太阳钟面映射的农历年、月、日、时查表。", "Uses the birth place's apparent-solar clock and a fixed 1946 reference table for lunar year, month, day and hour weights."),
            required: [.birthDate, .birthTimeZone, .birthCoordinates], optional: [.birthTime], questions: [L10n.text("传统文化参考", "Traditional culture"), L10n.text("长期阶段", "Long-term phases")],
            output: L10n.text("四项骨重、总骨重与对应公版原诗；时辰未知时输出可能范围。", "Shows four component weights, their total and the matching public-domain verse. With an unknown birth time, it shows a range."),
            limitations: [L10n.text("采用农历年干支，不以立春换称骨年。闰月沿用本月，不混入其他表版本。", "The year follows the lunar cycle. A leap month uses its regular month weight. All weights come from the same source edition."), L10n.text("本版2两1原诗缺文，保留缺文，不补造。", "The source has no verse for 2 liang 1 qian."), L10n.text("原诗只是历史文本，不能用作寿命、疾病、亲属结局等现实判断。", "Verses are historical texts and cannot determine a person's lifespan, health or family outcomes.")],
            source: L10n.text("1946《大雜字不求人》公版扫描 / DHCPSV/zhishi-bazi MIT录文", "Public-domain scan of the 1946 Da Zazi Bu Qiuren / DHCPSV/zhishi-bazi transcription (MIT)"), license: L10n.text("传统公版数表与歌诀；录文参考MIT", "Public-domain tables and verses · transcription reference (MIT)"))
        value.limitations += [TrueSolarClock.calendarRule, TrueSolarClock.coordinateLimitation]
        value.version = "2.0.0"
        return value
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        let clock: TrueSolarClock
        do { clock = try .birth(profile: input.profile) }
        catch { return unavailable(error.localizedDescription) }
        guard let url = NativeCalendar.resource("chenggu-1946", extension: "json"),
              let data = try? Data(contentsOf: url), let tables = try? JSONDecoder().decode(Tables.self, from: data),
              tables.year_weights.count == 60, tables.month_weights.count == 12,
              tables.day_weights.count == 30, tables.hour_weights.count == 12 else {
            return unavailable(L10n.text("本地称骨表未正确安装，未调用远程数据或补造结果。", "The local weight table could not be loaded."))
        }
        let unknown = input.profile.unknownFields.union(input.profile.declaredUnknownFields ?? [])
        let hasTime = input.profile.birthTimeKnown && !unknown.contains(.birthTime)
        if !hasTime {
            let candidates: [Solar]
            do { candidates = try TrueSolarClock.birthHourCandidates(profile: input.profile) }
            catch { return unavailable(error.localizedDescription) }
            guard !candidates.isEmpty else { return unavailable(L10n.text("未能确定合法的出生日期/时辰候选。", "No valid birth date and hour candidates could be established.")) }
            let components = candidates.map { Self.components($0.lunar, tables: tables) }
            let totals = components.map { $0.reduce(0, +) }
            let low = totals.min()!, high = totals.max()!
            let birthDay = String(format: "%04d-%02d-%02d", clock.civilSolar.year, clock.civilSolar.month, clock.civilSolar.day)
            // A stored representative noon is not a known birth clock. Do not
            // display its apparent clock or its single equation-of-time value.
            let rows: [OracleRow] = [
                .init(L10n.text("出生日期（时刻未知）", "Birth date (clock unknown)"), birthDay + " · " + clock.zoneID),
                .init(L10n.text("计算经度", "Calculation longitude"), String(format: "%.6f°", clock.longitude)),
                .init(L10n.text("纪日口径", "Calendar convention"), TrueSolarClock.calendarRule),
                .init(L10n.text("表版本", "Table edition"), L10n.text(tables.version, "1946 Da Zazi Bu Qiuren · v1.0")),
                .init(L10n.text("农历候选日期", "Candidate lunar dates"), Set(candidates.map { Self.lunarLabel($0.lunar) }).sorted().joined(separator: " / ")),
                .init(L10n.text("年骨重候选", "Year weight candidates"), Self.weights(components.map { $0[0] })),
                .init(L10n.text("月骨重候选", "Month weight candidates"), Self.weights(components.map { $0[1] })),
                .init(L10n.text("日骨重候选", "Day weight candidates"), Self.weights(components.map { $0[2] })),
                .init(L10n.text("时骨重", "Hour weight"), L10n.text("时辰未知，未取单一值", "Unknown, so there is no single value")),
                .init(L10n.text("合法日期/时辰组合", "Valid date and hour combinations"), String(candidates.count)),
                .init(L10n.text("可能总重", "Possible total weight"), L10n.text("\(Self.weight(low)) 至 \(Self.weight(high))", "\(Self.weight(low)) to \(Self.weight(high))"))
            ]
            return OracleResult(method: .chenggu, version: descriptor.version, status: .partial,
                headline: L10n.text("时辰未定 · \(Self.weight(low))–\(Self.weight(high))", "Birth time unknown · \(Self.weight(low))–\(Self.weight(high))"), rows: rows,
                limitations: Self.limitations(tables) + [L10n.text("已将完整出生民用日投影到真太阳钟面，逐个合法日期/时辰组合查表取范围；未用默认午时选日、时骨重或原诗。", "The complete civil birth day is projected onto the apparent-solar clock. The range uses each valid date/hour combination; no default noon, single hour weight or verse is selected.")], provenance: Self.provenance)
        }
        let lunar = clock.apparentSolar.lunar
        let parts = Self.components(lunar, tables: tables)
        let total = parts.reduce(0, +)
        var rows = clock.rows + [
            OracleRow(L10n.text("纪日口径", "Calendar convention"), TrueSolarClock.calendarRule),
            .init(L10n.text("表版本", "Table edition"), L10n.text(tables.version, "1946 Da Zazi Bu Qiuren · v1.0")),
            .init(L10n.text("农历日期", "Lunar date"), Self.lunarLabel(lunar)),
            .init(L10n.text("年骨重", "Year weight"), Self.weight(parts[0])),
            .init(L10n.text("月骨重", "Month weight"), Self.weight(parts[1])),
            .init(L10n.text("日骨重", "Day weight"), Self.weight(parts[2])),
            .init(L10n.text("时骨重", "Hour weight"), L10n.text("\(lunar.timeZhi)时 · \(Self.weight(parts[3]))", "\(NativeCalendar.stemBranch(lunar.timeZhi)) hour · \(Self.weight(parts[3]))")),
            .init(L10n.text("总骨重", "Total weight"), Self.weight(total))
        ]
        var limitations = Self.limitations(tables)
        if let poem = tables.poems[String(total)] {
            let original = poem.joined(separator: "\n")
            let note = Self.englishNotes[String(total)]
            let english = note.map { $0 + "\n\nClassical Chinese:\n" + original } ?? original
            let label = note == nil ? "Historical verse · classical Chinese" : "Historical verse"
            rows.append(.init(L10n.text("历史原诗（非现实判定）", label), L10n.text(original, english)))
        } else {
            rows.append(.init(L10n.text("原诗", "Original verse"), L10n.text("所据刊本此项缺文，未补写", "The reference edition contains no verse for this weight.")))
            limitations.append(L10n.text("该骨重原诗缺文。", "The original verse is missing for this weight."))
        }
        return OracleResult(method: .chenggu, version: descriptor.version,
            status: tables.poems[String(total)] == nil ? .partial : .complete,
            headline: Self.weight(total), rows: rows,
            evidence: [.init(id: "chenggu-cultural", statement: L10n.text("本地称骨合计为\(Self.weight(total))。该数值只作为传统文化附录，不参与现实事件的吉凶投票。", "The on-device table gives a total of \(Self.weight(total)). This is a historical reference and does not predict real outcomes."), strength: 0.05, topic: "cultural")],
            limitations: limitations, provenance: Self.provenance)
    }
    private func unavailable(_ reason: String) -> OracleResult {
        var result = NativeCalendar.unavailable(.chenggu, reason)
        result.version = descriptor.version
        result.limitations.append(TrueSolarClock.calendarRule)
        return result
    }
    private static func components(_ lunar: Lunar, tables: Tables) -> [Int] {
        [tables.year_weights[NativeCalendar.mod(lunar.year - 4, 60)],
         tables.month_weights[abs(lunar.month) - 1], tables.day_weights[lunar.day - 1],
         tables.hour_weights[lunar.timeZhiIndex]]
    }
    private static func lunarLabel(_ lunar: Lunar) -> String {
        L10n.text("\(lunar.yearInGanZhi)年\(lunar.monthInChinese)月\(lunar.dayInChinese)", "\(NativeCalendar.stemBranch(lunar.yearInGanZhi)) year · \(NativeCalendar.lunarDate(lunar, includeYear: false))")
    }
    private static func weights(_ values: [Int]) -> String {
        Set(values).sorted().map(weight).joined(separator: " / ")
    }
    private static func limitations(_ tables: Tables) -> [String] {
        [L10n.text(tables.variant_note, "This edition uses 8 qian for the Ji Chou year, 7 for the Gui Hai year, and 15 for lunar day 20. Other editions may differ."),
         L10n.text("称骨文字仅作传统文化材料，不代表人的价值、能力或真实命运。", "This traditional text cannot measure anyone's worth or abilities or predict their future."),
         TrueSolarClock.calendarRule, TrueSolarClock.coordinateLimitation]
    }
    private static var provenance: String {
        L10n.text("本地称骨表 · 1946《大雜字不求人》录文 · 真太阳纪日", "On-device 1946 Da Zazi Bu Qiuren table · apparent-solar date")
    }
    private static func weight(_ qian: Int) -> String { L10n.text("\(qian / 10)两\(qian % 10)钱", "\(qian / 10) liang \(qian % 10) qian") }
}
