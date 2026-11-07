import Foundation

/// UI operations are a fixed, local catalog. A model can request these operations,
/// but cannot supply executable UI, card identities, coin outcomes or random seeds.
enum OracleInteractionKind: String, Codable, Sendable {
    case numbers, coins, tarot

    var title: String {
        switch self {
        case .numbers: L10n.text("随心留数", "Choose Three Numbers")
        case .coins: L10n.text("六掷成卦", "Cast Six Lines")
        case .tarot: L10n.text("静心抽牌", "Draw Tarot Cards")
        }
    }
}

struct OracleInteractionRequest: Codable, Identifiable, Equatable, Sendable {
    var method: OracleMethod
    var kind: OracleInteractionKind
    var prompt: String
    var tarotClarification: TarotClarificationRequest?
    var id: String {
        guard kind == .tarot, let tarotClarification else { return method.rawValue }
        return "\(method.rawValue):\(tarotClarification.id.uuidString)"
    }
    var title: String { kind == .tarot && tarotClarification != nil ? L10n.text("抽取澄清牌", "Draw a Clarifying Card") : kind.title }
    var displayPrompt: String {
        let defaultChinese = Self.defaultPrompt(for: kind, clarifying: tarotClarification != nil, language: .simplifiedChinese)
        let defaultEnglish = Self.defaultPrompt(for: kind, clarifying: tarotClarification != nil, language: .english)
        if prompt.isEmpty || prompt == defaultChinese || prompt == defaultEnglish ||
            (AppLanguage.current.isEnglish && prompt.range(of: #"^\s*\p{Han}"#, options: .regularExpression) != nil) {
            return AppLanguage.current.isEnglish ? defaultEnglish : defaultChinese
        }
        return prompt
    }
    var tarotPositions: [String] {
        guard kind == .tarot else { return [] }
        return tarotClarification == nil ? TarotDeck.positions : [TarotDeck.clarificationPosition]
    }
    var tarotPositionTitles: [String] { tarotPositions.map(TarotDeck.localizedTitle(for:)) }

    init(method: OracleMethod, kind: OracleInteractionKind, prompt: String = "", tarotClarification: TarotClarificationRequest? = nil) {
        self.method = method; self.kind = kind
        self.tarotClarification = tarotClarification
        let supplied = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = supplied.isEmpty ? Self.defaultPrompt(for: kind, clarifying: tarotClarification != nil, language: .current) : String(supplied.prefix(180))
    }

    private static func defaultPrompt(for kind: OracleInteractionKind, clarifying: Bool, language: AppLanguage) -> String {
        switch kind {
        case .numbers: L10n.text("凭着此刻的心意，留下三个数。", "Enter the first three numbers that come to mind.", language: language)
        case .coins: L10n.text("心中留一问，依次留下六爻。", "Keep your question in mind as you cast each of the six lines.", language: language)
        case .tarot:
            clarifying
                ? L10n.text("围绕这个方向，从余下的牌中选出一张澄清牌。", "Keep the focus in mind and choose one card from the remaining deck.", language: language)
                : L10n.text("静下心，选出属于此问的三张牌。", "Take a moment, then choose three cards for your question.", language: language)
        }
    }
}

struct OracleInteractionResponse: Codable, Equatable, Sendable {
    var requestID: String
    var numbers: [Int] = []
    var lines: [Int] = []
    var tarotDraws: [TarotDraw] = []
    var revealedCount: Int = 0
    /// Editable number slots, including blanks or an unfinished invalid value.
    /// Optional for saved responses written before the editable-number step.
    var numberTexts: [String]? = nil
}

enum NumberInteractionDraft {
    static let count = 3
    static let maximumTextLength = 16

    static func value(in text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, text.count <= maximumTextLength,
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(digits), (1...999).contains(value) else { return nil }
        return value
    }

    static func values(in texts: [String]) -> [Int]? {
        guard texts.count == count else { return nil }
        var values: [Int] = []
        for text in texts {
            guard let value = value(in: text) else { return nil }
            values.append(value)
        }
        return values
    }

    static func texts(for response: OracleInteractionResponse) -> [String] {
        if let texts = response.numberTexts, texts.count == count { return texts }
        return (0..<count).map { response.numbers.indices.contains($0) ? String(response.numbers[$0]) : "" }
    }
}

struct OracleInteractionSession: Codable, Identifiable, Sendable {
    var id = UUID()
    var input: OracleInput
    var plan: OraclePlan
    var requests: [OracleInteractionRequest]
    var responses: [OracleInteractionResponse] = []
    var draft: OracleInteractionResponse?
    var currentIndex: Int { responses.count }
    var currentRequest: OracleInteractionRequest? {
        requests.indices.contains(currentIndex) ? requests[currentIndex] : nil
    }
    var seed: UInt64 {
        let salt: UInt64
        switch currentRequest?.kind {
        case .numbers: salt = 0x4E554D42455253
        case .coins: salt = 0x434F494E53
        case .tarot: salt = 0x5441524F54
        case nil: salt = 0
        }
        return input.seed ^ salt
    }

    var availableTarotCards: [TarotCard] {
        guard let request = currentRequest, request.kind == .tarot else { return [] }
        let deck = TarotDeck.shuffled(seed: seed)
        guard let clarification = request.tarotClarification else { return deck }
        guard canStartClarification(clarification) else { return [] }
        let drawnIDs = drawnTarotIDs
        return deck.filter { !drawnIDs.contains($0.id) }
    }

    private var drawnTarotIDs: Set<String> {
        Set((input.tarotDraws ?? []).map(\.cardID) + (input.tarotClarificationRounds ?? []).map(\.draw.cardID))
    }

    private func canStartClarification(_ request: TarotClarificationRequest) -> Bool {
        request.isValid && TarotDeck.canAppendClarification(to: input)
            && !(input.tarotClarificationRounds ?? []).contains { $0.id == request.id }
    }

    func isValid(_ response: OracleInteractionResponse, complete: Bool) -> Bool {
        guard let request = currentRequest, OracleInteractionPolicy.isValid(response, for: request, complete: complete) else { return false }
        guard request.kind == .tarot else { return true }
        let savedDraft = draft.flatMap { OracleInteractionPolicy.isValid($0, for: request, complete: false) ? $0 : nil }
        if let clarification = request.tarotClarification {
            let drawnIDs = drawnTarotIDs
            guard canStartClarification(clarification) else { return false }
            if let draw = response.tarotDraws.first {
                guard !drawnIDs.contains(draw.cardID) else { return false }
                // New selections have a local orientation. A restored draw keeps
                // the exact orientation saved with its identity and position.
                guard savedDraft?.tarotDraws.first == draw
                    || draw.isReversed == TarotDeck.isReversed(seed: seed, cardID: draw.cardID) else { return false }
            }
        } else if let draws = input.tarotDraws, TarotDeck.isValidInitialSpread(draws) {
            return false
        }
        if let savedDraft {
            return response.revealedCount >= savedDraft.revealedCount && response.tarotDraws.starts(with: savedDraft.tarotDraws)
        }
        return true
    }

    mutating func saveProgress(_ response: OracleInteractionResponse) -> Bool {
        guard isValid(response, complete: false) else { return false }
        draft = response
        return true
    }

    mutating func complete(_ response: OracleInteractionResponse) -> Bool {
        guard let request = currentRequest, isValid(response, complete: true) else { return false }
        switch request.kind {
        case .numbers:
            input.numbers = response.numbers
            input.profile.unknownFields.remove(.numbers)
            input.profile.declaredUnknownFields?.remove(.numbers)
        case .coins: input.manualLines = response.lines
        case .tarot:
            if let clarification = request.tarotClarification {
                guard let draw = response.tarotDraws.first else { return false }
                let round = TarotClarificationRound(request: clarification, draw: draw)
                input.tarotClarificationRounds = (input.tarotClarificationRounds ?? []) + [round]
            } else {
                input.tarotDraws = response.tarotDraws
            }
        }
        responses.append(response); draft = nil
        let completedIDs = Set(responses.map(\.requestID))
        input.interactionResponses = (input.interactionResponses ?? []).filter { !completedIDs.contains($0.requestID) } + responses
        return true
    }
}

enum OracleInteractionPolicy {
    static func kind(for method: OracleMethod) -> OracleInteractionKind? {
        switch method {
        case .meihua: .numbers
        case .liuyao: .coins
        case .tarot: .tarot
        default: nil
        }
    }

    static func requests(for plan: OraclePlan, numbers: [Int] = []) -> [OracleInteractionRequest] {
        var seen = Set<OracleMethod>()
        var requests = (plan.interactions ?? []).filter {
            $0.tarotClarification == nil && plan.methods.contains($0.method) && kind(for: $0.method) == $0.kind && seen.insert($0.method).inserted
        }.map { OracleInteractionRequest(method: $0.method, kind: $0.kind, prompt: $0.prompt) }
        // These methods require actual user interaction. Older/malformed plans
        // cannot bypass it by omitting a request from the model's response.
        for method in plan.methods where method == .tarot || method == .liuyao {
            if seen.insert(method).inserted, let kind = kind(for: method) {
                requests.append(OracleInteractionRequest(method: method, kind: kind))
            }
        }
        if plan.methods.contains(.meihua), plan.requiredFields.contains(.numbers), seen.insert(.meihua).inserted {
            requests.append(OracleInteractionRequest(method: .meihua, kind: .numbers))
        }
        let validNumbers = [2, 3].contains(numbers.count) && numbers.allSatisfy { (1...999).contains($0) }
        if plan.methods.contains(.meihua), !numbers.isEmpty, !validNumbers, seen.insert(.meihua).inserted {
            // Invalid saved values need the same editable step; the intake form
            // is no longer a second place to enter or repair numbers.
            requests.append(OracleInteractionRequest(method: .meihua, kind: .numbers))
        }
        if numbers.count == 3, validNumbers { requests.removeAll { $0.kind == .numbers } }
        return requests
    }

    static func isValid(_ response: OracleInteractionResponse, for request: OracleInteractionRequest, complete: Bool) -> Bool {
        guard response.requestID == request.id, kind(for: request.method) == request.kind else { return false }
        if let clarification = request.tarotClarification, request.kind != .tarot || !clarification.isValid { return false }
        switch request.kind {
        case .numbers:
            guard response.lines.isEmpty, response.tarotDraws.isEmpty, response.revealedCount == 0,
                  response.numbers.count <= 3, response.numbers.allSatisfy({ (1...999).contains($0) }) else { return false }
            if let texts = response.numberTexts {
                guard texts.count == NumberInteractionDraft.count,
                      texts.allSatisfy({ $0.count <= NumberInteractionDraft.maximumTextLength }) else { return false }
                let values = NumberInteractionDraft.values(in: texts)
                // Invalid or incomplete edits are resumable, but never carry a
                // stale previously-generated triple into a calculation.
                return response.numbers == (values ?? []) && (!complete || values != nil)
            }
            return !complete || response.numbers.count == 3
        case .coins:
            return response.numberTexts == nil && response.numbers.isEmpty && response.tarotDraws.isEmpty && response.revealedCount == 0
                && (complete ? response.lines.count == 6 : response.lines.count <= 6)
                && response.lines.allSatisfy { (6...9).contains($0) }
        case .tarot:
            let positions = request.tarotPositions
            guard response.numberTexts == nil, response.numbers.isEmpty, response.lines.isEmpty,
                  response.tarotDraws.count <= positions.count,
                  (0...response.tarotDraws.count).contains(response.revealedCount),
                  Set(response.tarotDraws.map(\.cardID)).count == response.tarotDraws.count else { return false }
            for (index, draw) in response.tarotDraws.enumerated() {
                guard TarotDeck.card(id: draw.cardID) != nil, draw.position == positions[index] else { return false }
            }
            return !complete || (response.tarotDraws.count == positions.count && response.revealedCount == positions.count)
        }
    }
}
