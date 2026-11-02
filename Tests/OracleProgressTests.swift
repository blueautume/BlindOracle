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
}
