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
        let reading = try await client.synthesize(run: run, weights: PreferenceLearning.initial, history: []) { collector.append($0) }
        XCTAssertFalse(reading.text.isEmpty)
        XCTAssertEqual(collector.text, reading.text)
        XCTAssertGreaterThan(reading.text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count, 80)
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
}

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var content = ""
    var text: String { lock.lock(); defer { lock.unlock() }; return content }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; content += value }
}
