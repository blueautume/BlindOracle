import Foundation
import JavaScriptCore

enum SkyPlugins {
    static var all: [any OraclePlugin] { [ZiweiPlugin(), WesternAstrologyPlugin()] }
}

struct ZiweiPlugin: OraclePlugin {
    let descriptor = OraclePluginDescriptor(
        method: .ziwei, version: "1.0.0+iztro.2.6.3",
        summary: "完全离线的紫微斗数排盘：十二宫、主辅星、亮度、生年四化、大限与问事时刻流年四化。",
        requiredFields: [.birthDate, .birthTime, .gender, .birthTimeZone],
        optionalFields: [.birthPlace],
        supportedQuestions: ["本人事业与财务主题", "关系主题", "长期趋势与本命结构"],
        outputDescription: "十二宫独立数据、生年四化、大限、小限与流年；固定规则产生符号性证据，不生成事实性命运预测。",
        limitations: ["出生时间或排盘性别不确定时不生成唯一命盘。", "采用 iztro 2.6.3 默认三合排盘配置，闰月按前后半月调整；不覆盖所有流派。", "时区采用用户确认的出生地时区，未作真太阳时校正。"],
        source: "https://github.com/SylarLong/iztro", license: "MIT；依赖许可证随应用内置")

    func calculate(_ input: OracleInput) async throws -> OracleResult {
        try await SkyCalculator.shared.ziwei(input)
    }
}

struct WesternAstrologyPlugin: OraclePlugin {
    let descriptor = OraclePluginDescriptor(
        method: .astrology, version: "1.0.0+astronomy.865d3da",
        summary: "完全离线的热带黄道星位、十大天体、主要相位及行运。出生时间和坐标完整时计算上升点、天顶与等宫制。",
        requiredFields: [.birthDate, .birthTimeZone],
        optionalFields: [.birthTime, .birthCoordinates, .birthPlace],
        supportedQuestions: ["本人当前阶段", "关系与行动节奏", "本命星位与当前行运"],
        outputDescription: "出生及问事时刻的地心黄经、本命相位、行运相位；符合条件时给出等宫制宫头。",
        limitations: ["采用 Astronomy Engine 内置解析模型，不是 Swiss Ephemeris；支持公历 1900–2100 年。", "仅支持热带黄道、地心视位置和等宫制；未实现 Placidus、小行星、合盘和推运。", "时间不确定时只输出出生日期的全天星位区间，不生成宫位和精确相位。", "纬度绝对值达到 66° 时不计算宫位。"],
        source: "https://github.com/cosinekitty/astronomy", license: "MIT")

    func calculate(_ input: OracleInput) async throws -> OracleResult {
        try await SkyCalculator.shared.astrology(input)
    }
}

enum SkyMath {
    static func normalize(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
    static func separation(_ a: Double, _ b: Double) -> Double {
        let distance = abs(normalize(a) - normalize(b))
        return min(distance, 360 - distance)
    }
    static func zodiac(_ longitude: Double) -> String {
        let names = ["白羊", "金牛", "双子", "巨蟹", "狮子", "处女", "天秤", "天蝎", "射手", "摩羯", "水瓶", "双鱼"]
        let angle = normalize(longitude)
        let degree = angle.truncatingRemainder(dividingBy: 30)
        return "\(names[min(11, Int(angle / 30))]) \(String(format: "%.2f", degree))°"
    }
    static func timeIndex(hour: Int) -> Int { hour == 23 ? 12 : (hour + 1) / 2 }
}

private enum SkyError: LocalizedError {
    case resourceMissing, javascript(String), astronomy(Int)
    var errorDescription: String? {
        switch self {
        case .resourceMissing: "本地紫微排盘资源缺失，请检查安装包。"
        case .javascript(let detail): "紫微排盘未完成：\(detail)"
        case .astronomy(let code): "本地天文计算返回错误 \(code)。"
        }
    }
}

/// Serializes JavaScriptCore contexts and Astronomy Engine's internal caches.
private actor SkyCalculator {
    static let shared = SkyCalculator()

    func ziwei(_ input: OracleInput) throws -> OracleResult {
        let start = Date()
        guard let birth = input.profile.birthDate, !input.profile.unknownFields.contains(.birthDate) else {
            return unavailable(.ziwei, "出生日期未确定，暂不生成紫微命盘。")
        }
        guard input.profile.birthTimeKnown, !input.profile.unknownFields.contains(.birthTime) else {
            return unavailable(.ziwei, "出生时辰不确定：十二宫和星曜落点依赖时辰，暂不生成唯一命盘。")
        }
        guard ["男", "女"].contains(input.profile.sex), !input.profile.unknownFields.contains(.gender) else {
            return unavailable(.ziwei, "紫微排盘需要确认排盘性别；未确定时不代填。")
        }
        guard let zone = TimeZone(identifier: input.profile.birthTimeZoneID), !input.profile.unknownFields.contains(.birthTimeZone) else {
            return unavailable(.ziwei, "出生地时区未确定，暂不生成命盘。")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: birth)
        guard let year = components.year, (1900...2100).contains(year) else {
            return unavailable(.ziwei, "当前离线版本仅支持 1900–2100 年出生日期。")
        }
        let targetZone = TimeZone(identifier: input.profile.currentTimeZoneID) ?? zone
        var targetCalendar = Calendar(identifier: .gregorian)
        targetCalendar.timeZone = targetZone
        let target = targetCalendar.dateComponents([.year, .month, .day, .hour], from: input.castingDate)
        let payload: [String: Any] = [
            "date": "\(year)-\(components.month ?? 1)-\(components.day ?? 1)",
            "timeIndex": SkyMath.timeIndex(hour: components.hour ?? 0),
            "gender": input.profile.sex,
            "targetDate": "\(target.year ?? year)-\(target.month ?? 1)-\(target.day ?? 1)",
            "targetTimeIndex": SkyMath.timeIndex(hour: target.hour ?? 0)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let serialized = String(data: data, encoding: .utf8), let context = JSContext() else {
            throw SkyError.javascript("无法创建本地运行环境")
        }
        // No fetch, XMLHttpRequest, native bridge, or network APIs are exposed to the script.
        context.evaluateScript("var console={log:function(){},warn:function(){},error:function(){}}; var setTimeout=function(f){if(typeof f==='function')f();return 0;}; var clearTimeout=function(){};")
        let source = try String(contentsOf: resourceURL(), encoding: .utf8)
        context.evaluateScript(source)
        if let error = context.exception?.toString() { throw SkyError.javascript(error) }
        let function = context.objectForKeyedSubscript("BlindOracleZiwei")?.objectForKeyedSubscript("calculate")
        let value = function?.call(withArguments: [serialized])
        if let error = context.exception?.toString() { throw SkyError.javascript(error) }
        guard let text = value?.toString(), let resultData = text.data(using: .utf8) else {
            throw SkyError.javascript("本地排盘未返回有效数据")
        }
        let chart = try JSONDecoder().decode(ZiweiChart.self, from: resultData)
        guard chart.palaces.count == 12 else { throw SkyError.javascript("命盘宫位数无效") }
        var rows: [OracleRow] = [
            .init("公历", chart.solarDate ?? ""), .init("农历", chart.lunarDate ?? ""),
            .init("干支", chart.chineseDate ?? ""), .init("五行局", chart.fiveElementsClass ?? ""),
            .init("命宫 / 身宫", "\(chart.earthlyBranchOfSoulPalace ?? "") / \(chart.earthlyBranchOfBodyPalace ?? "")"),
            .init("时区与时辰", "\(zone.identifier) · \(chart.time ?? "")"),
            .init("流派配置", "三合排盘；农历年界；早晚子时分开；闰月前后半月调整")
        ]
        for palace in chart.palaces {
            let stars = palace.majorStars + palace.minorStars
            let starText = stars.map { $0.display }.joined(separator: "、")
            let range = palace.decadal?.range.map(String.init).joined(separator: "–") ?? ""
            let body = palace.isBodyPalace ? " · 身宫" : ""
            rows.append(.init("\(palace.name)（\(palace.heavenlyStem)\(palace.earthlyBranch)）", "\(starText.isEmpty ? "无主辅星" : starText)\(body)；大限 \(range) 虚岁"))
        }
        var evidence: [OracleEvidence] = []
        for palace in chart.palaces {
            for star in palace.majorStars + palace.minorStars where !star.mutagen.isEmpty {
                let bias = mutagenBias(star.mutagen)
                evidence.append(.init(id: "ziwei.birth.\(palace.index).\(star.name).\(star.mutagen)",
                    statement: "生年\(star.name)\(star.mutagen)落\(palace.name)；在传统四化中作为\(bias.1)的符号线索，不能单独断具体事件。",
                    polarity: bias.0, strength: 0.5, topic: topic(palace.name)))
            }
        }
        if let yearly = chart.horoscope?.yearly {
            rows.append(.init("问事流年", "\(yearly.heavenlyStem ?? "")\(yearly.earthlyBranch ?? "")"))
            if let mutagen = yearly.mutagen, mutagen.count == 4 {
                let names = ["化禄", "化权", "化科", "化忌"]
                rows.append(.init("流年四化", zip(mutagen, names).map { "\($0)\($1)" }.joined(separator: "、")))
                for (index, name) in mutagen.enumerated() {
                    if let palace = chart.palaces.first(where: { ($0.majorStars + $0.minorStars).contains(where: { $0.name == name }) }) {
                        let bias = mutagenBias(names[index])
                        evidence.append(.init(id: "ziwei.yearly.\(index)",
                            statement: "问事流年\(name)\(names[index])对应本命\(palace.name)，传统象征为\(bias.1)。",
                            polarity: bias.0, strength: 0.45, topic: topic(palace.name)))
                    }
                }
            }
        }
        if let age = chart.horoscope?.age?.nominalAge { rows.append(.init("问事虚岁", String(age))) }
        if let decadal = chart.horoscope?.decadal,
           let index = decadal.index, chart.palaces.indices.contains(index) {
            rows.append(.init("当前大限宫", chart.palaces[index].name))
        }
        let life = chart.palaces.first { $0.name == "命宫" }
        let headline = "\(chart.fiveElementsClass ?? "紫微命盘") · 命宫\(life?.earthlyBranch ?? "") · \(life?.majorStars.map(\.name).joined(separator: "、") ?? "")"
        var result = OracleResult(method: .ziwei, version: "1.0.0+iztro.2.6.3", headline: headline,
            rows: rows, evidence: evidence,
            limitations: ZiweiPlugin().descriptor.limitations + ["证据强度是固定规则参数，非验证过的预测概率。"],
            provenance: "设备本地 JavaScriptCore · iztro 2.6.3（MIT）· 无网络接口")
        result.durationMilliseconds = Date().timeIntervalSince(start) * 1000
        return result
    }

    func astrology(_ input: OracleInput) throws -> OracleResult {
        let start = Date()
        guard let birth = input.profile.birthDate, !input.profile.unknownFields.contains(.birthDate) else {
            return unavailable(.astrology, "出生日期未确定，暂不计算本命星位。")
        }
        guard let zone = TimeZone(identifier: input.profile.birthTimeZoneID), !input.profile.unknownFields.contains(.birthTimeZone) else {
            return unavailable(.astrology, "出生地时区未确定，暂不计算星位。")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard (1900...2100).contains(calendar.component(.year, from: birth)),
              (1900...2100).contains(calendar.component(.year, from: input.castingDate)) else {
            return unavailable(.astrology, "当前本地天文模块支持公历 1900–2100 年。")
        }
        if !input.profile.birthTimeKnown || input.profile.unknownFields.contains(.birthTime) {
            let dayStart = calendar.startOfDay(for: birth)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            var rows = [OracleRow("计算范围", "出生地时区 \(zone.identifier) 的出生日期全天，非精确时刻命盘")]
            for (index, name) in planetNames.enumerated() {
                let first = try position(index, dayStart)
                let last = try position(index, dayEnd)
                rows.append(.init(name, "\(SkyMath.zodiac(first.longitude)) → \(SkyMath.zodiac(last.longitude))"))
            }
            return OracleResult(method: .astrology, status: .partial,
                headline: "出生时刻未确定 · 全天星位区间", rows: rows,
                limitations: ["未选择任意时刻冒充出生时间；区间端点不代表已确定的出生星位。", "不输出宫位、上升点、本命精确相位和行运判词。"],
                provenance: "Astronomy Engine C · 本地全天端点计算")
        }

        let natal = try planetNames.indices.map { try position($0, birth) }
        let current = try planetNames.indices.map { try position($0, input.castingDate) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        var rows: [OracleRow] = [
            .init("出生时刻", formatter.string(from: birth)),
            .init("黄道与坐标", "热带黄道 · 地心视位置 · 真春分点（日期）"),
            .init("计算内核", "Astronomy Engine 解析模型 · 设备本地")
        ]
        for (index, name) in planetNames.enumerated() {
            let retrograde = natal[index].speed < 0 ? " · 逆行" : ""
            rows.append(.init("本命\(name)", "\(SkyMath.zodiac(natal[index].longitude))\(retrograde)"))
        }
        var limitations = WesternAstrologyPlugin().descriptor.limitations
        var hasHouses = false
        if let latitude = input.profile.birthLatitude, let longitude = input.profile.birthLongitude,
           !input.profile.unknownFields.contains(.birthCoordinates) {
            var ascendant = 0.0
            var midheaven = 0.0
            let status = bo_sky_angles(birth.timeIntervalSince1970, latitude, longitude, &ascendant, &midheaven)
            if status == 0, ascendant.isFinite, midheaven.isFinite {
                hasHouses = true
                rows.append(.init("出生坐标", String(format: "%.4f°, %.4f°", latitude, longitude)))
                rows.append(.init("上升点 ASC", SkyMath.zodiac(ascendant)))
                rows.append(.init("天顶 MC", SkyMath.zodiac(midheaven)))
                rows.append(.init("宫制", "等宫制：第一宫宫头为上升点，其后每宫 30°；MC 不强制等于第十宫宫头"))
                for house in 0..<12 { rows.append(.init("第\(house + 1)宫宫头", SkyMath.zodiac(ascendant + Double(house * 30)))) }
                for index in natal.indices {
                    let house = Int(SkyMath.normalize(natal[index].longitude - ascendant) / 30) + 1
                    rows.append(.init("\(planetNames[index])落宫", "第\(house)宫（等宫制）"))
                }
            } else { limitations.append("出生坐标无效或超出当前宫位支持纬度，宫位未计算。") }
        } else { limitations.append("未确认出生地经纬度，只计算地心星位及相位，未计算上升点和宫位。") }

        var evidence: [OracleEvidence] = []
        var natalAspects: [(String, Double)] = []
        for first in natal.indices {
            for second in natal.indices where second > first {
                if let aspect = matchingAspect(natal[first].longitude, natal[second].longitude, maximumOrb: 6) {
                    natalAspects.append(("\(planetNames[first])\(aspect.name)\(planetNames[second])（容许度 \(String(format: "%.2f", aspect.orb))°）", aspect.orb))
                }
            }
        }
        for (index, aspect) in natalAspects.sorted(by: { $0.1 < $1.1 }).prefix(12).enumerated() {
            rows.append(.init("本命相位 \(index + 1)", aspect.0))
        }
        var transitAspects: [(label: String, orb: Double, polarity: Double, topic: String, id: String)] = []
        for transiting in 2..<10 {
            for target in 0..<7 {
                if let aspect = matchingAspect(current[transiting].longitude, natal[target].longitude, maximumOrb: 3) {
                    transitAspects.append(("行运\(planetNames[transiting])\(aspect.name)本命\(planetNames[target])", aspect.orb,
                                           aspect.polarity, planetTopic(target), "sky.transit.\(transiting).\(target).\(aspect.angle)"))
                }
            }
        }
        rows.append(.init("行运时刻", ISO8601DateFormatter().string(from: input.castingDate)))
        for (index, aspect) in transitAspects.sorted(by: { $0.orb < $1.orb }).prefix(10).enumerated() {
            rows.append(.init("行运相位 \(index + 1)", "\(aspect.label)（容许度 \(String(format: "%.2f", aspect.orb))°）"))
            let wording = aspect.polarity > 0 ? "协同" : aspect.polarity < 0 ? "张力" : "主题集中"
            evidence.append(.init(id: aspect.id, statement: "\(aspect.label)，传统相位象征偏向\(wording)；只是符号规则，不能直接推为现实吉凶。",
                polarity: aspect.polarity, strength: max(0.2, 1 - aspect.orb / 3), topic: aspect.topic))
        }
        if evidence.isEmpty {
            evidence.append(.init(id: "sky.no-tight-transit", statement: "当前行运与所检验本命点之间没有落入 3° 容许度的主要相位；不强行推断事件。", strength: 0.2))
        }
        var result = OracleResult(method: .astrology, version: "1.0.0+astronomy.865d3da", status: hasHouses ? .complete : .partial,
            headline: "太阳\(SkyMath.zodiac(natal[0].longitude)) · 月亮\(SkyMath.zodiac(natal[1].longitude))",
            rows: rows, evidence: evidence, limitations: limitations,
            provenance: "设备本地 Astronomy Engine C（MIT）；星历系数编译内置，无星历文件下载")
        result.durationMilliseconds = Date().timeIntervalSince(start) * 1000
        return result
    }

    private let planetNames = ["太阳", "月亮", "水星", "金星", "火星", "木星", "土星", "天王星", "海王星", "冥王星"]
    private struct Position { var longitude: Double; var speed: Double }
    private func position(_ body: Int, _ date: Date) throws -> Position {
        let value = bo_sky_geocentric(Int32(body), date.timeIntervalSince1970)
        guard value.status == 0, value.longitude.isFinite else { throw SkyError.astronomy(Int(value.status)) }
        return Position(longitude: value.longitude, speed: value.longitude_speed)
    }
    private struct Aspect { var name: String; var angle: Int; var orb: Double; var polarity: Double }
    private func matchingAspect(_ first: Double, _ second: Double, maximumOrb: Double) -> Aspect? {
        let separation = SkyMath.separation(first, second)
        let options: [(Int, String, Double)] = [(0, "合", 0), (60, "六合", 0.3), (90, "刑", -0.3), (120, "拱", 0.35), (180, "冲", -0.3)]
        guard let match = options.min(by: { abs(separation - Double($0.0)) < abs(separation - Double($1.0)) }) else { return nil }
        let orb = abs(separation - Double(match.0))
        return orb <= maximumOrb ? Aspect(name: match.1, angle: match.0, orb: orb, polarity: match.2) : nil
    }
    private func planetTopic(_ index: Int) -> String {
        switch index { case 1, 3: "relationship"; case 2: "communication"; case 4, 6: "career"; case 5: "finance"; default: "general" }
    }
    private func topic(_ palace: String) -> String {
        if palace.contains("财帛") { return "finance" }
        if palace.contains("官禄") { return "career" }
        if palace.contains("夫妻") || palace.contains("交友") || palace.contains("仆役") { return "relationship" }
        return "general"
    }
    private func mutagenBias(_ name: String) -> (Double, String) {
        if name.contains("忌") { return (-0.3, "牵挂、反复与需要审慎处理的主题") }
        if name.contains("禄") { return (0.35, "资源与机会") }
        if name.contains("权") { return (0.15, "行动、责任与主导") }
        if name.contains("科") { return (0.2, "条理、学习与可见度") }
        return (0, "中性主题")
    }
    private func unavailable(_ method: OracleMethod, _ message: String) -> OracleResult {
        OracleResult(method: method, status: .unavailable, headline: message,
                     rows: [], limitations: [message], provenance: "本地输入校验；未生成替代盘面")
    }
    private func resourceURL() throws -> URL {
        let bundle = Bundle.main
        let candidates = [
            bundle.url(forResource: "iztro.bundle", withExtension: "js", subdirectory: "Sky"),
            bundle.url(forResource: "iztro.bundle", withExtension: "js", subdirectory: "Resources/Sky"),
            bundle.url(forResource: "iztro.bundle", withExtension: "js")
        ]
        if let url = candidates.compactMap({ $0 }).first { return url }
        if let root = ProcessInfo.processInfo.environment["BLINDORACLE_RESOURCE_ROOT"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent("Sky/iztro.bundle.js")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw SkyError.resourceMissing
    }
}

private struct ZiweiChart: Decodable {
    var solarDate: String?
    var lunarDate: String?
    var chineseDate: String?
    var time: String?
    var fiveElementsClass: String?
    var earthlyBranchOfSoulPalace: String?
    var earthlyBranchOfBodyPalace: String?
    var palaces: [ZiweiPalace]
    var horoscope: ZiweiHoroscope?
}
private struct ZiweiPalace: Decodable {
    var index: Int
    var name: String
    var isBodyPalace: Bool
    var heavenlyStem: String
    var earthlyBranch: String
    var majorStars: [ZiweiStar]
    var minorStars: [ZiweiStar]
    var decadal: ZiweiDecadal?
}
private struct ZiweiStar: Decodable {
    var name: String
    var brightness: String
    var mutagen: String
    var display: String { name + (brightness.isEmpty ? "" : "[\(brightness)]") + (mutagen.isEmpty ? "" : "·\(mutagen)") }
}
private struct ZiweiDecadal: Decodable { var range: [Int] }
private struct ZiweiHoroscope: Decodable { var decadal: ZiweiLayer?; var age: ZiweiLayer?; var yearly: ZiweiLayer? }
private struct ZiweiLayer: Decodable {
    var index: Int?
    var heavenlyStem: String?
    var earthlyBranch: String?
    var mutagen: [String]?
    var nominalAge: Int?
}
