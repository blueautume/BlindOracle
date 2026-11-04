import Foundation

struct TarotCard: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let localizedName: String
    let upright: [String]
    let reversed: [String]
    let imageFilename: String
}

/// The completed user selection is the source of truth, including its order
/// and orientation. Reopening a saved reading never draws replacement cards.
struct TarotDraw: Codable, Equatable, Sendable {
    var cardID: String
    var isReversed: Bool
    var position: String
}

/// A proposed focus is separate from the locally confirmed request and draw.
struct TarotClarificationSuggestion: Codable, Equatable, Sendable {
    var focus: String
    var originalPosition: String? = nil

    var isValid: Bool {
        let text = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= 160
            && (originalPosition.map(TarotDeck.positions.contains) ?? true)
    }
}

struct TarotClarificationRequest: Codable, Equatable, Identifiable, Sendable {
    static let maximumRounds = 2

    var id: UUID = UUID()
    var focus: String
    var originalPosition: String? = nil
    var question: String? = nil

    var isValid: Bool {
        TarotClarificationSuggestion(focus: focus, originalPosition: originalPosition).isValid
    }
}

struct TarotClarificationRound: Codable, Equatable, Identifiable, Sendable {
    let request: TarotClarificationRequest
    let draw: TarotDraw
    var id: UUID { request.id }
}

enum TarotDeck {
    static let positions = ["Current situation", "Influences", "Advice"]
    static let localizedPositions = ["现状", "影响", "建议"]
    static let clarificationPosition = "Clarification"

    static func localizedTitle(for position: String) -> String {
        if AppLanguage.current.isEnglish { return position }
        if position == clarificationPosition { return "澄清" }
        guard let index = positions.firstIndex(of: position) else { return position }
        return localizedPositions[index]
    }

    private struct Archive: Decodable {
        let schemaVersion: Int
        let cards: [TarotCard]
    }

    static let cards: [TarotCard] = {
        guard let url = resourceURL(name: "tarot-cards", extension: "json"),
              let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.schemaVersion == 1,
              archive.cards.count == 78,
              Set(archive.cards.map(\.id)) == expectedIDs,
              archive.cards.allSatisfy({
                  !$0.name.isEmpty && !$0.localizedName.isEmpty && !$0.imageFilename.isEmpty &&
                  !$0.upright.isEmpty && !$0.reversed.isEmpty &&
                  $0.upright.allSatisfy({ !$0.isEmpty }) && $0.reversed.allSatisfy({ !$0.isEmpty })
              }) else { return [] }
        return archive.cards
    }()

    static func card(id: String) -> TarotCard? { cards.first { $0.id == id } }

    static func isValidInitialSpread(_ draws: [TarotDraw]) -> Bool {
        draws.map(\.position) == positions
            && Set(draws.map(\.cardID)).count == draws.count
            && draws.allSatisfy { card(id: $0.cardID) != nil }
    }

    /// A saved clarification belongs to the same deck as the initial spread.
    static func areValidClarificationRounds(_ rounds: [TarotClarificationRound], after initialDraws: [TarotDraw]) -> Bool {
        guard rounds.count <= TarotClarificationRequest.maximumRounds else { return false }
        var cardIDs = Set(initialDraws.map(\.cardID))
        var roundIDs = Set<UUID>()
        return rounds.allSatisfy { round in
            round.request.isValid && roundIDs.insert(round.id).inserted
                && round.draw.position == clarificationPosition && card(id: round.draw.cardID) != nil
                && cardIDs.insert(round.draw.cardID).inserted
        }
    }

    static func canAppendClarification(to input: OracleInput) -> Bool {
        let rounds = input.tarotClarificationRounds ?? []
        guard rounds.count < TarotClarificationRequest.maximumRounds,
              let draws = input.tarotDraws, isValidInitialSpread(draws) else { return false }
        return areValidClarificationRounds(rounds, after: draws)
    }

    static func imageURL(for card: TarotCard) -> URL? {
        let path = card.imageFilename as NSString
        return resourceURL(name: path.deletingPathExtension, extension: path.pathExtension, isImage: true)
    }

    /// Stable Fisher–Yates shuffle with rejection sampling. The final selected
    /// cards, rather than a seed, are persisted in TarotDraw for history.
    static func shuffled(seed: UInt64) -> [TarotCard] {
        var result = cards
        guard result.count > 1 else { return result }
        var random = OracleSeededRandom(seed: seed)
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let bound = UInt64(index + 1)
            let threshold = (UInt64(0) &- bound) % bound
            var value = random.next()
            while value < threshold { value = random.next() }
            result.swapAt(index, Int(value % bound))
        }
        return result
    }

    /// Independently derives orientation without relying on Swift's randomized
    /// String.hashValue or on how many cards have already been flipped.
    static func isReversed(seed: UInt64, cardID: String) -> Bool {
        let identifierHash = cardID.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        var random = OracleSeededRandom(seed: seed ^ identifierHash)
        return random.next() & 1 == 1
    }

    private static let expectedIDs: Set<String> = {
        let majors = (0...21).map { String(format: "major-%02d", $0) }
        let minors = ["wands", "cups", "swords", "pentacles"].flatMap { suit in
            (1...14).map { String(format: "%@-%02d", suit, $0) }
        }
        return Set(majors + minors)
    }()

    private static func resourceURL(name: String, extension ext: String, isImage: Bool = false) -> URL? {
        let directories: [String?] = isImage
            ? ["Tarot/Cards", "Resources/Tarot/Cards", "Cards", "Tarot", nil]
            : ["Tarot", "Resources/Tarot", nil]
        for directory in directories {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: directory) { return url }
        }
        return nil
    }
}
