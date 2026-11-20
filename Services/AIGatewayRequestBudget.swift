import Foundation

/// These limits apply to each request to the gateway, independent of the local transcript.
enum AIGatewayRequestBudget {
    static let maximumMessageCount = 160
    static let maximumContentBytes = 256 * 1024
    static let maximumRequestBytes = 1024 * 1024

    private static let contextTooLarge = DeepSeekError.gateway(status: 413, code: "context_too_large")

    static func wireMessages(_ messages: some Sequence<AIConversationTurn>) -> [[String: String]] {
        messages.map { ["role": $0.role, "content": $0.content] }
    }

    static func encode(_ messages: [AIConversationTurn], body: [String: Any]) throws -> Data {
        func serialize(_ turns: [AIConversationTurn]) throws -> Data {
            var payload = body
            payload["messages"] = wireMessages(turns)
            return try JSONSerialization.data(withJSONObject: payload)
        }

        guard !messages.isEmpty else { throw DeepSeekError.invalidResponse }
        if messages.count <= maximumMessageCount, contentSize(messages) <= maximumContentBytes {
            let original = try serialize(messages)
            if original.count <= maximumRequestBytes { return original }
        }

        guard let system = messages.first, system.role == "system",
              let question = messages.last, question.role == "user" else { throw contextTooLarge }
        let required = [system, question]
        let requiredContentBytes = contentSize(required)
        guard requiredContentBytes <= maximumContentBytes else { throw contextTooLarge }
        let requiredBody = try serialize(required)
        guard requiredBody.count <= maximumRequestBytes else { throw contextTooLarge }

        var remaining = Remaining(contentBytes: maximumContentBytes - requiredContentBytes,
                                  requestBytes: maximumRequestBytes - requiredBody.count)
        var prefix = [system]
        var history = messages.dropFirst().dropLast()
        if let summary = history.first, summary.role == "assistant", isSummary(summary.content) {
            if try remaining.add(history.prefix(1)) { prefix.append(summary) }
            history = history.dropFirst()
        }

        // Walk back by complete user-led turns so a reply is never kept without its question.
        var start = history.endIndex
        for index in history.indices.reversed() where history[index].role == "user" {
            guard try remaining.add(history[index..<start]) else { break }
            start = index
        }
        let fitted = try serialize(prefix + history[start...] + [question])
        guard fitted.count <= maximumRequestBytes else { throw contextTooLarge }
        return fitted
    }

    static func rebuildOversizedSnapshot(_ data: Data, purpose: String) throws -> Data {
        // Under-limit old snapshots may already be bound to a generation in the gateway.
        guard data.count > maximumRequestBytes else { return data }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["purpose"] as? String == purpose,
              let rows = body["messages"] as? [[String: Any]] else { throw DeepSeekError.invalidResponse }
        let messages = try rows.map { row in
            guard let role = row["role"] as? String, let content = row["content"] as? String else {
                throw DeepSeekError.invalidResponse
            }
            return AIConversationTurn(role: role, content: content)
        }
        return try encode(messages, body: body)
    }

    private static func isSummary(_ content: String) -> Bool {
        content.hasPrefix("此前对话的延续摘要（资料档案另存，不以摘要修改）：\n")
            || content.hasPrefix("Previous conversation summary (profile records are stored separately):\n")
    }

    private static func contentSize(_ messages: some Sequence<AIConversationTurn>) -> Int {
        messages.reduce(0) { $0 + $1.content.utf8.count }
    }

    private struct Remaining {
        var messages = AIGatewayRequestBudget.maximumMessageCount - 2
        var contentBytes: Int
        var requestBytes: Int

        mutating func add(_ turns: ArraySlice<AIConversationTurn>) throws -> Bool {
            guard turns.count <= messages else { return false }
            let content = AIGatewayRequestBudget.contentSize(turns)
            guard content <= contentBytes else { return false }
            // Replacing the array brackets with a separator gives the cost to add
            // these entries to the already nonempty JSON message array.
            let serialized = try JSONSerialization.data(withJSONObject: AIGatewayRequestBudget.wireMessages(turns)).count - 1
            guard serialized <= requestBytes else { return false }
            messages -= turns.count
            contentBytes -= content
            requestBytes -= serialized
            return true
        }
    }
}
