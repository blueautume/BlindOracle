import Foundation

struct TarotPlugin: OraclePlugin {
    let descriptor = OraclePluginDescriptor(
        method: .tarot, version: "1.0.0",
        summary: "由用户洗牌、选取并翻开三张经典韦特塔罗牌，以现状、影响、建议三个牌位读取本地正逆位英文牌义。",
        requiredFields: [], optionalFields: [],
        supportedQuestions: ["具体事情", "自我反思", "关系困惑", "进退选择", "近期安排"],
        outputDescription: "用户实际抽取的三张牌、固定牌位、正逆位与本地牌义关键词；保留原始英文供AI按问题解读。",
        limitations: ["必须先完成三张不重复的用户抽牌；缺少抽牌时不自动代抽。", "牌义是象征性解释文本，不作为现实事件的事实或概率。"],
        source: "LindseyB/tarot-api 319ce18；经典Rider–Waite–Smith牌面扫描，经luciellaes整理。",
        license: "牌义与API仓库MIT；经典牌面公版来源说明见Tarot/ThirdParty-Tarot-Sources.txt。"
    )

    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard TarotDeck.cards.count == 78 else {
            return NativeCalendar.unavailable(.tarot, "本地78张塔罗牌库未完整加载，未补造牌义或抽牌结果。")
        }
        guard let draws = input.tarotDraws, draws.count == TarotDeck.positions.count else {
            return NativeCalendar.unavailable(.tarot, "请先选取并翻开三张塔罗牌，再开始解读。")
        }
        guard Set(draws.map(\.cardID)).count == draws.count,
              draws.map(\.position) == TarotDeck.positions,
              draws.allSatisfy({ TarotDeck.card(id: $0.cardID) != nil }) else {
            return NativeCalendar.unavailable(.tarot, "抽牌记录无效：需要现状、影响、建议三个牌位上的三张不重复有效牌。")
        }

        var rows: [OracleRow] = [
            .init("牌阵", "Three-card spread: Current situation / Influences / Advice"),
            .init("抽牌方式", "User selected and revealed three cards; the saved selections and orientations are used unchanged.")
        ]
        var evidence: [OracleEvidence] = []
        for (index, draw) in draws.enumerated() {
            guard let card = TarotDeck.card(id: draw.cardID) else { continue }
            let orientation = draw.isReversed ? "Reversed" : "Upright"
            let keywords = (draw.isReversed ? card.reversed : card.upright).joined(separator: "; ")
            rows.append(.init("\(TarotDeck.localizedPositions[index]) · \(draw.position)", "\(card.localizedName) / \(card.name) · \(orientation)"))
            rows.append(.init("第\(index + 1)张牌义 · \(orientation)", keywords))
            evidence.append(.init(
                id: "tarot-\(index + 1)-\(card.id)",
                statement: "Position: \(draw.position). Card: \(card.name). Orientation: \(orientation). Reference keywords: \(keywords).",
                strength: 0.3, topic: "tarot-symbolism"
            ))
        }
        var result = OracleResult(
            method: .tarot, headline: "三张塔罗 · 现状 / 影响 / 建议", rows: rows, evidence: evidence,
            limitations: ["已按保存的用户抽牌读取对应正逆位牌义；牌义为象征性参考，需结合问题解释，不代表事件概率。"],
            provenance: "Local 78-card corpus · LindseyB/tarot-api MIT · 319ce18f1b583035e00c63854a2a405a0088bc73"
        )
        result.tarotDraws = draws
        return result
    }
}
