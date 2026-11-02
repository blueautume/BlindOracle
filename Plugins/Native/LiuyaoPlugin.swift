import Foundation

struct LiuyaoPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.liuyao, summary: "三枚铜钱、大衍蓍草等价概率法或手动六爻起卦，按京房八宫纳甲排盘并查询本地周易卦爻辞。",
            optional: [.currentLocation], questions: ["具体事情", "进退选择", "协作关系", "近期变化"],
            output: "六个爻值、本卦/变卦、八宫、世应、逐爻纳甲/六亲/六神、月破日冲/旬空、本卦卦辞、全部动爻爻辞及变卦卦辞。",
            limitations: ["castingStyle=nil/coins为铜钱法，6/7/8/9概率1/8、3/8、3/8、1/8；castingStyle=yarrow为大衍三变等价抽样，概率1/16、5/16、7/16、3/16。", "蓍草模拟按经典三变归奇的概率类抽样，不伪造逐根蓍草分堆。手动6爻优先于模拟。", "六爻值按初爻到上爻排列；只接受6、7、8、9。", "本版不自动选择用神，不做伏神、进退神与应期的完整断课。"], source: "BlindOracle Swift铜钱/大衍概率与京房纳甲；kentang2017/ichingshifa MIT卦爻辞录文；LunarSwift MIT历法", license: "原创Swift；LunarSwift MIT；卦爻辞上游MIT样式许可见ThirdParty-Iching.txt")
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard let solar = NativeCalendar.castingSolar(input) else { return NativeCalendar.unavailable(.liuyao, "需要有效起卦时间与时区，当前支持1900–2100年。") }
        let lunar = solar.lunar
        let values: [Int]
        let style: String
        var yarrowTrace: [String] = []
        if !input.manualLines.isEmpty {
            guard input.manualLines.count == 6, input.manualLines.allSatisfy({ (6...9).contains($0) }) else {
                return NativeCalendar.unavailable(.liuyao, "手动爻值必须是6个6/7/8/9，自初爻至上爻。")
            }
            values = input.manualLines
            style = "用户手动爻值"
        } else {
            var rng = OracleSeededRandom(seed: input.seed)
            switch input.castingStyle?.lowercased() ?? "coins" {
            case "coins":
                values = (0..<6).map { _ in Self.coinLine(using: &rng) }
                style = "本地三枚铜钱模拟 · 已保存种子，可复现"
            case "yarrow":
                var generated: [Int] = []
                for index in 0..<6 {
                    let cast = Self.yarrowCast(using: &rng)
                    generated.append(cast.value)
                    yarrowTrace.append("第\(index + 1)爻：49−\(cast.removals[0])−\(cast.removals[1])−\(cast.removals[2])＝\(cast.value * 4)，除4得\(cast.value)")
                }
                values = generated
                style = "本地大衍蓍草三变概率等价模拟 · 已保存种子，可复现"
            default:
                return NativeCalendar.unavailable(.liuyao, "起卦方式只支持coins或yarrow；未以其他方式代算。")
            }
        }
        let original = values.enumerated().reduce(0) { $0 | (($1.element == 7 || $1.element == 9) ? (1 << $1.offset) : 0) }
        let moving = Set(values.enumerated().filter { $0.element == 6 || $0.element == 9 }.map { $0.offset + 1 })
        let changed = moving.reduce(original) { $0 ^ (1 << ($1 - 1)) }
        let palace = Self.palace(original)
        let lower = original & 7, upper = (original >> 3) & 7
        let palaceElement = NativeHexagrams.trigramElements[palace.trigram]
        let spirits = ["青龙", "朱雀", "勾陈", "螣蛇", "白虎", "玄武"]
        let spiritStart = [0, 0, 1, 1, 2, 3, 4, 4, 5, 5][lunar.dayGanIndex]
        var rows: [OracleRow] = [
            .init("起卦方式", style), .init("爻值（初→上）", values.map(String.init).joined(separator: " ")),
            .init("起卦干支", "\(lunar.monthInGanZhiExact)月 \(lunar.dayInGanZhi)日 \(lunar.timeInGanZhi)时"),
            .init("本卦", NativeHexagrams.name(original)), .init("变卦", NativeHexagrams.name(changed)),
            .init("八宫", "\(NativeHexagrams.trigramNames[palace.trigram])宫 · \(NativeCalendar.elements[palaceElement]) · \(palace.stage)"),
            .init("世应", "世爻\(palace.shi) / 应爻\((palace.shi + 2) % 6 + 1)"),
            .init("旬空", lunar.dayXunKong), .init("卦象（自上而下）", NativeHexagrams.diagram(original, moving: moving))
        ]
        if !yarrowTrace.isEmpty { rows.append(.init("蓍草三变归奇过程", yarrowTrace.joined(separator: "\n"))) }
        var shiBranch = 0
        let names = ["初", "二", "三", "四", "五", "上"]
        for index in (0..<6).reversed() {
            let trigram = index < 3 ? lower : upper
            let info = Self.najia(trigram: trigram, upper: index >= 3)
            let branch = info.branches[index % 3]
            let relation = Self.relative(palace: palaceElement, branch: NativeCalendar.branchElements[branch])
            var annotations: [String] = []
            if index + 1 == palace.shi { annotations.append("世"); shiBranch = branch }
            if index + 1 == (palace.shi + 2) % 6 + 1 { annotations.append("应") }
            if moving.contains(index + 1) { annotations.append("动") }
            if NativeCalendar.mod(branch - lunar.monthZhiIndexExact, 12) == 6 { annotations.append("月破") }
            if NativeCalendar.mod(branch - lunar.dayZhiIndex, 12) == 6 { annotations.append("日冲") }
            if lunar.dayXunKong.contains(NativeCalendar.branches[branch]) { annotations.append("旬空") }
            let value = "\(info.stem)\(NativeCalendar.branches[branch])\(NativeCalendar.elements[NativeCalendar.branchElements[branch]]) · \(relation) · \(spirits[(spiritStart + index) % 6])" + (annotations.isEmpty ? "" : " · " + annotations.joined(separator: "/"))
            rows.append(.init("\(names[index])爻", value))
        }
        let shiElement = NativeCalendar.branchElements[shiBranch]
        let monthElement = NativeCalendar.branchElements[lunar.monthZhiIndexExact]
        let relation = NativeHexagrams.relationship(body: shiElement, use: monthElement)
        var evidence: [OracleEvidence] = [
            .init(id: "liuyao-movement", statement: "本卦\(NativeHexagrams.name(original))，\(moving.isEmpty ? "六爻皆静" : "动爻为" + moving.sorted().map(String.init).joined(separator: "、"))。动静只表示此套起卦规则的结构。", strength: 0.3, topic: "change"),
            .init(id: "liuyao-month-shi", statement: "以世爻为主体、月建五行为背景：\(relation.0)。\(relation.2)尚未结合用神、日辰及所有合冲综合定断。", polarity: relation.1, strength: 0.25, topic: "action")
        ]
        if NativeCalendar.mod(shiBranch - lunar.monthZhiIndexExact, 12) == 6 {
            evidence.append(.init(id: "liuyao-shi-yuepo", statement: "世爻与月建相冲，按月破规则应多留意条件变化，不能据此认定事情必败。", polarity: -0.25, strength: 0.3, topic: "action"))
        }
        let classical = NativeHexagrams.classicalReading(original: original, changed: changed, moving: moving)
        rows += classical.rows
        evidence += classical.evidence
        return OracleResult(method: .liuyao, status: .partial, headline: "\(NativeHexagrams.name(original)) → \(NativeHexagrams.name(changed))", rows: rows, evidence: evidence,
            limitations: ["已完成京房八宫基础纳甲排盘与典籍取文；未完成用神取值、伏神、完整生克制化与应期，不作为完整断课。", "随机种子只用于复现数字起卦，不代表观测到现实信息。"] + classical.limitations + NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate),
            provenance: "BlindOracle Swift · 铜钱/大衍概率 / 京房八宫纳甲 / 周易64卦384爻辞本地MIT录文")
    }
    static func coinLine<R: RandomNumberGenerator>(using rng: inout R) -> Int {
        (0..<3).reduce(0) { sum, _ in sum + Int.random(in: 2...3, using: &rng) }
    }
    /// Classical remainder-class sampling: first removal is 5:9 with 3:1
    /// probability, subsequent removals are 4:8 with 1:1 probability each.
    /// Dividing the remaining stalks by four gives 6/7/8/9 = 1/5/7/3 out of 16.
    static func yarrowCast<R: RandomNumberGenerator>(using rng: inout R) -> (value: Int, removals: [Int]) {
        let first = Int.random(in: 0..<4, using: &rng) == 0 ? 9 : 5
        let second = Bool.random(using: &rng) ? 4 : 8
        let third = Bool.random(using: &rng) ? 4 : 8
        return ((49 - first - second - third) / 4, [first, second, third])
    }
    static func yarrowLine<R: RandomNumberGenerator>(using rng: inout R) -> Int { yarrowCast(using: &rng).value }
    static func palace(_ bits: Int) -> (trigram: Int, shi: Int, stage: String) {
        let masks = [0, 1, 3, 7, 15, 31, 23, 16]
        let shi = [6, 1, 2, 3, 4, 5, 4, 3]
        let stage = ["本宫", "一世", "二世", "三世", "四世", "五世", "游魂", "归魂"]
        for trigram in 0..<8 {
            let base = trigram | (trigram << 3)
            for index in 0..<8 where base ^ masks[index] == bits { return (trigram, shi[index], stage[index]) }
        }
        return (7, 6, "本宫")
    }
    private static func najia(trigram: Int, upper: Bool) -> (stem: String, branches: [Int]) {
        let inside = [[7,5,3],[0,2,4],[2,4,6],[5,3,1],[4,6,8],[3,1,11],[1,11,9],[0,2,4]]
        let outside = [[1,11,9],[6,8,10],[8,10,0],[11,9,7],[10,0,2],[9,7,5],[7,5,3],[6,8,10]]
        let stemsIn = ["乙","庚","戊","丁","丙","己","辛","甲"]
        let stemsOut = ["癸","庚","戊","丁","丙","己","辛","壬"]
        return (upper ? stemsOut[trigram] : stemsIn[trigram], upper ? outside[trigram] : inside[trigram])
    }
    private static func relative(palace: Int, branch: Int) -> String {
        if palace == branch { return "兄弟" }
        if (branch + 1) % 5 == palace { return "父母" }
        if (palace + 1) % 5 == branch { return "子孙" }
        if (branch + 2) % 5 == palace { return "官鬼" }
        return "妻财"
    }
}
