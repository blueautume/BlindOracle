import Foundation

enum ReadingContextBuilder {
    static func payload(run: OracleRun, weights: [String: Double]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let eligible = run.results.filter { $0.status == .complete || $0.status == .partial }
        // Deliberately retain every person's result, even when method IDs match.
        return """
        用户问题：\(run.input.question)
        询问对象：\(run.input.subject)
        关系主题：\(run.input.relationship ?? "未指定")
        参与人员（本次已确认快照） json：\(try json(run.input.readingParticipants))
        已保存的起问时刻 json：\(try json(run.input.castingDate))
        原始六爻爻值（由下至上） json：\(try json(run.input.manualLines))
        原始塔罗牌位及正逆位 json：\(try json(run.input.tarotDraws ?? []))
        原始报数 json：\(try json(run.input.numbers))
        用户已完成的交互 json：\(try json(run.input.interactionResponses ?? []))
        全部可用结果 json：\(try json(eligible))
        因资料限制而未采用的方法 json：\(try json(run.plan.omittedMethods ?? []))
        本次资料说明 json：\(try json(run.plan.preparationNotes ?? []))
        偏好权重 json：\(try json(weights))
        """
    }
}
