import CryptoKit
import Foundation

/// The archive remains intact. Only the outbound model context is compacted.
struct ContextCompressor {
    private static let tokenThreshold = 32_000
    private static let messageThreshold = 120
    private static let byteThreshold = 192 * 1024
    private static let minimumNewMessages = 24
    private static let retainedRecentMessages = 16
    private static let batchMessageLimit = 96
    private static let transcriptByteLimit = 48 * 1024
    private static let summaryByteLimit = 8 * 1024

    struct Batch: Sendable {
        let previous: String
        let transcript: String
        let messageIDs: [UUID]
        fileprivate let summary: ConversationSummary
        fileprivate let messageCount: Int
        fileprivate let language: AppLanguage

        var stageID: String {
            // Include record IDs as well as payload text: distinct turns may have identical text.
            var digest = SHA256()
            let fields = ["1", language.rawValue, previous, transcript] + messageIDs.map(\.uuidString)
            for field in fields {
                digest.update(data: Data("\(field.utf8.count):".utf8))
                digest.update(data: Data(field.utf8))
            }
            return "summary:" + digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    static func estimatedTokens(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in count + (scalar.value > 0x2FF ? 2 : 1) } / 2
    }

    static func shouldCompress(messages: [ChatMessage], summary: ConversationSummary) -> Bool {
        batch(messages: messages, summary: summary) != nil
    }

    static func batch(messages: [ChatMessage], summary: ConversationSummary, language: AppLanguage = .current) -> Batch? {
        let covered = Set(summary.coveredMessageIDs)
        let pending = messages.filter { !covered.contains($0.id) && canSend($0) }
        guard pending.count > retainedRecentMessages else { return nil }
        let previous = boundedSummary(summary.text)
        let nearRequestLimit = pending.count >= messageThreshold
            || pending.reduce(previous.utf8.count, { $0 + $1.content.utf8.count }) >= byteThreshold
        guard nearRequestLimit || (
            messages.count - summary.lastCompressedMessageCount >= minimumNewMessages
                && pending.count > retainedRecentMessages + minimumNewMessages
                && pending.reduce(estimatedTokens(previous), { $0 + estimatedTokens($1.content) }) > tokenThreshold
        ) else { return nil }

        let recentStart = pending.count - retainedRecentMessages
        let olderEnd = pending[...recentStart].lastIndex(where: { $0.role == .user }) ?? recentStart
        let older = pending[..<olderEnd]
        var start = older.startIndex
        var bytesRemaining = transcriptByteLimit
        var transcript = ""
        var messageIDs: [UUID] = []
        while start < older.endIndex {
            let following = older.index(after: start)
            let end = older[start].role == .user
                ? older[following...].firstIndex(where: { $0.role == .user }) ?? older.endIndex
                : following
            let turn = older[start..<end]
            start = end
            // An oversized turn stays available in the archive and is never marked summarized.
            guard turn.count <= batchMessageLimit else { continue }
            // Four bytes account for the role's two brackets, space and newline.
            let turnBytes = turn.reduce(0) { $0 + $1.role.rawValue.utf8.count + $1.content.utf8.count + 4 }
            guard turnBytes <= transcriptByteLimit else { continue }
            guard turnBytes <= bytesRemaining, messageIDs.count + turn.count <= batchMessageLimit else { break }
            for message in turn {
                transcript += "[\(message.role.rawValue)] \(message.content)\n"
                messageIDs.append(message.id)
            }
            bytesRemaining -= turnBytes
        }
        guard !messageIDs.isEmpty else { return nil }
        return Batch(previous: previous, transcript: transcript, messageIDs: messageIDs, summary: summary,
                     messageCount: messages.count, language: language)
    }

    static func history(messages: [ChatMessage], summary: ConversationSummary, language: AppLanguage = .current) -> [AIConversationTurn] {
        let covered = Set(summary.coveredMessageIDs)
        var history: [AIConversationTurn] = []
        let summaryText = boundedSummary(summary.text)
        if !summaryText.isEmpty {
            history.append(AIConversationTurn(role: "assistant", content: L10n.text("此前对话的延续摘要（资料档案另存，不以摘要修改）：\n", "Previous conversation summary (profile records are stored separately):\n", language: language) + summaryText))
        }
        history += messages.filter { !covered.contains($0.id) && canSend($0) }
            .map { AIConversationTurn(role: $0.role.rawValue, content: $0.content) }
        return history
    }

    static func compact(_ batch: Batch, using client: DeepSeekClient) async throws -> ConversationSummary? {
        // If the network fails, leave the current summary and all messages unchanged.
        let text = boundedSummary(try await client.summarize(transcript: batch.transcript, previous: batch.previous, language: batch.language))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var output = batch.summary
        output.text = text
        output.coveredMessageIDs.append(contentsOf: batch.messageIDs)
        output.updatedAt = Date()
        output.lastCompressedMessageCount = batch.messageCount
        return output
    }

    private static func boundedSummary(_ text: String) -> String {
        guard text.utf8.count > summaryByteLimit else { return text }
        var end = text.startIndex
        var bytesRemaining = summaryByteLimit
        while end < text.endIndex {
            let next = text.index(after: end)
            let bytes = text[end..<next].utf8.count
            guard bytes <= bytesRemaining else { break }
            bytesRemaining -= bytes
            end = next
        }
        return String(text[..<end])
    }

    private static func canSend(_ message: ChatMessage) -> Bool {
        message.role != .system && message.localProfileCorrection != true && message.kind != .intake && message.kind != .choice
            && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
