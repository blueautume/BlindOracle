import Foundation

/// UI operations are a fixed, local catalog. A model can request these operations,
/// but cannot supply executable UI, card identities, coin outcomes or random seeds.
enum OracleInteractionKind: String, Codable, Sendable {
    case numbers, coins, tarot

    var title: String {
        switch self {
        case .numbers: "随心留数"
        case .coins: "六掷成卦"
        case .tarot: "静心抽牌"
        }
    }
}

struct OracleInteractionRequest: Codable, Identifiable, Equatable, Sendable {
    var method: OracleMethod
    var kind: OracleInteractionKind
    var prompt: String
    var id: String { method.rawValue }
    var title: String { kind.title }

    init(method: OracleMethod, kind: OracleInteractionKind, prompt: String = "") {
        self.method = method; self.kind = kind
        let supplied = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback: String
        switch kind {
        case .numbers: fallback = "凭着此刻的心意，留下三个数。"
        case .coins: fallback = "心中留一问，依次留下六爻。"
        case .tarot: fallback = "静下心，选出属于此问的三张牌。"
        }
        self.prompt = supplied.isEmpty ? fallback : String(supplied.prefix(180))
    }
}

struct OracleInteractionResponse: Codable, Equatable, Sendable {
    var requestID: String
    var numbers: [Int] = []
    var lines: [Int] = []
    var tarotDraws: [TarotDraw] = []
    var revealedCount: Int = 0
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

    mutating func saveProgress(_ response: OracleInteractionResponse) -> Bool {
        guard let request = currentRequest,
              OracleInteractionPolicy.isValid(response, for: request, complete: false) else { return false }
        draft = response
        return true
    }

    mutating func complete(_ response: OracleInteractionResponse) -> Bool {
        guard let request = currentRequest,
              OracleInteractionPolicy.isValid(response, for: request, complete: true) else { return false }
        switch request.kind {
        case .numbers:
            input.numbers = response.numbers
            input.profile.unknownFields.remove(.numbers)
        case .coins: input.manualLines = response.lines
        case .tarot: input.tarotDraws = response.tarotDraws
        }
        responses.append(response); draft = nil
        input.interactionResponses = responses
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
            plan.methods.contains($0.method) && kind(for: $0.method) == $0.kind && seen.insert($0.method).inserted
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
        if !numbers.isEmpty { requests.removeAll { $0.kind == .numbers } }
        return requests
    }

    static func isValid(_ response: OracleInteractionResponse, for request: OracleInteractionRequest, complete: Bool) -> Bool {
        guard response.requestID == request.id, kind(for: request.method) == request.kind else { return false }
        switch request.kind {
        case .numbers:
            return response.lines.isEmpty && response.tarotDraws.isEmpty && response.revealedCount == 0
                && (complete ? response.numbers.count == 3 : response.numbers.count <= 3)
                && response.numbers.allSatisfy { (1...999).contains($0) }
        case .coins:
            return response.numbers.isEmpty && response.tarotDraws.isEmpty && response.revealedCount == 0
                && (complete ? response.lines.count == 6 : response.lines.count <= 6)
                && response.lines.allSatisfy { (6...9).contains($0) }
        case .tarot:
            guard response.numbers.isEmpty, response.lines.isEmpty,
                  response.tarotDraws.count <= 3,
                  (0...response.tarotDraws.count).contains(response.revealedCount),
                  Set(response.tarotDraws.map(\.cardID)).count == response.tarotDraws.count else { return false }
            for (index, draw) in response.tarotDraws.enumerated() {
                guard TarotDeck.card(id: draw.cardID) != nil, draw.position == TarotDeck.positions[index] else { return false }
            }
            return !complete || (response.tarotDraws.count == 3 && response.revealedCount == 3)
        }
    }
}
