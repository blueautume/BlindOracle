import Foundation

struct BaziPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        var value = NativeCalendar.descriptor(.bazi,
            summary: L10n.text("按出生经度与均时差计算真太阳时四柱、十神、五行、藏干、纳音与大运。", "Uses birth longitude and the equation of time for apparent-solar Four Pillars, Ten Gods, elements, hidden stems, Na Yin and luck cycles."),
            required: [.birthDate, .birthTimeZone, .birthCoordinates], optional: [.birthTime, .gender],
            questions: [L10n.text("个人阶段", "Personal phases"), L10n.text("长期事业", "Long-term career"), L10n.text("关系", "Relationships"), L10n.text("自我梳理", "Self-reflection")],
            output: L10n.text("真太阳时四柱、十神、五行表层计数、藏干、纳音、旬空；时辰与排盘性别确定时输出起运和八步大运。", "Apparent-solar Four Pillars, Ten Gods, unweighted elements, hidden stems, Na Yin and void branches; luck cycles when birth time and chart gender are known."),
            limitations: [L10n.text("立春与十二节按真实瞬间判断，日柱与时柱按真太阳时；sect 2 零点换日；出生年份1900–2100。", "Year/month boundaries use actual solar-term instants; day/hour pillars use apparent solar time, with sect 2 midnight day changes. Birth years: 1900–2100."),
                          L10n.text("出生地经纬度不确定时不排盘；时辰未知时列候选，不用默认时刻生成四柱。", "No chart without confirmed birth coordinates. Unknown birth time produces candidates, never four pillars from a default clock time."),
                          L10n.text("尚未实现神煞、格局和喜用神完整判断；不预测疾病、寿命或必然事件。", "Full Shen Sha, chart pattern and favorable-element analysis are unavailable. The chart does not predict illness, lifespan or inevitable events.")])
        value.version = "2.0.0"
        return value
    }

    func calculate(_ input: OracleInput) async throws -> OracleResult {
        await TrueSolarBaziEngine.shared.calculate(profile: input.profile).result
    }
}
