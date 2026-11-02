import XCTest
@testable import BlindOracle

/// Opt-in only: BLINDORACLE_LIVE_SMOKE=1 in the test scheme. Uses synthetic fixture data.
final class LiveIntegrationTests: XCTestCase {
    func testPlannerLocalPluginsAndStreamingReading() async throws {
        guard ProcessInfo.processInfo.environment["BLINDORACLE_LIVE_SMOKE"] == "1" else { throw XCTSkip("Live API smoke is opt-in") }
        KeychainStore.shared.bootstrapDevelopmentKey()
        guard KeychainStore.shared.string() != nil else { throw XCTSkip("Development key unavailable") }
        let client = DeepSeekClient()
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
