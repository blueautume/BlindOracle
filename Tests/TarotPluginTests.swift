import XCTest
@testable import BlindOracle

final class TarotPluginTests: XCTestCase {
    private func request(draws: [TarotDraw]? = nil) -> OracleInput {
        var input = OracleInput(question: "接下来如何安排？", profile: OracleProfile(), seed: 42)
        input.tarotDraws = draws
        return input
    }

    private var validDraws: [TarotDraw] {
        [
            .init(cardID: "major-00", isReversed: false, position: TarotDeck.positions[0]),
            .init(cardID: "cups-02", isReversed: true, position: TarotDeck.positions[1]),
            .init(cardID: "swords-14", isReversed: false, position: TarotDeck.positions[2])
        ]
    }

    func testCompleteOfflineDeckHasUniqueCardsMeaningsAndBundledJPEGImages() throws {
        XCTAssertEqual(TarotDeck.cards.count, 78)
        XCTAssertEqual(Set(TarotDeck.cards.map(\.id)).count, 78)
        XCTAssertEqual(TarotDeck.cards.filter { $0.id.hasPrefix("major-") }.count, 22)
        for suit in ["wands", "cups", "swords", "pentacles"] {
            XCTAssertEqual(TarotDeck.cards.filter { $0.id.hasPrefix(suit + "-") }.count, 14)
        }
        for card in TarotDeck.cards {
            XCTAssertFalse(card.upright.isEmpty, card.id)
            XCTAssertFalse(card.reversed.isEmpty, card.id)
            let url = try XCTUnwrap(TarotDeck.imageURL(for: card), card.id)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF], card.id)
        }
    }

    func testSeededShuffleIsRepeatablePermutationAndChangesWithSeed() {
        let first = TarotDeck.shuffled(seed: 42).map(\.id)
        XCTAssertEqual(first, TarotDeck.shuffled(seed: 42).map(\.id))
        XCTAssertEqual(Set(first), Set(TarotDeck.cards.map(\.id)))
        XCTAssertNotEqual(first, TarotDeck.shuffled(seed: 43).map(\.id))
    }

    func testMissingOrIncompleteSelectionDoesNotSilentlyDrawCards() async throws {
        for draws in [nil, [], Array(validDraws.prefix(2))] as [[TarotDraw]?] {
            let result = try await TarotPlugin().calculate(request(draws: draws))
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertTrue(result.rows.isEmpty)
            XCTAssertNil(result.tarotDraws)
        }
    }

    func testSavedSelectionControlsCardsOrientationAndReferenceKeywords() async throws {
        let result = try await TarotPlugin().calculate(request(draws: validDraws))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.tarotDraws, validDraws)
        let reversedCard = try XCTUnwrap(TarotDeck.card(id: "cups-02"))
        XCTAssertEqual(result.rows.first { $0.label == "第2张牌义 · Reversed" }?.value,
                       reversedCard.reversed.joined(separator: "; "))
        XCTAssertTrue(result.evidence[1].statement.contains("Card: \(reversedCard.name). Orientation: Reversed."))
        XCTAssertTrue(result.evidence.allSatisfy { $0.polarity == 0 })
    }

    func testDuplicateUnknownAndMisorderedCardsAreRejected() async throws {
        var duplicate = validDraws
        duplicate[1].cardID = duplicate[0].cardID
        var unknown = validDraws
        unknown[1].cardID = "missing-card"
        var misplaced = validDraws
        misplaced[1].position = TarotDeck.positions[0]
        for draws in [duplicate, unknown, misplaced] {
            let result = try await TarotPlugin().calculate(request(draws: draws))
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertNil(result.tarotDraws)
        }
    }

    func testDrawRecordsRoundTripWithoutChangingSelection() throws {
        let data = try JSONEncoder().encode(validDraws)
        XCTAssertEqual(try JSONDecoder().decode([TarotDraw].self, from: data), validDraws)
    }

    func testSavedClarificationAddsItsOwnMeaningAndLeavesTheOriginalSpreadIntact() async throws {
        var input = request(draws: validDraws)
        let original = try await TarotPlugin().calculate(input)
        let round = TarotClarificationRound(request: .init(focus: "下一步怎么做", originalPosition: TarotDeck.positions[2]),
            draw: .init(cardID: "major-01", isReversed: true, position: TarotDeck.clarificationPosition))
        input.tarotClarificationRounds = [round]

        let result = try await TarotPlugin().calculate(input)
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.tarotDraws, original.tarotDraws)
        XCTAssertEqual(result.tarotClarificationRounds, [round])
        XCTAssertEqual(Array(result.rows.prefix(original.rows.count)), original.rows)
        let card = try XCTUnwrap(TarotDeck.card(id: round.draw.cardID))
        XCTAssertEqual(result.rows.first { $0.label == "澄清牌 1 · 牌义" }?.value, card.reversed.joined(separator: "; "))
        XCTAssertEqual(result.rows.first { $0.label == "澄清牌 1 · 方向" }?.value, "下一步怎么做（对应建议）")
    }

    func testInvalidClarificationCannotProduceFabricatedEvidence() async throws {
        var input = request(draws: validDraws)
        let clarification = TarotClarificationRequest(focus: "补一张")
        input.tarotClarificationRounds = [.init(request: clarification,
            draw: .init(cardID: validDraws[0].cardID, isReversed: true, position: TarotDeck.clarificationPosition))]
        let result = try await TarotPlugin().calculate(input)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertTrue(result.evidence.isEmpty)
        XCTAssertNil(result.tarotClarificationRounds)
    }
}
