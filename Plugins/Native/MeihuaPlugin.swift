import Foundation

struct MeihuaPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.meihua, summary: "数字或当前农历时间起卦，计算本互变与体用五行关系。",
            optional: [.numbers, .currentLocation], questions: ["具体选择", "近期进展", "关系沟通", "行动节奏"],
            output: "本卦、互卦、变卦、动爻、体用与五行生克；保留完整起数过程，并给本卦卦辞、动爻爻辞与变卦卦辞。",
            limitations: ["默认普通互卦取法，乾坤也取本卦二三四/三四五爻；不自动预测应期。", "三数法第三数定动爻；双数法两原数加时辰定动爻。", "时间起卦支持1900–2100年。"],
            source: "BlindOracle先天八卦本互变与体用Swift公式；kentang2017/ichingshifa MIT周易卦爻辞；LunarSwift MIT历法", license: "原创Swift；LunarSwift MIT；卦爻辞上游MIT样式许可见ThirdParty-Iching.txt")
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard let solar = NativeCalendar.castingSolar(input) else { return NativeCalendar.unavailable(.meihua, "需要有效起卦时间与时区。") }
        let lunar = solar.lunar
        let hour = lunar.timeZhiIndex + 1
        let upperNumber: Int, lowerNumber: Int, movingNumber: Int, calculation: String
        if !input.profile.unknownFields.contains(.numbers) && input.numbers.count >= 2 {
            // Reduce before addition to prevent overflow for arbitrary UI integers.
            upperNumber = NativeCalendar.mod(input.numbers[0], 8)
            lowerNumber = NativeCalendar.mod(input.numbers[1], 8)
            movingNumber = input.numbers.count >= 3 ? NativeCalendar.mod(input.numbers[2], 6)
                : NativeCalendar.mod(NativeCalendar.mod(input.numbers[0], 6) + NativeCalendar.mod(input.numbers[1], 6) + hour, 6)
            calculation = input.numbers.count >= 3 ? "三数法：首数定上卦、次数定下卦、第三数除6定动爻。" : "双数法：首数定上卦、次数定下卦，两原数加时辰序数除6定动爻。"
        } else {
            let total = lunar.yearZhiIndex + 1 + abs(lunar.month) + lunar.day
            upperNumber = total % 8
            lowerNumber = (total + hour) % 8
            movingNumber = (total + hour) % 6
            calculation = "年支数\(lunar.yearZhiIndex + 1)＋农历月\(abs(lunar.month))＋日\(lunar.day)＝\(total)；上卦取余8，下卦加时辰\(hour)取余8，动爻取余6。余0分别作8、6。"
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
            .init("起卦时间", NativeCalendar.dateLabel(input.castingDate, zone: input.profile.currentTimeZoneID)),
            .init("起数过程", calculation), .init("本卦", NativeHexagrams.name(original)),
            .init("卦象（自上而下）", NativeHexagrams.diagram(original, moving: [moving])),
            .init("动爻", "第\(moving)爻（自下而上）"), .init("互卦", NativeHexagrams.name(mutual)),
            .init("变卦", NativeHexagrams.name(changed)),
            .init("体卦", "\(NativeHexagrams.trigramNames[body]) · \(NativeCalendar.elements[NativeHexagrams.trigramElements[body]])"),
            .init("用卦", "\(NativeHexagrams.trigramNames[use]) · \(NativeCalendar.elements[NativeHexagrams.trigramElements[use]])"),
            .init("体用关系", relation.0)
        ]
        let classical = NativeHexagrams.classicalReading(original: original, changed: changed, moving: [moving])
        rows += classical.rows
        return OracleResult(method: .meihua, status: classical.available && NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate).isEmpty ? .complete : .partial, headline: "\(NativeHexagrams.name(original)) · \(moving)爻动 · \(relation.0)", rows: rows,
            evidence: [.init(id: "meihua-body-use", statement: relation.2, polarity: relation.1, strength: 0.45, topic: "action")] + classical.evidence,
            limitations: ["本版按基础体用规则结合典籍原文提供线索，不将卦象视为现实事件或成功率；未纳入外应与应期。"] + classical.limitations + NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate),
            provenance: "BlindOracle Swift · 先天八卦本互变 / 周易64卦384爻辞本地MIT录文")
    }
}
