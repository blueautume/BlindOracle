import XCTest
@testable import BlindOracle

/// Opt-in only: BLINDORACLE_LIVE_SMOKE=1 in the test scheme. Uses synthetic fixture data.
final class LiveIntegrationTests: XCTestCase {
    private func liveClient() throws -> DeepSeekClient {
        guard ProcessInfo.processInfo.environment["BLINDORACLE_LIVE_SMOKE"] == "1" else { throw XCTSkip("Live API smoke is opt-in") }
        // Unsigned simulator hosts cannot always access the keychain. The
        // ignored Debug-only fixture is read in memory and never logged.
        let bundled = Bundle.main.url(forResource: "dev-key", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let key = KeychainStore.shared.string() ?? bundled, !key.isEmpty else { throw XCTSkip("Development key unavailable") }
        return DeepSeekClient(apiKey: key)
    }

    func testTarotInteractivePlanAndChineseReadingWithPro() async throws {
        let client = try liveClient()
        let registry = PluginRegistry()
        let question = "请只用塔罗三张牌，帮我梳理是否接下一个新工作项目，以及接之前需要考虑什么。请先让我抽牌，最后用中文解读。"
        let plan = try await client.plan(question: question, profile: OracleProfile(), plugins: registry.descriptors, history: [])
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.tarot])
        XCTAssertTrue(plan.requiredFields.isEmpty)
        XCTAssertEqual(plan.interactions?.map(\.kind), [.tarot])
        let selected = zip(TarotDeck.shuffled(seed: 42).prefix(3), TarotDeck.positions).map {
            TarotDraw(cardID: $0.0.id, isReversed: TarotDeck.isReversed(seed: 42, cardID: $0.0.id), position: $0.1)
        }
        let input = OracleInput(question: question, profile: OracleProfile(), seed: 42, tarotDraws: selected)
        let results = await registry.calculate(input, methods: plan.methods) { _ in }
        XCTAssertEqual(results.first?.tarotDraws, selected)
        let run = OracleRun(input: input, plan: plan, results: results)
        let collector = StreamCollector()
        let progress = LiveProgressCollector()
        let reading = try await client.synthesize(run: run, weights: PreferenceLearning.initial, history: [], onProgress: { stage in
            await progress.append(stage)
        }) { collector.append($0) }
        XCTAssertFalse(reading.text.isEmpty)
        XCTAssertEqual(collector.text, reading.text)
        XCTAssertGreaterThan(reading.text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count, 80)
        let stages = await progress.snapshot()
        XCTAssertEqual(stages, [.preparing, .requesting, .writing, .validating])
    }

    func testPlannerLocalPluginsAndStreamingReading() async throws {
        let client = try liveClient()
        let registry = PluginRegistry()
        var profile = OracleProfile()
        profile.displayName = "合成测试档案"; profile.familyName = "王"; profile.givenName = "明"; profile.sex = "男"
        profile.birthDate = ISO8601DateFormatter().date(from: "1992-08-15T04:00:00Z")
        profile.birthPlace = "上海"; profile.birthLatitude = 31.2304; profile.birthLongitude = 121.4737
        profile.currentTimeZoneID = "Asia/Shanghai"
        let question = "我想梳理接下来一个月的工作节奏，怎样安排手头计划更稳妥？"
        let plan = try await client.plan(question: question, profile: profile, plugins: registry.descriptors, history: [])
        XCTAssertFalse(plan.methods.isEmpty)
        XCTAssertTrue(plan.methods.allSatisfy { registry.plugin($0) != nil })
        let input = OracleInput(question: question, profile: profile, numbers: [12,23,6], seed: 42)
        let results = await registry.calculate(input, methods: plan.methods) { _ in }
        XCTAssertFalse(results.isEmpty)
        let run = OracleRun(input: input, plan: plan, results: results)
        let collector = StreamCollector()
        let reading = try await client.synthesize(run: run, weights: PreferenceLearning.initial, history: []) { collector.append($0) }
        XCTAssertFalse(reading.text.isEmpty)
        XCTAssertTrue(reading.alternatives.isEmpty || reading.alternatives.count == 2)
        XCTAssertEqual(collector.text, reading.text)
    }

    func testNamedPeopleAreCollectedIncrementallyAndJointReadingRetainsBothResults() async throws {
        let client = try liveClient()
        let registry = PluginRegistry()
        let firstText = "先留存两个人的资料：姓名：张三，男，1995年1月2日出生；姓名：李四，女，1996年3月4日出生。先保存资料，不要算卦。"
        // Match OracleStore: explicit local facts are saved before asking the
        // model to route the message; model extraction can supplement them.
        var people = ProfileDirectory.applying(ProfileDirectory.parseExplicitUpdates(in: firstText, profiles: []), to: []).profiles
        let first = try await client.plan(question: firstText, profile: OracleProfile(), plugins: registry.descriptors, history: [], profiles: people)
        XCTAssertEqual(first.action, "collect")
        XCTAssertTrue(first.methods.isEmpty)
        let firstUpdates = ProfileDirectory.groundedUpdates(first.profileUpdates ?? [], in: firstText, profiles: people)
        people = ProfileDirectory.applying(firstUpdates, to: people).profiles
        XCTAssertEqual(Set(people.map(\.resolvedName)), ["张三", "李四"])
        let secondText = "补充张三的出生时间08:30，出生时区Asia/Shanghai；李四的出生时间不确定，出生时区Asia/Shanghai。只补充资料。"
        let history = [AIConversationTurn(role: "user", content: firstText), AIConversationTurn(role: "assistant", content: first.note)]
        people = ProfileDirectory.applying(ProfileDirectory.parseExplicitUpdates(in: secondText, profiles: people), to: people).profiles
        XCTAssertEqual(people.first { $0.resolvedName == "张三" }?.birthTimeText, "08:30")
        let second = try await client.plan(question: secondText, profile: OracleProfile(), plugins: registry.descriptors, history: history, profiles: people)
        XCTAssertEqual(second.action, "collect")
        let secondUpdates = ProfileDirectory.groundedUpdates(second.profileUpdates ?? [], in: secondText, profiles: people)
        people = ProfileDirectory.applying(secondUpdates, to: people).profiles
        XCTAssertEqual(people.first { $0.resolvedName == "张三" }?.birthTimeText, "08:30")
        XCTAssertEqual(people.first { $0.resolvedName == "李四" }?.birthDateText, "1996-03-04")
        XCTAssertEqual(people.first { $0.resolvedName == "李四" }?.birthTimeKnown, false)
        let question = "请只用八字，联合看看张三和李四的友情相处与沟通建议，分别保留两个人的资料。"
        let plan = try await client.plan(question: question, profile: OracleProfile(), plugins: registry.descriptors, history: history, profiles: people)
        XCTAssertEqual(plan.subject, "多人")
        XCTAssertEqual(plan.methods, [.bazi])
        let selected = Set(plan.participantIDs ?? [])
        XCTAssertEqual(selected, Set(people.map(\.id)))
        let input = OracleInput(question: question, profile: people[0], seed: 42, subject: "多人", participants: people, relationship: "友情")
        let results = await registry.calculate(input, methods: plan.methods) { _ in }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.compactMap(\.participantID)), Set(people.map(\.id)))
        let run = OracleRun(input: input, plan: plan, results: results)
        let reading = try await client.synthesize(run: run, weights: PreferenceLearning.initial, history: []) { _ in }
        XCTAssertTrue(reading.text.contains("张三"))
        XCTAssertTrue(reading.text.contains("李四"))
    }
}

private actor LiveProgressCollector {
    private var stages: [AIReadingProgress] = []
    func append(_ stage: AIReadingProgress) { stages.append(stage) }
    func snapshot() -> [AIReadingProgress] { stages }
}

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var content = ""
    var text: String { lock.lock(); defer { lock.unlock() }; return content }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; content += value }
}
