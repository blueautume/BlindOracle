import Foundation

struct MeihuaPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.meihua, summary: L10n.text("数字或当前农历时间起卦，计算本互变与体用五行关系。", "Casts from numbers or the lunar time and calculates original, nuclear and resulting hexagrams and the relationship between Body and Use."),
            optional: [.numbers, .currentLocation], questions: [L10n.text("具体选择", "Specific decisions"), L10n.text("近期进展", "Near-term developments"), L10n.text("关系沟通", "Communication in relationships"), L10n.text("行动节奏", "Timing an action")],
            output: L10n.text("本卦、互卦、变卦、动爻、体用与五行生克；保留完整起数过程，并给本卦卦辞、动爻爻辞与变卦卦辞。", "Original, nuclear and resulting hexagrams, changing line, and Body and Use elements. Includes the complete cast calculation and the relevant I Ching passages."),
            limitations: [L10n.text("默认普通互卦取法，乾坤也取本卦二三四/三四五爻；不自动预测应期。", "The nuclear hexagram uses original lines 2–4 and 3–5, including for Qian and Kun. Event timing is outside the method's scope."), L10n.text("三数法第三数定动爻；双数法两原数加时辰定动爻。", "With three numbers, the third determines the changing line. With two, both numbers plus the hour index determine it."), L10n.text("时间起卦支持1900–2100年。", "Time-based casting supports 1900–2100.")],
            source: L10n.text("BlindOracle先天八卦本互变与体用Swift公式；kentang2017/ichingshifa MIT周易卦爻辞；LunarSwift MIT历法", "BlindOracle Swift formulas for Earlier Heaven trigrams and Body/Use · kentang2017/ichingshifa (MIT) · LunarSwift (MIT)"), license: L10n.text("原创Swift；LunarSwift MIT；卦爻辞上游MIT样式许可见ThirdParty-Iching.txt", "Original Swift implementation · LunarSwift (MIT). See ThirdParty-Iching.txt for the I Ching source license."))
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard let solar = NativeCalendar.castingSolar(input) else { return NativeCalendar.unavailable(.meihua, L10n.text("需要有效起卦时间与时区。", "A valid casting time and time zone are required.")) }
        let lunar = solar.lunar
        let hour = lunar.timeZhiIndex + 1
        let upperNumber: Int, lowerNumber: Int, movingNumber: Int, calculation: String
        if !input.profile.unknownFields.contains(.numbers) && input.numbers.count >= 2 {
            // Reduce before addition to prevent overflow for arbitrary UI integers.
            upperNumber = NativeCalendar.mod(input.numbers[0], 8)
            lowerNumber = NativeCalendar.mod(input.numbers[1], 8)
            movingNumber = input.numbers.count >= 3 ? NativeCalendar.mod(input.numbers[2], 6)
                : NativeCalendar.mod(NativeCalendar.mod(input.numbers[0], 6) + NativeCalendar.mod(input.numbers[1], 6) + hour, 6)
            calculation = input.numbers.count >= 3 ? L10n.text("三数法：首数定上卦、次数定下卦、第三数除6定动爻。", "Three numbers: the first determines the upper trigram, the second the lower trigram, and the third modulo six the changing line.") : L10n.text("双数法：首数定上卦、次数定下卦，两原数加时辰序数除6定动爻。", "Two numbers: the first determines the upper trigram and the second the lower. Their sum plus the hour index, modulo six, determines the changing line.")
        } else {
            let total = lunar.yearZhiIndex + 1 + abs(lunar.month) + lunar.day
            upperNumber = total % 8
            lowerNumber = (total + hour) % 8
            movingNumber = (total + hour) % 6
            calculation = L10n.text("年支数\(lunar.yearZhiIndex + 1)＋农历月\(abs(lunar.month))＋日\(lunar.day)＝\(total)；上卦取余8，下卦加时辰\(hour)取余8，动爻取余6。余0分别作8、6。", "Year branch \(lunar.yearZhiIndex + 1) + lunar month \(abs(lunar.month)) + day \(lunar.day) = \(total). Use the remainder modulo 8 for the upper trigram. Add hour \(hour) and use modulo 8 for the lower trigram and modulo 6 for the changing line. A zero remainder counts as 8 or 6, respectively.")
        }
        let upper = NativeHexagrams.orderedBits[(upperNumber == 0 ? 8 : upperNumber) - 1]
        let lower = NativeHexagrams.orderedBits[(lowerNumber == 0 ? 8 : lowerNumber) - 1]
        let moving = movingNumber == 0 ? 6 : movingNumber
        let original = (upper << 3) | lower
        let changed = original ^ (1 << (moving - 1))
        let mutual = (((original >> 2) & 7) << 3) | ((original >> 1) & 7)
        let body = moving <= 3 ? upper : lower
        let use = moving <= 3 ? lower : upper
        let relation = NativeHexagrams.relationship(body: NativeHexagrams.trigramElements[body], use: NativeHexagrams.trigramElements[use])
        var rows: [OracleRow] = [
            .init(L10n.text("起卦时间", "Casting time"), NativeCalendar.dateLabel(input.castingDate, zone: input.profile.currentTimeZoneID)),
            .init(L10n.text("起数过程", "Cast calculation"), calculation), .init(L10n.text("本卦", "Original hexagram"), NativeHexagrams.displayName(original)),
            .init(L10n.text("卦象（自上而下）", "Hexagram (top to bottom)"), NativeHexagrams.diagram(original, moving: [moving])),
            .init(L10n.text("动爻", "Changing line"), L10n.text("第\(moving)爻（自下而上）", "Line \(moving) (counted from the bottom)")), .init(L10n.text("互卦", "Nuclear hexagram"), NativeHexagrams.displayName(mutual)),
            .init(L10n.text("变卦", "Resulting hexagram"), NativeHexagrams.displayName(changed)),
            .init(L10n.text("体卦", "Body trigram"), "\(NativeHexagrams.trigram(body)) · \(NativeCalendar.element(NativeHexagrams.trigramElements[body]))"),
            .init(L10n.text("用卦", "Use trigram"), "\(NativeHexagrams.trigram(use)) · \(NativeCalendar.element(NativeHexagrams.trigramElements[use]))"),
            .init(L10n.text("体用关系", "Body and Use relationship"), relation.0)
        ]
        if !input.profile.unknownFields.contains(.numbers), input.numbers.count >= 2 {
            rows.insert(.init(L10n.text("所留数字", "Your numbers"), input.numbers.map(String.init).joined(separator: L10n.text("、", ", "))), at: 1)
        }
        let classical = NativeHexagrams.classicalReading(original: original, changed: changed, moving: [moving])
        rows += classical.rows
        return OracleResult(method: .meihua, status: classical.available && NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate).isEmpty ? .complete : .partial, headline: L10n.text("\(NativeHexagrams.displayName(original)) · \(moving)爻动 · \(relation.0)", "\(NativeHexagrams.displayName(original)) · line \(moving) changes · \(relation.0)"), rows: rows,
            evidence: [.init(id: "meihua-body-use", statement: relation.2, polarity: relation.1, strength: 0.45, topic: "action")] + classical.evidence,
            limitations: [L10n.text("本版按基础体用规则结合典籍原文提供线索，不将卦象视为现实事件或成功率；未纳入外应与应期。", "The reading combines basic Body and Use rules with classical texts. It does not determine outcomes, account for external omens or predict timing.")] + classical.limitations + NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate),
            provenance: L10n.text("BlindOracle Swift · 先天八卦本互变 / 周易64卦384爻辞本地MIT录文", "BlindOracle Swift · Earlier Heaven trigrams / local I Ching collection of 64 hexagrams and 384 lines (MIT)"))
    }
}
