import Foundation

struct XiaoliurenPlugin: OraclePlugin {
    static let palaces = ["大安", "留连", "速喜", "赤口", "小吉", "空亡"]
    static let meanings = ["重在安定与守成，适合先稳住已有条件。", "有反复与拖延之象，适合先查清卡点。", "有消息与推进之象，适合保持沟通并及时回应。", "有口舌与分歧之象，适合把边界与约定说清。", "有小幅改善与协作之象，适合循序推进。", "条件尚未落实，适合留出余地并复核信息。"]
    var descriptor: OraclePluginDescriptor {
        NativeCalendar.descriptor(.xiaoliuren, summary: "按起课时刻的农历月、日、时辰，计算月日时三宫。",
            optional: [.currentLocation], questions: ["近期进展", "沟通", "行动安排"],
            output: "农历起课时间、月宫、日宫、时宫与六宫通行象征释义。",
            limitations: ["只用时间起课，不混用数字、道传等其他取法。", "闰月沿用该农历月序；子时按当前农历日，不额外23点换日。"])
    }
    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard let solar = NativeCalendar.castingSolar(input) else { return NativeCalendar.unavailable(.xiaoliuren, "需要有效起课时间，支持1900–2100年。") }
        let lunar = solar.lunar
        let month = abs(lunar.month), day = lunar.day, hour = lunar.timeZhiIndex + 1
        let monthPalace = (month - 1) % 6
        let dayPalace = (monthPalace + day - 1) % 6
        let hourPalace = (dayPalace + hour - 1) % 6
        let tendencies = [0.15, -0.15, 0.3, -0.3, 0.2, -0.2]
        return OracleResult(method: .xiaoliuren, status: NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate).isEmpty ? .complete : .partial, headline: Self.palaces[hourPalace], rows: [
            .init("起课时间", "农历\(lunar.monthInChinese)月\(lunar.dayInChinese) · \(lunar.timeZhi)时"),
            .init("月宫", Self.palaces[monthPalace]), .init("日宫", Self.palaces[dayPalace]),
            .init("时宫", Self.palaces[hourPalace]),
            .init("计算过程", "月(\(month)−1)%6＝\(monthPalace)；日(\(monthPalace)+\(day)−1)%6＝\(dayPalace)；时(\(dayPalace)+\(hour)−1)%6＝\(hourPalace)"),
            .init("传统象征", Self.meanings[hourPalace])
        ], evidence: [.init(id: "xiaoliuren-hour-palace", statement: Self.meanings[hourPalace], polarity: tendencies[hourPalace], strength: 0.25, topic: "action")],
           limitations: ["宫名与释义是民俗符号，不是具体事情已发生或将发生的证据。"] + NativeCalendar.timezoneLimit(input.profile.currentTimeZoneID, date: input.castingDate))
    }
}
