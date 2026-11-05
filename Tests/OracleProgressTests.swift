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

    @MainActor func testClearingHistoryDuringAStreamRejectsLateOutputAndKeepsSavedReadings() async throws {
        let token = UUID().uuidString
        let partial = "This answer will be cleared."
        let client = scriptedClient([.delayedTail(partial, " This old tail must never return.", 0.3, token),
                                     .complete("A fresh conversation.")])
        let vault = try temporaryVault()
        let saved = savedReading(question: "保留的推演", evidence: "保留的计算结果", seed: 42)
        let store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        store.runs = [saved]
        store.send("Hello!")
        try await waitUntil { store.messages.last?.content == partial }
        let oldID = store.activeConversationID
        XCTAssertTrue(store.isBusy)

        store.clearConversationHistory()

        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.canRetryAnalysis)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertTrue(store.activities.isEmpty)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertNotEqual(store.activeConversationID, oldID)
        XCTAssertEqual(store.runs.map(\.id), [saved.id])

        store.send("Hi!")
        try await waitUntil { !store.isBusy }
        try await waitUntil { AnalysisURLProtocol.didDeliverDelayedResponse(token) }
        XCTAssertEqual(store.messages.filter { $0.role == .user }.map(\.content), ["Hi!"])
        XCTAssertEqual(store.messages.last?.content, "A fresh conversation.")
        XCTAssertFalse(store.messages.contains { $0.content.contains("old tail") || $0.content == partial })
        XCTAssertFalse(store.conversations.contains { $0.id == oldID })
        XCTAssertFalse(store.canRetryAnalysis)

        let restored = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        XCTAssertEqual(restored.messages.map(\.content), store.messages.map(\.content))
        XCTAssertFalse(restored.conversations.contains { $0.id == oldID })
        XCTAssertEqual(restored.runs.map(\.id), [saved.id])
        XCTAssertFalse(restored.canRetryAnalysis)
    }

    @MainActor func testClearingHistoryDuringPlanningRejectsALateIntakeAndAllowsANewChat() async throws {
        let token = UUID().uuidString
        let proposal = #"{"action":"intake","intent":"旧问题","subject":"本人","methods":["bazi"],"requiredFields":["birthDate"],"note":"不应出现的旧表单"}"#
        let client = scriptedClient([.delayedPlan(proposal, 0.3, token), .complete("The new chat is ready.")])
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        store.send("只用八字看看今年工作的方向")
        try await waitUntil { AnalysisURLProtocol.didStartDelayedResponse(token) }
        XCTAssertTrue(store.isBusy)

        store.clearConversationHistory()
        store.send("Hello!")
        try await waitUntil { !store.isBusy }
        try await waitUntil { AnalysisURLProtocol.didDeliverDelayedResponse(token) }

        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showIntake)
        XCTAssertFalse(store.showInteraction)
        XCTAssertFalse(store.canRetryAnalysis)
        XCTAssertEqual(store.messages.filter { $0.role == .user }.map(\.content), ["Hello!"])
        XCTAssertEqual(store.messages.last?.content, "The new chat is ready.")
        XCTAssertTrue(store.runs.isEmpty)
        let restored = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        XCTAssertNil(restored.pendingPlan)
        XCTAssertEqual(restored.messages.map(\.content), store.messages.map(\.content))
    }

    @MainActor func testNetworkFailureNeverBecomesALocalReadingWhenAnOldLocalPreferenceIsSet() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "oracle.localOnly")
        defaults.set(true, forKey: "oracle.localOnly")
        defer {
            if let previous { defaults.set(previous, forKey: "oracle.localOnly") }
            else { defaults.removeObject(forKey: "oracle.localOnly") }
        }
        let client = scriptedClient([.networkError])
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false, aiClient: client)
        let run = savedReading(question: "今晚的安排", evidence: "已完成的本地计算", seed: 42)
        store.runs = [run]

        store.retrySynthesis(run)
        try await waitUntil { !store.isBusy }

        XCTAssertNil(store.runs.first?.synthesis)
        XCTAssertTrue(store.canRetryAnalysis)
        XCTAssertNotNil(store.notice)
        XCTAssertEqual(store.runs.first?.results.map(\.id), run.results.map(\.id))
        XCTAssertFalse(store.messages.contains { $0.content.contains("当前为本地试算") || $0.content.contains("这次推演已完成。") })
        XCTAssertTrue(store.activities.contains { $0.status == .failed })
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

    @MainActor func testTimeRangeFollowUpUsesTheRecentTextTopicInsteadOfAnOlderReading() async throws {
        let workEvidence = "旧工作盘面专属线索"
        let work = savedReading(question: "今天的工作怎么样？", evidence: workEvidence, seed: 41)
        let loveQuestion = ChatMessage(role: .user, content: "感情呢，今天")
        let loveAnswer = ChatMessage(role: .assistant, content: "今天可以观察对方是否主动联系。")
        let expanded = "再看看这周的感情走向。"
        let reply = "这周继续看双方有没有主动推进联系。"
        let client = scriptedClient([
            .plan(try mistakenIntake(continuing: loveAnswer, expanded: expanded), requiringReference: loveAnswer.id),
            .checkedReply("这周先观察", questionIncludes: [expanded], priorTurn: loveQuestion.content,
                          includesEvidence: nil, excludesEvidence: workEvidence, complete: false),
            .checkedReply(reply, questionIncludes: [expanded], priorTurn: loveQuestion.content,
                          includesEvidence: nil, excludesEvidence: workEvidence)
        ])
        let conversation = OracleConversation(messages: [
            ChatMessage(role: .user, content: work.input.question),
            ChatMessage(role: .assistant, content: "工作上先确认分工。", kind: .reading, runID: work.id),
            loveQuestion, loveAnswer
        ])
        let vault = try temporaryVault()
        let store = try routedStore(conversation: conversation, runs: [work], client: client, vault: vault)

        store.send("再看看这周")
        try await waitUntil { !store.isBusy }
        XCTAssertTrue(store.canRetryAnalysis)
        XCTAssertTrue(store.messages.last?.content.contains("这周先观察") == true)
        XCTAssertNil(store.pendingPlan)

        let restored = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        restored.retryAnalysis()
        try await waitUntil { !restored.isBusy }

        XCTAssertEqual(restored.activeConversationID, conversation.id)
        XCTAssertEqual(restored.messages.filter { $0.role == .user }.map(\.content),
                       [work.input.question, loveQuestion.content, "再看看这周"])
        XCTAssertEqual(restored.messages.last?.content, reply)
        XCTAssertNil(restored.messages.last?.runID)
        XCTAssertNil(restored.pendingPlan)
        XCTAssertNil(restored.pendingInteraction)
        XCTAssertEqual(restored.runs.map(\.id), [work.id])
        XCTAssertEqual(restored.runs.first?.input.seed, 41)
    }

    @MainActor func testTextOnlyContinuationDoesNotImportAnUncitedPersonFromAnEarlierTopic() async throws {
        var chen = OracleProfile(); chen.name = "陈平"
        let workEvidence = "陈平旧工作盘面专属线索"
        var work = savedReading(question: "陈平今天的工作怎么样？", evidence: workEvidence, seed: 41)
        work.input.profile = chen
        work.input.participants = [chen]
        work.input.subject = "他人"
        work.plan.subject = "他人"
        let loveQuestion = ChatMessage(role: .user, content: "感情呢，今天")
        let loveAnswer = ChatMessage(role: .assistant, content: "今天可以观察对方是否主动联系。")
        let raw = "再看看这周"
        let reply = "这周继续看双方有没有主动推进联系。"
        let client = scriptedClient([
            .plan(try mistakenIntake(continuing: loveAnswer, expanded: "陈平这周的感情怎么样？"),
                  requiringReference: loveAnswer.id),
            .checkedReply(reply, questionIncludes: [raw, "感情"], priorTurn: loveQuestion.content,
                          includesEvidence: nil, excludesEvidence: workEvidence, questionExcludes: [chen.resolvedName])
        ])
        let conversation = OracleConversation(messages: [
            ChatMessage(role: .user, content: work.input.question),
            ChatMessage(role: .assistant, content: "陈平工作上先确认分工。", kind: .reading, runID: work.id),
            loveQuestion, loveAnswer
        ])
        let store = try routedStore(conversation: conversation, runs: [work], client: client, vault: temporaryVault())
        store.saveProfile(chen)

        store.send(raw)
        try await waitUntil { !store.isBusy }

        XCTAssertEqual(store.messages.dropLast().last?.content, raw)
        XCTAssertFalse(store.messages.dropLast().last?.resolvedQuestion?.contains(chen.resolvedName) ?? false)
        XCTAssertEqual(store.messages.last?.content, reply)
        XCTAssertNil(store.messages.last?.runID)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.map(\.id), [work.id])
    }

    @MainActor func testFollowUpCanReturnToAnOlderReadingWithoutReusingTheNewerOne() async throws {
        let earlierEvidence = "较早合作盘面专属线索"
        let laterEvidence = "较晚出行盘面专属线索"
        let earlier = savedReading(question: "这个合作怎么推进？", evidence: earlierEvidence, seed: 21)
        let later = savedReading(question: "这周出行怎么安排？", evidence: laterEvidence, seed: 22)
        let earlierQuestion = ChatMessage(role: .user, content: earlier.input.question)
        let earlierAnswer = ChatMessage(role: .assistant, content: "合作前先问清费用和分工。", kind: .reading, runID: earlier.id)
        let raw = "还是前面那件事，先问哪一条？"
        let expanded = "回到前面的合作，费用和分工应该先问清哪一项？"
        let reply = "先问清谁承担费用。"
        let client = scriptedClient([
            .plan(try mistakenIntake(continuing: earlierQuestion, expanded: expanded), requiringReference: earlierQuestion.id),
            .checkedReply(reply, questionIncludes: [expanded], priorTurn: earlierQuestion.content,
                          includesEvidence: earlierEvidence, excludesEvidence: laterEvidence)
        ])
        let conversation = OracleConversation(messages: [
            earlierQuestion, earlierAnswer,
            ChatMessage(role: .user, content: later.input.question),
            ChatMessage(role: .assistant, content: "出行前先核对场馆时间。", kind: .reading, runID: later.id)
        ])
        let store = try routedStore(conversation: conversation, runs: [earlier, later], client: client, vault: temporaryVault())

        store.send(raw)
        try await waitUntil { !store.isBusy }

        XCTAssertEqual(store.messages.dropLast().last?.content, raw)
        XCTAssertEqual(store.messages.last?.content, reply)
        XCTAssertEqual(store.messages.last?.runID, earlier.id)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.map(\.id), [earlier.id, later.id])
        XCTAssertEqual(store.runs.map(\.input.seed), [21, 22])
    }

    @MainActor func testContinuationWithReferenceFromAnotherConversationAsksForClarification() async throws {
        let currentQuestion = ChatMessage(role: .user, content: "今天适合先做什么？")
        let currentAnswer = ChatMessage(role: .assistant, content: "先核对手头的计划。")
        let foreignQuestion = ChatMessage(role: .user, content: "出行怎么安排？")
        let foreign = OracleConversation(messages: [foreignQuestion, ChatMessage(role: .assistant, content: "先核对场馆时间。")])
        let current = OracleConversation(messages: [currentQuestion, currentAnswer])
        let client = scriptedClient([
            .plan(try mistakenIntake(continuing: foreignQuestion, expanded: "这周出行怎么安排？"),
                  excludingReference: foreignQuestion.id)
        ])
        let store = try routedStore(conversation: current, runs: [], client: client, vault: temporaryVault(), other: [foreign])

        store.send("那这周呢？")
        try await waitUntil { !store.isBusy }

        XCTAssertEqual(store.activeConversationID, current.id)
        XCTAssertEqual(store.messages.dropLast().last?.content, "那这周呢？")
        XCTAssertEqual(store.messages.last?.role, .assistant)
        XCTAssertFalse(store.messages.last?.content.isEmpty ?? true)
        XCTAssertNil(store.messages.last?.runID)
        XCTAssertFalse(store.canRetryAnalysis)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
    }

    @MainActor func testChangedParticipantStartsASeparateReadingWithTheExpandedQuestion() async throws {
        var chen = OracleProfile(); chen.name = "陈平"
        var li = OracleProfile(); li.name = "李岚"
        let raw = "换成李岚呢？"
        let expanded = "李岚这周的工作怎么样？"
        let oldQuestion = ChatMessage(role: .user, content: "陈平这周的工作怎么样？")
        let oldPlan = OraclePlan(intent: "本周工作", subject: "他人", methods: [.xiaoliuren],
                                 requiredFields: [], note: "", question: oldQuestion.content)
        let oldInput = OracleInput(question: oldQuestion.content, profile: chen, seed: 41, subject: "他人", participants: [chen])
        let oldResult = OracleResult(method: .xiaoliuren, headline: "陈平的测试盘", rows: [])
        let oldReply = "陈平这周先确认手头任务。"
        let oldRun = OracleRun(input: oldInput, plan: oldPlan, results: [oldResult],
                               synthesis: ReadingSynthesis(text: oldReply, alternatives: []))
        let oldAnswer = ChatMessage(role: .assistant, content: oldReply, kind: .reading, runID: oldRun.id)
        let conversation = OracleConversation(messages: [oldQuestion, oldAnswer])
        let client = scriptedClient([
            .plan(try contextualIntake(anchoredTo: oldQuestion, expanded: expanded, relation: .changedParticipants, person: li),
                  requiringReference: oldQuestion.id),
            .complete(#"{"text":"李岚这周可以先梳理优先级。","alternatives":[]}"#)
        ])
        let store = try routedStore(conversation: conversation, runs: [oldRun], client: client, vault: temporaryVault())
        store.saveProfile(chen)
        store.saveProfile(li)

        store.send(raw)
        try await waitUntil { !store.isBusy }

        let pending = try XCTUnwrap(store.pendingPlan)
        XCTAssertEqual(pending.question, expanded)
        XCTAssertEqual(pending.participantIDs, [li.id])
        XCTAssertNil(pending.baseRunID)
        XCTAssertEqual(store.intakeParticipants.map(\.id), [li.id])
        XCTAssertTrue(store.confirmGroupIntake(profiles: store.intakeParticipants, numbers: [], save: false))
        try await waitUntil { !store.isBusy }

        let newRun = try XCTUnwrap(store.runs.last)
        XCTAssertEqual(store.runs.count, 2)
        XCTAssertNotEqual(newRun.id, oldRun.id)
        XCTAssertEqual(newRun.input.question, expanded)
        XCTAssertEqual(newRun.input.readingParticipants.map(\.id), [li.id])
        XCTAssertNil(newRun.plan.baseRunID)
        XCTAssertEqual(newRun.synthesis?.text, "李岚这周可以先梳理优先级。")
        XCTAssertEqual(store.runs.first?.input.readingParticipants.map(\.id), [chen.id])
        XCTAssertEqual(store.runs.first?.results.map(\.id), [oldResult.id])
        XCTAssertEqual(store.runs.first?.input.seed, 41)
        XCTAssertEqual(store.runs.first?.synthesis?.text, oldReply)
        XCTAssertTrue(store.messages.contains { $0.role == .user && $0.content == raw })
    }

    @MainActor func testExplicitMethodsOverrideAPlannerReplyOrUnrelatedIntake() async throws {
        let cases: [(OracleMethod, String)] = [
            (.tarot, "用塔罗牌计算今晚的运势"), (.liuyao, "再用六爻再试试呢？"),
            (.meihua, "再用梅花易数分析一下"), (.qimen, "再用奇门遁甲计算一下"),
            (.xiaoliuren, "再用小六壬试试看"), (.bazi, "再用八字分析一下"),
            (.ziwei, "再用紫微斗数试试"), (.chenggu, "再用称骨计算一下"),
            (.xingming, "再用姓名五格分析一下"), (.astrology, "再用西方占星试试")
        ]
        for action in ["reply", "intake"] {
            for (method, raw) in cases {
                var original = savedReading(question: "今晚的运势如何？", evidence: "原推演", seed: 41)
                if method != .meihua {
                    original.plan.methods = [.meihua]
                    original.results[0].method = .meihua
                }
                let question = ChatMessage(role: .user, content: original.input.question)
                let reading = ChatMessage(role: .assistant, content: "先确认安排。", kind: .reading, runID: original.id)
                let expanded = "用指定方法分析今晚的运势。"
                var proposal = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(
                    contextualIntake(anchoredTo: reading, expanded: expanded, relation: .continuation).utf8)) as? [String: Any])
                proposal["action"] = action
                proposal["methods"] = action == "reply" ? [] : original.plan.methods.map(\.rawValue) + ["bazi"]
                let body = String(decoding: try JSONSerialization.data(withJSONObject: proposal), as: UTF8.self)
                let client = scriptedClient([.plan(body, requiringReference: reading.id),
                                             .complete(#"{"text":"新方法已完成。","alternatives":[]}"#)])
                let store = try routedStore(conversation: OracleConversation(messages: [question, reading]),
                                            runs: [original], client: client, vault: temporaryVault())
                defer { if store.isBusy { store.stop() } }

                store.send(raw)
                try await waitUntil { !store.isBusy }

                let label = "\(action): \(raw)"
                if method == .tarot || method == .liuyao {
                    let session = try XCTUnwrap(store.pendingInteraction, label)
                    XCTAssertEqual(session.currentRequest?.method, method, label)
                    XCTAssertEqual(session.plan.baseRunID, original.id, label)
                    XCTAssertTrue(session.plan.mandatoryMethods?.contains(method) == true, label)
                    XCTAssertEqual(Set(session.plan.methods), Set(original.plan.methods + [method]), label)
                    if method == .tarot {
                        let request = try XCTUnwrap(session.currentRequest)
                        let draws = zip(["major-00", "cups-01", "swords-14"], request.tarotPositions).map {
                            TarotDraw(cardID: $0.0, isReversed: false, position: $0.1)
                        }
                        store.completeInteraction(.init(requestID: request.id, tarotDraws: draws, revealedCount: draws.count), sessionID: session.id)
                        try await waitUntil { !store.isBusy }
                        XCTAssertEqual(store.runs.last?.results.first { $0.method == .tarot }?.tarotDraws, draws, label)
                        XCTAssertEqual(store.runs.last?.synthesis?.text, "新方法已完成。", label)
                    }
                } else if method.usesPersonalProfile {
                    let pending = try XCTUnwrap(store.pendingPlan, label)
                    XCTAssertTrue(pending.methods.contains(method), label)
                    XCTAssertTrue(pending.mandatoryMethods?.contains(method) == true, label)
                    XCTAssertEqual(Set(pending.methods), Set(original.plan.methods + [method]), label)
                    XCTAssertTrue(store.showIntake, label)
                    XCTAssertFalse(store.canConfirmIntake, label)
                } else {
                    let calculated = try XCTUnwrap(store.runs.last, label)
                    XCTAssertNotEqual(calculated.id, original.id, label)
                    XCTAssertEqual(Set(calculated.plan.methods), Set(original.plan.methods + [method]), label)
                    XCTAssertTrue(calculated.results.contains { $0.method == method && [.complete, .partial].contains($0.status) }, label)
                    XCTAssertEqual(calculated.synthesis?.text, "新方法已完成。", label)
                }
                XCTAssertEqual(store.runs.first?.results.map(\.id), original.results.map(\.id), label)
            }
        }
    }

    @MainActor func testExplicitTarotRequestStartsIntakeWhenPlannerRepliesToATextOnlyOrNewTopic() async throws {
        for relation in [ConversationUnderstanding.Relation.continuation, .newQuestion] {
            for raw in ["用塔罗牌计算今晚的运势", "改用塔罗"] {
                let previous = ChatMessage(role: .user, content: "今晚的运势如何？")
                var proposal = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(
                    contextualIntake(anchoredTo: previous, expanded: raw, relation: relation).utf8)) as? [String: Any])
                proposal["action"] = "reply"
                proposal["methods"] = []
                let body = String(decoding: try JSONSerialization.data(withJSONObject: proposal), as: UTF8.self)
                let client = scriptedClient([.plan(body)])
                let store = try routedStore(conversation: OracleConversation(messages: [previous]), runs: [],
                                            client: client, vault: temporaryVault())

                store.send(raw)
                try await waitUntil { !store.isBusy }

                let pending = try XCTUnwrap(store.pendingPlan)
                XCTAssertEqual(pending.methods, [.tarot])
                XCTAssertEqual(pending.mandatoryMethods, [.tarot])
                XCTAssertTrue(store.showIntake)
                XCTAssertNil(pending.baseRunID)
                XCTAssertTrue(store.confirmGroupIntake(profiles: store.intakeParticipants, numbers: [], save: false))
                XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .tarot)
            }
        }
    }

    @MainActor func testEnglishNewQuestionKeepsTheOnlyRequestedMethodWhenPlannerAddsAnother() async throws {
        let raw = "New question: use only Tarot to examine tonight's plans."
        let proposal = #"{"action":"intake","intent":"Tonight","subject":"事件","methods":["tarot","bazi"],"requiredFields":[],"note":"Review details","understanding":{"relation":"newQuestion","resolvedQuestion":"New question: use only Tarot to examine tonight's plans."}}"#
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false,
                                aiClient: scriptedClient([.plan(proposal)]))

        store.send(raw)
        try await waitUntil { !store.isBusy }

        XCTAssertEqual(store.pendingPlan?.methods, [.tarot])
        XCTAssertEqual(store.pendingPlan?.mandatoryMethods, [.tarot])
        XCTAssertTrue(store.intakeParticipants.isEmpty)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .tarot)
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

    private func savedReading(question: String, evidence: String, seed: UInt64) -> OracleRun {
        let plan = OraclePlan(intent: question, subject: "事件", methods: [.xiaoliuren],
                              requiredFields: [], note: "", question: question)
        let result = OracleResult(method: .xiaoliuren, headline: evidence, rows: [])
        return OracleRun(input: OracleInput(question: question, profile: OracleProfile(), seed: seed),
                         plan: plan, results: [result])
    }

    private func mistakenIntake(continuing message: ChatMessage, expanded: String) throws -> String {
        try contextualIntake(anchoredTo: message, expanded: expanded, relation: .continuation)
    }

    private func contextualIntake(anchoredTo message: ChatMessage, expanded: String,
                                  relation: ConversationUnderstanding.Relation, person: OracleProfile? = nil) throws -> String {
        var body: [String: Any] = [
            "action": "intake", "intent": "补充问事", "subject": "事件", "methods": ["xiaoliuren"],
            "requiredFields": [], "note": "请填写问事资料。", "question": expanded,
            "understanding": [
                "relation": relation.rawValue, "resolvedQuestion": expanded,
                "referenceMessageID": message.id.uuidString
            ]
        ]
        if let person {
            body["subject"] = "他人"
            body["participantIDs"] = [person.id.uuidString]
            body["participantNames"] = [person.resolvedName]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    @MainActor private func routedStore(conversation: OracleConversation, runs: [OracleRun], client: DeepSeekClient,
                                         vault: LocalVault, other: [OracleConversation] = []) throws -> OracleStore {
        try vault.save(runs, as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation] + other),
                       as: ConversationHistory.filename)
        return OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
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
        case delayedTail(String, String, TimeInterval, String)
        case delayedPlan(String, TimeInterval, String)
        case truncate(String)
        case complete(String)
        case checkedReply(String, questionIncludes: [String], priorTurn: String, includesEvidence: String?, excludesEvidence: String,
                          complete: Bool = true, questionExcludes: [String] = [])
        case networkError
        case plan(String, requiringReference: UUID? = nil, excludingReference: UUID? = nil)
    }

    private static let lock = NSLock()
    private static var scripts: [String: [Response]] = [:]
    private static var startedDelayedResponses: Set<String> = []
    private static var deliveredDelayedResponses: Set<String> = []

    static func didStartDelayedResponse(_ token: String) -> Bool {
        lock.withLock { startedDelayedResponses.contains(token) }
    }

    static func didDeliverDelayedResponse(_ token: String) -> Bool {
        lock.withLock { deliveredDelayedResponses.contains(token) }
    }

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
        case .delayedTail(let initial, let tail, let delay, let token):
            sendStream(initial, hold: true, complete: false)
            Self.lock.withLock { _ = Self.startedDelayedResponses.insert(token) }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                let body = ["choices": [["delta": ["content": tail]]]]
                if let bytes = try? JSONSerialization.data(withJSONObject: body) {
                    client?.urlProtocol(self, didLoad: Data(("data: " + String(decoding: bytes, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8))
                    client?.urlProtocolDidFinishLoading(self)
                }
                Self.lock.withLock { _ = Self.deliveredDelayedResponses.insert(token) }
            }
        case .delayedPlan(let content, let delay, let token):
            Self.lock.withLock { _ = Self.startedDelayedResponses.insert(token) }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                let body: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
                if sendJSON(body, contentType: "application/json") { client?.urlProtocolDidFinishLoading(self) }
                Self.lock.withLock { _ = Self.deliveredDelayedResponses.insert(token) }
            }
        case .networkError:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .plan(let content, let requiringReference, let excludingReference):
            if requiringReference != nil || excludingReference != nil {
                guard let user = (try? requestTurns())?.last?["content"],
                      requiringReference.map({ user.localizedCaseInsensitiveContains($0.uuidString) }) ?? true,
                      excludingReference.map({ !user.localizedCaseInsensitiveContains($0.uuidString) }) ?? true else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
            }
            let body: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
            if sendJSON(body, contentType: "application/json") { client?.urlProtocolDidFinishLoading(self) }
        case .checkedReply(let content, let questionIncludes, let priorTurn, let includesEvidence, let excludesEvidence,
                           let complete, let questionExcludes):
            guard let turns = try? requestTurns(), let system = turns.first?["content"],
                  turns.last?["role"] == "user", let question = turns.last?["content"],
                  questionIncludes.allSatisfy({ question.contains($0) }),
                  questionExcludes.allSatisfy({ !question.contains($0) }),
                  turns.dropLast().contains(["role": "user", "content": priorTurn]),
                  includesEvidence.map({ system.contains($0) }) ?? true,
                  !system.contains(excludesEvidence) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            sendStream(content, hold: false, complete: complete)
        case .hold(let content):
            sendStream(content, hold: true, complete: false)
        case .truncate(let content):
            sendStream(content, hold: false, complete: false)
        case .complete(let content):
            sendStream(content, hold: false, complete: true)
        }
    }

    private func sendStream(_ content: String, hold: Bool, complete: Bool) {
        let body = ["choices": [["delta": ["content": content]]]]
        guard sendJSON(body, contentType: "text/event-stream") else { return }
        if hold { return }
        if complete { client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func requestTurns() throws -> [[String: String]] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, data.isEmpty {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw stream.streamError ?? URLError(.badServerResponse) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let turns = body["messages"] as? [[String: String]] else {
            throw URLError(.badServerResponse)
        }
        return turns
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
