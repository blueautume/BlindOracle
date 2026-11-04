import Foundation

struct XingmingPlugin: OraclePlugin {
    // Decimal scalar keys keep canonically equivalent compatibility ideographs
    // separate, including pairs with different recorded Kangxi counts.
    private static let kangxi: [UInt32: Int] = {
        guard let url = NativeCalendar.resource("kangxi-strokes", extension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data), raw.count == 63_696 else { return [:] }
        var table: [UInt32: Int] = [:]
        for (key, value) in raw {
            guard let scalar = UInt32(key), (1...80).contains(value) else { return [:] }
            table[scalar] = value
        }
        return table.count == 63_696 ? table : [:]
    }()
    static func kangxiCount(_ character: Character) -> Int? {
        let scalars = String(character).unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        return kangxi[scalar.value]
    }
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.xingming, summary: L10n.text("以本地63,696字康熙部首笔画表计算五格与三才。系统繁体转换只产生候选，未确认字形则保留partial。", "Calculates the Five Grids and Three Talents from an on-device table of 63,696 Kangxi character stroke counts. An unconfirmed traditional spelling produces a partial result."),
            required: [.surname, .givenName], questions: [L10n.text("姓名文化参考", "Traditional name symbolism"), L10n.text("名字结构", "Name structure")],
            output: L10n.text("原输入字形/笔画、实际计算字形/笔画、天格/人格/地格/外格/总格、三才五行；数据源和字形不确定性。", "Shows the characters and stroke counts as entered and as calculated, the five grids, the Three Talents elements, and any uncertainty about character forms."),
            limitations: [L10n.text("请填写已确认的繁体姓名。简体经ICU转换所得繁体只是候选；有字形变化时返回partial，明确展示两种写法。", "Enter the name in confirmed traditional Chinese characters. Conversion from simplified characters yields a candidate. If characters change, both spellings are shown and the result is partial."), L10n.text("康熙表按精确Unicode码点读数，不将兼容字规范化合并；资料为部首笔画录文，未全量古籍校勘。", "The Kangxi table uses exact Unicode code points and keeps compatibility characters distinct. The source transcription has not been fully collated against historical editions."), L10n.text("主表缺失时才降级到现代笔画表，降级始终partial；缺字不猜。", "The modern stroke table is a partial fallback if the Kangxi table is missing. The app does not estimate unknown counts."), L10n.text("不使用数意姓名学的五=5/七=7等替换，不输出个人品格、能力或必然命运判断。", "The method does not substitute numeral values for stroke counts or assess character, ability or fate.")],
            source: L10n.text("breezyreeds/kangxi-strokecount MIT，63,696字码点表；ICU繁体候选；modern fallback为chinese-character-strokes 0.0.3 ISC", "breezyreeds/kangxi-strokecount, 63,696 code points (MIT) · ICU character conversion · chinese-character-strokes 0.0.3 fallback (ISC)"), license: L10n.text("康熙表MIT ©2017–2018 Kawai Lo；现代备选表ISC；原创Swift公式", "Kangxi table: MIT ©2017–2018 Kawai Lo · modern fallback: ISC · original Swift formulas"))
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard !input.profile.unknownFields.contains(.surname), !input.profile.unknownFields.contains(.givenName) else {
            return NativeCalendar.unavailable(.xingming, L10n.text("姓或名已明确标为不确定，未使用保存的旧姓名推算。", "The family or given name is marked uncertain. The saved name was not used."))
        }
        let surname = input.profile.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = input.profile.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surname.isEmpty, !given.isEmpty, surname.count <= 4, given.count <= 4 else {
            return NativeCalendar.unavailable(.xingming, L10n.text("请分别提供姓与名，每部分1–4字；昵称不当作真实姓名。", "Enter the family and given names separately, using one to four Chinese characters for each. Use the actual name, rather than a nickname."))
        }
        var calculationSurname = surname, calculationGiven = given
        var usesCandidate = false
        let hasKangxi = !Self.kangxi.isEmpty
        var transformUnavailable = false
        if hasKangxi {
            let transform = StringTransform("Simplified-Traditional")
            if let familyCandidate = surname.applyingTransform(transform, reverse: false),
               let givenCandidate = given.applyingTransform(transform, reverse: false) {
                calculationSurname = familyCandidate
                calculationGiven = givenCandidate
                usesCandidate = Array(surname.unicodeScalars.map(\.value)) != Array(familyCandidate.unicodeScalars.map(\.value))
                    || Array(given.unicodeScalars.map(\.value)) != Array(givenCandidate.unicodeScalars.map(\.value))
            } else { transformUnavailable = true }
        }
        let chars = Array(calculationSurname + calculationGiven)
        var counts: [Int] = []
        var missing: [String] = []
        if hasKangxi {
            for char in chars {
                if let count = Self.kangxiCount(char) { counts.append(count) }
                else { missing.append(String(char)) }
            }
        } else {
            guard let url = NativeCalendar.resource("stroke-counts", extension: "bin"), let data = try? Data(contentsOf: url), data.count == 20_976 else {
                return NativeCalendar.unavailable(.xingming, L10n.text("本地康熙主表与现代备选笔画表均未正确安装。", "Neither of the local stroke-count tables could be loaded."))
            }
            for char in chars {
                let values = String(char).unicodeScalars
                guard values.count == 1, let scalar = values.first, (0x4e00...0x9fef).contains(scalar.value) else { missing.append(String(char)); continue }
                counts.append(Int(data[Int(scalar.value) - 0x4e00]))
            }
        }
        guard missing.isEmpty else {
            return NativeCalendar.unavailable(.xingming, L10n.text("本地字表缺少：\(missing.joined(separator: "、"))。未对缺字猜测笔画。", "The local table has no stroke counts for: \(missing.joined(separator: ", "))."))
        }
        let family = Array(counts.prefix(calculationSurname.count)), name = Array(counts.dropFirst(calculationSurname.count))
        let sky = family.reduce(0, +) + (family.count == 1 ? 1 : 0)
        let person = (family.last ?? 0) + (name.first ?? 0)
        let earth = name.reduce(0, +) + (name.count == 1 ? 1 : 0)
        let outer = (family.count == 1 ? 1 : family.dropLast().reduce(0, +)) + (name.count == 1 ? 1 : name.dropFirst().reduce(0, +))
        let total = counts.reduce(0, +)
        let skyElement = Self.element(sky), personElement = Self.element(person), earthElement = Self.element(earth)
        let relation = NativeHexagrams.relationship(body: personElement, use: earthElement)
        var rows: [OracleRow] = [
            .init(L10n.text("输入姓名", "Name as entered"), surname + " · " + given),
            .init(L10n.text("计算字形", "Characters used"), calculationSurname + " · " + calculationGiven + (usesCandidate ? L10n.text("（繁体候选，待核对）", " (traditional forms need confirmation)") : "")),
            .init(L10n.text("笔画口径", "Stroke-count rules"), hasKangxi ? L10n.text("康熙部首笔画 · 精确Unicode码点表", "Kangxi radical stroke counts · exact Unicode code points") : L10n.text("现代书写笔画（康熙主表缺失，已降级）", "Modern stroke counts (Kangxi table unavailable)")),
            .init(L10n.text("逐字笔画", "Strokes per character"), zip(chars, counts).map { "\($0.0) \($0.1)" }.joined(separator: " / ")),
            .init(L10n.text("天格", "Heaven grid"), "\(sky) · \(NativeCalendar.element(skyElement))"),
            .init(L10n.text("人格", "Person grid"), "\(person) · \(NativeCalendar.element(personElement))"),
            .init(L10n.text("地格", "Earth grid"), "\(earth) · \(NativeCalendar.element(earthElement))"),
            .init(L10n.text("外格", "Outer grid"), "\(outer) · \(NativeCalendar.element(Self.element(outer)))"),
            .init(L10n.text("总格", "Total grid"), "\(total) · \(NativeCalendar.element(Self.element(total)))"),
            .init(L10n.text("三才", "Three Talents"), [skyElement, personElement, earthElement].map { NativeCalendar.element($0) }.joined(separator: " · "))
        ]
        if hasKangxi {
            rows.insert(.init(L10n.text("输入字形原表笔画", "Table counts for the entered characters"), Array(surname + given).map { character in
                "\(character) \(Self.kangxiCount(character).map(String.init) ?? L10n.text("缺字", "unavailable"))"
            }.joined(separator: " / ")), at: 3)
        }
        var limitations = [L10n.text("康熙部首笔画录文尚未全量校勘；本版不含完整81数理吉凶歌诀。", "The Kangxi transcription has not been fully collated. This edition omits the complete set of 81 traditional verse interpretations."), L10n.text("五格只记录传统数理结构，不构成个人品格、能力或人生结果的测量。", "The Five Grids record a traditional numerical structure. They do not measure character, ability or life outcomes."), L10n.text("人格/地格五行关系：\(relation.0)，仅记录传统符号。", "Person and Earth grid elements: \(relation.0). This is a traditional symbolic relationship.")]
        if usesCandidate { limitations.insert(L10n.text("系统繁体转换具有一对多歧义；所列\(calculationSurname + calculationGiven)只是候选，请核对真实姓名繁体写法后再作确定五格参考。", "Simplified characters can have multiple traditional equivalents. Confirm whether \(calculationSurname + calculationGiven) is the correct traditional spelling."), at: 0) }
        if transformUnavailable { limitations.insert(L10n.text("系统字形转换不可用，尚未确认输入是否为传统姓名原字；暂按精确输入字形。", "Character conversion is unavailable. The app used the exact characters entered, whose traditional forms are unconfirmed."), at: 0) }
        if !hasKangxi { limitations.insert(L10n.text("康熙主表未加载，本次为现代笔画降级参考，不能称为康熙五格。", "The Kangxi table could not be loaded. These results use modern stroke counts."), at: 0) }
        return OracleResult(method: .xingming, status: hasKangxi && !usesCandidate && !transformUnavailable ? .complete : .partial,
            headline: L10n.text("五格 \(sky) / \(person) / \(earth) / \(outer) / \(total)", "Five Grids \(sky) / \(person) / \(earth) / \(outer) / \(total)"), rows: rows,
            evidence: [.init(id: "xingming-structure", statement: L10n.text("按\(hasKangxi ? "康熙部首笔画" : "现代备选笔画")与\(usesCandidate ? "未确认的繁体候选" : "所填字形")，三才为\(NativeCalendar.element(skyElement))\(NativeCalendar.element(personElement))\(NativeCalendar.element(earthElement))；只作文字结构参考，不参与具体事件吉凶判断。", "Using \(hasKangxi ? "Kangxi" : "modern") stroke counts for the \(usesCandidate ? "unconfirmed traditional spelling" : "entered characters"), the Three Talents are \(NativeCalendar.element(skyElement)), \(NativeCalendar.element(personElement)), and \(NativeCalendar.element(earthElement)). These describe a symbolic name structure."), strength: 0.05, topic: "cultural")],
            limitations: limitations,
            provenance: hasKangxi ? L10n.text("本地63,696字康熙部首笔画表（MIT，码点键）＋BlindOracle五格公式", "On-device table of 63,696 Kangxi stroke counts (MIT, code-point keys) · BlindOracle Five Grids formulas") : L10n.text("本地21KB现代笔画数表（ISC）＋BlindOracle五格公式", "On-device modern stroke-count table (ISC) · BlindOracle Five Grids formulas"))
    }
    private static func element(_ value: Int) -> Int { let digit = value % 10; return (digit == 0 ? 9 : digit - 1) / 2 }
}
