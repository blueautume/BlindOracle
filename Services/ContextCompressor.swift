import Foundation

/// The archive remains intact. Only the outbound model context is compacted.
struct ContextCompressor {
    static let tokenThreshold = 32_000
    static let minimumNewMessages = 24
    static let retainedRecentMessages = 16

    static func estimatedTokens(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in count + (scalar.value > 0x2FF ? 2 : 1) } / 2
    }

    static func shouldCompress(messages: [ChatMessage], summary: ConversationSummary) -> Bool {
        guard messages.count - summary.lastCompressedMessageCount >= minimumNewMessages,
              messages.count > retainedRecentMessages + minimumNewMessages else { return false }
        let covered = Set(summary.coveredMessageIDs)
        let pending = messages.filter { !covered.contains($0.id) && $0.kind != .intake && $0.kind != .choice }
        let total = pending.reduce(estimatedTokens(summary.text)) { $0 + estimatedTokens($1.content) }
        return total > tokenThreshold
    }

    static func history(messages: [ChatMessage], summary: ConversationSummary, language: AppLanguage = .current) -> [AIConversationTurn] {
        let covered = Set(summary.coveredMessageIDs)
        var history: [AIConversationTurn] = []
        if !summary.text.isEmpty {
            history.append(AIConversationTurn(role: "assistant", content: L10n.text("此前对话的延续摘要（资料档案另存，不以摘要修改）：\n", "Previous conversation summary (profile records are stored separately):\n", language: language) + summary.text))
        }
        history += messages.filter { !covered.contains($0.id) && $0.role != .system && $0.kind != .intake && $0.kind != .choice }
            .map { AIConversationTurn(role: $0.role.rawValue, content: $0.content) }
        return history
    }

    static func compact(messages: [ChatMessage], summary: ConversationSummary,
                        using client: DeepSeekClient, language: AppLanguage = .current) async throws -> ConversationSummary? {
        guard shouldCompress(messages: messages, summary: summary) else { return nil }
        let older = Array(messages.dropLast(retainedRecentMessages))
        let alreadyCovered = Set(summary.coveredMessageIDs)
        let pending = older.filter { !alreadyCovered.contains($0.id) && $0.kind != .intake && $0.kind != .choice }
        guard !pending.isEmpty else { return nil }
        let transcript = pending.map { "[\($0.role.rawValue)] \($0.content)" }.joined(separator: "\n")
        // If the network fails, leave the current summary and all messages unchanged.
        let text = try await client.summarize(transcript: transcript, previous: summary.text, language: language)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var output = summary
        output.text = text
        output.coveredMessageIDs = Array(Set(summary.coveredMessageIDs + older.map(\.id)))
        output.updatedAt = Date()
        output.lastCompressedMessageCount = messages.count
        return output
    }
}
