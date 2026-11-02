import XCTest
@testable import BlindOracle

final class PersistenceAndPreferenceTests: XCTestCase {
    func testPreferenceLearningStartsEqualAndMovesSlowly() {
        let initial = PreferenceLearning.initial
        let updated = PreferenceLearning.updated(initial, chosen: [.bazi], opposing: [.meihua])
        XCTAssertEqual(initial.values.reduce(0,+), 1, accuracy: 1e-10)
        XCTAssertEqual(updated.values.reduce(0,+), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(updated["bazi"]!, initial["bazi"]!)
        XCTAssertLessThan(abs(updated["bazi"]! - initial["bazi"]!), 0.01)
    }
    func testRepeatedVotesStayBoundedAndNormalized() {
        var values = PreferenceLearning.initial
        for _ in 0..<3000 { values = PreferenceLearning.updated(values, chosen: [.bazi], opposing: [.meihua, .qimen]) }
        XCTAssertEqual(values.values.reduce(0,+), 1, accuracy: 1e-7)
        XCTAssertTrue(values.values.allSatisfy { $0 >= 0.04 - 1e-7 && $0 <= 0.25 + 1e-7 })
    }
    func testOpposingSupportDoesNotChangeWeights() {
        XCTAssertEqual(PreferenceLearning.updated(PreferenceLearning.initial, chosen: [.bazi], opposing: [.bazi]), PreferenceLearning.initial)
    }
    func testCompressionDoesNotTouchPermanentProfileOrOriginalMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory)
        var profile = OracleProfile(); profile.displayName = "独立留存资料"
        try vault.save(profile, as: "profiles")
        let messages = (0..<60).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: String(repeating: "旧问题需要保留", count: 250)) }
        let summary = LocalContextPolicy.compact(messages: messages, previous: ConversationSummary())
        try vault.save(summary, as: "context")
        XCTAssertEqual(vault.load(OracleProfile.self, from: "profiles", fallback: OracleProfile()).displayName, profile.displayName)
        XCTAssertEqual(messages.count, 60)
        XCTAssertEqual(summary.coveredMessageIDs.count, 44)
        XCTAssertFalse(summary.text.isEmpty)
    }
    func testShortConversationIsNotCompressed() {
        let messages = (0..<30).map { _ in ChatMessage(role: .user, content: "一个很短的问题") }
        XCTAssertFalse(LocalContextPolicy.shouldCompact(messages: messages, summary: ConversationSummary()))
    }
}
