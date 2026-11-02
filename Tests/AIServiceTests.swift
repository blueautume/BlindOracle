import XCTest
@testable import BlindOracle

final class AIServiceTests: XCTestCase {
    func testReplyAndClarificationNeverCreateFallbackCharts() {
        let available = Set(OracleMethod.allCases)
        XCTAssertEqual(AIPlanRouting.normalizedAction(nil), "intake")
        XCTAssertEqual(AIPlanRouting.normalizedAction("execute_arbitrary_code"), "intake")
        XCTAssertTrue(AIPlanRouting.selectedMethods(action: "reply", requested: ["bazi"], available: available).isEmpty)
        XCTAssertTrue(AIPlanRouting.selectedMethods(action: "clarify", requested: [], available: available).isEmpty)
        XCTAssertEqual(AIPlanRouting.selectedMethods(action: "intake", requested: ["not_a_plugin"], available: [.meihua]), [.meihua])
        XCTAssertEqual(AIPlanRouting.selectedMethods(action: "intake", requested: ["bazi", "bazi", "unknown"], available: available), [.bazi])
    }

    func testStreamingJSONShowsOnlyTextAndPreservesEscapes() {
        var extractor = JSONTextStreamExtractor()
        let pieces = ["{\"te", "xt\":\"先别", "着急。\\n把\\\"问题\\\"", "写下。\",\"alternatives\":[]}"]
        let output = pieces.compactMap { extractor.append($0) }.joined()
        XCTAssertEqual(output, "先别着急。\n把\"问题\"写下。")
        XCTAssertFalse(output.contains("alternatives"))
        XCTAssertFalse(output.contains("text"))
    }

    func testStreamingJSONHandlesSplitUnicodeSurrogates() {
        var extractor = JSONTextStreamExtractor()
        let pieces = ["{\"text\":\"静候", "\\uD83D", "\\uDC41", "，再行动。\"}"]
        XCTAssertEqual(pieces.compactMap { extractor.append($0) }.joined(), "静候👁，再行动。")
    }

    func testSSEIgnoresReasoningAndAcceptsCompletion() throws {
        let chunk = try DeepSeekSSEChunk.decode(#"{"choices":[{"delta":{"reasoning_content":"hidden","content":"可先观察"},"finish_reason":null}]}"#)
        XCTAssertEqual(chunk.content, "可先观察")
        XCTAssertNil(chunk.finishReason)
        XCTAssertFalse(chunk.isDone)
        let finish = try DeepSeekSSEChunk.decode(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        XCTAssertEqual(finish.finishReason, "stop")
        XCTAssertTrue(try DeepSeekSSEChunk.decode("[DONE]").isDone)
        XCTAssertThrowsError(try DeepSeekSSEChunk.decode(#"{"error":{"message":"overloaded"}}"#))
    }

    func testSSEFramesConsecutiveDataLinesWithoutBlankSeparators() throws {
        var framer = DeepSeekSSEFramer()
        let lines = [
            #"data: {"choices":[{"delta":{"content":"先稳"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"reasoning_content":"hidden","content":"住。"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]"
        ]
        let chunks = try lines.compactMap { try framer.push($0) }
        XCTAssertEqual(chunks.map(\.content).joined(), "先稳住。")
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[2].finishReason, "stop")
        XCTAssertTrue(chunks[3].isDone)
        XCTAssertNoThrow(try framer.finish())
    }

    func testSSEFramesActualMultilineJSONAndIgnoresComments() throws {
        var framer = DeepSeekSSEFramer()
        XCTAssertNil(try framer.push(": keepalive"))
        XCTAssertNil(try framer.push("event: message"))
        XCTAssertNil(try framer.push(#"data: {"choices":"#))
        let chunk = try framer.push(#"data: [{"delta":{"content":"括号 { } 在正文内"},"finish_reason":null}]}"#)
        XCTAssertEqual(chunk?.content, "括号 { } 在正文内")
        XCTAssertNil(try framer.push(""))
        XCTAssertNoThrow(try framer.finish())
        XCTAssertNil(try framer.push(#"data: {"choices": ["#))
        XCTAssertThrowsError(try framer.finish())
    }

    func testConflictOptionsOnlyUseAvailableDistinctMethods() {
        let raw = [
            AIReadingAlternative(title: "先稳住", body: "先做好手边之事。", supportingMethods: ["bazi", "bazi", "not_a_plugin"]),
            AIReadingAlternative(title: "可尝试", body: "做一次小范围尝试。", supportingMethods: ["bazi", "meihua", "astrology"])
        ]
        let result = ReadingSynthesisValidator.validatedAlternatives(raw, supported: [.bazi, .meihua])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].supportingMethods, [.bazi])
        XCTAssertEqual(result[1].supportingMethods, [.meihua])
        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }

    func testInvalidConflictCardinalityOrUnsupportedOptionsAreRejected() {
        let a = AIReadingAlternative(title: "一", body: "说明", supportingMethods: ["bazi"])
        let b = AIReadingAlternative(title: "二", body: "说明", supportingMethods: ["unknown"])
        XCTAssertTrue(ReadingSynthesisValidator.validatedAlternatives([a], supported: [.bazi]).isEmpty)
        XCTAssertTrue(ReadingSynthesisValidator.validatedAlternatives([a, b], supported: [.bazi]).isEmpty)
        XCTAssertTrue(ReadingSynthesisValidator.validatedAlternatives([a, a, a], supported: [.bazi]).isEmpty)
    }

    func testHistoryPreservesSummaryAndEveryUncoveredTurn() {
        let messages = (0..<60).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "消息\($0)") }
        var summary = ConversationSummary()
        summary.text = "已确认此前的事项"
        summary.coveredMessageIDs = Array(messages.prefix(10).map(\.id))
        let history = ContextCompressor.history(messages: messages, summary: summary)
        XCTAssertEqual(history.count, 51)
        XCTAssertTrue(history[0].content.contains(summary.text))
        XCTAssertEqual(history[1].content, "消息10")
        XCTAssertEqual(history.last?.content, "消息59")
        XCTAssertEqual(messages.count, 60)
    }

    func testCompressionIsInfrequentAndThresholdBased() {
        let short = (0..<60).map { _ in ChatMessage(role: .user, content: "短消息") }
        XCTAssertFalse(ContextCompressor.shouldCompress(messages: short, summary: ConversationSummary()))
        let long = (0..<60).map { _ in ChatMessage(role: .user, content: String(repeating: "字", count: 1200)) }
        XCTAssertTrue(ContextCompressor.shouldCompress(messages: long, summary: ConversationSummary()))
        var recent = ConversationSummary()
        recent.lastCompressedMessageCount = 50
        XCTAssertFalse(ContextCompressor.shouldCompress(messages: long, summary: recent))
    }
}
