import Foundation

struct LiuyaoPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.liuyao, summary: L10n.text("三枚铜钱、大衍蓍草等价概率法或手动六爻起卦，按京房八宫纳甲排盘并查询本地周易卦爻辞。", "Cast with three coins, an equivalent yarrow-stalk simulation or six manually entered lines. The chart uses Jing Fang's Eight Palaces and Na Jia system and includes I Ching passages."),
            optional: [.currentLocation], questions: [L10n.text("具体事情", "Specific situations"), L10n.text("进退选择", "Decisions"), L10n.text("协作关系", "Working relationships"), L10n.text("近期变化", "Near-term changes")],
            output: L10n.text("六个爻值、本卦/变卦、八宫、世应、逐爻纳甲/六亲/六神、月破日冲/旬空、本卦卦辞、全部动爻爻辞及变卦卦辞。", "Six line values, original and resulting hexagrams, Eight Palaces, host and guest lines, line correspondences, clashes, void branches and relevant I Ching passages."),
            limitations: [L10n.text("castingStyle=nil/coins为铜钱法，6/7/8/9概率1/8、3/8、3/8、1/8；castingStyle=yarrow为大衍三变等价抽样，概率1/16、5/16、7/16、3/16。", "For lines 6, 7, 8 and 9, the coin method uses probabilities of 1/8, 3/8, 3/8 and 1/8. Yarrow simulation uses 1/16, 5/16, 7/16 and 3/16."), L10n.text("蓍草模拟按经典三变归奇的概率类抽样，不伪造逐根蓍草分堆。手动6爻优先于模拟。", "Yarrow simulation samples the traditional three-step outcome classes. Manual line values take precedence."), L10n.text("六爻值按初爻到上爻排列；只接受6、7、8、9。", "Lines are entered from bottom to top. The valid values are 6, 7, 8 and 9."), L10n.text("本版不自动选择用神，不做伏神、进退神与应期的完整断课。", "The method does not select a focus line or provide a full reading of hidden lines, advancing and retreating signs, or timing.")], source: L10n.text("BlindOracle Swift铜钱/大衍概率与京房纳甲；kentang2017/ichingshifa MIT卦爻辞录文；LunarSwift MIT历法", "BlindOracle Swift coin and yarrow probabilities and Jing Fang Na Jia · kentang2017/ichingshifa (MIT) · LunarSwift (MIT)"), license: L10n.text("原创Swift；LunarSwift MIT；卦爻辞上游MIT样式许可见ThirdParty-Iching.txt", "Original Swift implementation · LunarSwift (MIT). See ThirdParty-Iching.txt for the I Ching source license."))
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard let solar = NativeCalendar.castingSolar(input) else { return NativeCalendar.unavailable(.liuyao, L10n.text("需要有效起卦时间与时区，当前支持1900–2100年。", "A valid casting time and time zone in 1900–2100 are required.")) }
        let lunar = solar.lunar
        let values: [Int]
        let style: String
        var yarrowTrace: [String] = []
        if !input.manualLines.isEmpty {
            guard input.manualLines.count == 6, input.manualLines.allSatisfy({ (6...9).contains($0) }) else {
                return NativeCalendar.unavailable(.liuyao, L10n.text("手动爻值必须是6个6/7/8/9，自初爻至上爻。", "Enter six values from bottom to top. Each value must be 6, 7, 8 or 9."))
            }
            values = input.manualLines
            if input.interactionResponses?.contains(where: { $0.requestID == OracleMethod.liuyao.rawValue }) == true {
                style = input.castingStyle == "yarrow" ? L10n.text("用户逐爻归奇 · 本地大衍蓍草三变概率模拟", "User cast each line · on-device yarrow-stalk simulation") : L10n.text("用户逐次投掷 · 本地三枚铜钱模拟", "User tossed each line · on-device three-coin simulation")
            } else { style = L10n.text("用户手动爻值", "User-entered line values") }
        } else {
            var rng = OracleSeededRandom(seed: input.seed)
            switch input.castingStyle?.lowercased() ?? "coins" {
            case "coins":
                values = (0..<6).map { _ in Self.coinLine(using: &rng) }
                style = L10n.text("本地三枚铜钱模拟 · 已保存种子，可复现", "On-device three-coin simulation · reproducible from the saved seed")
            case "yarrow":
                var generated: [Int] = []
                for index in 0..<6 {
                    let cast = Self.yarrowCast(using: &rng)
                    generated.append(cast.value)
                    yarrowTrace.append(L10n.text("第\(index + 1)爻：49−\(cast.removals[0])−\(cast.removals[1])−\(cast.removals[2])＝\(cast.value * 4)，除4得\(cast.value)", "Line \(index + 1): (49 − \(cast.removals[0]) − \(cast.removals[1]) − \(cast.removals[2])) ÷ 4 = \(cast.value)"))
                }
                values = generated
                style = L10n.text("本地大衍蓍草三变概率等价模拟 · 已保存种子，可复现", "On-device three-step yarrow simulation · reproducible from the saved seed")
            default:
                return NativeCalendar.unavailable(.liuyao, L10n.text("起卦方式只支持coins或yarrow；未以其他方式代算。", "Choose coins or yarrow for a simulated cast."))
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
            .init(L10n.text("起卦方式", "Casting method"), style), .init(L10n.text("爻值（初→上）", "Line values (bottom to top)"), values.map(String.init).joined(separator: " ")),
            .init(L10n.text("起卦干支", "Casting stems and branches"), L10n.text("\(lunar.monthInGanZhiExact)月 \(lunar.dayInGanZhi)日 \(lunar.timeInGanZhi)时", "Month: \(NativeCalendar.stemBranch(lunar.monthInGanZhiExact)) · Day: \(NativeCalendar.stemBranch(lunar.dayInGanZhi)) · Hour: \(NativeCalendar.stemBranch(lunar.timeInGanZhi))")),
            .init(L10n.text("本卦", "Original hexagram"), NativeHexagrams.displayName(original)), .init(L10n.text("变卦", "Resulting hexagram"), NativeHexagrams.displayName(changed)),
            .init(L10n.text("八宫", "Eight Palaces"), L10n.text("\(NativeHexagrams.trigramNames[palace.trigram])宫 · \(NativeCalendar.elements[palaceElement]) · \(palace.stage)", "\(NativeHexagrams.trigram(palace.trigram)) palace · \(NativeCalendar.element(palaceElement)) · \(Self.palaceStage(palace.stage))")),
            .init(L10n.text("世应", "Host and guest"), L10n.text("世爻\(palace.shi) / 应爻\((palace.shi + 2) % 6 + 1)", "Host line \(palace.shi) / guest line \((palace.shi + 2) % 6 + 1)")),
            .init(L10n.text("旬空", "Void branches"), NativeCalendar.stemBranch(lunar.dayXunKong)), .init(L10n.text("卦象（自上而下）", "Hexagram (top to bottom)"), NativeHexagrams.diagram(original, moving: moving))
        ]
        if !yarrowTrace.isEmpty { rows.append(.init(L10n.text("蓍草三变归奇过程", "Three-step yarrow calculation"), yarrowTrace.joined(separator: "\n"))) }
        var shiBranch = 0
        let names = ["初", "二", "三", "四", "五", "上"]
        for index in (0..<6).reversed() {
            let trigram = index < 3 ? lower : upper
            let info = Self.najia(trigram: trigram, upper: index >= 3)
            let branch = info.branches[index % 3]
            let relation = Self.relative(palace: palaceElement, branch: NativeCalendar.branchElements[branch])
            var annotations: [String] = []
            if index + 1 == palace.shi { annotations.append(L10n.text("世", "Host")); shiBranch = branch }
            if index + 1 == (palace.shi + 2) % 6 + 1 { annotations.append(L10n.text("应", "Guest")) }
            if moving.contains(index + 1) { annotations.append(L10n.text("动", "Changing")) }
            if NativeCalendar.mod(branch - lunar.monthZhiIndexExact, 12) == 6 { annotations.append(L10n.text("月破", "Month break")) }
            if NativeCalendar.mod(branch - lunar.dayZhiIndex, 12) == 6 { annotations.append(L10n.text("日冲", "Day clash")) }
            if lunar.dayXunKong.contains(NativeCalendar.branches[branch]) { annotations.append(L10n.text("旬空", "Void branches")) }
            let pillars = info.stem + NativeCalendar.branches[branch]
            let element = NativeCalendar.element(NativeCalendar.branchElements[branch])
            let spirit = spirits[(spiritStart + index) % 6]
            let correspondences = L10n.text("\(pillars)\(element) · \(relation) · \(spirit)",
                                            "\(NativeCalendar.stemBranch(pillars)) · \(element) · \(Self.relativeName(relation)) · \(Self.spiritName(spirit))")
            let value = correspondences + (annotations.isEmpty ? "" : " · " + annotations.joined(separator: "/"))
            rows.append(.init(L10n.text("\(names[index])爻", "Line \(index + 1)"), value))
        }
        let shiElement = NativeCalendar.branchElements[shiBranch]
        let monthElement = NativeCalendar.branchElements[lunar.monthZhiIndexExact]
        let relation = NativeHexagrams.relationship(body: shiElement, use: monthElement)
        var evidence: [OracleEvidence] = [
            .init(id: "liuyao-movement", statement: L10n.text("本卦\(NativeHexagrams.displayName(original))，\(moving.isEmpty ? "六爻皆静" : "动爻为" + moving.sorted().map(String.init).joined(separator: "、"))。动静只表示此套起卦规则的结构。",
                       "Original hexagram: \(NativeHexagrams.displayName(original)). \(moving.isEmpty ? "All six lines are still" : "Changing lines: " + moving.sorted().map(String.init).joined(separator: ", ")). This describes the cast structure."), strength: 0.3, topic: "change"),
            .init(id: "liuyao-month-shi", statement: L10n.text("以世爻为主体、月建五行为背景：\(relation.0)。\(relation.2)尚未结合用神、日辰及所有合冲综合定断。",
                       "The host line is the subject and the month element is the context: \(relation.0). \(relation.2) This does not combine the focus line, day or all combinations and clashes."), polarity: relation.1, strength: 0.25, topic: "action")
        ]
        if NativeCalendar.mod(shiBranch - lunar.monthZhiIndexExact, 12) == 6 {
            evidence.append(.init(id: "liuyao-shi-yuepo", statement: L10n.text("世爻与月建相冲，按月破规则应多留意条件变化，不能据此认定事情必败。", "The host line clashes with the month branch. The month-break rule calls attention to changing conditions; it does not establish failure."), polarity: -0.25, strength: 0.3, topic: "action"))
        }
        let classical = NativeHexagrams.classicalReading(original: original, changed: changed, moving: moving)
        rows += classical.rows
        evidence += classical.evidence
        return OracleResult(method: .liuyao, status: .partial, headline: "\(NativeHexagrams.displayName(original)) → \(NativeHexagrams.displayName(changed))", rows: rows, evidence: evidence,
            limitations: [L10n.text("已完成京房八宫基础纳甲排盘与典籍取文；未完成用神取值、伏神、完整生克制化与应期，不作为完整断课。", "Includes the basic Jing Fang Na Jia chart and classical texts. Focus-line selection, hidden lines, full element interactions and timing are outside this reading's scope."), L10n.text("随机种子只用于复现数字起卦，不代表观测到现实信息。", "The random seed allows the digital cast to be reproduced. It is not an observation of real conditions.")] + classical.limitations + NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate),
            provenance: L10n.text("BlindOracle Swift · 铜钱/大衍概率 / 京房八宫纳甲 / 周易64卦384爻辞本地MIT录文", "BlindOracle Swift · coin and yarrow probabilities / Jing Fang Eight Palaces and Na Jia / local I Ching collection of 64 hexagrams and 384 lines (MIT)"))
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
    private static func palaceStage(_ value: String) -> String {
        ["本宫": "Base", "一世": "First", "二世": "Second", "三世": "Third", "四世": "Fourth",
         "五世": "Fifth", "游魂": "Wandering Soul", "归魂": "Returning Soul"][value] ?? value
    }

    private static func relativeName(_ value: String) -> String {
        ["兄弟": "Siblings", "父母": "Parents", "子孙": "Descendants", "官鬼": "Officials and Ghosts", "妻财": "Spouse and Wealth"][value] ?? value
    }

    private static func spiritName(_ value: String) -> String {
        ["青龙": "Azure Dragon", "朱雀": "Vermilion Bird", "勾陈": "Gou Chen", "螣蛇": "Flying Serpent", "白虎": "White Tiger", "玄武": "Black Tortoise"][value] ?? value
    }
}
