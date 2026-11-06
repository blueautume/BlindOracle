import Foundation

enum ReadingContextBuilder {
    private struct CastingPlaceSnapshot: Encodable {
        let place: String
        let timeZone: String
        let latitude: Double?
        let longitude: Double?
        let confirmed: Bool
        init(_ profile: OracleProfile) {
            place = profile.currentPlace; timeZone = profile.currentTimeZoneID
            let point = TrueSolarClock.castingCoordinates(profile: profile)
            latitude = point?.latitude; longitude = point?.longitude
            confirmed = point != nil && TimeZone(identifier: timeZone) != nil
        }
    }
    static func canSuggestTarotClarification(for run: OracleRun) -> Bool {
        TarotDeck.canAppendClarification(to: run.input) && run.results.contains { result in
            result.method == .tarot && result.status == .complete
        }
    }

    static func payload(run: OracleRun, language: AppLanguage = .current) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let eligible = run.results.filter { $0.status == .complete || $0.status == .partial }
        let confirmedTarot = TarotDeck.isValidInitialSpread(run.input.tarotDraws ?? []) && eligible.contains {
            $0.method == .tarot && $0.status == .complete && $0.tarotDraws == run.input.tarotDraws
        }
        let tarotRounds = run.input.tarotClarificationRounds ?? []
        let currentTarotFocus = tarotRounds.last.flatMap { round -> String? in
            if let question = round.request.question, run.plan.followUpQuestion != question { return nil }
            let confirmed = TarotClarificationSuggestion(focus: round.request.focus, originalPosition: round.request.originalPosition)
            return run.plan.tarotClarification == confirmed ? confirmed.focus : nil
        }
        // Deliberately retain every person's result, even when method IDs match.
        func label(_ chinese: String, _ english: String) -> String { L10n.text(chinese, english, language: language) }
        let understoodFollowUp = run.plan.followUpQuestion.flatMap { _ in run.plan.understanding?.resolvedQuestion }
        let followUp = run.plan.followUpQuestion ?? label("无，回答原问题", "None; answer the original question.")
        let archivedConflict = run.synthesis?.archivedConflictDetails?.trimmingCharacters(in: .whitespacesAndNewlines)
        let archivedNote = archivedConflict.flatMap { $0.isEmpty ? nil : "\n" + label("历史解读中的分歧说明（仅作已保存文字）：", "Archived disagreement explanation (saved text only): ") + $0 } ?? ""
        return """
        \(label("用户问题：", "Original question: "))\(run.input.question)
        \(label("本条补充问题（用户的实际追问或操作请求）：", "Actual follow-up or action request: "))\(followUp)\(understoodFollowUp.map { "\n" + label("结合对话理解的追问：", "Follow-up resolved from the conversation: ") + $0 } ?? "")
        \(label("本轮塔罗初阵确认状态：", "Current initial Tarot spread state: "))\(confirmedTarot ? label("已确认3张有效初阵牌，抽牌和计算均已完成", "Three valid initial cards are confirmed; the draw and calculation are complete.") : label("没有已确认可用的塔罗初阵结果", "No confirmed usable initial Tarot result."))
        \(label("询问对象：", "Subject: "))\(run.input.subject)
        \(label("关系主题：", "Relationship: "))\(run.input.relationship ?? label("未指定", "Unspecified"))
        \(label("参与人员（本次已确认快照） json：", "Confirmed participants JSON: "))\(try json(run.input.readingParticipants))
        \(label("参与人员称呼（以ID配对） json：", "Participant labels by ID JSON: "))\(try json(run.input.readingParticipants.map { ["id": $0.id.uuidString, "participantLabel": $0.participantLabel] }))
        \(label("已保存的起问时刻 json：", "Saved casting time JSON: "))\(try json(run.input.castingDate))
        \(label("本次独立起卦地点（与参与人出生地分开） json：", "Independent casting place for this question (separate from birthplaces) JSON: "))\(try json(CastingPlaceSnapshot(run.input.profile)))
        \(label("原始六爻爻值（由下至上） json：", "Original six-line values, bottom to top, JSON: "))\(try json(run.input.manualLines))
        \(label("原始塔罗牌位及正逆位 json：", "Original Tarot positions and orientations JSON: "))\(try json(run.input.tarotDraws ?? []))
        \(label("已确认塔罗补牌（按轮次排列，含澄清焦点、关联原牌位、实际牌面及正逆位） json：", "Confirmed Tarot clarifiers in round order, with focus, position, card and orientation, JSON: "))\(try json(tarotRounds))
        \(label("最近已确认补牌轮ID：", "Latest confirmed clarifier round ID: "))\(tarotRounds.last?.request.id.uuidString ?? label("无", "None"))
        \(label("本次确认的补牌焦点：", "Current confirmed clarifier focus: "))\(currentTarotFocus ?? label("无", "None"))
        \(label("补牌建议是否可用：", "May suggest a clarifier: "))\(canSuggestTarotClarification(for: run) ? label("可选，须由用户确认", "Optional; user confirmation required.") : label("不可提出", "No"))
        \(label("原始报数 json：", "Original numbers JSON: "))\(try json(run.input.numbers))
        \(label("用户已完成的交互 json：", "Completed user interactions JSON: "))\(try json(run.input.interactionResponses ?? []))
        \(label("全部可用结果 json：", "All usable results JSON: "))\(try json(eligible))
        \(label("沿用已有计算的结果ID json：", "Reused result IDs JSON: "))\(try json(run.reusedResultIDs ?? []))
        \(label("因资料限制而未采用的方法 json：", "Methods omitted due to missing details JSON: "))\(try json(run.plan.omittedMethods ?? []))
        \(label("本次资料说明 json：", "Notes on available details JSON: "))\(try json(run.plan.preparationNotes ?? []))\(archivedNote)
        """
    }
}
