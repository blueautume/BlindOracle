import Foundation

enum OracleMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case bazi, ziwei, liuyao, meihua, qimen, xiaoliuren, chenggu, xingming, astrology, tarot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bazi: "八字 / 四柱"
        case .ziwei: "紫微斗数"
        case .liuyao: "六爻 / 周易筮法"
        case .meihua: "梅花易数"
        case .qimen: "奇门遁甲"
        case .xiaoliuren: "小六壬"
        case .chenggu: "称骨"
        case .xingming: "姓名五格"
        case .astrology: "西方占星"
        case .tarot: "塔罗牌"
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
        case .name: "姓名"
        case .surname: "姓氏"
        case .givenName: "名字"
        case .gender: "排盘性别"
        case .birthDate: "出生日期"
        case .birthTime: "出生时间"
        case .birthPlace: "出生地"
        case .birthTimeZone: "出生地时区"
        case .birthCoordinates: "出生地经纬度"
        case .currentLocation: "当前所在地"
        case .numbers: "心中想到的数字"
        }
    }
}

struct OracleProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var displayName = ""
    var familyName = ""
    var givenName = ""
    var sex = "未提供"
    var birthDate: Date?
    var birthTimeKnown = true
    var birthTimeZoneID = "Asia/Shanghai"
    var birthPlace = ""
    var birthLatitude: Double?
    var birthLongitude: Double?
    var currentPlace = ""
    var currentLatitude: Double?
    var currentLongitude: Double?
    var currentTimeZoneID = TimeZone.current.identifier
    var unknownFields: Set<OracleField> = []
    var updatedAt = Date()
    var fullName: String { familyName + givenName }
    var name: String? = nil
    var birthDateText: String? = nil
    var birthTimeText: String? = nil
    var declaredUnknownFields: Set<OracleField>? = []
    var resolvedName: String {
        [name ?? "", fullName, displayName].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !["我", "本人", "他人资料", "我的资料"].contains($0) }) ?? ""
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
    var tarotDraws: [TarotDraw]? = nil
    var participantID: UUID? = nil
    var participantName: String? = nil
    var displayTitle: String {
        guard let name = participantName, !name.isEmpty else { return method.title }
        return "\(name) · \(method.title)"
    }
    init(method: OracleMethod, version: String = "1.0.0", status: OracleResultStatus = .complete,
         headline: String, rows: [OracleRow], evidence: [OracleEvidence] = [],
         limitations: [String] = [], provenance: String = "本地计算") {
        self.method = method; self.version = version; self.status = status
        self.headline = headline; self.rows = rows; self.evidence = evidence
        self.limitations = limitations; self.provenance = provenance
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
}

struct ReadingAlternative: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var body: String
    var supportingMethods: [OracleMethod]
}

struct ReadingSynthesis: Codable, Sendable {
    var text: String
    var alternatives: [ReadingAlternative]
    var hasSignificantConflict: Bool { alternatives.count == 2 }
}

struct OracleRun: Codable, Identifiable, Sendable {
    var id = UUID()
    var input: OracleInput
    var plan: OraclePlan
    var results: [OracleResult] = []
    var synthesis: ReadingSynthesis?
    var selectedAlternative: String?
    var completedAt: Date?
    var weightsSnapshot: [String: Double] = [:]
    var activities: [OracleActivity]? = nil
}

struct ConversationSummary: Codable, Sendable {
    var text = ""
    var coveredMessageIDs: [UUID] = []
    var updatedAt: Date?
    var lastCompressedMessageCount = 0
}
