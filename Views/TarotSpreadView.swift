import SwiftUI

/// The exact saved cards also appear when opening a historical result.
struct TarotSpreadView: View {
    let draws: [TarotDraw]
    let clarificationRounds: [TarotClarificationRound]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionEyebrow(text: L10n.text("首轮 · 三张牌", "Initial spread · 3 cards"))
                    .accessibilityAddTraits(.isHeader)
                spread(draws)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("savedTarotSpread")
            }
            ForEach(Array(clarificationRounds.enumerated()), id: \.offset) { index, round in
                Divider().overlay(InkTheme.line.opacity(0.6))
                VStack(alignment: .leading, spacing: 10) {
                    SectionEyebrow(text: L10n.text("第\(index + 1)次补牌", "Clarifier \(index + 1)"))
                        .accessibilityAddTraits(.isHeader)
                    Text(round.request.focus)
                        .font(.system(size: 15, design: .serif)).lineSpacing(4)
                        .foregroundStyle(InkTheme.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("savedTarotClarificationFocus-\(index)")
                    if let position = round.request.originalPosition {
                        Text(L10n.text("对应牌位 · \(TarotDeck.localizedTitle(for: position))", "Related position · \(TarotDeck.localizedTitle(for: position))"))
                            .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    }
                    spread([round.draw]).frame(maxWidth: 136)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("savedTarotClarification-\(index)")
            }
        }
    }

    private func spread(_ draws: [TarotDraw]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(draws.enumerated()), id: \.offset) { _, draw in
                if let card = TarotDeck.card(id: draw.cardID) {
                    let title = TarotDeck.localizedTitle(for: draw.position)
                    let orientation = draw.isReversed ? L10n.text("逆位", "Reversed") : L10n.text("正位", "Upright")
                    VStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 11, weight: .medium, design: .serif)).foregroundStyle(InkTheme.cinnabar)
                        Group {
                            if let url = TarotDeck.imageURL(for: card), let image = UIImage(contentsOfFile: url.path) {
                                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                RoundedRectangle(cornerRadius: 5).fill(InkTheme.wash)
                                    .overlay(Text(card.name).font(.caption).padding(8))
                            }
                        }
                        .aspectRatio(300.0 / 527.0, contentMode: .fit)
                        .rotationEffect(.degrees(draw.isReversed ? 180 : 0))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(InkTheme.line, lineWidth: 0.5))
                        Text(card.name).font(.system(size: 11, design: .serif))
                            .multilineTextAlignment(.center).foregroundStyle(InkTheme.ink)
                        Text(orientation).font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([title, card.name, orientation].joined(separator: L10n.text("，", ", ")))
                }
            }
        }
    }
}
