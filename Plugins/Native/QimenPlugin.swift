import Foundation

/// A narrowly specified local chart: 時家轉盤、拆補、五日符頭定元、中五寄坤。
/// Ring rotations follow qfdk/qimen's MIT implementation; no Node runtime is used.
struct QimenPlugin: OraclePlugin {
    private static let ring = [1, 8, 3, 4, 9, 2, 7, 6]
    private static let stars = ["天蓬", "天任", "天冲", "天辅", "天英", "禽芮", "天柱", "天心"]
    private static let doors = ["休门", "生门", "伤门", "杜门", "景门", "死门", "惊门", "开门"]
    private static let spirits = ["值符", "螣蛇", "太阴", "六合", "白虎", "玄武", "九地", "九天"]
    private static let instrument = ["戊", "己", "庚", "辛", "壬", "癸", "丁", "丙", "乙"]
    private static let terms = ["冬至","小寒","大寒","立春","雨水","惊蛰","春分","清明","谷雨","立夏","小满","芒种","夏至","小暑","大暑","立秋","处暑","白露","秋分","寒露","霜降","立冬","小雪","大雪"]
    private static let numbers = [[1,7,4],[2,8,5],[3,9,6],[8,5,2],[9,6,3],[1,7,4],[3,9,6],[4,1,7],[5,2,8],[4,1,7],[5,2,8],[6,3,9],[9,3,6],[8,2,5],[7,1,4],[2,5,8],[1,4,7],[9,3,6],[7,1,4],[6,9,3],[5,8,2],[6,9,3],[5,8,2],[4,7,1]]
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.qimen, summary: L10n.text("时家转盘拆补法，按当地起盘时间算节气、符头、三元、阴阳遁局、天地盘、九星、八门、八神。", "Uses the hourly rotating Chai Bu method to calculate the solar term, cycle leaders, Yuan phase, Yin or Yang chart, Heaven and Earth plates, stars, gates and spirits."),
            optional: [.currentLocation], questions: [L10n.text("行动节奏", "Timing an action"), L10n.text("具体选择", "Specific decisions"), L10n.text("协作与沟通", "Cooperation and communication"), L10n.text("近期规划", "Near-term planning")],
            output: L10n.text("节气/符头/三元/局数/旬首/值符/值使与逐宫天地干、星门神；值使门基础释义。", "Solar term, cycle and configuration, chief star and duty gate, and each palace's stems, stars, gates and spirits. Includes the traditional duty gate meaning."),
            limitations: [L10n.text("只支持时家转盘拆补，不混用置闰、茅山或飞盘。", "Uses hourly rotating Chai Bu only. Other schools use different chart rules."), L10n.text("中五寄坤，值使由寄宫按九宫数顺逆加时。", "The center palace is hosted in Kun. The duty gate advances or reverses through the numbered palaces according to the hour."), L10n.text("不含暗干、十干克应、完整格局取用及应期判断。", "Hidden stems, stem interaction readings, full chart interpretation and event timing are outside its scope.")],
            source: L10n.text("qfdk/qimen MIT转盘公式参考；6tail/lunar-swift节气；BlindOracle Swift移植", "qfdk/qimen rotating chart formulas (MIT) · 6tail/lunar-swift solar terms · BlindOracle Swift port"), license: L10n.text("MIT参考实现，保留Resources/Native/ThirdParty-Qimen.txt", "MIT reference implementation. See Resources/Native/ThirdParty-Qimen.txt."))
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard let solar = NativeCalendar.castingSolar(input) else { return NativeCalendar.unavailable(.qimen, L10n.text("起盘时刻或时区无效，支持1900–2100年。", "A valid casting time and time zone in 1900–2100 are required.")) }
        let lunar = solar.lunar
        let term = lunar.prevJieQi.name
        guard let termIndex = Self.terms.firstIndex(of: term) else {
            return NativeCalendar.unavailable(.qimen, L10n.text("当前节气\(term)未匹配本地定局表，未采用默认假局。", "The local chart table has no matching solar term for \(NativeCalendar.pinyin(term))."))
        }
        let dayIndex = NativeCalendar.jiaziIndex(lunar.dayInGanZhi)
        let headIndex = dayIndex - dayIndex % 5
        let headBranch = headIndex % 12
        let yuan = [0,3,6,9].contains(headBranch) ? 0 : ([2,5,8,11].contains(headBranch) ? 1 : 2)
        let ju = Self.numbers[termIndex][yuan]
        let yang = termIndex < 12
        let direction = yang ? 1 : -1
        var earth: [Int: String] = [:]
        for index in 0..<9 { earth[NativeCalendar.mod(ju - 1 + direction * index, 9) + 1] = Self.instrument[index] }
        let hourIndex = NativeCalendar.jiaziIndex(lunar.timeInGanZhi)
        let hiddenStem = Self.instrument[hourIndex / 10]
        let originRaw = earth.first(where: { $0.value == hiddenStem })?.key ?? 5
        let origin = originRaw == 5 ? 2 : originRaw
        let hourStem = lunar.timeGan == "甲" ? hiddenStem : lunar.timeGan
        let targetRaw = earth.first(where: { $0.value == hourStem })?.key ?? origin
        let target = targetRaw == 5 ? 2 : targetRaw
        guard let originIndex = Self.ring.firstIndex(of: origin), let targetIndex = Self.ring.firstIndex(of: target) else {
            return NativeCalendar.unavailable(.qimen, L10n.text("值符落宫校验失败。", "The chief star's palace could not be validated."))
        }
        let rotate = NativeCalendar.mod(targetIndex - originIndex, 8)
        var sky: [Int: String] = [5: earth[5] ?? ""]
        var stars: [Int: String] = [:]
        for index in 0..<8 {
            let sourcePalace = Self.ring[index]
            let destination = Self.ring[(index + rotate) % 8]
            sky[destination] = (earth[sourcePalace] ?? "") + (sourcePalace == 2 ? "/" + (earth[5] ?? "") + "（寄）" : "")
            stars[destination] = Self.stars[index]
        }
        let doorTargetRaw = NativeCalendar.mod(origin - 1 + direction * (hourIndex % 10), 9) + 1
        let doorTarget = doorTargetRaw == 5 ? 2 : doorTargetRaw
        let doorDelta = NativeCalendar.mod((Self.ring.firstIndex(of: doorTarget) ?? 0) - originIndex, 8)
        var doors: [Int: String] = [:]
        for index in 0..<8 { doors[Self.ring[(index + doorDelta) % 8]] = Self.doors[index] }
        var spirits: [Int: String] = [:]
        for index in 0..<8 { spirits[Self.ring[NativeCalendar.mod(targetIndex + direction * index, 8)]] = Self.spirits[index] }
        let yuanNames = ["上元", "中元", "下元"]
        let zhiShi = Self.doors[originIndex]
        let zhiFu = Self.stars[originIndex]
        let configuration = L10n.text("\(yang ? "阳遁" : "阴遁")\(ju)局", "\(yang ? "Yang" : "Yin") Dun \(ju)")
        var rows: [OracleRow] = [
            .init(L10n.text("排法", "Chart method"), L10n.text("时家转盘拆补 · 中五寄坤", "Hourly rotating Chai Bu · center palace hosted in Kun")),
            .init(L10n.text("起盘时间", "Casting time"), solar.ymdhms + " · " + input.profile.currentTimeZoneID),
            .init(L10n.text("四柱", "Four Pillars"), [lunar.yearInGanZhiExact, lunar.monthInGanZhiExact, lunar.dayInGanZhi, lunar.timeInGanZhi].map { NativeCalendar.stemBranch($0) }.joined(separator: " ")),
            .init(L10n.text("节气 / 三元", "Solar term / Yuan phase"), L10n.text("\(term) · \(yuanNames[yuan])", "\(Self.englishTerms[termIndex]) · \(["Upper", "Middle", "Lower"][yuan]) Yuan")),
            .init(L10n.text("上次交节", "Most recent solar-term boundary"), lunar.prevJieQi.solar.ymdhms + L10n.text("（东八区历表）", " (UTC+8 calendar)")),
            .init(L10n.text("符头", "Five-day cycle leader"), NativeCalendar.stemBranch(NativeCalendar.stems[headIndex % 10] + NativeCalendar.branches[headBranch])),
            .init(L10n.text("局数", "Configuration"), configuration),
            .init(L10n.text("旬首六仪", "Ten-day cycle leader"), L10n.text("\(lunar.timeXun)遁\(hiddenStem)", "\(NativeCalendar.stemBranch(lunar.timeXun)) hides under \(NativeCalendar.stemBranch(hiddenStem))")),
            .init(L10n.text("值符", "Chief star"), L10n.text("\(zhiFu) · 原\(originRaw)宫（寄\(origin)宫）→ \(target)宫", "\(Self.starName(zhiFu)) · palace \(originRaw) (hosted in \(origin)) → palace \(target)")),
            .init(L10n.text("值使", "Duty gate"), L10n.text("\(zhiShi) → \(doorTargetRaw)宫\(doorTargetRaw == 5 ? "（寄坤2）" : "")", "\(Self.doorName(zhiShi)) → palace \(doorTargetRaw)\(doorTargetRaw == 5 ? " (hosted in Kun 2)" : "")"))
        ]
        let palaceNames = [1:"坎",2:"坤",3:"震",4:"巽",5:"中",6:"乾",7:"兑",8:"艮",9:"离"]
        let englishPalaces = ["Kan", "Kun", "Zhen", "Xun", "Center", "Qian", "Dui", "Gen", "Li"]
        for palace in 1...9 {
            let value = palace == 5 ? "地干\(earth[5] ?? "")；天禽随芮寄，星门神不入中" : "地\(earth[palace] ?? "") / 天\(sky[palace] ?? "") · \(stars[palace] ?? "") · \(doors[palace] ?? "") · \(spirits[palace] ?? "")"
            let label = palaceNames[palace] ?? ""
            let title = L10n.text("\(label)\(palace)宫", "\(englishPalaces[palace - 1]) palace \(palace)")
            let english = palace == 5
                ? "Earth stem \(NativeCalendar.stemBranch(earth[5] ?? "")); Tian Qin is hosted with Tian Rui."
                : "Earth \(NativeCalendar.stemBranch(earth[palace] ?? "")) / Heaven \(Self.skyStem(sky[palace] ?? "")) · \(Self.starName(stars[palace] ?? "")) · \(Self.doorName(doors[palace] ?? "")) · \(Self.spiritName(spirits[palace] ?? ""))"
            rows.append(.init(title, L10n.text(value, english)))
        }
        let doorMeaning: [String: (String, Double)] = [
            "休门": (L10n.text("值使休门，传统象征取休整、沟通与积蓄。", "The Rest Gate traditionally suggests taking a pause, communicating and building reserves."), 0.1),
            "生门": (L10n.text("值使生门，传统象征取生发、资源与循序推进。", "The Life Gate traditionally suggests growth, resources and gradual progress."), 0.3),
            "伤门": (L10n.text("值使伤门，传统象征提示行动中的摩擦与成本。", "The Injury Gate traditionally draws attention to friction and costs."), -0.2),
            "杜门": (L10n.text("值使杜门，传统象征取边界与收敛，宜先核对阻塞条件。", "The Blocked Gate traditionally points to boundaries. Check what might be blocking progress."), -0.15),
            "景门": (L10n.text("值使景门，传统象征取表达、文书和公开呈现。", "The View Gate traditionally suggests expression, documents and public presentation."), 0.1),
            "死门": (L10n.text("值使死门，传统象征取阶段收束与暂缓，不应解读为真实死亡。", "The Death Gate traditionally signifies closure or postponement. The name is symbolic."), -0.25),
            "惊门": (L10n.text("值使惊门，传统象征提示信息差与沟通分歧，宜先澄清。", "The Alarm Gate traditionally points to gaps in information and disagreement. Seek clarification."), -0.2),
            "开门": (L10n.text("值使开门，传统象征取开放、联络和行动机会。", "The Open Gate traditionally suggests openness, contact and opportunities to act."), 0.3)
        ]
        let meaning = doorMeaning[zhiShi] ?? (L10n.text("值使门只作盘面记录。", "The duty gate is recorded as a chart detail."), 0)
        return OracleResult(method: .qimen, status: .partial, headline: "\(configuration) · \(L10n.text(zhiFu, Self.starName(zhiFu))) / \(L10n.text(zhiShi, Self.doorName(zhiShi)))", rows: rows,
            evidence: [.init(id: "qimen-duty-door", statement: meaning.0 + L10n.text("仍需结合具体问题与用神，不能单以门名定结果。", " Consider the question and relevant chart focus. The gate alone cannot determine an outcome."), polarity: meaning.1, strength: 0.25, topic: "action")],
            limitations: [L10n.text("已排天地干、九星八门八神；本版尚未实现完整格局、暗干和应期，仅输出基础盘与值使门线索。", "This basic chart includes the Heaven and Earth stems, nine stars, eight gates, eight spirits and a duty gate cue. It does not provide a full interpretation, hidden stems or timing."), L10n.text("奇门流派存在差异，当前固定拆补与中五寄坤口径。", "Qi Men schools differ. This chart uses Chai Bu and places the center in Kun.")] + NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate),
            provenance: L10n.text("qfdk/qimen MIT转盘参考＋6tail/lunar-swift本地节气；BlindOracle Swift", "qfdk/qimen rotating chart reference (MIT) · 6tail/lunar-swift solar terms · BlindOracle Swift"))
    }
    private static let englishTerms = [
        "Winter Solstice", "Minor Cold", "Major Cold", "Start of Spring", "Rain Water", "Awakening of Insects",
        "Spring Equinox", "Clear and Bright", "Grain Rain", "Start of Summer", "Grain Full", "Grain in Ear",
        "Summer Solstice", "Minor Heat", "Major Heat", "Start of Autumn", "End of Heat", "White Dew",
        "Autumn Equinox", "Cold Dew", "Frost Descent", "Start of Winter", "Minor Snow", "Major Snow"
    ]

    private static func starName(_ value: String) -> String {
        ["天蓬": "Tian Peng", "天任": "Tian Ren", "天冲": "Tian Chong", "天辅": "Tian Fu",
         "天英": "Tian Ying", "禽芮": "Tian Qin / Tian Rui", "天柱": "Tian Zhu", "天心": "Tian Xin"][value] ?? value
    }

    private static func doorName(_ value: String) -> String {
        ["休门": "Rest Gate", "生门": "Life Gate", "伤门": "Injury Gate", "杜门": "Blocked Gate",
         "景门": "View Gate", "死门": "Death Gate", "惊门": "Alarm Gate", "开门": "Open Gate"][value] ?? value
    }

    private static func spiritName(_ value: String) -> String {
        ["值符": "Chief Spirit", "螣蛇": "Flying Serpent", "太阴": "Great Yin", "六合": "Six Harmonies",
         "白虎": "White Tiger", "玄武": "Black Tortoise", "九地": "Nine Earth", "九天": "Nine Heaven"][value] ?? value
    }

    private static func skyStem(_ value: String) -> String {
        value.split(separator: "/", maxSplits: 1).enumerated().map { index, part in
            if index == 0 { return NativeCalendar.stemBranch(String(part)) }
            let stem = part.replacingOccurrences(of: "（寄）", with: "")
            return NativeCalendar.stemBranch(stem) + " (hosted)"
        }.joined(separator: " / ")
    }
}
