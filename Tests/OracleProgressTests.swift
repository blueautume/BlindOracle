import XCTest
@testable import BlindOracle

final class OracleProgressTests: XCTestCase {
    private enum Event: Equatable, Sendable {
        case started(OracleMethod, Int, Int)
        case calculated(OracleMethod)
        case completed(OracleMethod)
    }

    private actor EventLog {
        private var events: [Event] = []
        func append(_ event: Event) { events.append(event) }
        func snapshot() -> [Event] { events }
    }

    private struct RecordedPlugin: OraclePlugin {
        let method: OracleMethod
        let events: EventLog
        var cancels = false
        var descriptor: OraclePluginDescriptor {
            NativeCalendar.descriptor(method, summary: "进度测试", questions: [], output: "测试结果")
        }
        func calculate(_ input: OracleInput) async throws -> OracleResult {
            await events.append(.calculated(method))
            if cancels { throw CancellationError() }
            return OracleResult(method: method, headline: "本地结果已返回", rows: [])
        }
    }

    private func instant(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("progress-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    func testStartingNextStepCompletesPreviousStepWithItsActualDuration() {
        var timeline = OracleProgressTimeline()
        let first = timeline.begin(text: "理解问题", detail: "准备这次使用的方法", at: instant(10))
        let second = timeline.begin(text: "梅花易数", detail: "正在计算本互变卦", method: .meihua, at: instant(13))

        XCTAssertEqual(timeline.activities.map(\.id), [first, second])
        XCTAssertEqual(timeline.activities.first?.status, .completed)
        XCTAssertEqual(timeline.activities.first?.finishedAt, instant(13))
        XCTAssertEqual(timeline.activities.first?.duration, 3)
        XCTAssertEqual(timeline.activities.last?.status, .running)
        XCTAssertEqual(timeline.activities.last?.method, .meihua)
        XCTAssertEqual(timeline.activities.last?.detail, "正在计算本互变卦")
        XCTAssertNil(timeline.activities.last?.finishedAt)
        XCTAssertNil(timeline.activities.last?.duration)
    }

    func testWaitingForUserCompletesBeforeCalculationStarts() {
        var timeline = OracleProgressTimeline()
        timeline.begin(text: "等待抽牌", status: .waiting, at: instant(1))
        timeline.begin(text: "塔罗牌", method: .tarot, at: instant(21))

        XCTAssertEqual(timeline.activities.map(\.status), [.completed, .running])
        XCTAssertEqual(timeline.activities.first?.duration, 20)
        XCTAssertEqual(timeline.activities.filter { $0.status == .running || $0.status == .waiting }.count, 1)
    }

    func testFailureAndCancellationOnlyTerminateCurrentStep() {
        for terminal in [OracleActivityStatus.failed, .cancelled] {
            var timeline = OracleProgressTimeline()
            timeline.begin(text: "本地计算", at: instant(2))
            timeline.begin(text: "综合解读", at: instant(5))
            timeline.finish(status: terminal, at: instant(12))

            XCTAssertEqual(timeline.activities.first?.status, .completed)
            XCTAssertEqual(timeline.activities.first?.finishedAt, instant(5))
            XCTAssertEqual(timeline.activities.last?.status, terminal)
            XCTAssertEqual(timeline.activities.last?.finishedAt, instant(12))
            XCTAssertEqual(timeline.activities.last?.duration, 7)
            timeline.finish(at: instant(20))
            XCTAssertEqual(timeline.activities.last?.status, terminal)
            XCTAssertEqual(timeline.activities.last?.finishedAt, instant(12))
        }
    }

    func testCompleteTimelineRetainsEveryStepBeyondSixEntries() {
        var timeline = OracleProgressTimeline()
        let titles = ["理解问题", "八字", "紫微", "六爻", "梅花", "奇门", "综合解读", "整理输出"]
        for (index, title) in titles.enumerated() { timeline.begin(text: title, at: instant(Double(index))) }
        timeline.finish(at: instant(8))

        XCTAssertEqual(timeline.activities.map(\.text), titles)
        XCTAssertEqual(timeline.activities.count, 8)
        XCTAssertTrue(timeline.activities.allSatisfy { $0.status == .completed })
        XCTAssertEqual(Set(timeline.activities.map(\.id)).count, titles.count)
    }

    func testResetStartsAnotherRunWithoutPreviousSteps() {
        var timeline = OracleProgressTimeline()
        let previous = timeline.begin(text: "上一问", at: instant(1))
        timeline.finish(at: instant(2))
        timeline.reset()
        XCTAssertTrue(timeline.activities.isEmpty)
        let current = timeline.begin(text: "这一次", at: instant(3))
        XCTAssertNotEqual(current, previous)
        XCTAssertEqual(timeline.activities.count, 1)
        XCTAssertEqual(timeline.activities.first?.text, "这一次")
        XCTAssertEqual(timeline.activities.first?.status, .running)
    }

    func testRegistryReportsActualStartAndCompletionAroundEachCalculation() async {
        let events = EventLog()
        let registry = PluginRegistry(plugins: [RecordedPlugin(method: .meihua, events: events),
                                                RecordedPlugin(method: .xiaoliuren, events: events)])
        let input = OracleInput(question: "测试执行进度", profile: OracleProfile(), seed: 42)
        let results = await registry.calculate(input, methods: [.xiaoliuren, .meihua, .meihua], onMethodStart: { method, index, total in
            await events.append(.started(method, index, total))
        }, onProgress: { result in
            await events.append(.completed(result.method))
        })
        let recorded = await events.snapshot()
        XCTAssertEqual(results.map(\.method), [.meihua, .xiaoliuren])
        XCTAssertEqual(recorded, [.started(.meihua, 1, 2), .calculated(.meihua), .completed(.meihua),
                                  .started(.xiaoliuren, 2, 2), .calculated(.xiaoliuren), .completed(.xiaoliuren)])
    }

    func testCancelledCalculationDoesNotPublishFakeFailureOrStartAnotherMethod() async {
        let events = EventLog()
        let registry = PluginRegistry(plugins: [RecordedPlugin(method: .meihua, events: events, cancels: true),
                                                RecordedPlugin(method: .qimen, events: events)])
        let results = await registry.calculate(OracleInput(question: "取消中的任务", profile: OracleProfile()),
                                               methods: [.meihua, .qimen], onMethodStart: { method, index, total in
            await events.append(.started(method, index, total))
        }, onProgress: { result in
            await events.append(.completed(result.method))
        })
        let recorded = await events.snapshot()
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(recorded, [.started(.meihua, 1, 2), .calculated(.meihua)])
    }

    func testRecordedProgressSurvivesRunEncodingAndLegacyRunNeedsNoProgressField() throws {
        let plan = OraclePlan(intent: "测试进度", subject: "本人", methods: [.meihua], requiredFields: [], note: "", question: "原有问题")
        var run = OracleRun(input: OracleInput(question: plan.question, profile: OracleProfile()), plan: plan)
        var timeline = OracleProgressTimeline()
        timeline.begin(text: "梅花易数", method: .meihua, at: instant(1))
        timeline.finish(at: instant(2))
        run.activities = timeline.activities
        let encoded = try JSONEncoder().encode(run)
        let restored = try JSONDecoder().decode(OracleRun.self, from: encoded)
        XCTAssertEqual(restored.activities, timeline.activities)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "activities")
        let legacyRun = try JSONDecoder().decode(OracleRun.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyRun.activities)
        XCTAssertEqual(legacyRun.id, run.id)
    }

    func testMessageProgressSurvivesHistoryStorageAndLegacyMessagesNeedNoActivities() throws {
        let vault = try temporaryVault()
        let step = OracleActivity(text: "解读已完成", date: instant(1), finishedAt: instant(4), status: .completed)
        let message = ChatMessage(role: .assistant, content: "已保存的解读", activities: [step])
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: "原有问题"), message])
        let archive = OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation])
        try vault.save(archive, as: ConversationHistory.filename)
        let restored = ConversationHistory.load(from: vault)
        XCTAssertEqual(restored.archive.conversations.first?.messages.last?.activities, [step])

        let archiveURL = vault.directory.appendingPathComponent(ConversationHistory.filename + ".json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any])
        var conversations = try XCTUnwrap(legacy["conversations"] as? [[String: Any]])
        var messages = try XCTUnwrap(conversations[0]["messages"] as? [[String: Any]])
        messages[1].removeValue(forKey: "activities")
        conversations[0]["messages"] = messages
        legacy["conversations"] = conversations
        try JSONSerialization.data(withJSONObject: legacy).write(to: archiveURL, options: .atomic)
        let oldHistory = ConversationHistory.load(from: vault)
        XCTAssertFalse(oldHistory.recoveredUnreadableFile)
        XCTAssertEqual(oldHistory.archive.conversations.first?.messages.last?.id, message.id)
        XCTAssertNil(oldHistory.archive.conversations.first?.messages.last?.activities)
        XCTAssertEqual(oldHistory.archive.conversations.first?.messages.last?.content, message.content)
    }

    @MainActor func testBackgroundCheckpointKeepsPartialAnswerAndRestoresInterruptedWorkOnlyOnce() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let plan = OraclePlan(intent: "后台恢复", subject: "事件", methods: [.xiaoliuren], requiredFields: [], note: "", question: "如何安排出行？")
        var run = OracleRun(input: OracleInput(question: plan.question, profile: OracleProfile(), seed: 42), plan: plan)
        run.results = [OracleResult(method: .xiaoliuren, headline: "已计算的结果", rows: [.init("时宫", "大安")])]
        let step = OracleActivity(text: "正在整理中文解读", date: instant(10), status: .running)
        run.activities = [step]
        let reply = ChatMessage(role: .assistant, content: "先核对行程，再", kind: .reading, runID: run.id)
        store.runs = [run]
        store.messages = [ChatMessage(role: .user, content: plan.question), reply]
        store.activities = [step]; store.activityMessageID = reply.id; store.phase = .synthesizing

        store.checkpoint()

        XCTAssertTrue(store.isBusy)
        XCTAssertEqual(store.activities.last?.status, .running)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertFalse(restarted.isBusy)
        XCTAssertEqual(restarted.messages.last?.content, reply.content)
        XCTAssertEqual(restarted.activities.last?.status, .cancelled)
        XCTAssertNotNil(restarted.activities.last?.finishedAt)
        XCTAssertEqual(restarted.runs.first?.results.map(\.id), run.results.map(\.id))
        XCTAssertEqual(restarted.runs.first?.input.seed, 42)
        XCTAssertNil(restarted.runs.first?.synthesis)
        XCTAssertNotNil(restarted.notice)
        let saved = vault.load([OracleRun].self, from: "readings", fallback: [])
        XCTAssertEqual(saved.first?.activities?.last?.status, .cancelled)

        let nextRestart = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(nextRestart.messages.last?.content, reply.content)
        XCTAssertEqual(nextRestart.activities.last?.id, step.id)
        XCTAssertNil(nextRestart.notice)
    }

    @MainActor func testRelaunchReplacesInterruptedEmptyReplyWithoutChangingCompletedReplies() throws {
        let vault = try temporaryVault()
        let completed = ChatMessage(role: .assistant, content: "已完成的回答", activities: [
            OracleActivity(text: "回答已完成", date: instant(1), finishedAt: instant(2), status: .completed)
        ])
        let interrupted = ChatMessage(role: .assistant, content: "", activities: [
            OracleActivity(text: "正在生成补充回答", date: instant(3), status: .running)
        ])
        let conversation = OracleConversation(messages: [completed, interrupted])
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]), as: ConversationHistory.filename)

        let store = OracleStore(vault: vault, bootstrapCredential: false)

        XCTAssertEqual(store.messages.first?.content, completed.content)
        XCTAssertEqual(store.messages.first?.activities, completed.activities)
        XCTAssertFalse(store.messages.last?.content.isEmpty ?? true)
        XCTAssertEqual(store.messages.last?.activities?.last?.status, .cancelled)
        let persisted = ConversationHistory.load(from: vault).archive.conversations.first?.messages
        XCTAssertEqual(persisted?.last?.content, store.messages.last?.content)
        XCTAssertEqual(persisted?.last?.activities?.last?.status, .cancelled)
    }

    @MainActor func testRelaunchCancelsBothIntakeAndRunProgressDuringLocalCalculation() async throws {
        let vault = try temporaryVault()
        let plan = OraclePlan(intent: "计算恢复", subject: "事件", methods: [.xiaoliuren], requiredFields: [], note: "", question: "出行如何安排？")
        var run = OracleRun(input: OracleInput(question: plan.question, profile: OracleProfile(), seed: 73), plan: plan)
        let step = OracleActivity(text: "正在推演小六壬", date: instant(1), status: .running, method: .xiaoliuren)
        run.activities = [step]
        let intake = ChatMessage(role: .assistant, content: "问事笺已收好。", kind: .intake, runID: run.id, activities: [step])
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: plan.question), intake])
        try vault.save([run], as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]), as: ConversationHistory.filename)

        let store = OracleStore(vault: vault, bootstrapCredential: false)

        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.messages.last?.content, intake.content)
        XCTAssertEqual(store.messages.last?.activities?.last?.status, .cancelled)
        XCTAssertEqual(store.runs.first?.activities?.last?.status, .cancelled)
        XCTAssertEqual(vault.load([OracleRun].self, from: "readings", fallback: []).first?.activities?.last?.status, .cancelled)
        XCTAssertEqual(store.runs.first?.input.seed, 73)

        XCTAssertTrue(store.canRetryAnalysis)
        store.retryAnalysis()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.runs.map(\.id), [run.id])
        XCTAssertEqual(store.runs.first?.input.seed, 73)
        XCTAssertEqual(store.runs.first?.results.map(\.method), [.xiaoliuren])
        XCTAssertNotNil(store.runs.first?.synthesis)
        XCTAssertFalse(store.canRetryAnalysis)
    }

    @MainActor func testCancelledQueuedSendCannotAppendCompressionProgressToRestoredLongChat() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let longChatID = store.activeConversationID
        let finished = OracleActivity(text: "旧对话已完成", date: instant(1), finishedAt: instant(3), status: .completed)
        let body = String(repeating: "保留此前已经确认的完整对话内容。", count: 100)
        store.messages = (0..<60).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "第\(index)条：" + body)
        }
        store.messages.append(ChatMessage(role: .assistant, content: "这段聊天的原有结论", activities: [finished]))
        store.newConversation()
        store.send("一个尚未开始处理的新问题")
        XCTAssertTrue(store.isBusy)
        // Stay on the main actor until the queued task has been cancelled by the switch.
        store.openConversation(longChatID)
        XCTAssertTrue(ContextCompressor.shouldCompress(messages: store.messages, summary: store.summary))
        let restoredActivities = store.activities
        let restoredMessages = store.messages.map(\.id)
        XCTAssertEqual(restoredActivities, [finished])

        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(store.activeConversationID, longChatID)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.activities, restoredActivities)
        XCTAssertEqual(store.messages.map(\.id), restoredMessages)
        XCTAssertEqual(store.messages.last?.activities, [finished])
        XCTAssertFalse(store.activities.contains { $0.text == "整理此前对话与已确认资料" })
    }

    @MainActor func testSendingWhileWritingKeepsThePartialReplyAndAnswersTheNewQuestion() async throws {
        let partial = "Here is the first part."
        let newReply = "You're welcome."
        let client = scriptedClient([.hold(partial), .complete(newReply)])
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false, aiClient: client)
        let conversationID = store.activeConversationID
        defer { if store.isBusy { store.stop() } }

        store.send("Hello!")
        try await waitUntil { store.messages.last?.content == partial }
        XCTAssertTrue(store.isBusy)
        let interruptedReplyID = try XCTUnwrap(store.messages.last?.id)

        store.send("Thank you!")
        try await waitUntil { !store.isBusy }

        XCTAssertEqual(store.activeConversationID, conversationID)
        XCTAssertEqual(store.messages.filter { $0.role == .user }.map(\.content), ["Hello!", "Thank you!"])
        let interrupted = try XCTUnwrap(store.messages.first { $0.id == interruptedReplyID })
        XCTAssertTrue(interrupted.content.contains(partial))
        XCTAssertEqual(interrupted.activities?.last?.status, .cancelled)
        XCTAssertEqual(store.messages.last?.content, newReply)
        XCTAssertFalse(store.canRetryAnalysis)
    }

    @MainActor func testRetryAfterTruncatedReadingReusesTheSavedRun() async throws {
        let partial = "Confirm the schedule first."
        let completed = "Confirm the schedule first. Then allow extra time."
        let client = scriptedClient([.truncate(#"{"text":""# + partial),
                                     .complete(#"{"text":""# + completed + #"","alternatives":[]}"#)])
        let vault = try temporaryVault()
        let plan = OraclePlan(intent: "Travel", subject: "事件", methods: [.xiaoliuren],
                              requiredFields: [], note: "", question: "How should I plan this trip?")
        let result = OracleResult(method: .xiaoliuren, headline: "Saved result", rows: [])
        let run = OracleRun(input: OracleInput(question: plan.question, profile: OracleProfile(), seed: 42),
                            plan: plan, results: [result])
        let question = ChatMessage(role: .user, content: plan.question)
        let intake = ChatMessage(role: .assistant, content: "Details confirmed.", kind: .intake, runID: run.id)
        let conversation = OracleConversation(messages: [question, intake])
        try vault.save([run], as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]),
                       as: ConversationHistory.filename)
        let store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        defer { if store.isBusy { store.stop() } }

        store.retrySynthesis(run)
        try await waitUntil { !store.isBusy }
        XCTAssertTrue(store.canRetryAnalysis)
        XCTAssertTrue(store.messages.last?.content.contains(partial) == true)
        XCTAssertNil(store.runs.first?.synthesis)

        store.retryAnalysis()
        try await waitUntil { !store.isBusy }

        XCTAssertEqual(store.messages.filter { $0.role == .user }.map(\.id), [question.id])
        XCTAssertEqual(store.messages.last?.runID, run.id)
        XCTAssertEqual(store.messages.last?.content, completed)
        XCTAssertEqual(store.runs.map(\.id), [run.id])
        XCTAssertEqual(store.runs.first?.results.map(\.id), [result.id])
        XCTAssertEqual(store.runs.first?.input.seed, 42)
        XCTAssertEqual(store.runs.first?.synthesis?.text, completed)
        XCTAssertFalse(store.canRetryAnalysis)
    }

    @MainActor func testRetryAfterPlanningNetworkErrorReusesTheOriginalQuestion() async throws {
        let question = "只用小六壬看看这次出行怎么安排？"
        let plan = #"{"action":"intake","intent":"出行安排","subject":"事件","methods":["xiaoliuren"],"requiredFields":[],"note":"请核对资料。","question":"出行怎么安排？"}"#
        let client = scriptedClient([.networkError, .plan(plan)])
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false, aiClient: client)
        defer { if store.isBusy { store.stop() } }

        store.send(question)
        try await waitUntil { !store.isBusy }
        let originalID = try XCTUnwrap(store.messages.first?.id)
        XCTAssertTrue(store.canRetryAnalysis)
        XCTAssertNil(store.pendingPlan)

        store.retryAnalysis()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.messages.filter { $0.role == .user }.map(\.id), [originalID])
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.methods, [.xiaoliuren])
        XCTAssertFalse(store.canRetryAnalysis)
    }

    @MainActor func testBackgroundExpirationPersistsFollowUpRetryAcrossRelaunch() async throws {
        let partial = "I can help."
        let completed = "I can help. What are you working on?"
        let client = scriptedClient([.hold(partial), .complete(completed)])
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        defer { if store.isBusy { store.stop() } }

        store.send("Hello!")
        try await waitUntil { store.messages.last?.content == partial }
        store.checkpoint()
        XCTAssertTrue(store.isBusy)

        store.suspendAnalysisForBackgroundExpiration()
        XCTAssertFalse(store.isBusy)
        let restored = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        defer { if restored.isBusy { restored.stop() } }
        XCTAssertEqual(restored.activeConversationID, store.activeConversationID)
        XCTAssertTrue(restored.messages.last?.content.contains(partial) == true)
        XCTAssertTrue(restored.canRetryAnalysis)

        restored.retryAnalysis()
        try await waitUntil { !restored.isBusy }

        XCTAssertEqual(restored.messages.filter { $0.role == .user }.map(\.content), ["Hello!"])
        XCTAssertEqual(restored.messages.last?.content, completed)
        XCTAssertFalse(restored.canRetryAnalysis)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the analysis to reach the expected state.")
    }

    private func scriptedClient(_ responses: [AnalysisURLProtocol.Response]) -> DeepSeekClient {
        let key = UUID().uuidString
        AnalysisURLProtocol.install(responses, for: key)
        addTeardownBlock { AnalysisURLProtocol.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalysisURLProtocol.self]
        return DeepSeekClient(apiKey: key, sessionConfiguration: configuration)
    }
}

private final class AnalysisURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case hold(String)
        case truncate(String)
        case complete(String)
        case networkError
        case plan(String)
    }

    private static let lock = NSLock()
    private static var scripts: [String: [Response]] = [:]

    static func install(_ responses: [Response], for key: String) {
        lock.withLock { scripts["Bearer " + key] = responses }
    }

    static func remove(_ key: String) {
        lock.withLock { _ = scripts.removeValue(forKey: "Bearer " + key) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let response = Self.lock.withLock { () -> Response? in
            guard Self.scripts[key]?.isEmpty == false else { return nil }
            return Self.scripts[key]?.removeFirst()
        }
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch response {
        case .networkError:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .plan(let content):
            let body: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
            if sendJSON(body, contentType: "application/json") { client?.urlProtocolDidFinishLoading(self) }
        case .hold(let content), .truncate(let content), .complete(let content):
            let body = ["choices": [["delta": ["content": content]]]]
            guard sendJSON(body, contentType: "text/event-stream") else { return }
            if case .hold = response { return }
            if case .complete = response { client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func sendJSON(_ body: [String: Any], contentType: String) -> Bool {
        guard let url = request.url, request.value(forHTTPHeaderField: "Accept") == contentType,
              let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": contentType]),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return false
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        let payload = contentType == "text/event-stream"
            ? Data(("data: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8) : data
        client?.urlProtocol(self, didLoad: payload)
        return true
    }

    override func stopLoading() {}
}
