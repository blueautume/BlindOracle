import Foundation

enum ReadingContextBuilder {
    static func canSuggestTarotClarification(for run: OracleRun) -> Bool {
        TarotDeck.canAppendClarification(to: run.input) && run.results.contains { result in
            result.method == .tarot && result.status == .complete
        }
    }

    static func payload(run: OracleRun, weights: [String: Double]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let eligible = run.results.filter { $0.status == .complete || $0.status == .partial }
        let tarotRounds = run.input.tarotClarificationRounds ?? []
        let currentTarotFocus = tarotRounds.last.flatMap { round -> String? in
            if let question = round.request.question, run.plan.followUpQuestion != question { return nil }
            let confirmed = TarotClarificationSuggestion(focus: round.request.focus, originalPosition: round.request.originalPosition)
            return run.plan.tarotClarification == confirmed ? confirmed.focus : nil
        }
        // Deliberately retain every person's result, even when method IDs match.
        return """
        用户问题：\(run.input.question)
        本条补充问题（用户的实际追问或操作请求）：\(run.plan.followUpQuestion ?? "无，回答原问题")
        询问对象：\(run.input.subject)
        关系主题：\(run.input.relationship ?? "未指定")
        参与人员（本次已确认快照） json：\(try json(run.input.readingParticipants))
        参与人员称呼（以ID配对） json：\(try json(run.input.readingParticipants.map { ["id": $0.id.uuidString, "participantLabel": $0.participantLabel] }))
        已保存的起问时刻 json：\(try json(run.input.castingDate))
        原始六爻爻值（由下至上） json：\(try json(run.input.manualLines))
        原始塔罗牌位及正逆位 json：\(try json(run.input.tarotDraws ?? []))
        已确认塔罗补牌（按轮次排列，含澄清焦点、关联原牌位、实际牌面及正逆位） json：\(try json(tarotRounds))
        最近已确认补牌轮ID：\(tarotRounds.last?.request.id.uuidString ?? "无")
        本次确认的补牌焦点：\(currentTarotFocus ?? "无")
        补牌建议是否可用：\(canSuggestTarotClarification(for: run) ? "可选，须由用户确认" : "不可提出")
        原始报数 json：\(try json(run.input.numbers))
        用户已完成的交互 json：\(try json(run.input.interactionResponses ?? []))
        全部可用结果 json：\(try json(eligible))
        沿用已有计算的结果ID json：\(try json(run.reusedResultIDs ?? []))
        因资料限制而未采用的方法 json：\(try json(run.plan.omittedMethods ?? []))
        本次资料说明 json：\(try json(run.plan.preparationNotes ?? []))
        偏好权重 json：\(try json(weights))
        """
    }
}
