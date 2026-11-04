import XCTest
@testable import BlindOracle

final class AIServiceTests: XCTestCase {
    func testModelVerificationAcceptsVersionSuffixesAndRejectsOtherModelFamilies() {
        XCTAssertTrue(DeepSeekClient.modelsMatch(requested: "deepseek-v4-pro", returned: "deepseek-v4-pro"))
        XCTAssertTrue(DeepSeekClient.modelsMatch(requested: "deepseek-v4-pro", returned: "deepseek-v4-pro-0813"))
        XCTAssertTrue(DeepSeekClient.modelsMatch(requested: "deepseek-v4-pro", returned: " deepseek-v4-pro-2026-08-13\n"))
        XCTAssertFalse(DeepSeekClient.modelsMatch(requested: "deepseek-v4-pro", returned: "deepseek-v4-flash"))
        XCTAssertFalse(DeepSeekClient.modelsMatch(requested: "deepseek-v4-pro", returned: "deepseek-v4-professional"))
        XCTAssertFalse(DeepSeekClient.modelsMatch(requested: "deepseek-v4-pro-0813", returned: "deepseek-v4-pro"))
        XCTAssertFalse(DeepSeekClient.modelsMatch(requested: "", returned: "-0813"))
    }

    func testQwenPinnedSnapshotAcceptsOnlyTheExactReleaseAndItsDateAlias() {
        let requested = "qwen3.8-max-0902"
        XCTAssertTrue(DeepSeekClient.modelsMatch(requested: requested, returned: requested))
        XCTAssertTrue(DeepSeekClient.modelsMatch(requested: requested, returned: " qwen3.8-max-2026-09-02\n"))
        for returned in ["qwen3.8-max", "qwen3.8-max-0903", "qwen3.8-max-2026-09-03", "qwen3.8-max-0902-preview", "qwen3.8-flash"] {
            XCTAssertFalse(DeepSeekClient.modelsMatch(requested: requested, returned: returned), returned)
        }
    }

    func testQwenRequestUsesBailianParametersForPlanningAndStreaming() {
        let provider = AIProvider.qwen
        let messages = [
            AIConversationTurn(role: "assistant", content: "此前的回答"),
            AIConversationTurn(role: "user", content: "请输出 json")
        ]
        XCTAssertEqual(provider.endpoint.host, "dashscope.aliyuncs.com")
        XCTAssertEqual(provider.endpoint.path, "/compatible-mode/v1/chat/completions")
        for streaming in [false, true] {
            let body = DeepSeekClient.requestBody(messages, model: provider.model(),
                jsonMode: true, streaming: streaming, maxTokens: 2400, provider: provider)
            XCTAssertEqual(body["model"] as? String, "qwen3.8-max-0902")
            XCTAssertEqual(body["messages"] as? [[String: String]], [
                ["role": "assistant", "content": "此前的回答"],
                ["role": "user", "content": "请输出 json"]
            ])
            XCTAssertEqual(body["enable_thinking"] as? Bool, true)
            XCTAssertEqual(body["preserve_thinking"] as? Bool, false)
            XCTAssertEqual(body["reasoning_effort"] as? String, "xhigh")
            XCTAssertEqual(body["max_completion_tokens"] as? Int, 65_536)
            XCTAssertEqual(body["stream"] as? Bool, streaming)
            XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], streaming ? true : nil)
            XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
            XCTAssertNil(body["thinking"])
            XCTAssertNil(body["max_tokens"])
        }
    }

    func testBailianStreamSeparatesVisibleAnswerAndUsageFromHiddenReasoning() throws {
        var framer = DeepSeekSSEFramer()
        let lines = [
            #"data: {"model":"qwen3.8-max-0902","choices":[{"delta":{"content":null,"reasoning_content":"private"},"finish_reason":null}]}"#,
            #"data: {"model":"qwen3.8-max-0902","choices":[{"delta":{"content":"可先观察"},"finish_reason":null}]}"#,
            #"data: {"model":"qwen3.8-max-0902","choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"data: {"model":"qwen3.8-max-0902","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":8,"total_tokens":20,"completion_tokens_details":{"reasoning_tokens":5}}}"#,
            "data: [DONE]"
        ]
        let chunks = try lines.compactMap { try framer.push($0) }
        XCTAssertEqual(Set(chunks.compactMap(\.model)), ["qwen3.8-max-0902"])
        XCTAssertEqual(chunks.map(\.content).joined(), "可先观察")
        XCTAssertEqual(chunks.compactMap(\.finishReason), ["stop"])
        XCTAssertEqual(chunks.compactMap { $0.usage?.reasoningTokens }, [5])
        XCTAssertTrue(chunks.last?.isDone == true)
        try framer.finish()
    }

    func testConnectionProbeKeepsModelAndTokenEvidenceWithoutSavingResponseOrReasoningText() throws {
        let data = Data(#"{"model":"deepseek-v4-pro-0813","choices":[{"message":{"content":"synthetic-response-marker","reasoning_content":"private-reasoning-marker"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":8,"total_tokens":20,"completion_tokens_details":{"reasoning_tokens":5}}}"#.utf8)
        let checkedAt = Date(timeIntervalSince1970: 1_730_000_000)
        let report = try DeepSeekClient.connectionReport(from: data, requestedModel: "deepseek-v4-pro",
            host: "api.deepseek.com", elapsed: 1.25, checkedAt: checkedAt)
        XCTAssertEqual(report.requestedModel, "deepseek-v4-pro")
        XCTAssertEqual(report.actualModel, "deepseek-v4-pro-0813")
        XCTAssertEqual(report.host, "api.deepseek.com")
        XCTAssertEqual(report.elapsed, 1.25)
        XCTAssertEqual(report.checkedAt, checkedAt)
        XCTAssertEqual(report.finishReason, "stop")
        XCTAssertEqual(report.promptTokens, 12)
        XCTAssertEqual(report.completionTokens, 8)
        XCTAssertEqual(report.totalTokens, 20)
        XCTAssertEqual(report.reasoningTokens, 5)
        let stored = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(stored.contains("synthetic-response-marker"))
        XCTAssertFalse(stored.contains("private-reasoning-marker"))
        XCTAssertFalse(stored.contains("reasoning_content"))
    }

    func testConnectionProbeRejectsMissingModelsEmptyAnswersAndNonStopFinishes() {
        let invalidResponses = [
            #"{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#,
            #"{"model":" ","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#,
            #"{"model":"deepseek-v4-pro","choices":[{"message":{"content":"OK"},"finish_reason":"length"}]}"#,
            #"{"model":"deepseek-v4-pro","choices":[{"message":{"content":"OK"},"finish_reason":"content_filter"}]}"#,
            #"{"model":"deepseek-v4-pro","choices":[{"message":{"content":"OK"},"finish_reason":null}]}"#,
            #"{"model":"deepseek-v4-pro","choices":[{"message":{"content":" \n\t"},"finish_reason":"stop"}]}"#,
            #"{"model":"deepseek-v4-pro","choices":[{"message":{"reasoning_content":"not-an-answer"},"finish_reason":"stop"}]}"#,
            #"{"model":"deepseek-v4-pro","choices":[]}"#
        ]
        for response in invalidResponses {
            XCTAssertThrowsError(try DeepSeekClient.connectionReport(from: Data(response.utf8), requestedModel: "deepseek-v4-pro",
                host: "api.deepseek.com", elapsed: 0))
        }
        let mismatch = Data(#"{"model":"deepseek-v4-flash","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#.utf8)
        XCTAssertThrowsError(try DeepSeekClient.connectionReport(from: mismatch, requestedModel: "deepseek-v4-pro",
            host: "api.deepseek.com", elapsed: 0)) { error in
            guard case DeepSeekError.unexpectedModel(let requested, let actual) = error else {
                return XCTFail("Expected a model mismatch, received \(error)")
            }
            XCTAssertEqual(requested, "deepseek-v4-pro")
            XCTAssertEqual(actual, "deepseek-v4-flash")
        }
    }

    func testStreamingUsageOnlyEventsPreserveMetadataWithoutInventingContent() throws {
        let chunk = try DeepSeekSSEChunk.decode(#"{"model":"deepseek-v4-pro-0813","choices":[],"usage":{"prompt_tokens":4,"completion_tokens":6,"total_tokens":10,"completion_tokens_details":{"reasoning_tokens":3}}}"#)
        XCTAssertEqual(chunk.model, "deepseek-v4-pro-0813")
        XCTAssertEqual(chunk.content, "")
        XCTAssertFalse(chunk.isDone)
        XCTAssertNil(chunk.finishReason)
        XCTAssertEqual(chunk.usage?.promptTokens, 4)
        XCTAssertEqual(chunk.usage?.completionTokens, 6)
        XCTAssertEqual(chunk.usage?.totalTokens, 10)
        XCTAssertEqual(chunk.usage?.reasoningTokens, 3)
        let legacy = try DeepSeekSSEChunk.decode(#"{"choices":[{"delta":{"content":"继续"},"finish_reason":"stop"}]}"#)
        XCTAssertEqual(legacy.content, "继续")
        XCTAssertNil(legacy.model)
        XCTAssertNil(legacy.usage)
    }

    func testUsageMergesPartialMetadataAndAcceptsZeroWithoutKeepingNegativeCounts() throws {
        let decoder = JSONDecoder()
        var usage = try decoder.decode(DeepSeekTokenUsage.self,
            from: Data(#"{"prompt_tokens":12,"completion_tokens":8,"total_tokens":20,"reasoning_tokens":5}"#.utf8))
        let update = try decoder.decode(DeepSeekTokenUsage.self,
            from: Data(#"{"prompt_tokens":-1,"completion_tokens":0,"total_tokens":12}"#.utf8))
        usage.merge(update)
        XCTAssertEqual(usage.promptTokens, 12)
        XCTAssertEqual(usage.completionTokens, 0)
        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.reasoningTokens, 5)
        let invalid = try decoder.decode(DeepSeekTokenUsage.self,
            from: Data(#"{"prompt_tokens":-1,"completion_tokens_details":{"reasoning_tokens":-2}}"#.utf8))
        XCTAssertNil(invalid.promptTokens)
        XCTAssertNil(invalid.reasoningTokens)
    }

    func testPlanningAndStreamingRequestsKeepTheSameProThinkingAndOutputBudget() {
        let messages = [AIConversationTurn(role: "user", content: "synthetic check")]
        for streaming in [false, true] {
            let body = DeepSeekClient.requestBody(messages, model: DeepSeekConfiguration.defaultModel,
                jsonMode: true, streaming: streaming, maxTokens: 2400)
            XCTAssertEqual(body["model"] as? String, "deepseek-v4-pro")
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "enabled")
            XCTAssertEqual(body["reasoning_effort"] as? String, "max")
            XCTAssertEqual(body["max_tokens"] as? Int, 65_536)
            XCTAssertEqual(body["stream"] as? Bool, streaming)
            XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        }
        let plain = DeepSeekClient.requestBody(messages, model: DeepSeekConfiguration.defaultModel,
            jsonMode: false, streaming: false, maxTokens: 128)
        XCTAssertNil(plain["response_format"])
        XCTAssertEqual(plain["max_tokens"] as? Int, 65_536)
    }

    func testSavedProfileFieldQuestionsUseTheFormInsteadOfRepeatingChatPrompts() {
        XCTAssertTrue(AIPlanRouting.shouldOpenFormForProfileRequest(action: "clarify", note: "这次要看的姓名是什么？", question: "看一下财运明年", hasPendingQuestion: false))
        XCTAssertTrue(AIPlanRouting.shouldOpenFormForProfileRequest(action: "reply", note: "请明确出生地时区。", question: "李浩的事业", hasPendingQuestion: false))
        XCTAssertTrue(AIPlanRouting.shouldOpenFormForProfileRequest(action: "collect", note: "请补充生日和性别。", question: "李浩", hasPendingQuestion: true))
    }

    func testOrdinaryClarificationAndProfileExplanationDoNotBecomeNewReadings() {
        XCTAssertFalse(AIPlanRouting.shouldOpenFormForProfileRequest(action: "clarify", note: "你最想问的是哪件事？", question: "帮我看看", hasPendingQuestion: false))
        XCTAssertFalse(AIPlanRouting.shouldOpenFormForProfileRequest(action: "reply", note: "出生地时区表示当地采用的时间标准。", question: "什么是出生地时区", hasPendingQuestion: false))
        XCTAssertFalse(AIPlanRouting.shouldOpenFormForProfileRequest(action: "intake", note: "请填写生日。", question: "财运", hasPendingQuestion: false))
    }

    func testReplyAndClarificationNeverCreateFallbackCharts() {
        let available = Set(OracleMethod.allCases)
        XCTAssertEqual(AIPlanRouting.normalizedAction(nil), "intake")
        XCTAssertEqual(AIPlanRouting.normalizedAction("execute_arbitrary_code"), "intake")
        XCTAssertTrue(AIPlanRouting.selectedMethods(action: "reply", requested: ["bazi"], available: available).isEmpty)
        XCTAssertTrue(AIPlanRouting.selectedMethods(action: "clarify", requested: [], available: available).isEmpty)
        XCTAssertEqual(AIPlanRouting.selectedMethods(action: "intake", requested: ["not_a_plugin"], available: [.meihua]), [.meihua])
        XCTAssertEqual(AIPlanRouting.selectedMethods(action: "intake", requested: ["bazi", "bazi", "unknown"], available: available), [.bazi])
        for action in ["reply", "clarify"] {
            XCTAssertTrue(AIPlanRouting.selectedMethods(action: action, requested: ["tarot", "meihua", "bazi"], available: available).isEmpty)
        }
    }

    func testSupplementNeverFallsBackToUnrequestedMethods() {
        let available = Set(OracleMethod.allCases)
        XCTAssertEqual(AIPlanRouting.normalizedAction("supplement"), "supplement")
        XCTAssertTrue(AIPlanRouting.selectedMethods(action: "supplement", requested: [], available: available).isEmpty)
        XCTAssertTrue(AIPlanRouting.selectedMethods(action: "supplement", requested: ["unknown", "not_a_plugin"], available: available).isEmpty)
        XCTAssertTrue(AIPlanRouting.selectedMethods(action: "supplement", requested: ["bazi"], available: [.meihua, .tarot]).isEmpty)
        XCTAssertTrue(AIPlanRouting.selectedMethods(action: "supplement", requested: ["bazi", "meihua"], available: []).isEmpty)
    }

    func testSupplementKeepsOnlyAvailableMethodsOnceInRequestedOrder() {
        let methods = AIPlanRouting.selectedMethods(action: "supplement",
            requested: ["unknown", "meihua", "bazi", "meihua", "liuyao", "tarot", "bazi", "tarot"],
            available: [.bazi, .meihua, .tarot])
        XCTAssertEqual(methods, [.meihua, .bazi, .tarot])
    }

    func testSupplementMissingProfileDataDoesNotBecomeANewIntake() {
        XCTAssertFalse(AIPlanRouting.shouldOpenFormForProfileRequest(action: "supplement",
            note: "请补充出生日期与出生时区，才能增加这项参考。", question: "补充看看长期事业选择", hasPendingQuestion: false))
        XCTAssertFalse(AIPlanRouting.shouldOpenFormForProfileRequest(action: "supplement",
            note: "请在资料表确认姓名和生日。", question: "继续", hasPendingQuestion: true))
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

    func testStreamingJSONPreservesGraphemesSplitAcrossProviderChunks() {
        var extractor = JSONTextStreamExtractor()
        let pieces = ["{\"text\":\"e", "\u{301}，👩", "\u{200D}", "💻，🇨", "🇳继续。\"}"]
        let output = pieces.compactMap { extractor.append($0) }.joined()
        XCTAssertEqual(output, "e\u{301}，👩‍💻，🇨🇳继续。")
    }

    func testStreamingJSONFindsOnlyTheTopLevelTextProperty() {
        var extractor = JSONTextStreamExtractor()
        let pieces = [
            #"{"metadata":{"text":"不应展示","values":[{"text":"也不应展示"}]},"note":"提到 \"text\": 的说明","t\u0065xt":"#,
            #""实际正文","alternatives":[{"text":"不得混入"}]}"#
        ]
        XCTAssertEqual(pieces.compactMap { extractor.append($0) }.joined(), "实际正文")
        XCTAssertNil(extractor.append(#"{"text":"已结束后不得重复展示"}"#))
    }

    func testStreamingJSONHandlesEveryScalarBoundaryAndAllJSONEscapes() throws {
        let expected = "含引号\"、斜线/、反斜线\\、换行\n制表\t回车\r\u{8}\u{C}e\u{301}👨‍👩‍👧‍👦🇨🇳"
        let encoded = String(decoding: try JSONEncoder().encode(["text": expected]), as: UTF8.self)
        let scalars = Array(encoded.unicodeScalars)
        for split in 0...scalars.count {
            var extractor = JSONTextStreamExtractor()
            let first = String(String.UnicodeScalarView(scalars.prefix(split)))
            let second = String(String.UnicodeScalarView(scalars.dropFirst(split)))
            XCTAssertEqual([first, second].compactMap { extractor.append($0) }.joined(), expected, "split=\(split)")
        }
        var extractor = JSONTextStreamExtractor()
        let escaped = #"{"text":"\u4F60\u597D\uD83D\uDC41\/\b\f\n\r\t\"\\"}"#
        XCTAssertEqual(escaped.unicodeScalars.compactMap { extractor.append(String($0)) }.joined(), "你好👁/\u{8}\u{C}\n\r\t\"\\")
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

extension AIServiceTests {
    func testBothProvidersPlanAndStreamAnEnglishReadingWithLegacyHistory() async throws {
        let question = "Should I apply for the new job?"
        let history = [AIConversationTurn(role: "assistant", content: "上次的对话原文")]
        let profile = OracleProfile()
        let plugins = PluginRegistry().descriptors
        for provider in AIProvider.allCases {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [EnglishReadingURLProtocol.self]
            let client = DeepSeekClient(provider: provider, apiKey: "test-key", sessionConfiguration: configuration)
            let plan = try await client.plan(question: question, profile: profile, plugins: plugins, history: history, language: .english)
            XCTAssertEqual(plan.action, "intake")
            XCTAssertEqual(plan.subject, "本人")
            XCTAssertEqual(plan.methods, [.tarot])
            XCTAssertEqual(plan.interactions?.first?.kind, .tarot)
            XCTAssertEqual(plan.interactions?.first?.prompt, "Choose three cards.")
            XCTAssertEqual(plan.note, "Review the reading details.")
            XCTAssertEqual(plan.question, question)

            var run = OracleRun(input: OracleInput(question: question, profile: profile), plan: plan)
            run.results = [OracleResult(method: .tarot, headline: "Test Tarot result", rows: [])]
            let visible = XCTestExpectation(description: "\(provider) streamed only the visible reply")
            let synthesis = try await client.synthesize(run: run, weights: [:], history: history, language: .english) { delta in
                XCTAssertEqual(delta, "Apply if the role fits your priorities.")
                visible.fulfill()
            }
            await fulfillment(of: [visible], timeout: 1)
            XCTAssertEqual(synthesis.text, "Apply if the role fits your priorities.")
            XCTAssertTrue(synthesis.alternatives.isEmpty)
        }
    }
}

/// Validates real encoded requests while supplying synthetic API envelopes for
/// both provider endpoints. This protocol claims all requests in the test session.
private final class EnglishReadingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let data = try requestBody()
            guard let url = request.url, let host = url.host,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = body["model"] as? String,
                  let stream = body["stream"] as? Bool,
                  let turns = body["messages"] as? [[String: String]],
                  turns.first?["role"] == "system",
                  turns.first?["content"]?.contains("natural English") == true,
                  turns.contains(["role": "assistant", "content": "上次的对话原文"]),
                  turns.last?["content"]?.contains("Should I apply for the new job?") == true,
                  (body["response_format"] as? [String: String])?["type"] == "json_object",
                  (host == "api.deepseek.com" && body["thinking"] != nil
                    || host == "dashscope.aliyuncs.com" && body["enable_thinking"] as? Bool == true) else {
                throw URLError(.badServerResponse)
            }

            let payload: Data
            if stream {
                let content = #"{"text":"Apply if the role fits your priorities.","alternatives":[]}"#
                let events: [[String: Any]] = [
                    ["model": model, "choices": [["delta": ["reasoning_content": "Private test reasoning"]]]],
                    ["model": model, "choices": [["delta": ["content": content], "finish_reason": "stop"]]]
                ]
                let framed = try events.map { event in
                    "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
                }.joined(separator: "\n\n") + "\n\ndata: [DONE]\n\n"
                payload = Data(framed.utf8)
            } else {
                let content = #"{"action":"intake","intent":"Career choice","subject":"本人","methods":["tarot"],"requiredFields":[],"note":"Review the reading details.","question":"Untrusted replacement","interactions":[{"method":"tarot","kind":"tarot","prompt":"Choose three cards."}]}"#
                payload = try JSONSerialization.data(withJSONObject: [
                    "model": model, "choices": [["message": ["content": content], "finish_reason": "stop"]]
                ])
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": stream ? "text/event-stream" : "application/json"]) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func requestBody() throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.badServerResponse) }
        stream.open()
        defer { stream.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return output }
            guard count > 0 else { throw stream.streamError ?? URLError(.badServerResponse) }
            output.append(contentsOf: buffer.prefix(count))
        }
    }
}
