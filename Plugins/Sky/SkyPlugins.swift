import Foundation
import JavaScriptCore

enum SkyPlugins {
    static var all: [any OraclePlugin] { [ZiweiPlugin(), WesternAstrologyPlugin()] }
}

struct ZiweiPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        OraclePluginDescriptor(
            method: .ziwei, version: "1.0.0+iztro.2.6.3",
            summary: L10n.text("完全离线的紫微斗数排盘：十二宫、主辅星、亮度、生年四化、大限与问事时刻流年四化。", "Calculates a Zi Wei Dou Shu chart on device, including twelve palaces, major and minor stars, brightness, birth transformations, decade cycles and annual transformations."),
            requiredFields: [.birthDate, .birthTime, .gender, .birthTimeZone],
            optionalFields: [.birthPlace],
            supportedQuestions: [L10n.text("本人事业与财务主题", "Career and finances"), L10n.text("关系主题", "Relationships"), L10n.text("长期趋势与本命结构", "Long-term patterns and birth chart")],
            outputDescription: L10n.text("十二宫独立数据、生年四化、大限、小限与流年；固定规则产生符号性证据，不生成事实性命运预测。", "Twelve palaces, birth transformations, decade and annual cycles, with symbolic cues from the traditional rules."),
            limitations: [L10n.text("出生时间或排盘性别不确定时不生成唯一命盘。", "A birth time and chart gender are required to produce a unique chart."), L10n.text("采用 iztro 2.6.3 默认三合排盘配置，闰月按前后半月调整；不覆盖所有流派。", "Uses the default San He rules in iztro 2.6.3, with a half-month adjustment for leap months."), L10n.text("时区采用用户确认的出生地时区，未作真太阳时校正。", "Uses the confirmed birth time zone without a true solar time correction.")],
            source: "https://github.com/SylarLong/iztro", license: L10n.text("MIT；依赖许可证随应用内置", "MIT · dependency licenses included in the app"))
    }

    func calculate(_ input: OracleInput) async throws -> OracleResult {
        try await SkyCalculator.shared.ziwei(input)
    }
}

struct WesternAstrologyPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        OraclePluginDescriptor(
            method: .astrology, version: "1.0.0+astronomy.865d3da",
            summary: L10n.text("完全离线的热带黄道星位、十大天体、主要相位及行运。出生时间和坐标完整时计算上升点、天顶与等宫制。", "Calculates tropical zodiac positions for ten bodies, major aspects and transits on device. Birth time and coordinates enable the Ascendant, Midheaven and equal houses."),
            requiredFields: [.birthDate, .birthTimeZone],
            optionalFields: [.birthTime, .birthCoordinates, .birthPlace],
            supportedQuestions: [L10n.text("本人当前阶段", "Current life phase"), L10n.text("关系与行动节奏", "Relationships and timing an action"), L10n.text("本命星位与当前行运", "Natal positions and current transits")],
            outputDescription: L10n.text("出生及问事时刻的地心黄经、本命相位、行运相位；符合条件时给出等宫制宫头。", "Geocentric ecliptic longitudes at birth and casting, natal and transit aspects, and equal house cusps when the birth data is complete."),
            limitations: [L10n.text("采用 Astronomy Engine 内置解析模型，不是 Swiss Ephemeris；支持公历 1900–2100 年。", "Uses the built-in Astronomy Engine analytical model for Gregorian years 1900–2100."), L10n.text("仅支持热带黄道、地心视位置和等宫制；未实现 Placidus、小行星、合盘和推运。", "Supports the tropical zodiac, apparent geocentric positions and equal houses. Placidus, asteroids, synastry and progressions are outside its scope."), L10n.text("时间不确定时只输出出生日期的全天星位区间，不生成宫位和精确相位。", "If birth time is unknown, the result shows a full-day position range without houses or exact aspects."), L10n.text("纬度绝对值达到 66° 时不计算宫位。", "Houses require a latitude between 66° S and 66° N, excluding the endpoints.")],
            source: "https://github.com/cosinekitty/astronomy", license: "MIT")
    }

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
        let chinese = ["白羊", "金牛", "双子", "巨蟹", "狮子", "处女", "天秤", "天蝎", "射手", "摩羯", "水瓶", "双鱼"]
        let english = ["Aries", "Taurus", "Gemini", "Cancer", "Leo", "Virgo", "Libra", "Scorpio", "Sagittarius", "Capricorn", "Aquarius", "Pisces"]
        let names = AppLanguage.current.isEnglish ? english : chinese
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
        case .resourceMissing: L10n.text("本地紫微排盘资源缺失，请检查安装包。", "The local Zi Wei chart resource is missing. Check the app installation.")
        case .javascript(let detail): L10n.text("紫微排盘未完成：\(detail)", "The Zi Wei chart could not be calculated: \(detail)")
        case .astronomy(let code): L10n.text("本地天文计算返回错误 \(code)。", "The local astronomy engine returned error \(code).")
        }
    }
}

/// Serializes JavaScriptCore contexts and Astronomy Engine's internal caches.
private actor SkyCalculator {
    static let shared = SkyCalculator()

    func ziwei(_ input: OracleInput) throws -> OracleResult {
        let start = Date()
        guard let birth = input.profile.birthDate, !input.profile.unknownFields.contains(.birthDate) else {
            return unavailable(.ziwei, L10n.text("出生日期未确定，暂不生成紫微命盘。", "A birth date is required for a Zi Wei chart."))
        }
        guard input.profile.birthTimeKnown, !input.profile.unknownFields.contains(.birthTime) else {
            return unavailable(.ziwei, L10n.text("出生时辰不确定：十二宫和星曜落点依赖时辰，暂不生成唯一命盘。", "A known birth time is needed to place the twelve palaces and stars."))
        }
        guard ["男", "女"].contains(input.profile.sex), !input.profile.unknownFields.contains(.gender) else {
            return unavailable(.ziwei, L10n.text("紫微排盘需要确认排盘性别；未确定时不代填。", "Confirm the chart gender to calculate a Zi Wei chart."))
        }
        guard let zone = TimeZone(identifier: input.profile.birthTimeZoneID), !input.profile.unknownFields.contains(.birthTimeZone) else {
            return unavailable(.ziwei, L10n.text("出生地时区未确定，暂不生成命盘。", "The birth time zone is required."))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: birth)
        guard let year = components.year, (1900...2100).contains(year) else {
            return unavailable(.ziwei, L10n.text("当前离线版本仅支持 1900–2100 年出生日期。", "This offline version supports birth dates from 1900 to 2100."))
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
            throw SkyError.javascript(L10n.text("无法创建本地运行环境", "Unable to initialize the local chart engine"))
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
            throw SkyError.javascript(L10n.text("本地排盘未返回有效数据", "The local engine did not return valid chart data"))
        }
        let chart = try JSONDecoder().decode(ZiweiChart.self, from: resultData)
        guard chart.palaces.count == 12 else { throw SkyError.javascript(L10n.text("命盘宫位数无效", "The chart has an invalid number of palaces")) }
        var rows: [OracleRow] = [
            .init(L10n.text("公历", "Gregorian date"), chart.solarDate ?? ""), .init(L10n.text("农历", "Lunar date"), ZiweiDisplay.lunarDate(chart.lunarDate ?? "")),
            .init(L10n.text("干支", "Stems and branches"), ZiweiDisplay.pillars(chart.chineseDate ?? "")), .init(L10n.text("五行局", "Five Element configuration"), ZiweiDisplay.configuration(chart.fiveElementsClass ?? "")),
            .init(L10n.text("命宫 / 身宫", "Life palace / Body palace"), "\(NativeCalendar.stemBranch(chart.earthlyBranchOfSoulPalace ?? "")) / \(NativeCalendar.stemBranch(chart.earthlyBranchOfBodyPalace ?? ""))"),
            .init(L10n.text("时区与时辰", "Time zone and hour"), "\(zone.identifier) · \(ZiweiDisplay.hour(chart.time ?? ""))"),
            .init(L10n.text("流派配置", "Chart rules"), L10n.text("三合排盘；农历年界；早晚子时分开；闰月前后半月调整", "San He chart; lunar year boundary; early and late Zi hours are separate; leap months use a half-month adjustment."))
        ]
        for palace in chart.palaces {
            let stars = palace.majorStars + palace.minorStars
            let starText = stars.map { $0.display }.joined(separator: L10n.text("、", ", "))
            let range = palace.decadal?.range.map(String.init).joined(separator: "–") ?? ""
            let body = palace.isBodyPalace ? L10n.text(" · 身宫", " · Body palace") : ""
            let pillars = palace.heavenlyStem + palace.earthlyBranch
            let title = L10n.text("\(palace.name)（\(pillars)）", "\(ZiweiDisplay.palace(palace.name)) (\(NativeCalendar.stemBranch(pillars)))")
            let starList = starText.isEmpty ? L10n.text("无主辅星", "No major or minor stars") : starText
            let value = L10n.text("\(starList)\(body)；大限 \(range) 虚岁", "\(starList)\(body); decade cycle, East Asian age \(range)")
            rows.append(.init(title, value))
        }
        var evidence: [OracleEvidence] = []
        for palace in chart.palaces {
            for star in palace.majorStars + palace.minorStars where !star.mutagen.isEmpty {
                let bias = mutagenBias(star.mutagen)
                evidence.append(.init(id: "ziwei.birth.\(palace.index).\(star.name).\(star.mutagen)",
                    statement: L10n.text("生年\(star.name)\(star.mutagen)落\(palace.name)；在传统四化中作为\(bias.1)的符号线索，不能单独断具体事件。",
                        "Birth transformation: \(NativeCalendar.pinyin(star.name)) (\(ZiweiDisplay.transformation(star.mutagen))) in the \(ZiweiDisplay.palace(palace.name)). Traditional themes include \(bias.1)."),
                    polarity: bias.0, strength: 0.5, topic: topic(palace.name)))
            }
        }
        if let yearly = chart.horoscope?.yearly {
            rows.append(.init(L10n.text("问事流年", "Casting year"), NativeCalendar.stemBranch((yearly.heavenlyStem ?? "") + (yearly.earthlyBranch ?? ""))))
            if let mutagen = yearly.mutagen, mutagen.count == 4 {
                let names = ["化禄", "化权", "化科", "化忌"]
                rows.append(.init(L10n.text("流年四化", "Annual Four Transformations"), zip(mutagen, names).map { name, transformation in
                    L10n.text(name + transformation, "\(NativeCalendar.pinyin(name)) · \(ZiweiDisplay.transformation(transformation))")
                }.joined(separator: L10n.text("、", ", "))))
                for (index, name) in mutagen.enumerated() {
                    if let palace = chart.palaces.first(where: { ($0.majorStars + $0.minorStars).contains(where: { $0.name == name }) }) {
                        let bias = mutagenBias(names[index])
                        evidence.append(.init(id: "ziwei.yearly.\(index)",
                            statement: L10n.text("问事流年\(name)\(names[index])对应本命\(palace.name)，传统象征为\(bias.1)。",
                                "Annual transformation: \(NativeCalendar.pinyin(name)) (\(ZiweiDisplay.transformation(names[index]))) in the natal \(ZiweiDisplay.palace(palace.name)). Traditional themes include \(bias.1)."),
                            polarity: bias.0, strength: 0.45, topic: topic(palace.name)))
                    }
                }
            }
        }
        if let age = chart.horoscope?.age?.nominalAge { rows.append(.init(L10n.text("问事虚岁", "East Asian age at casting"), String(age))) }
        if let decadal = chart.horoscope?.decadal,
           let index = decadal.index, chart.palaces.indices.contains(index) {
            rows.append(.init(L10n.text("当前大限宫", "Current decade palace"), ZiweiDisplay.palace(chart.palaces[index].name)))
        }
        let life = chart.palaces.first { $0.name == "命宫" }
        let configuration = ZiweiDisplay.configuration(chart.fiveElementsClass ?? L10n.text("紫微命盘", "Zi Wei chart"))
        let lifeBranch = NativeCalendar.stemBranch(life?.earthlyBranch ?? "")
        let lifeStars = life?.majorStars.map { NativeCalendar.pinyin($0.name) }.joined(separator: L10n.text("、", ", ")) ?? ""
        let lifeLabel = L10n.text("命宫\(lifeBranch)", "Life palace: \(lifeBranch)")
        let headline = "\(configuration) · \(lifeLabel) · \(lifeStars)"
        var result = OracleResult(method: .ziwei, version: "1.0.0+iztro.2.6.3", headline: headline,
            rows: rows, evidence: evidence,
            limitations: ZiweiPlugin().descriptor.limitations + [L10n.text("证据强度是固定规则参数，非验证过的预测概率。", "Cue weights are fixed rules and do not measure the probability of an event.")],
            provenance: L10n.text("设备本地 JavaScriptCore · iztro 2.6.3（MIT）· 无网络接口", "On-device JavaScriptCore · iztro 2.6.3 (MIT) · no network access"))
        result.durationMilliseconds = Date().timeIntervalSince(start) * 1000
        return result
    }

    func astrology(_ input: OracleInput) throws -> OracleResult {
        let start = Date()
        guard let birth = input.profile.birthDate, !input.profile.unknownFields.contains(.birthDate) else {
            return unavailable(.astrology, L10n.text("出生日期未确定，暂不计算本命星位。", "A birth date is required for natal positions."))
        }
        guard let zone = TimeZone(identifier: input.profile.birthTimeZoneID), !input.profile.unknownFields.contains(.birthTimeZone) else {
            return unavailable(.astrology, L10n.text("出生地时区未确定，暂不计算星位。", "The birth time zone is required for planetary positions."))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard (1900...2100).contains(calendar.component(.year, from: birth)),
              (1900...2100).contains(calendar.component(.year, from: input.castingDate)) else {
            return unavailable(.astrology, L10n.text("当前本地天文模块支持公历 1900–2100 年。", "The local astronomy engine supports Gregorian years 1900–2100."))
        }
        if !input.profile.birthTimeKnown || input.profile.unknownFields.contains(.birthTime) {
            let dayStart = calendar.startOfDay(for: birth)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            var rows = [OracleRow(L10n.text("计算范围", "Calculation scope"), L10n.text("出生地时区 \(zone.identifier) 的出生日期全天，非精确时刻命盘", "Full birth date in \(zone.identifier), without an exact birth time"))]
            for (index, name) in planetNames.enumerated() {
                let first = try position(index, dayStart)
                let last = try position(index, dayEnd)
                rows.append(.init(name, "\(SkyMath.zodiac(first.longitude)) → \(SkyMath.zodiac(last.longitude))"))
            }
            return OracleResult(method: .astrology, version: "1.0.0+astronomy.865d3da", status: .partial,
                headline: L10n.text("出生时刻未确定 · 全天星位区间", "Birth time unknown · full-day position range"), rows: rows,
                limitations: [L10n.text("未选择任意时刻冒充出生时间；区间端点不代表已确定的出生星位。", "The endpoints show the possible range over the birth date."), L10n.text("不输出宫位、上升点、本命精确相位和行运判词。", "Houses, the Ascendant, exact natal aspects and transit interpretation require a known birth time.")],
                provenance: L10n.text("Astronomy Engine C · 本地全天端点计算", "Astronomy Engine C · full-day endpoints calculated on device"))
        }

        let natal = try planetNames.indices.map { try position($0, birth) }
        let current = try planetNames.indices.map { try position($0, input.castingDate) }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.timeZone = zone
        if AppLanguage.current.isEnglish { formatter.setLocalizedDateFormatFromTemplate("yMMMdjmz") }
        else { formatter.dateFormat = "yyyy-MM-dd HH:mm zzz" }
        var rows: [OracleRow] = [
            .init(L10n.text("出生时刻", "Birth time"), formatter.string(from: birth)),
            .init(L10n.text("黄道与坐标", "Zodiac and coordinates"), L10n.text("热带黄道 · 地心视位置 · 真春分点（日期）", "Tropical zodiac · apparent geocentric positions · true equinox of date")),
            .init(L10n.text("计算内核", "Calculation engine"), L10n.text("Astronomy Engine 解析模型 · 设备本地", "Astronomy Engine analytical model · on device"))
        ]
        for (index, name) in planetNames.enumerated() {
            let retrograde = natal[index].speed < 0 ? L10n.text(" · 逆行", " · retrograde") : ""
            rows.append(.init(L10n.text("本命\(name)", "Natal \(name)"), "\(SkyMath.zodiac(natal[index].longitude))\(retrograde)"))
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
                rows.append(.init(L10n.text("出生坐标", "Birth coordinates"), String(format: "%.4f°, %.4f°", latitude, longitude)))
                rows.append(.init(L10n.text("上升点 ASC", "Ascendant (ASC)"), SkyMath.zodiac(ascendant)))
                rows.append(.init(L10n.text("天顶 MC", "Midheaven (MC)"), SkyMath.zodiac(midheaven)))
                rows.append(.init(L10n.text("宫制", "House system"), L10n.text("等宫制：第一宫宫头为上升点，其后每宫 30°；MC 不强制等于第十宫宫头", "Equal houses: the first cusp is the Ascendant and each house spans 30°. The Midheaven can differ from the tenth cusp.")))
                for house in 0..<12 { rows.append(.init(L10n.text("第\(house + 1)宫宫头", "House \(house + 1) cusp"), SkyMath.zodiac(ascendant + Double(house * 30)))) }
                for index in natal.indices {
                    let house = Int(SkyMath.normalize(natal[index].longitude - ascendant) / 30) + 1
                    rows.append(.init(L10n.text("\(planetNames[index])落宫", "\(planetNames[index]) house"), L10n.text("第\(house)宫（等宫制）", "House \(house) (equal houses)")))
                }
            } else { limitations.append(L10n.text("出生坐标无效或超出当前宫位支持纬度，宫位未计算。", "Houses are unavailable because the birth coordinates are invalid or outside the supported latitude range.")) }
        } else { limitations.append(L10n.text("未确认出生地经纬度，只计算地心星位及相位，未计算上升点和宫位。", "Birth coordinates are unconfirmed. Geocentric positions and aspects are shown without an Ascendant or houses.")) }

        var evidence: [OracleEvidence] = []
        var natalAspects: [(String, Double)] = []
        for first in natal.indices {
            for second in natal.indices where second > first {
                if let aspect = matchingAspect(natal[first].longitude, natal[second].longitude, maximumOrb: 6) {
                    let orb = String(format: "%.2f", aspect.orb)
                    let label = L10n.text("\(planetNames[first])\(aspect.name)\(planetNames[second])（容许度 \(orb)°）",
                                          "\(planetNames[first]) \(aspect.name) \(planetNames[second]) (orb \(orb)°)")
                    natalAspects.append((label, aspect.orb))
                }
            }
        }
        for (index, aspect) in natalAspects.sorted(by: { $0.1 < $1.1 }).prefix(12).enumerated() {
            rows.append(.init(L10n.text("本命相位 \(index + 1)", "Natal aspect \(index + 1)"), aspect.0))
        }
        var transitAspects: [(label: String, orb: Double, polarity: Double, topic: String, id: String)] = []
        for transiting in 2..<10 {
            for target in 0..<7 {
                if let aspect = matchingAspect(current[transiting].longitude, natal[target].longitude, maximumOrb: 3) {
                    let label = L10n.text("行运\(planetNames[transiting])\(aspect.name)本命\(planetNames[target])",
                                          "Transit \(planetNames[transiting]) \(aspect.name) natal \(planetNames[target])")
                    transitAspects.append((label, aspect.orb,
                                           aspect.polarity, planetTopic(target), "sky.transit.\(transiting).\(target).\(aspect.angle)"))
                }
            }
        }
        rows.append(.init(L10n.text("行运时刻", "Transit time"), ISO8601DateFormatter().string(from: input.castingDate)))
        for (index, aspect) in transitAspects.sorted(by: { $0.orb < $1.orb }).prefix(10).enumerated() {
            rows.append(.init(L10n.text("行运相位 \(index + 1)", "Transit aspect \(index + 1)"), L10n.text("\(aspect.label)（容许度 \(String(format: "%.2f", aspect.orb))°）", "\(aspect.label) (orb \(String(format: "%.2f", aspect.orb))°)")))
            let wording = aspect.polarity > 0 ? L10n.text("协同", "cooperation")
                : aspect.polarity < 0 ? L10n.text("张力", "tension") : L10n.text("主题集中", "a shared focus")
            evidence.append(.init(id: aspect.id, statement: L10n.text("\(aspect.label)，传统相位象征偏向\(wording)；只是符号规则，不能直接推为现实吉凶。", "\(aspect.label). The traditional association is \(wording), offered as a symbolic cue."),
                polarity: aspect.polarity, strength: max(0.2, 1 - aspect.orb / 3), topic: aspect.topic))
        }
        if evidence.isEmpty {
            evidence.append(.init(id: "sky.no-tight-transit", statement: L10n.text("当前行运与所检验本命点之间没有落入 3° 容许度的主要相位；不强行推断事件。", "No major transit aspect is within a 3° orb of the checked natal positions."), strength: 0.2))
        }
        var result = OracleResult(method: .astrology, version: "1.0.0+astronomy.865d3da", status: hasHouses ? .complete : .partial,
            headline: L10n.text("太阳\(SkyMath.zodiac(natal[0].longitude)) · 月亮\(SkyMath.zodiac(natal[1].longitude))", "Sun: \(SkyMath.zodiac(natal[0].longitude)) · Moon: \(SkyMath.zodiac(natal[1].longitude))"),
            rows: rows, evidence: evidence, limitations: limitations,
            provenance: L10n.text("设备本地 Astronomy Engine C（MIT）；星历系数编译内置，无星历文件下载", "On-device Astronomy Engine C (MIT) · compiled ephemeris coefficients"))
        result.durationMilliseconds = Date().timeIntervalSince(start) * 1000
        return result
    }

    private var planetNames: [String] {
        AppLanguage.current.isEnglish
            ? ["Sun", "Moon", "Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune", "Pluto"]
            : ["太阳", "月亮", "水星", "金星", "火星", "木星", "土星", "天王星", "海王星", "冥王星"]
    }
    private struct Position { var longitude: Double; var speed: Double }
    private func position(_ body: Int, _ date: Date) throws -> Position {
        let value = bo_sky_geocentric(Int32(body), date.timeIntervalSince1970)
        guard value.status == 0, value.longitude.isFinite else { throw SkyError.astronomy(Int(value.status)) }
        return Position(longitude: value.longitude, speed: value.longitude_speed)
    }
    private struct Aspect { var name: String; var angle: Int; var orb: Double; var polarity: Double }
    private func matchingAspect(_ first: Double, _ second: Double, maximumOrb: Double) -> Aspect? {
        let separation = SkyMath.separation(first, second)
        let options: [(Int, String, Double)] = [(0, L10n.text("合", "conjunct"), 0), (60, L10n.text("六合", "sextile"), 0.3),
            (90, L10n.text("刑", "square"), -0.3), (120, L10n.text("拱", "trine"), 0.35),
            (180, L10n.text("冲", "opposite"), -0.3)]
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
        if name.contains("忌") { return (-0.3, L10n.text("牵挂、反复与需要审慎处理的主题", "attachments, recurring concerns and issues that need care")) }
        if name.contains("禄") { return (0.35, L10n.text("资源与机会", "resources and opportunities")) }
        if name.contains("权") { return (0.15, L10n.text("行动、责任与主导", "initiative, responsibility and leadership")) }
        if name.contains("科") { return (0.2, L10n.text("条理、学习与可见度", "organization, learning and visibility")) }
        return (0, L10n.text("中性主题", "neutral themes"))
    }
    private func unavailable(_ method: OracleMethod, _ message: String) -> OracleResult {
        OracleResult(method: method, status: .unavailable, headline: message,
                     rows: [], limitations: [message], provenance: L10n.text("本地输入校验；未生成替代盘面", "On-device input validation"))
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
    var display: String {
        let gloss = brightness.isEmpty ? "" : L10n.text("[\(brightness)]", " [\(ZiweiDisplay.brightness(brightness))]")
        let change = mutagen.isEmpty ? "" : L10n.text("·\(mutagen)", " · \(ZiweiDisplay.transformation(mutagen))")
        return NativeCalendar.pinyin(name) + gloss + change
    }
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


// The bridge uses Chinese identifiers for stable star matching and calculation.
// These functions localize display values after decoding the chart.
private enum ZiweiDisplay {
    static func palace(_ name: String) -> String {
        let english = ["命宫": "Life palace", "兄弟": "Siblings palace", "夫妻": "Partner palace",
                       "子女": "Children palace", "财帛": "Wealth palace", "疾厄": "Health palace",
                       "迁移": "Travel palace", "交友": "Friends palace", "仆役": "Friends palace",
                       "官禄": "Career palace", "田宅": "Property palace", "福德": "Well-being palace", "父母": "Parents palace"]
        return L10n.text(name, english[name] ?? NativeCalendar.pinyin(name))
    }

    static func transformation(_ value: String) -> String {
        let names = ["禄": "Lu (resources)", "权": "Quan (authority)", "科": "Ke (recognition)", "忌": "Ji (obstacles)"]
        return names[value.replacingOccurrences(of: "化", with: "")] ?? NativeCalendar.pinyin(value)
    }

    static func brightness(_ value: String) -> String {
        let names = ["庙": "exalted", "旺": "strong", "得": "supported", "利": "favorable",
                     "平": "neutral", "不": "weak", "陷": "fallen"]
        return names[value] ?? NativeCalendar.pinyin(value)
    }

    static func hour(_ value: String) -> String {
        guard AppLanguage.current.isEnglish, !value.isEmpty else { return value }
        if value == "早子时" { return "Early Zi hour" }
        if value == "晚子时" { return "Late Zi hour" }
        return NativeCalendar.stemBranch(String(value.dropLast())) + " hour"
    }

    static func pillars(_ value: String) -> String {
        guard AppLanguage.current.isEnglish else { return value }
        return value.split(separator: " ").map { NativeCalendar.stemBranch(String($0)) }.joined(separator: " / ")
    }

    static func configuration(_ value: String) -> String {
        guard AppLanguage.current.isEnglish, let phase = value.first,
              let index = NativeCalendar.elements.firstIndex(of: String(phase)),
              let count = value.dropFirst().first, let number = digits[count] else { return value }
        return "\(NativeCalendar.element(index)) \(number) configuration"
    }

    private static let digits: [Character: Int] =
        ["〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]

    static func lunarDate(_ value: String) -> String {
        guard AppLanguage.current.isEnglish else { return value }
        let parts = value.split(whereSeparator: { $0 == "年" || $0 == "月" })
        guard parts.count == 3 else { return NativeCalendar.pinyin(value) }
        let year = parts[0].compactMap { digits[$0] }.map(String.init).joined()
        let leap = parts[1].hasPrefix("闰") || parts[1].hasPrefix("閏")
        let monthText = leap ? parts[1].dropFirst() : parts[1]
        let conventionalMonths: [Substring: Int] = ["正": 1, "冬": 11, "腊": 12, "臘": 12]
        let month = conventionalMonths[monthText] ?? lunarNumber(monthText)
        return "\(year) · \(leap ? "Leap month" : "Month") \(month), day \(lunarNumber(parts[2]))"
    }

    private static func lunarNumber(_ value: Substring) -> Int {
        var number = 0
        for character in value where character != "初" {
            switch character {
            case "十": number = max(1, number) * 10
            case "廿": number = 20
            case "卅": number = 30
            default: number += digits[character] ?? 0
            }
        }
        return number
    }
}
