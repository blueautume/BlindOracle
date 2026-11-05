import Foundation

enum OracleMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case bazi, ziwei, liuyao, meihua, qimen, xiaoliuren, chenggu, xingming, astrology, tarot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bazi: L10n.text("八字 / 四柱", "BaZi / Four Pillars")
        case .ziwei: L10n.text("紫微斗数", "Zi Wei Dou Shu")
        case .liuyao: L10n.text("六爻 / 周易筮法", "Liu Yao / Six Lines")
        case .meihua: L10n.text("梅花易数", "Mei Hua Yi Shu")
        case .qimen: L10n.text("奇门遁甲", "Qi Men Dun Jia")
        case .xiaoliuren: L10n.text("小六壬", "Xiao Liu Ren")
        case .chenggu: L10n.text("称骨", "Bone Weight Reading")
        case .xingming: L10n.text("姓名五格", "Chinese Name Numerology")
        case .astrology: L10n.text("西方占星", "Western Astrology")
        case .tarot: L10n.text("塔罗牌", "Tarot")
        }
    }
    var symbol: String {
        switch self {
        case .bazi: "square.grid.2x2"
        case .ziwei: "sparkles"
        case .liuyao: "line.3.horizontal"
        case .meihua: "leaf"
        case .qimen: "safari"
        case .xiaoliuren: "hand.draw"
        case .chenggu: "scalemass"
        case .xingming: "character.book.closed"
        case .astrology: "moon.stars"
        case .tarot: "rectangle.on.rectangle.angled"
        }
    }
    var usesPersonalProfile: Bool { [.bazi, .ziwei, .chenggu, .xingming, .astrology].contains(self) }
}

enum OracleField: String, Codable, CaseIterable, Hashable, Sendable {
    case name, surname, givenName, gender, birthDate, birthTime, birthPlace, birthTimeZone, birthCoordinates, currentLocation, numbers
    var title: String {
        switch self {
        case .name: L10n.text("姓名", "Name")
        case .surname: L10n.text("姓氏", "Family Name")
        case .givenName: L10n.text("名字", "Given Name")
        case .gender: L10n.text("排盘性别", "Chart Gender")
        case .birthDate: L10n.text("出生日期", "Date of Birth")
        case .birthTime: L10n.text("出生时间", "Time of Birth")
        case .birthPlace: L10n.text("出生地", "Birthplace")
        case .birthTimeZone: L10n.text("出生地时区", "Birth Time Zone")
        case .birthCoordinates: L10n.text("出生地经纬度", "Birth Coordinates")
        case .currentLocation: L10n.text("当前所在地", "Current Location")
        case .numbers: L10n.text("心中想到的数字", "Numbers You Have in Mind")
        }
    }
}

struct OracleProfile: Codable, Equatable, Identifiable, Sendable {
    static let defaultChinaTimeZoneID = "Asia/Shanghai"

    var id = UUID()
    var displayName = ""
    var familyName = ""
    var givenName = ""
    var sex = "未提供"
    var birthDate: Date?
    var birthTimeKnown = true
    var birthTimeZoneID = Self.defaultChinaTimeZoneID
    var birthPlace = ""
    var birthLatitude: Double?
    var birthLongitude: Double?
    var currentPlace = ""
    var currentLatitude: Double?
    var currentLongitude: Double?
    var currentTimeZoneID = Self.defaultChinaTimeZoneID
    var unknownFields: Set<OracleField> = []
    var updatedAt = Date()
    var fullName: String { familyName + givenName }
    var name: String? = nil
    var birthDateText: String? = nil
    var birthTimeText: String? = nil
    var declaredUnknownFields: Set<OracleField>? = []
    var alias: String? = nil
    var isAnonymousRecord: Bool? = nil
    var birthDistrictCode: String? = nil
    var currentDistrictCode: String? = nil
    var resolvedName: String {
        [name ?? "", fullName, displayName].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !["我", "本人", "他人资料", "我的资料"].contains($0) }) ?? ""
    }
    var anonymousCode: String {
        let bytes = id.uuid
        let tail = UInt32(bytes.12) << 24 | UInt32(bytes.13) << 16 | UInt32(bytes.14) << 8 | UInt32(bytes.15)
        return String(format: "%04u", tail % 10_000)
    }
    var participantLabel: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty { return alias }
        let name = resolvedName
        return name.isEmpty ? anonymousCode : name
    }
}

struct OracleInput: Codable, Sendable {
    var question: String
    var profile: OracleProfile
    var castingDate: Date = Date()
    var numbers: [Int] = []
    var manualLines: [Int] = []
    var seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    var subject = "本人"
    var castingStyle: String? = nil
    var tarotDraws: [TarotDraw]? = nil
    var tarotClarificationRounds: [TarotClarificationRound]? = nil
    var interactionResponses: [OracleInteractionResponse]? = nil
    var participants: [OracleProfile]? = nil
    var relationship: String? = nil
    var readingParticipants: [OracleProfile] {
        var seen = Set<UUID>()
        return (participants ?? [profile]).filter { seen.insert($0.id).inserted }
    }
}

struct OracleRow: Codable, Identifiable, Sendable, Equatable {
    var id: String { label }
    var label: String
    var value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

struct OracleEvidence: Codable, Identifiable, Sendable {
    var id: String
    var statement: String
    /// A symbolic rule's tendency, not an empirical probability or prediction confidence.
    var polarity: Double
    var strength: Double
    var topic: String
    init(id: String, statement: String, polarity: Double = 0, strength: Double = 0.5, topic: String = "general") {
        self.id = id; self.statement = statement; self.polarity = polarity
        self.strength = strength; self.topic = topic
    }
}

enum OracleResultStatus: String, Codable, Sendable { case complete, partial, unavailable, failed }

struct OracleResult: Codable, Identifiable, Sendable {
    var id = UUID()
    var method: OracleMethod
    var version: String
    var status: OracleResultStatus
    var headline: String
    var rows: [OracleRow]
    var evidence: [OracleEvidence]
    var limitations: [String]
    var generatedAt = Date()
    var durationMilliseconds: Double = 0
    var provenance: String
    /// Language of the saved result text. Older records predate this field.
    var contentLanguageCode: String?
    var tarotDraws: [TarotDraw]? = nil
    var tarotClarificationRounds: [TarotClarificationRound]? = nil
    var participantID: UUID? = nil
    var participantName: String? = nil
    var displayTitle: String {
        guard let name = participantName, !name.isEmpty else { return method.title }
        return "\(name) · \(method.title)"
    }
    init(method: OracleMethod, version: String = "1.0.0", status: OracleResultStatus = .complete,
         headline: String, rows: [OracleRow], evidence: [OracleEvidence] = [],
         limitations: [String] = [], provenance: String = L10n.text("本地计算", "Calculated on device")) {
        self.method = method; self.version = version; self.status = status
        self.headline = headline; self.rows = rows; self.evidence = evidence
        self.limitations = limitations; self.provenance = provenance
        self.contentLanguageCode = AppLanguage.current.rawValue
    }
}

struct OraclePluginDescriptor: Codable, Identifiable, Sendable {
    var method: OracleMethod
    var id: String { method.rawValue }
    var version: String
    var summary: String
    var requiredFields: [OracleField]
    var optionalFields: [OracleField]
    var supportedQuestions: [String]
    var outputDescription: String
    var limitations: [String]
    var source: String
    var license: String
    var interactionKinds: [OracleInteractionKind]? = nil
}

protocol OraclePlugin: Sendable {
    var descriptor: OraclePluginDescriptor { get }
    func calculate(_ input: OracleInput) async throws -> OracleResult
}

struct ConversationUnderstanding: Codable, Sendable {
    enum Relation: String, Codable, Sendable {
        case newQuestion, continuation, changedConditions, changedParticipants, ambiguous
    }

    var relation: Relation
    var resolvedQuestion: String
    var referenceMessageID: UUID?
}

struct OraclePlan: Codable, Sendable {
    var intent: String
    var subject: String
    var methods: [OracleMethod]
    var requiredFields: [OracleField]
    var note: String
    var question: String
    var createdAt = Date()
    var action: String? = nil
    var interactions: [OracleInteractionRequest]? = nil
    var participantIDs: [UUID]? = nil
    var participantNames: [String]? = nil
    var profileUpdates: [ProfileUpdate]? = nil
    var relationship: String? = nil
    var resumesPendingQuestion: Bool? = nil
    var mandatoryMethods: [OracleMethod]? = nil
    var preparationStage: OraclePreparationStage? = nil
    var requestedProfileID: UUID? = nil
    var requestedFields: [OracleField]? = nil
    var reviewedParticipants: [OracleProfile]? = nil
    var omittedMethods: [OracleMethodOmission]? = nil
    var preparationNotes: [String]? = nil
    var pendingAnswer: String? = nil
    var collectionDeclined: Bool? = nil
    /// Unsubmitted form drafts are independent of the permanent people directory.
    var draftParticipants: [OracleProfile]? = nil
    var draftNumbers: [Int]? = nil
    /// A pending supplement refers to a saved reading, never to a new random cast.
    var baseRunID: UUID? = nil
    var followUpQuestion: String? = nil
    var tarotClarification: TarotClarificationSuggestion? = nil
    var understanding: ConversationUnderstanding? = nil
}

enum ChatRole: String, Codable, Sendable { case user, assistant, system }
enum ChatMessageKind: String, Codable, Sendable { case text, intake, reading, choice, notice }
struct ChatMessage: Codable, Identifiable, Sendable {
    var id = UUID()
    var role: ChatRole
    var content: String
    var kind: ChatMessageKind = .text
    var date = Date()
    var runID: UUID?
    var activities: [OracleActivity]? = nil
    /// Keeps the transcript's deleted reference distinct from another reading.
    var deletedRunID: UUID? = nil
    var tarotClarificationOffer: TarotClarificationSuggestion? = nil
    /// The question the planner understood. The transcript still displays content.
    var resolvedQuestion: String? = nil
    var referenceMessageID: UUID? = nil

    var isConversationTurn: Bool {
        guard role != .system, kind == .text || kind == .reading,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Confirmations in existing archives were stored as ordinary user text.
        return role != .user || ![
            "已核对问事资料，开始推演。",
            "I’ve reviewed the details. Start the reading."
        ].contains(content)
    }
}

struct ReadingSynthesis: Codable, Sendable {
    var text: String
    var tarotClarification: TarotClarificationSuggestion? = nil
    /// Text-only compatibility for archived readings from the retired choice UI.
    /// New readings describe disagreements directly in `text`.
    var archivedConflictDetails: String? = nil

    init(text: String, tarotClarification: TarotClarificationSuggestion? = nil,
         archivedConflictDetails: String? = nil) {
        self.text = text
        self.tarotClarification = tarotClarification
        self.archivedConflictDetails = archivedConflictDetails
    }

    private enum CodingKeys: String, CodingKey {
        case text, tarotClarification, archivedConflictDetails, alternatives
    }

    private struct LegacyAlternative: Decodable {
        var title: String?
        var body: String?
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        tarotClarification = try values.decodeIfPresent(TarotClarificationSuggestion.self, forKey: .tarotClarification)
        archivedConflictDetails = try values.decodeIfPresent(String.self, forKey: .archivedConflictDetails)
        if archivedConflictDetails == nil,
           let legacy = try? values.decode([LegacyAlternative].self, forKey: .alternatives) {
            let details = legacy.compactMap { option -> String? in
                let parts = [option.title, option.body].compactMap { value -> String? in
                    guard let value else { return nil }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return parts.isEmpty ? nil : parts.joined(separator: "\n")
            }.joined(separator: "\n\n")
            if !details.isEmpty { archivedConflictDetails = details }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(text, forKey: .text)
        try values.encodeIfPresent(tarotClarification, forKey: .tarotClarification)
        try values.encodeIfPresent(archivedConflictDetails, forKey: .archivedConflictDetails)
    }
}

struct OracleRun: Codable, Identifiable, Sendable {
    var id = UUID()
    var input: OracleInput
    var plan: OraclePlan
    var results: [OracleResult] = []
    var synthesis: ReadingSynthesis?
    var completedAt: Date?
    var activities: [OracleActivity]? = nil
    /// The result objects themselves are copied into this run for independent recovery.
    var reusedResultIDs: [UUID]? = nil
}

struct ConversationSummary: Codable, Sendable {
    var text = ""
    var coveredMessageIDs: [UUID] = []
    var updatedAt: Date?
    var lastCompressedMessageCount = 0
}
