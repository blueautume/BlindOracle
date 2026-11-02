import SwiftUI

/// The exact saved cards also appear when opening a historical result.
struct TarotSpreadView: View {
    let draws: [TarotDraw]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(draws.enumerated()), id: \.offset) { index, draw in
                if let card = TarotDeck.card(id: draw.cardID) {
                    VStack(spacing: 8) {
                        Text(TarotDeck.localizedPositions.indices.contains(index) ? TarotDeck.localizedPositions[index] : draw.position)
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
                        Text(draw.isReversed ? "逆位" : "正位").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(TarotDeck.localizedPositions.indices.contains(index) ? TarotDeck.localizedPositions[index] : draw.position)，\(card.name)，\(draw.isReversed ? "逆位" : "正位")")
                }
            }
        }
        .accessibilityIdentifier("savedTarotSpread")
    }
}
