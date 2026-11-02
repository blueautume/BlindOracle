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
        NativeCalendar.descriptor(.qimen, summary: "时家转盘拆补法，按当地起盘时间算节气、符头、三元、阴阳遁局、天地盘、九星、八门、八神。",
            optional: [.currentLocation], questions: ["行动节奏", "具体选择", "协作与沟通", "近期规划"],
            output: "节气/符头/三元/局数/旬首/值符/值使与逐宫天地干、星门神；值使门基础释义。",
            limitations: ["只支持时家转盘拆补，不混用置闰、茅山或飞盘。", "中五寄坤，值使由寄宫按九宫数顺逆加时。", "不含暗干、十干克应、完整格局取用及应期判断。"],
            source: "qfdk/qimen MIT转盘公式参考；6tail/lunar-swift节气；BlindOracle Swift移植", license: "MIT参考实现，保留Resources/Native/ThirdParty-Qimen.txt")
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard let solar = NativeCalendar.castingSolar(input) else { return NativeCalendar.unavailable(.qimen, "起盘时刻或时区无效，支持1900–2100年。") }
        let lunar = solar.lunar
        let term = lunar.prevJieQi.name
        guard let termIndex = Self.terms.firstIndex(of: term) else {
            return NativeCalendar.unavailable(.qimen, "当前节气\(term)未匹配本地定局表，未采用默认假局。")
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
            return NativeCalendar.unavailable(.qimen, "值符落宫校验失败。")
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
        var rows: [OracleRow] = [
            .init("排法", "时家转盘拆补 · 中五寄坤"),
            .init("起盘时间", solar.ymdhms + " · " + input.profile.currentTimeZoneID),
            .init("四柱", "\(lunar.yearInGanZhiExact) \(lunar.monthInGanZhiExact) \(lunar.dayInGanZhi) \(lunar.timeInGanZhi)"),
            .init("节气 / 三元", "\(term) · \(yuanNames[yuan])"),
            .init("上次交节", lunar.prevJieQi.solar.ymdhms + "（东八区历表）"),
            .init("符头", NativeCalendar.stems[headIndex % 10] + NativeCalendar.branches[headBranch]),
            .init("局数", "\(yang ? "阳遁" : "阴遁")\(ju)局"),
            .init("旬首六仪", "\(lunar.timeXun)遁\(hiddenStem)"),
            .init("值符", "\(zhiFu) · 原\(originRaw)宫（寄\(origin)宫）→ \(target)宫"),
            .init("值使", "\(zhiShi) → \(doorTargetRaw)宫\(doorTargetRaw == 5 ? "（寄坤2）" : "")")
        ]
        let palaceNames = [1:"坎",2:"坤",3:"震",4:"巽",5:"中",6:"乾",7:"兑",8:"艮",9:"离"]
        for palace in 1...9 {
            let value = palace == 5 ? "地干\(earth[5] ?? "")；天禽随芮寄，星门神不入中" : "地\(earth[palace] ?? "") / 天\(sky[palace] ?? "") · \(stars[palace] ?? "") · \(doors[palace] ?? "") · \(spirits[palace] ?? "")"
            rows.append(.init("\(palaceNames[palace] ?? "")\(palace)宫", value))
        }
        let doorMeaning: [String: (String, Double)] = [
            "休门": ("值使休门，传统象征取休整、沟通与积蓄。", 0.1),
            "生门": ("值使生门，传统象征取生发、资源与循序推进。", 0.3),
            "伤门": ("值使伤门，传统象征提示行动中的摩擦与成本。", -0.2),
            "杜门": ("值使杜门，传统象征取边界与收敛，宜先核对阻塞条件。", -0.15),
            "景门": ("值使景门，传统象征取表达、文书和公开呈现。", 0.1),
            "死门": ("值使死门，传统象征取阶段收束与暂缓，不应解读为真实死亡。", -0.25),
            "惊门": ("值使惊门，传统象征提示信息差与沟通分歧，宜先澄清。", -0.2),
            "开门": ("值使开门，传统象征取开放、联络和行动机会。", 0.3)
        ]
        let meaning = doorMeaning[zhiShi] ?? ("值使门只作盘面记录。", 0)
        return OracleResult(method: .qimen, status: .partial, headline: "\(yang ? "阳遁" : "阴遁")\(ju)局 · \(zhiFu) / \(zhiShi)", rows: rows,
            evidence: [.init(id: "qimen-duty-door", statement: meaning.0 + "仍需结合具体问题与用神，不能单以门名定结果。", polarity: meaning.1, strength: 0.25, topic: "action")],
            limitations: ["已排天地干、九星八门八神；本版尚未实现完整格局、暗干和应期，仅输出基础盘与值使门线索。", "奇门流派存在差异，当前固定拆补与中五寄坤口径。"] + NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate),
            provenance: "qfdk/qimen MIT转盘参考＋6tail/lunar-swift本地节气；BlindOracle Swift")
    }
}
