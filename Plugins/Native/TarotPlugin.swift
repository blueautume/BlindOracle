import Foundation

struct TarotPlugin: OraclePlugin {
    var descriptor: OraclePluginDescriptor {
        OraclePluginDescriptor(
            method: .tarot, version: "1.0.0",
            summary: L10n.text("由用户选取并翻开三张经典韦特塔罗牌，以现状、影响、建议三个牌位读取英文牌义。后续可以沿用同一牌组补充澄清牌。", "Reveal three Rider–Waite–Smith tarot cards for the current situation, influences and advice. You can draw clarification cards from the same deck."),
            requiredFields: [], optionalFields: [],
            supportedQuestions: [L10n.text("具体事情", "Specific situations"), L10n.text("自我反思", "Self-reflection"), L10n.text("关系困惑", "Relationship questions"), L10n.text("进退选择", "Decisions"), L10n.text("近期安排", "Near-term plans")],
            outputDescription: L10n.text("原三张牌及已确认的每轮澄清牌、正逆位和本地牌义关键词，按各自牌位或澄清方向解读。", "The three original cards and any confirmed clarification cards, with positions, orientations and on-device reference keywords."),
            limitations: [L10n.text("必须先完成三张不重复的用户抽牌；缺少抽牌时不自动代抽。", "Reveal three distinct cards before starting the reading."), L10n.text("牌义是象征性解释文本，不作为现实事件的事实或概率。", "Card meanings are symbolic. They do not establish facts or probabilities about real events.")],
            source: L10n.text("LindseyB/tarot-api 319ce18；经典Rider–Waite–Smith牌面扫描，经luciellaes整理。", "LindseyB/tarot-api, revision 319ce18 · Rider–Waite–Smith scans prepared by luciellaes"),
            license: L10n.text("牌义与API仓库MIT；经典牌面公版来源说明见Tarot/ThirdParty-Tarot-Sources.txt。", "Card meanings and API repository: MIT. See Tarot/ThirdParty-Tarot-Sources.txt for public-domain card artwork.")
        )
    }

    func calculate(_ input: OracleInput) async throws -> OracleResult {
        guard TarotDeck.cards.count == 78 else {
            return NativeCalendar.unavailable(.tarot, L10n.text("本地78张塔罗牌库未完整加载，未补造牌义或抽牌结果。", "The local 78-card deck could not be loaded."))
        }
        guard let draws = input.tarotDraws, draws.count == TarotDeck.positions.count else {
            return NativeCalendar.unavailable(.tarot, L10n.text("请先选取并翻开三张塔罗牌，再开始解读。", "Reveal three cards to start your reading."))
        }
        guard TarotDeck.isValidInitialSpread(draws) else {
            return NativeCalendar.unavailable(.tarot, L10n.text("抽牌记录无效：需要现状、影响、建议三个牌位上的三张不重复有效牌。", "The spread requires one distinct card in each of the three positions: Current situation, Influences and Advice."))
        }
        let clarifications = input.tarotClarificationRounds ?? []
        guard TarotDeck.areValidClarificationRounds(clarifications, after: draws) else {
            return NativeCalendar.unavailable(.tarot, L10n.text("澄清牌记录无效：每轮须确认一张同牌组中未抽过的有效牌。", "Each clarification round requires one card from the same deck that has not already been drawn."))
        }

        var rows: [OracleRow] = [
            .init(L10n.text("牌阵", "Spread"), "Three-card spread: Current situation / Influences / Advice"),
            .init(L10n.text("抽牌方式", "How the cards were drawn"), "User selected and revealed three cards; the saved selections and orientations are used unchanged.")
        ]
        var evidence: [OracleEvidence] = []
        for (index, draw) in draws.enumerated() {
            guard let card = TarotDeck.card(id: draw.cardID) else { continue }
            let orientation = draw.isReversed ? "Reversed" : "Upright"
            let keywords = (draw.isReversed ? card.reversed : card.upright).joined(separator: "; ")
            rows.append(.init(L10n.text("\(TarotDeck.localizedPositions[index]) · \(draw.position)", "\(draw.position)"), L10n.text("\(card.localizedName) / \(card.name) · \(orientation)", "\(card.name) · \(orientation)")))
            rows.append(.init(L10n.text("第\(index + 1)张牌义 · \(orientation)", "Card \(index + 1) keywords · \(orientation)"), keywords))
            evidence.append(.init(
                id: "tarot-\(index + 1)-\(card.id)",
                statement: "Position: \(draw.position). Card: \(card.name). Orientation: \(orientation). Reference keywords: \(keywords).",
                strength: 0.3, topic: "tarot-symbolism"
            ))
        }
        for (index, round) in clarifications.enumerated() {
            let draw = round.draw
            guard let card = TarotDeck.card(id: draw.cardID) else { continue }
            let label = L10n.text("澄清牌 \(index + 1)", "Clarification card \(index + 1)")
            let orientation = draw.isReversed ? "Reversed" : "Upright"
            let keywords = (draw.isReversed ? card.reversed : card.upright).joined(separator: "; ")
            let originalPosition = round.request.originalPosition.map { L10n.text("（对应\(TarotDeck.localizedTitle(for: $0))）", " (\(TarotDeck.localizedTitle(for: $0)))") } ?? ""
            rows.append(.init(L10n.text("\(label) · 方向", "\(label) · focus"), round.request.focus + originalPosition))
            rows.append(.init(label, L10n.text("\(card.localizedName) / \(card.name) · \(orientation)", "\(card.name) · \(orientation)")))
            rows.append(.init(L10n.text("\(label) · 牌义", "\(label) · keywords"), keywords))
            evidence.append(.init(
                id: "tarot-clarification-\(round.id.uuidString)",
                statement: "Clarification \(index + 1). Card: \(card.name). Orientation: \(orientation). Reference keywords: \(keywords).",
                strength: 0.3, topic: "tarot-symbolism"
            ))
        }
        let headline = clarifications.isEmpty ? L10n.text("三张塔罗 · 现状 / 影响 / 建议", "Three-card tarot · Situation / Influences / Advice") : L10n.text("三张塔罗 · 另有\(clarifications.count)张澄清牌", "Three-card tarot · clarification cards: \(clarifications.count)")
        var result = OracleResult(
            method: .tarot, headline: headline, rows: rows, evidence: evidence,
            limitations: [L10n.text("已按保存的用户抽牌读取对应正逆位牌义；牌义为象征性参考，需结合问题解释，不代表事件概率。", "The reading uses the saved cards and their orientations. Their meanings are symbolic and should be considered alongside your question.")],
            provenance: "Local 78-card corpus · LindseyB/tarot-api MIT · 319ce18f1b583035e00c63854a2a405a0088bc73"
        )
        result.tarotDraws = draws
        result.tarotClarificationRounds = clarifications.isEmpty ? nil : clarifications
        return result
    }
}
