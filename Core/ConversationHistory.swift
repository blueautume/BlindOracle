import Foundation

/// The work needed to retry the latest request without duplicating its user
/// turn or making a new cast. Presence while idle means it can be retried.
enum OracleAnalysisAttempt: Codable, Sendable {
    case planning(questionID: UUID)
    case followUp(questionID: UUID, replyID: UUID, runID: UUID?, tarotOffer: TarotClarificationSuggestion?)
    case reading(runID: UUID, messageID: UUID?, needsCalculation: Bool)

    var messageID: UUID? {
        switch self {
        case let .planning(questionID): questionID
        case let .followUp(_, replyID, _, _): replyID
        case let .reading(_, messageID, _): messageID
        }
    }

    var runID: UUID? {
        switch self {
        case .planning: nil
        case let .followUp(_, _, runID, _): runID
        case let .reading(runID, _, _): runID
        }
    }
}

/// A conversation owns its transcript and model context; profiles, readings and
/// personal preferences remain independent, device-local records.
struct OracleConversation: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var summary: ConversationSummary
    var pendingPlan: OraclePlan?
    var pendingInteraction: OracleInteractionSession?
    var analysisAttempt: OracleAnalysisAttempt?

    var title: String {
        let source = messages.first(where: { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.content
            ?? pendingPlan?.question
            ?? messages.first?.content
            ?? L10n.text("新的对话", "New Conversation")
        let line = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? L10n.text("新的对话", "New Conversation") : String(line.prefix(40))
    }

    var isEmpty: Bool { messages.isEmpty && summary.text.isEmpty && pendingPlan == nil && pendingInteraction == nil }

    init(id: UUID = UUID(), messages: [ChatMessage] = [],
         summary: ConversationSummary = ConversationSummary(), pendingPlan: OraclePlan? = nil,
         pendingInteraction: OracleInteractionSession? = nil,
         createdAt: Date? = nil, fallbackDate: Date = Date(), analysisAttempt: OracleAnalysisAttempt? = nil) {
        self.id = id
        self.messages = messages
        self.summary = summary
        self.pendingPlan = pendingPlan
        self.pendingInteraction = pendingInteraction
        self.analysisAttempt = analysisAttempt
        self.createdAt = createdAt ?? messages.map(\.date).min() ?? pendingPlan?.createdAt ?? fallbackDate
        // Reading a historical conversation must not make it appear newly active.
        self.updatedAt = (messages.map(\.date) + [pendingPlan?.createdAt, summary.updatedAt].compactMap { $0 }).max() ?? self.createdAt
    }
}

struct OracleConversationArchive: Codable, Sendable {
    var schemaVersion = 1
    var activeConversationID: UUID
    var conversations: [OracleConversation]

    static func blank() -> OracleConversationArchive {
        OracleConversationArchive(activeConversationID: UUID(), conversations: [])
    }
}

struct ConversationHistoryLoadResult {
    var archive: OracleConversationArchive
    var needsInitialSave: Bool
    var recoveredUnreadableFile: Bool
    var recoveryCopyPreserved = true
}

enum ConversationHistory {
    static let filename = "conversation-history"

    static func ordered(_ conversations: [OracleConversation]) -> [OracleConversation] {
        conversations.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func load(from vault: LocalVault) -> ConversationHistoryLoadResult {
        // Presence, including an intentionally empty history, is the migration
        // marker. Deleting the final chat must never revive legacy archives.
        if vault.contains(filename) {
            let stored = vault.load(OracleConversationArchive?.self, from: filename, fallback: nil)
            // One malformed conversation should not hide every other chat in
            // an otherwise valid archive. The original remains recoverable.
            let recovered = stored == nil
                ? vault.load(RecoverableArchive?.self, from: filename, fallback: nil)?.archive
                : nil
            guard var archive = stored ?? recovered,
                  archive.schemaVersion == 1 else {
                // Preserve unknown schemas and JSON null as well as decoder
                // failures before a future action writes the current schema.
                let preserved = vault.preserveRecoveryCopy(filename)
                return ConversationHistoryLoadResult(archive: .blank(), needsInitialSave: false,
                                                     recoveredUnreadableFile: true, recoveryCopyPreserved: preserved)
            }
            var seen = Set<UUID>()
            archive.conversations = ordered(archive.conversations).filter { !$0.isEmpty && seen.insert($0.id).inserted }
            let preserved = stored != nil || vault.preserveRecoveryCopy(filename)
            return ConversationHistoryLoadResult(archive: archive, needsInitialSave: false,
                                                 recoveredUnreadableFile: stored == nil, recoveryCopyPreserved: preserved)
        }

        var conversations: [OracleConversation] = []
        var indicesByTranscript: [String: Int] = [:]
        let archiveFiles = vault.legacyConversationArchiveNames()
        for name in archiveFiles {
            let messages = vault.load([ChatMessage].self, from: name, fallback: [])
            guard !messages.isEmpty else { continue }
            let signature = transcriptIdentity(messages)
            guard indicesByTranscript[signature] == nil else { continue }
            let timestamp = name.dropFirst("conversation-".count)
            let date = Double(timestamp).map(Date.init(timeIntervalSince1970:)) ?? messages.last!.date
            indicesByTranscript[signature] = conversations.count
            conversations.append(OracleConversation(messages: messages, fallbackDate: date))
        }

        let current = vault.load([ChatMessage].self, from: "conversation", fallback: [])
        let summary = vault.load(ConversationSummary.self, from: "context", fallback: ConversationSummary())
        let pending = vault.load(OraclePlan?.self, from: "pending-intake", fallback: nil)
        var activeID = UUID()
        let snapshot = OracleConversation(id: activeID, messages: current, summary: summary, pendingPlan: pending)
        if !snapshot.isEmpty {
            if let index = indicesByTranscript[transcriptIdentity(current)], !current.isEmpty {
                // The current snapshot wins over the same archived transcript:
                // it owns its current summary, pending form and streamed content.
                activeID = conversations[index].id
                conversations[index] = OracleConversation(id: activeID, messages: current, summary: summary, pendingPlan: pending,
                                                          createdAt: conversations[index].createdAt)
            } else { conversations.append(snapshot) }
        }
        return ConversationHistoryLoadResult(
            archive: OracleConversationArchive(activeConversationID: activeID, conversations: ordered(conversations)),
            needsInitialSave: true, recoveredUnreadableFile: false)
    }

    private static func transcriptIdentity(_ messages: [ChatMessage]) -> String {
        // Repeated question text can be a different conversation. Message UUIDs
        // identify a copied transcript without merging independent questions.
        messages.map { $0.id.uuidString }.joined(separator: "/")
    }

    private struct RecoverableArchive: Decodable {
        let archive: OracleConversationArchive

        private enum CodingKeys: String, CodingKey { case schemaVersion, activeConversationID, conversations }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let version = try values.decode(Int.self, forKey: .schemaVersion)
            let activeID = (try? values.decode(UUID.self, forKey: .activeConversationID)) ?? UUID()
            let entries = try values.decode([RecoverableConversation].self, forKey: .conversations)
            archive = OracleConversationArchive(schemaVersion: version, activeConversationID: activeID,
                                                conversations: entries.compactMap(\.conversation))
        }
    }

    private struct RecoverableConversation: Decodable {
        let conversation: OracleConversation?

        init(from decoder: Decoder) throws {
            conversation = try? OracleConversation(from: decoder)
        }
    }
}
