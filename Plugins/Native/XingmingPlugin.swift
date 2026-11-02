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
        NativeCalendar.descriptor(.xingming, summary: "以本地63,696字康熙部首笔画表计算五格与三才。系统繁体转换只产生候选，未确认字形则保留partial。",
            required: [.surname, .givenName], questions: ["姓名文化参考", "名字结构"],
            output: "原输入字形/笔画、实际计算字形/笔画、天格/人格/地格/外格/总格、三才五行；数据源和字形不确定性。",
            limitations: ["请填写已确认的繁体姓名。简体经ICU转换所得繁体只是候选；有字形变化时返回partial，明确展示两种写法。", "康熙表按精确Unicode码点读数，不将兼容字规范化合并；资料为部首笔画录文，未全量古籍校勘。", "主表缺失时才降级到现代笔画表，降级始终partial；缺字不猜。", "不使用数意姓名学的五=5/七=7等替换，不输出个人品格、能力或必然命运判断。"],
            source: "breezyreeds/kangxi-strokecount MIT，63,696字码点表；ICU繁体候选；modern fallback为chinese-character-strokes 0.0.3 ISC", license: "康熙表MIT ©2017–2018 Kawai Lo；现代备选表ISC；原创Swift公式")
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard !input.profile.unknownFields.contains(.surname), !input.profile.unknownFields.contains(.givenName) else {
            return NativeCalendar.unavailable(.xingming, "姓或名已明确标为不确定，未使用保存的旧姓名推算。")
        }
        let surname = input.profile.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = input.profile.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surname.isEmpty, !given.isEmpty, surname.count <= 4, given.count <= 4 else {
            return NativeCalendar.unavailable(.xingming, "请分别提供姓与名，每部分1–4字；昵称不当作真实姓名。")
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
                return NativeCalendar.unavailable(.xingming, "本地康熙主表与现代备选笔画表均未正确安装。")
            }
            for char in chars {
                let values = String(char).unicodeScalars
                guard values.count == 1, let scalar = values.first, (0x4e00...0x9fef).contains(scalar.value) else { missing.append(String(char)); continue }
                counts.append(Int(data[Int(scalar.value) - 0x4e00]))
            }
        }
        guard missing.isEmpty else {
            return NativeCalendar.unavailable(.xingming, "本地字表缺少：\(missing.joined(separator: "、"))。未对缺字猜测笔画。")
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
            .init("输入姓名", surname + " · " + given),
            .init("计算字形", calculationSurname + " · " + calculationGiven + (usesCandidate ? "（繁体候选，待核对）" : "")),
            .init("笔画口径", hasKangxi ? "康熙部首笔画 · 精确Unicode码点表" : "现代书写笔画（康熙主表缺失，已降级）"),
            .init("逐字笔画", zip(chars, counts).map { "\($0.0) \($0.1)" }.joined(separator: " / ")),
            .init("天格", "\(sky) · \(NativeCalendar.elements[skyElement])"),
            .init("人格", "\(person) · \(NativeCalendar.elements[personElement])"),
            .init("地格", "\(earth) · \(NativeCalendar.elements[earthElement])"),
            .init("外格", "\(outer) · \(NativeCalendar.elements[Self.element(outer)])"),
            .init("总格", "\(total) · \(NativeCalendar.elements[Self.element(total)])"),
            .init("三才", [skyElement, personElement, earthElement].map { NativeCalendar.elements[$0] }.joined(separator: " · "))
        ]
        if hasKangxi {
            rows.insert(.init("输入字形原表笔画", Array(surname + given).map { character in
                "\(character) \(Self.kangxiCount(character).map(String.init) ?? "缺字")"
            }.joined(separator: " / ")), at: 3)
        }
        var limitations = ["康熙部首笔画录文尚未全量校勘；本版不含完整81数理吉凶歌诀。", "五格只记录传统数理结构，不构成个人品格、能力或人生结果的测量。", "人格/地格五行关系：\(relation.0)，仅记录传统符号。"]
        if usesCandidate { limitations.insert("系统繁体转换具有一对多歧义；所列\(calculationSurname + calculationGiven)只是候选，请核对真实姓名繁体写法后再作确定五格参考。", at: 0) }
        if transformUnavailable { limitations.insert("系统字形转换不可用，尚未确认输入是否为传统姓名原字；暂按精确输入字形。", at: 0) }
        if !hasKangxi { limitations.insert("康熙主表未加载，本次为现代笔画降级参考，不能称为康熙五格。", at: 0) }
        return OracleResult(method: .xingming, status: hasKangxi && !usesCandidate && !transformUnavailable ? .complete : .partial,
            headline: "五格 \(sky) / \(person) / \(earth) / \(outer) / \(total)", rows: rows,
            evidence: [.init(id: "xingming-structure", statement: "按\(hasKangxi ? "康熙部首笔画" : "现代备选笔画")与\(usesCandidate ? "未确认的繁体候选" : "所填字形")，三才为\(NativeCalendar.elements[skyElement])\(NativeCalendar.elements[personElement])\(NativeCalendar.elements[earthElement])；只作文字结构参考，不参与具体事件吉凶判断。", strength: 0.05, topic: "cultural")],
            limitations: limitations,
            provenance: hasKangxi ? "本地63,696字康熙部首笔画表（MIT，码点键）＋BlindOracle五格公式" : "本地21KB现代笔画数表（ISC）＋BlindOracle五格公式")
    }
    private static func element(_ value: Int) -> Int { let digit = value % 10; return (digit == 0 ? 9 : digit - 1) / 2 }
}
