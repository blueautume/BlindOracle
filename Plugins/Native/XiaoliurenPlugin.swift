import Foundation

struct XiaoliurenPlugin: OraclePlugin {
    static let palaces = ["大安", "留连", "速喜", "赤口", "小吉", "空亡"]
    static let meanings = ["重在安定与守成，适合先稳住已有条件。", "有反复与拖延之象，适合先查清卡点。", "有消息与推进之象，适合保持沟通并及时回应。", "有口舌与分歧之象，适合把边界与约定说清。", "有小幅改善与协作之象，适合循序推进。", "条件尚未落实，适合留出余地并复核信息。"]
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.xiaoliuren, summary: L10n.text("按起课时刻的农历月、日、时辰，计算月日时三宫。", "Uses the lunar month, day and hour of casting to calculate three palaces."),
            optional: [.currentLocation], questions: [L10n.text("近期进展", "Near-term developments"), L10n.text("沟通", "Communication"), L10n.text("行动安排", "Planning an action")],
            output: L10n.text("农历起课时间、月宫、日宫、时宫与六宫通行象征释义。", "Lunar casting time, month, day and hour palaces, and traditional symbolism of the six palaces."),
            limitations: [L10n.text("只用时间起课，不混用数字、道传等其他取法。", "This edition uses time-based casting only."), L10n.text("闰月沿用该农历月序；子时按当前农历日，不额外23点换日。", "A leap month keeps its regular month number. The Zi hour follows the current lunar date without an additional day boundary at 11 p.m.")])
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard let solar = NativeCalendar.castingSolar(input) else { return NativeCalendar.unavailable(.xiaoliuren, L10n.text("需要有效起课时间，支持1900–2100年。", "A valid casting time in 1900–2100 is required.")) }
        let lunar = solar.lunar
        let month = abs(lunar.month), day = lunar.day, hour = lunar.timeZhiIndex + 1
        let monthPalace = (month - 1) % 6
        let dayPalace = (monthPalace + day - 1) % 6
        let hourPalace = (dayPalace + hour - 1) % 6
        let tendencies = [0.15, -0.15, 0.3, -0.3, 0.2, -0.2]
        return OracleResult(method: .xiaoliuren, status: NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate).isEmpty ? .complete : .partial, headline: Self.palace(hourPalace), rows: [
            .init(L10n.text("起课时间", "Casting time"), L10n.text("农历\(lunar.monthInChinese)月\(lunar.dayInChinese) · \(lunar.timeZhi)时", "Lunar \(NativeCalendar.lunarDate(lunar, includeYear: false)) · \(NativeCalendar.stemBranch(lunar.timeZhi)) hour")),
            .init(L10n.text("月宫", "Month palace"), Self.palace(monthPalace)), .init(L10n.text("日宫", "Day palace"), Self.palace(dayPalace)),
            .init(L10n.text("时宫", "Hour palace"), Self.palace(hourPalace)),
            .init(L10n.text("计算过程", "Calculation"), L10n.text("月(\(month)−1)%6＝\(monthPalace)；日(\(monthPalace)+\(day)−1)%6＝\(dayPalace)；时(\(dayPalace)+\(hour)−1)%6＝\(hourPalace)", "Month: (\(month) − 1) mod 6 = \(monthPalace) · Day: (\(monthPalace) + \(day) − 1) mod 6 = \(dayPalace) · Hour: (\(dayPalace) + \(hour) − 1) mod 6 = \(hourPalace)")),
            .init(L10n.text("传统象征", "Traditional symbolism"), Self.meaning(hourPalace))
        ], evidence: [.init(id: "xiaoliuren-hour-palace", statement: Self.meaning(hourPalace), polarity: tendencies[hourPalace], strength: 0.25, topic: "action")],
           limitations: [L10n.text("宫名与释义是民俗符号，不是具体事情已发生或将发生的证据。", "Palace names and meanings come from folk tradition. They do not establish what has happened or will happen.")] + NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate))
    }
    private static func palace(_ index: Int) -> String {
        L10n.text(palaces[index], ["Great Peace", "Lingering", "Quick Joy", "Red Mouth", "Small Fortune", "Void"][index])
    }

    private static func meaning(_ index: Int) -> String {
        L10n.text(meanings[index], [
            "Stability and continuity are the traditional themes. Secure the conditions you already have.",
            "Delay and repetition are the traditional themes. Identify what is holding things up.",
            "News and movement are the traditional themes. Stay in touch and respond promptly.",
            "Disagreement is the traditional theme. Clarify boundaries and agreements.",
            "Small improvements and cooperation are the traditional themes. Proceed one step at a time.",
            "Conditions are unsettled. Leave room to adapt and verify the information."
        ][index])
    }
}
