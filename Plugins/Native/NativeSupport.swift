import Foundation

enum NativePlugins {
    static var all: [any OraclePlugin] {
        [BaziPlugin(), LiuyaoPlugin(), MeihuaPlugin(), QimenPlugin(), XiaoliurenPlugin(), ChengguPlugin(), XingmingPlugin(), TarotPlugin()]
    }
}

enum NativeCalendar {
    static let stems = Array("甲乙丙丁戊己庚辛壬癸").map(String.init)
    static let branches = Array("子丑寅卯辰巳午未申酉戌亥").map(String.init)
    static let elements = ["木", "火", "土", "金", "水"]
    static let branchElements = [4, 2, 0, 0, 2, 1, 1, 2, 3, 3, 2, 4]
    private static let stemNames = ["Jia", "Yi", "Bing", "Ding", "Wu", "Ji", "Geng", "Xin", "Ren", "Gui"]
    private static let branchNames = ["Zi", "Chou", "Yin", "Mao", "Chen", "Si", "Wu", "Wei", "Shen", "You", "Xu", "Hai"]
    private static let elementNames = ["Wood", "Fire", "Earth", "Metal", "Water"]

    static func element(_ index: Int) -> String {
        L10n.text(elements[index], elementNames[index])
    }

    /// Chart identifiers remain in their original form for calculations.
    static func stemBranch(_ value: String, separator: String = " ") -> String {
        guard AppLanguage.current.isEnglish else { return value }
        return value.map { character in
            let key = String(character)
            if let index = stems.firstIndex(of: key) { return stemNames[index] }
            if let index = branches.firstIndex(of: key) { return branchNames[index] }
            return key
        }.joined(separator: separator)
    }

    static func fiveElements(_ value: String) -> String {
        guard AppLanguage.current.isEnglish else { return value }
        return value.map { character in
            elements.firstIndex(of: String(character)).map(element) ?? String(character)
        }.joined(separator: " / ")
    }

    static func lunarDate(_ lunar: Lunar, includeYear: Bool = true) -> String {
        let chinese = (includeYear ? lunar.yearInChinese + "年" : "") + lunar.monthInChinese + "月" + lunar.dayInChinese
        return L10n.text(chinese,
                         (includeYear ? "\(lunar.year) · " : "") + (lunar.month < 0 ? "Leap month " : "Month ") + "\(abs(lunar.month)), day \(lunar.day)")
    }

    static func pinyin(_ value: String) -> String {
        guard AppLanguage.current.isEnglish,
              value.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return value }
        return value.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? value
    }

    static func mod(_ n: Int, _ d: Int) -> Int { (n % d + d) % d }
    static func solar(_ date: Date, timeZoneID: String) -> Solar? {
        guard date.timeIntervalSince1970.isFinite, let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, (1900...2100).contains(year), let month = c.month, let day = c.day else { return nil }
        return Solar(year: year, month: month, day: day, hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }
    static func castingSolar(_ input: OracleInput) -> Solar? {
        solar(input.castingDate, timeZoneID: input.profile.currentTimeZoneID)
    }
    static func timezoneLimit(_ zone: String, date: Date = Date()) -> [String] {
        let offset = TimeZone(identifier: zone)?.secondsFromGMT(for: date) ?? 0
        return offset == 28_800 ? [] : [L10n.text("本版农历与交节表以东八区为基准；非东八区的交节与农历日期边界尚未逐项校准。", "The lunar calendar and solar-term tables use UTC+8. Local boundaries in other time zones have not been individually calibrated.")]
    }
    static func unavailable(_ method: OracleMethod, _ reason: String) -> OracleResult {
        OracleResult(method: method, status: .unavailable, headline: L10n.text("资料不足，暂不推算", "More information is needed"), rows: [], limitations: [reason])
    }
    static func descriptor(_ method: OracleMethod, summary: String, required: [OracleField] = [], optional: [OracleField] = [], questions: [String], output: String, limitations: [String] = [], source: String = L10n.text("瞎子独立 Swift 实现；历法：6tail/lunar-swift", "BlindOracle Swift implementation · Calendar: 6tail/lunar-swift"), license: String = L10n.text("原创实现；LunarSwift MIT", "Original implementation · LunarSwift, MIT")) -> OraclePluginDescriptor {
        OraclePluginDescriptor(method: method, version: "1.0.0", summary: summary, requiredFields: required,
                               optionalFields: optional, supportedQuestions: questions, outputDescription: output,
                               limitations: [L10n.text("传统规则的结构化演算，不代表经验证的事件概率。", "The calculation follows traditional symbolic rules. Its results do not measure the probability of real events.")] + limitations,
                               source: source, license: license)
    }
    static func resource(_ name: String, extension ext: String) -> URL? {
        for directory in [nil, "Native", "Resources/Native"] as [String?] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: directory) { return url }
        }
        return nil
    }
    static func dateLabel(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.timeZone = TimeZone(identifier: zone)
        if AppLanguage.current.isEnglish { formatter.setLocalizedDateFormatFromTemplate("yMMMdjm") }
        else { formatter.dateFormat = "yyyy-MM-dd HH:mm" }
        return formatter.string(from: date)
    }
    static func jiaziIndex(_ ganzhi: String) -> Int {
        let chars = Array(ganzhi).map(String.init)
        guard chars.count >= 2, let stem = stems.firstIndex(of: chars[0]), let branch = branches.firstIndex(of: chars[1]) else { return 0 }
        return (0..<60).first { $0 % 10 == stem && $0 % 12 == branch } ?? 0
    }
}

struct OracleSeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum NativeHexagrams {
    struct ClassicalText: Decodable {
        let bits: Int
        let name: String
        let judgment: String
        let lines: [String]
        let tuan: String
        let specialUse: String?
    }
    private struct ClassicalArchive: Decodable { let entries: [ClassicalText] }
    static let classicalTexts: [Int: ClassicalText] = {
        guard let url = NativeCalendar.resource("iching-texts", extension: "json"),
              let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(ClassicalArchive.self, from: data),
              archive.entries.count == 64,
              Set(archive.entries.map(\.bits)) == Set(0..<64),
              archive.entries.allSatisfy({ $0.lines.count == 6 && !$0.judgment.isEmpty && $0.lines.allSatisfy { !$0.isEmpty } }) else { return [:] }
        return Dictionary(uniqueKeysWithValues: archive.entries.map { ($0.bits, $0) })
    }()

    private struct EnglishNote: Decodable {
        var judgment: String
        var specialUse: String?
    }

    /// Notes are keyed by the original hexagram bits, not by their translated title.
    private static let englishNotes: [String: EnglishNote] = {
        guard let url = NativeCalendar.resource("iching-english-notes", extension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([String: EnglishNote].self, from: data) else { return [:] }
        return notes
    }()

    private static func sourceText(_ original: String, note: String?) -> String {
        guard AppLanguage.current.isEnglish, let note else { return original }
        return note + "\n\nClassical Chinese:\n" + original
    }

    /// Retains classical text as text, rather than converting individual words
    /// such as "吉/凶" into an event probability or automatic polarity vote.
    static func classicalReading(original: Int, changed: Int, moving: Set<Int>) -> (rows: [OracleRow], evidence: [OracleEvidence], limitations: [String], available: Bool) {
        guard let originalText = classicalTexts[original], let changedText = classicalTexts[changed] else {
            return ([.init(L10n.text("典籍资料", "Classical source"), L10n.text("本地卦爻辞库未正确安装，未补造原文", "The local I Ching text could not be loaded."))], [], [L10n.text("本地64卦/384爻辞未完整加载，仅保留数学排盘结果。", "The local collection of 64 hexagrams and 384 lines could not be loaded. Only the calculated chart is available.")], false)
        }
        let originalName = displayName(original)
        let changedName = displayName(changed)
        let originalNote = englishNotes[String(original)]
        let changedNote = englishNotes[String(changed)]
        let originalJudgment = sourceText(originalText.judgment, note: originalNote?.judgment)
        var rows: [OracleRow] = [.init(L10n.text("本卦卦辞", "Original hexagram judgment"),
                                         L10n.text("\(originalText.name)卦：\(originalText.judgment)", "\(originalName): \(originalJudgment)"))]
        var excerpts = [L10n.text("本卦《\(originalText.name)》：\(originalText.judgment)", "Original hexagram \(originalName): \(originalJudgment)")]
        for line in moving.sorted() where (1...6).contains(line) {
            let text = originalText.lines[line - 1]
            rows.append(.init(L10n.text("动爻第\(line)爻爻辞", "Changing line \(line) · classical Chinese"), text))
            excerpts.append(L10n.text(text, "Changing line \(line), classical Chinese: \(text)"))
        }
        if moving.isEmpty { rows.append(.init(L10n.text("动爻取文说明", "Changing lines"), L10n.text("六爻皆静，没有动爻爻辞；保留本卦卦辞作文本参考。", "All six lines are still. The original hexagram judgment is the textual reference."))) }
        if moving.count == 6, let special = originalText.specialUse {
            let specialText = sourceText(special, note: originalNote?.specialUse)
            rows.append(.init(L10n.text("乾坤全变特别用辞", "Special passage when all six lines change"), specialText))
            excerpts.append(specialText)
        }
        let changedJudgment = sourceText(changedText.judgment, note: changedNote?.judgment)
        rows.append(.init(L10n.text("变卦卦辞", "Resulting hexagram judgment"),
                          L10n.text("\(changedText.name)卦：\(changedText.judgment)", "\(changedName): \(changedJudgment)")))
        if original != changed {
            excerpts.append(L10n.text("变卦《\(changedText.name)》：\(changedText.judgment)", "Resulting hexagram \(changedName): \(changedJudgment)"))
        }
        var limitations = [L10n.text("卦爻辞采用公版古文录文，保留异体字与标点，尚未逐字校勘；古代象辞不作为现实事件的事实断言。", "The English notes summarize the classical source. The original passages preserve variant characters and punctuation and have not been critically edited.")]
        if moving.count > 1 { limitations.append(L10n.text("多爻变时列出全部动爻原文，未指定某一爻为唯一主断，不混入未实现的变占取辞流派。", "When several lines change, all their original passages are included without selecting one as decisive.")) }
        return (rows, [.init(id: "iching-classical-\(original)-\(changed)", statement: excerpts.joined(separator: "\n"), strength: 0.3, topic: "classical-text")], limitations, true)
    }

    /// Six bits, initial line at bit zero. Trigram bits use bottom-to-top order.
    static let orderedBits = [7, 3, 5, 1, 6, 2, 4, 0]
    static let trigramNames = ["坤", "震", "坎", "兑", "艮", "离", "巽", "乾"]
    static let trigramElements = [2, 0, 4, 3, 2, 1, 0, 3]
    static let table = [
        ["乾为天", "天泽履", "天火同人", "天雷无妄", "天风姤", "天水讼", "天山遁", "天地否"],
        ["泽天夬", "兑为泽", "泽火革", "泽雷随", "泽风大过", "泽水困", "泽山咸", "泽地萃"],
        ["火天大有", "火泽睽", "离为火", "火雷噬嗑", "火风鼎", "火水未济", "火山旅", "火地晋"],
        ["雷天大壮", "雷泽归妹", "雷火丰", "震为雷", "雷风恒", "雷水解", "雷山小过", "雷地豫"],
        ["风天小畜", "风泽中孚", "风火家人", "风雷益", "巽为风", "风水涣", "风山渐", "风地观"],
        ["水天需", "水泽节", "水火既济", "水雷屯", "水风井", "坎为水", "水山蹇", "水地比"],
        ["山天大畜", "山泽损", "山火贲", "山雷颐", "山风蛊", "山水蒙", "艮为山", "山地剥"],
        ["地天泰", "地泽临", "地火明夷", "地雷复", "地风升", "地水师", "地山谦", "坤为地"]
    ]
    static func name(_ bits: Int) -> String {
        let lower = orderedBits.firstIndex(of: bits & 7) ?? 0
        let upper = orderedBits.firstIndex(of: (bits >> 3) & 7) ?? 0
        return table[upper][lower]
    }
    private static let englishHexagrams = [
        ["The Creative", "Treading", "Fellowship", "Innocence", "Coming to Meet", "Conflict", "Retreat", "Standstill"],
        ["Breakthrough", "The Joyous", "Revolution", "Following", "Great Exceeding", "Oppression", "Influence", "Gathering"],
        ["Great Possession", "Opposition", "The Clinging", "Biting Through", "The Cauldron", "Before Completion", "The Wanderer", "Progress"],
        ["Great Power", "The Marrying Maiden", "Abundance", "The Arousing", "Duration", "Deliverance", "Small Exceeding", "Enthusiasm"],
        ["Small Taming", "Inner Truth", "The Family", "Increase", "The Gentle", "Dispersion", "Gradual Development", "Contemplation"],
        ["Waiting", "Limitation", "After Completion", "Difficulty at the Beginning", "The Well", "The Abysmal", "Obstruction", "Holding Together"],
        ["Great Taming", "Decrease", "Grace", "Nourishment", "Work on What Has Been Spoiled", "Youthful Folly", "Keeping Still", "Splitting Apart"],
        ["Peace", "Approach", "Darkening of the Light", "Return", "Pushing Upward", "The Army", "Modesty", "The Receptive"]
    ]
    static func displayName(_ bits: Int) -> String {
        let lower = orderedBits.firstIndex(of: bits & 7) ?? 0
        let upper = orderedBits.firstIndex(of: (bits >> 3) & 7) ?? 0
        return L10n.text(table[upper][lower], englishHexagrams[upper][lower])
    }
    static func trigram(_ index: Int) -> String {
        L10n.text(trigramNames[index], ["Kun", "Zhen", "Kan", "Dui", "Gen", "Li", "Xun", "Qian"][index])
    }

    static func diagram(_ bits: Int, moving: Set<Int> = []) -> String {
        (0..<6).reversed().map { index in
            let yang = bits & (1 << index) != 0
            return (yang ? "━━━━━━" : "━━  ━━") + (moving.contains(index + 1) ? "  ◦" : "")
        }.joined(separator: "\n")
    }
    static func relationship(body: Int, use: Int) -> (String, Double, String) {
        if body == use { return (L10n.text("体用比和", "Body and Use share an element"), 0.25, L10n.text("双方同属一行，传统规则取协同、平稳之象。", "Both share an element, traditionally associated with cooperation and stability.")) }
        if (use + 1) % 5 == body { return (L10n.text("用生体", "Use supports Body"), 0.4, L10n.text("外在条件生扶主体，可留意支持与资源。", "External conditions support the subject. Look for help or resources.")) }
        if (body + 1) % 5 == use { return (L10n.text("体生用", "Body supports Use"), -0.2, L10n.text("主体向外耗泄，宜先分配精力与成本。", "The subject gives energy to the situation. Consider how to allocate effort and cost.")) }
        if (body + 2) % 5 == use { return (L10n.text("体克用", "Body restrains Use"), 0.15, L10n.text("主体约束外部，仍需结合实际能力判断。", "The subject restrains the situation. Consider what is within your practical ability.")) }
        return (L10n.text("用克体", "Use restrains Body"), -0.4, L10n.text("外在条件对主体形成约束，宜审视阻力与边界。", "The situation constrains the subject. Consider barriers and boundaries."))
    }
}
