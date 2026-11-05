import XCTest
@testable import BlindOracle

final class PersistenceAndPreferenceTests: XCTestCase {
    func testLegacyReadingKeepsConflictTextButDropsPreferenceAndSelectionMetadata() throws {
        let run = OracleRun(input: OracleInput(question: "合作如何安排？", profile: OracleProfile()),
                            plan: OraclePlan(intent: "合作", subject: "本人", methods: [.bazi, .meihua], requiredFields: [], note: "", question: "合作如何安排？"))
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(run)) as? [String: Any])
        object["weightsSnapshot"] = ["bazi": 0.8, "meihua": 0.2]
        object["selectedAlternative"] = "a"
        object["synthesis"] = [
            "text": "先核对合作条件。",
            "alternatives": [
                ["id": "a", "title": "可以推进", "body": "分工清楚时适合推进。", "supportingMethods": ["bazi"]],
                ["id": "b", "title": "先核对条件", "body": "预算不明时应先确认。", "supportingMethods": ["meihua"]]
            ]
        ]
        let decoded = try JSONDecoder().decode(OracleRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, run.id)
        XCTAssertEqual(decoded.synthesis?.text, "先核对合作条件。")
        let details = try XCTUnwrap(decoded.synthesis?.archivedConflictDetails)
        XCTAssertTrue(details.contains("分工清楚时适合推进。"))
        XCTAssertTrue(details.contains("预算不明时应先确认。"))

        let encoded = try encoder.encode(decoded)
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(current["weightsSnapshot"])
        XCTAssertNil(current["selectedAlternative"])
        let synthesis = try XCTUnwrap(current["synthesis"] as? [String: Any])
        XCTAssertNil(synthesis["alternatives"])
        let restarted = try JSONDecoder().decode(OracleRun.self, from: encoded)
        XCTAssertEqual(restarted.synthesis?.archivedConflictDetails, details)
    }

    @MainActor func testRetiredPreferenceFilesAreRemovedWithoutTouchingPeopleReadingsOrChats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory)
        var person = OracleProfile(); person.name = "保留人员"
        let run = OracleRun(input: OracleInput(question: "保留推演", profile: person),
                            plan: OraclePlan(intent: "测试", subject: "本人", methods: [.xiaoliuren], requiredFields: [], note: "", question: "保留推演"),
                            synthesis: ReadingSynthesis(text: "保留正文。"))
        let message = ChatMessage(role: .assistant, content: "原聊天正文。", kind: .reading, runID: run.id)
        let chat = OracleConversation(messages: [message])
        try vault.save([person], as: "profiles")
        try vault.save([run], as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: chat.id, conversations: [chat]), as: ConversationHistory.filename)
        let retired = ["preferences.json", "preferences.recovery-old.json"]
        for name in retired { try Data("obsolete preference bytes".utf8).write(to: directory.appendingPathComponent(name)) }
        let unrelated = directory.appendingPathComponent("preferences-notes.json")
        try Data("unrelated user file".utf8).write(to: unrelated)

        let store = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(store.profiles.map(\.id), [person.id])
        XCTAssertEqual(store.runs.map(\.id), [run.id])
        XCTAssertEqual(store.messages.map(\.content), [message.content])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        for name in retired { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)) }

        store.checkpoint()
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.runs.first?.synthesis?.text, "保留正文。")
        XCTAssertEqual(restarted.messages.map(\.content), [message.content])
        XCTAssertFalse(vault.contains("preferences"))
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

    func testUnreadableDataIsBackedUpOnceBeforeFallbackCanBeSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory)
        let source = directory.appendingPathComponent("profiles.json")
        let original = Data("unreadable profile data".utf8)
        try original.write(to: source)

        for _ in 0..<3 {
            XCTAssertEqual(vault.load([String].self, from: "profiles", fallback: []), [])
        }
        let copies = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("profiles.recovery-") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), original)

        try vault.save(["new profile"], as: "profiles")
        XCTAssertEqual(vault.load([String].self, from: "profiles", fallback: []), ["new profile"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), original)
    }

    func testFailedRecoveryCopyPreventsReplacingUnreadableOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory)
        // The canonical file fits the filesystem's component limit, while the
        // longer recovery filename does not. This makes copy failure repeatable
        // without relying on device storage pressure or permission races.
        let name = String(repeating: "a", count: 240)
        let source = directory.appendingPathComponent(name + ".json")
        let original = Data("unreadable original".utf8)
        try original.write(to: source)
        XCTAssertEqual(vault.load([String].self, from: name, fallback: []), [])
        XCTAssertFalse(vault.preserveRecoveryCopy(name))

        XCTAssertThrowsError(try vault.save(["fallback"], as: name))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
