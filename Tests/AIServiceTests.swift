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

    func testServiceErrorsDoNotExposeCredentialsProvidersOrModelSettings() {
        let errors: [DeepSeekError] = [.missingKey, .invalidResponse, .malformedJSON, .truncated,
            .http(401), .http(402), .http(403), .http(429), .http(500), .missingResponseModel,
            .unexpectedModel(requested: "internal-request-model", actual: "internal-response-model"),
            .provider("private-server-message")]
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLanguage.$override.withValue(language) {
                for error in errors {
                    let message = error.localizedDescription.lowercased()
                    XCTAssertFalse(message.isEmpty)
                    for hidden in ["deepseek", "qwen", "api", "key", "密钥", "模型", "设置", "internal-", "private-server-message"] {
                        XCTAssertFalse(message.contains(hidden), "\(message) exposes \(hidden)")
                    }
                }
            }
        }
    }

    func testStreamSeparatesVisibleAnswerAndUsageFromHiddenReasoning() throws {
        var framer = DeepSeekSSEFramer()
        let lines = [
            #"data: {"model":"deepseek-v4-pro","choices":[{"delta":{"content":null,"reasoning_content":"private"},"finish_reason":null}]}"#,
            #"data: {"model":"deepseek-v4-pro","choices":[{"delta":{"content":"可先观察"},"finish_reason":null}]}"#,
            #"data: {"model":"deepseek-v4-pro","choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"data: {"model":"deepseek-v4-pro","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":8,"total_tokens":20,"completion_tokens_details":{"reasoning_tokens":5}}}"#,
            "data: [DONE]"
        ]
        let chunks = try lines.compactMap { try framer.push($0) }
        XCTAssertEqual(Set(chunks.compactMap(\.model)), ["deepseek-v4-pro"])
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
            let body = DeepSeekClient.requestBody(messages,
                jsonMode: true, streaming: streaming, maxTokens: 2400)
            XCTAssertEqual(body["model"] as? String, "deepseek-v4-pro")
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "enabled")
            XCTAssertEqual(body["reasoning_effort"] as? String, "max")
            XCTAssertEqual(body["max_tokens"] as? Int, 65_536)
            XCTAssertEqual(body["stream"] as? Bool, streaming)
            XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        }
        let plain = DeepSeekClient.requestBody(messages,
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
    func testDeepSeekPlansAndStreamsAnEnglishReadingWithLegacyHistory() async throws {
        let question = "Should I apply for the new job?"
        let history = [AIConversationTurn(role: "assistant", content: "上次的对话原文")]
        let profile = OracleProfile()
        let plugins = PluginRegistry().descriptors
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReadingURLProtocol.self]
            let client = DeepSeekClient(apiKey: "test-key", sessionConfiguration: configuration)
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
            let visible = XCTestExpectation(description: "DeepSeek streamed only the visible reply")
            let synthesis = try await client.synthesize(run: run, weights: [:], history: history, language: .english) { delta in
                XCTAssertEqual(delta, "Apply if the role fits your priorities.")
                visible.fulfill()
            }
            await fulfillment(of: [visible], timeout: 1)
            XCTAssertEqual(synthesis.text, "Apply if the role fits your priorities.")
            XCTAssertTrue(synthesis.alternatives.isEmpty)
        }
    }

    func testDeepSeekSendsEachVoiceForSynthesisAndFollowUpWithoutChangingFormats() async throws {
        let question = "这个新项目靠谱吗？"
        let followUp = "如果分工仍不明确呢？"
        let profile = OracleProfile()
        let plan = OraclePlan(intent: "合作", subject: "事件", methods: [.tarot],
                              requiredFields: [], note: "", question: question)
        let run = OracleRun(input: OracleInput(question: question, profile: profile), plan: plan,
                            results: [OracleResult(method: .tarot, headline: "测试牌面", rows: [])])
        let history = [AIConversationTurn(role: "assistant", content: "上次的对话原文")]

        do {
            for voice in OracleVoiceStyle.allCases {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ReadingURLProtocol.self]
                let client = DeepSeekClient(apiKey: "test-voice-\(voice.rawValue)",
                                            sessionConfiguration: configuration)
                let synthesisDelta = expectation(description: "DeepSeek \(voice) streamed synthesis text")
                let synthesis = try await client.synthesize(run: run, weights: [:], history: history,
                                                            language: .simplifiedChinese, voice: voice) { delta in
                    XCTAssertEqual(delta, "先问清分工。")
                    synthesisDelta.fulfill()
                }
                XCTAssertEqual(synthesis.text, "先问清分工。")
                XCTAssertTrue(synthesis.alternatives.isEmpty)
                let followUpDelta = expectation(description: "DeepSeek \(voice) streamed follow-up text")
                let reply = try await client.followUp(question: followUp, run: run, profile: profile, history: history,
                                                      language: .simplifiedChinese, voice: voice) { delta in
                    XCTAssertEqual(delta, "先别答应。")
                    followUpDelta.fulfill()
                }
                XCTAssertEqual(reply, "先别答应。")
                await fulfillment(of: [synthesisDelta, followUpDelta], timeout: 1)
            }
        }
    }

    func testCompletedFreshTarotSynthesisTargetsTheOriginalQuestionDespiteRedrawHistory() async throws {
        let question = "今晚和朋友谈合作，应该先确认分工还是预算？"
        let draws = zip(["cups-02", "pentacles-06", "swords-04"], TarotDeck.positions).enumerated().map {
            TarotDraw(cardID: $0.element.0, isReversed: $0.offset == 1, position: $0.element.1)
        }
        var input = OracleInput(question: question, profile: OracleProfile(), seed: 73, subject: "事件", tarotDraws: draws, participants: [])
        input.interactionResponses = [.init(requestID: "tarot", tarotDraws: draws, revealedCount: 3)]
        let plan = OraclePlan(intent: "合作安排", subject: "事件", methods: [.tarot], requiredFields: [], note: "", question: question)
        let result = try await TarotPlugin().calculate(input)
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.tarotDraws, draws)
        let run = OracleRun(input: input, plan: plan, results: [result])
        XCTAssertNil(run.plan.followUpQuestion)
        try await assertSynthesisTaskRequest(run: run, expectedDraws: draws, result: result)
    }

    func testSynthesisDoesNotClaimCompletedTarotWhenOnlyMeihuaReturnedAUsableResult() async throws {
        let question = "今晚和朋友谈合作，应该先确认分工还是预算？"
        let input = OracleInput(question: question, profile: OracleProfile(), seed: 73, subject: "事件", participants: [])
        let plan = OraclePlan(intent: "合作安排", subject: "事件", methods: [.meihua, .tarot], requiredFields: [], note: "", question: question)
        let result = try await MeihuaPlugin().calculate(input)
        XCTAssertTrue([.complete, .partial].contains(result.status))
        let unavailable = try await TarotPlugin().calculate(input)
        XCTAssertEqual(unavailable.status, .unavailable)
        let run = OracleRun(input: input, plan: plan, results: [result, unavailable])
        try await assertSynthesisTaskRequest(run: run, expectedDraws: [], result: result)
    }

    private func assertSynthesisTaskRequest(run: OracleRun, expectedDraws: [TarotDraw], result: OracleResult) async throws {
        let operation = "我是想重新抽三张牌，不是解释旧结果。"
        let oldAnswer = "我不能重新抽牌，得你自己在界面再抽三张，抽完再解。"
        let history = [AIConversationTurn(role: "user", content: run.input.question),
            AIConversationTurn(role: "assistant", content: oldAnswer), AIConversationTurn(role: "user", content: operation)]
        let inspected = expectation(description: "The encoded synthesis request identifies the completed calculation and current question")
        let key = UUID().uuidString
        SynthesisTaskURLProtocol.install(.init(question: run.input.question, draws: expectedDraws, result: result,
            operation: operation, oldAnswer: oldAnswer, inspected: inspected), key: key)
        defer { SynthesisTaskURLProtocol.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SynthesisTaskURLProtocol.self]
        let client = DeepSeekClient(apiKey: key, sessionConfiguration: configuration)
        let synthesis = try await client.synthesize(run: run, weights: [:], history: history, language: .simplifiedChinese) { _ in }
        await fulfillment(of: [inspected], timeout: 1)
        XCTAssertFalse(synthesis.text.isEmpty)
    }
}

/// Validates real encoded requests while supplying synthetic API envelopes for
/// the fixed interpretation endpoint. It claims all requests in the test session.
private final class ReadingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let voiceTitles = [
        "Bearer test-voice-classic": "经典",
        "Bearer test-voice-deadpan": "冷面直断",
        "Bearer test-voice-warm": "温和参谋",
        "Bearer test-voice-storyteller": "江湖说书"
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let data = try requestBody()
            let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let voiceTitle = Self.voiceTitles[key]
            guard let url = request.url, let host = url.host,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = body["model"] as? String,
                  let stream = body["stream"] as? Bool,
                  let turns = body["messages"] as? [[String: String]],
                  turns.first?["role"] == "system",
                  let system = turns.first?["content"],
                  let latest = turns.last?["content"],
                  turns.contains(["role": "assistant", "content": "上次的对话原文"]),
                  host == "api.deepseek.com", model == DeepSeekConfiguration.defaultModel,
                  (body["thinking"] as? [String: String])?["type"] == "enabled",
                  body["reasoning_effort"] as? String == "max",
                  body["max_tokens"] as? Int == 65_536 else {
                throw URLError(.badServerResponse)
            }

            let jsonMode = (body["response_format"] as? [String: String])?["type"] == "json_object"
            let isFollowUp = latest == "如果分工仍不明确呢？"
            if let voiceTitle {
                let markers = Self.voiceTitles.values.filter { system.contains("本轮回答风格：" + $0) }
                guard stream, system.contains("简体中文"), markers == [voiceTitle],
                      (isFollowUp ? !jsonMode : jsonMode && latest.contains("这个新项目靠谱吗？")) else {
                    throw URLError(.badServerResponse)
                }
            } else {
                guard key == "Bearer test-key", jsonMode, system.contains("natural English"),
                      latest.contains("Should I apply for the new job?") else {
                    throw URLError(.badServerResponse)
                }
            }

            let payload: Data
            if stream {
                let content: String
                if isFollowUp { content = "先别答应。" }
                else if voiceTitle != nil { content = #"{"text":"先问清分工。","alternatives":[]}"# }
                else { content = #"{"text":"Apply if the role fits your priorities.","alternatives":[]}"# }
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

/// Checks the real transport payload using real plugin output. The synthetic
/// reply only finishes the request; it does not stand in for intent validation.
private final class SynthesisTaskURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture {
        let question: String
        let draws: [TarotDraw]
        let result: OracleResult
        let operation: String
        let oldAnswer: String
        let inspected: XCTestExpectation
    }
    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]

    static func install(_ fixture: Fixture, key: String) { lock.withLock { fixtures["Bearer " + key] = fixture } }
    static func remove(_ key: String) { lock.withLock { _ = fixtures.removeValue(forKey: "Bearer " + key) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let fixture = try XCTUnwrap(Self.lock.withLock { Self.fixtures[key] })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData()) as? [String: Any])
            XCTAssertEqual(request.url, DeepSeekConfiguration.endpoint)
            XCTAssertEqual(body["model"] as? String, DeepSeekConfiguration.defaultModel)
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
            let turns = try XCTUnwrap(body["messages"] as? [[String: String]])
            let system = try XCTUnwrap(turns.first?["content"])
            XCTAssertEqual(turns.first?["role"], "system")
            XCTAssertTrue(system.contains("当前阶段是可用结果计算完成后的解读"))
            XCTAssertTrue(system.contains("其对应的历史“重抽”“再掷”等操作请求已经完成"))
            // Direct client callers retain both historical turns; the final
            // task must still override the old operational conversation.
            XCTAssertTrue(turns.dropFirst().dropLast().contains(["role": "user", "content": fixture.operation]))
            XCTAssertTrue(turns.dropFirst().dropLast().contains(["role": "assistant", "content": fixture.oldAnswer]))
            XCTAssertEqual(turns.last?["role"], "user")
            let payload = try XCTUnwrap(turns.last?["content"])
            let task = try XCTUnwrap(payload.components(separatedBy: "\n\n").last)
            XCTAssertTrue(task.contains("现在请依据以上本轮结果回答这个问事"))
            XCTAssertTrue(task.contains(fixture.question))
            XCTAssertFalse(task.contains(fixture.operation))
            XCTAssertTrue(task.contains("不要把历史中的重抽操作句当成本轮问事"))

            func line(_ label: String) throws -> Data {
                let value = try XCTUnwrap(payload.components(separatedBy: "\n").first { $0.hasPrefix(label) })
                return Data(value.dropFirst(label.count).utf8)
            }
            let savedDraws = try JSONDecoder().decode([TarotDraw].self, from: line("原始塔罗牌位及正逆位 json："))
            XCTAssertEqual(savedDraws, fixture.draws)
            let usable = try XCTUnwrap(JSONSerialization.jsonObject(with: line("全部可用结果 json：")) as? [[String: Any]])
            XCTAssertEqual(usable.compactMap { $0["method"] as? String }, [fixture.result.method.rawValue])
            XCTAssertEqual(usable.compactMap { $0["id"] as? String }.map { $0.lowercased() }, [fixture.result.id.uuidString.lowercased()])
            if fixture.draws.count == 3 {
                XCTAssertTrue(payload.contains("本轮塔罗初阵确认状态：已确认3张有效初阵牌，抽牌和计算均已完成"))
                XCTAssertFalse(payload.contains("没有已确认可用的塔罗初阵结果"))
            } else {
                XCTAssertTrue(payload.contains("本轮塔罗初阵确认状态：没有已确认可用的塔罗初阵结果"))
                XCTAssertFalse(payload.contains("已确认3张有效初阵牌，抽牌和计算均已完成"))
            }
            fixture.inspected.fulfill()
            let text = #"{"text":"先确认分工和预算，再决定合作安排。","alternatives":[]}"#
            let event: [String: Any] = ["model": DeepSeekConfiguration.defaultModel,
                "choices": [["delta": ["content": text], "finish_reason": "stop"]]]
            let framed = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\ndata: [DONE]\n\n"
            let response = try XCTUnwrap(HTTPURLResponse(url: DeepSeekConfiguration.endpoint, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(framed.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func requestData() throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            guard count > 0 else { throw stream.streamError ?? URLError(.badServerResponse) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
