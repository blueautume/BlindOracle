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
        用户已完成的交互 json：\(try json(run.input.interactionResponses ?? []))
        全部可用结果 json：\(try json(eligible))
        偏好权重 json：\(try json(weights))
        """
    }
}
