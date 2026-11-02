import XCTest
@testable import BlindOracle

final class ConversationHistoryTests: XCTestCase {
    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }
    private func message(_ text: String, seconds: TimeInterval = 1) -> ChatMessage {
        ChatMessage(role: .user, content: text, date: Date(timeIntervalSince1970: seconds))
    }
    private func plan(_ question: String) -> OraclePlan {
        OraclePlan(intent: "待填写", subject: "本人", methods: [.bazi], requiredFields: [.birthDate], note: "请确认资料", question: question,
                   createdAt: Date(timeIntervalSince1970: 10))
    }

    @MainActor func testNewChatRestoresPreviousTranscriptAndSurvivesRestart() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let firstID = store.activeConversationID
        let first = message("第一卷：这份工作怎样安排？")
        store.messages = [first]
        store.newConversation()
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNotEqual(store.activeConversationID, firstID)
        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertEqual(store.conversations.first?.title, first.content)

        store.messages = [message("第二卷：周末是否出行？", seconds: 20)]
        store.newConversation()
        XCTAssertEqual(store.conversations.count, 2)
        store.openConversation(firstID)
        XCTAssertEqual(store.messages.map(\.id), [first.id])

        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.activeConversationID, firstID)
        XCTAssertEqual(restarted.messages.map(\.id), [first.id])
        XCTAssertEqual(restarted.conversations.count, 2)
    }

    @MainActor func testEachChatRestoresItsOwnSummaryAndPendingIntake() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let firstID = store.activeConversationID
        let first = message("第一份问题")
        store.messages = [first]
        store.summary = ConversationSummary(text: "第一卷的摘要", coveredMessageIDs: [first.id], updatedAt: Date(timeIntervalSince1970: 5))
        store.pendingPlan = plan(first.content)
        store.newConversation()

        let secondID = store.activeConversationID
        store.messages = [message("第二份问题", seconds: 30)]
        store.summary = ConversationSummary(text: "第二卷的摘要")
        store.pendingPlan = nil
        store.openConversation(firstID)
        XCTAssertEqual(store.summary.text, "第一卷的摘要")
        XCTAssertEqual(store.summary.coveredMessageIDs, [first.id])
        XCTAssertEqual(store.pendingPlan?.question, first.content)
        XCTAssertEqual(store.phase, .awaitingIntake)
        XCTAssertFalse(store.showIntake)
        XCTAssertEqual(store.status, "等待你确认问事资料")
        XCTAssertEqual(store.activities.last?.status, .waiting)
        store.openConversation(secondID)
        XCTAssertEqual(store.summary.text, "第二卷的摘要")
        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(store.phase, .idle)
    }

    @MainActor func testLegacyArchivesMigrateOnceDeduplicatingByMessageIDs() async throws {
        let vault = try temporaryVault()
        let shared = [message("相同问题，但有独立身份")]
        let independent = [message("相同问题，但有独立身份", seconds: 20)]
        try vault.save(shared, as: "conversation-100")
        try vault.save(shared, as: "conversation-101")
        try vault.save(independent, as: "conversation-200")
        try vault.save(shared, as: "conversation")
        try vault.save(ConversationSummary(text: "当前卷摘要"), as: "context")
        try vault.save(Optional(plan("尚未填完")), as: "pending-intake")
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(store.conversations.count, 2)
        XCTAssertEqual(store.summary.text, "当前卷摘要")
        XCTAssertEqual(store.pendingPlan?.question, "尚未填完")
        XCTAssertEqual(store.messages.map(\.id), shared.map(\.id))

        // Even with the old archive files still present, deleting everything is
        // authoritative. Neither a restart nor a stale legacy current file revives it.
        for id in store.conversations.map(\.id) { store.deleteConversation(id) }
        try vault.save(shared, as: "conversation")
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertTrue(restarted.conversations.isEmpty)
        XCTAssertTrue(restarted.messages.isEmpty)
    }

    @MainActor func testDeletingOtherChatKeepsCurrentTranscriptAndPermanentRecords() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let oldID = store.activeConversationID
        store.messages = [message("旧卷")]
        store.newConversation()
        let currentID = store.activeConversationID
        let current = message("当前卷", seconds: 20)
        store.messages = [current]
        var profile = store.profile; profile.displayName = "永久资料"
        store.saveProfile(profile)
        let run = OracleRun(input: OracleInput(question: "独立推演", profile: profile), plan: plan("独立推演"))
        store.runs = [run]
        let originalWeights = store.weights
        store.deleteConversation(oldID)

        XCTAssertEqual(store.activeConversationID, currentID)
        XCTAssertEqual(store.messages.map(\.id), [current.id])
        XCTAssertEqual(store.profiles.first?.displayName, "永久资料")
        XCTAssertEqual(store.runs.map(\.id), [run.id])
        XCTAssertEqual(store.weights, originalWeights)
        XCTAssertFalse(store.conversations.contains { $0.id == oldID })
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.runs.map(\.id), [run.id])
        XCTAssertEqual(restarted.profiles.first?.displayName, "永久资料")
    }

    @MainActor func testDeletingCurrentChatCreatesFreshEmptyChatAndDoesNotResurrectIt() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let deletedID = store.activeConversationID
        store.messages = [message("待删除的当前卷")]
        var saved = store.profile; saved.name = "留存测试人员"
        store.saveProfile(saved)
        store.deleteConversation(deletedID)
        XCTAssertNotEqual(store.activeConversationID, deletedID)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertEqual(store.phase, .idle)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertTrue(restarted.conversations.isEmpty)
        XCTAssertTrue(restarted.messages.isEmpty)
        XCTAssertNotEqual(restarted.activeConversationID, deletedID)
    }

    @MainActor func testEmptyNewChatsDoNotAccumulateAndOpeningDoesNotReorderHistory() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let blankID = store.activeConversationID
        for _ in 0..<5 { store.newConversation() }
        XCTAssertEqual(store.activeConversationID, blankID)
        XCTAssertTrue(store.conversations.isEmpty)
        store.messages = [message("较早", seconds: 1)]
        store.newConversation()
        store.messages = [message("较新", seconds: 50)]
        store.newConversation()
        let before = store.conversations.map { ($0.id, $0.updatedAt) }
        store.openConversation(blankID)
        XCTAssertEqual(store.conversations.map(\.id), before.map(\.0))
        XCTAssertEqual(store.conversations.map(\.updatedAt), before.map(\.1))
    }

    @MainActor func testSwitchingCancelsQueuedWorkBeforeItCanAlterRestoredChat() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let savedID = store.activeConversationID
        let savedMessage = message("已经保存的旧对话")
        store.messages = [savedMessage]
        store.newConversation()
        let interruptedID = store.activeConversationID
        store.send("一个排队中的新问题")
        XCTAssertTrue(store.isBusy)
        // No suspension occurred since send; its asynchronous closure has not run.
        store.openConversation(savedID)
        XCTAssertFalse(store.isBusy)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(store.activeConversationID, savedID)
        XCTAssertEqual(store.messages.map(\.id), [savedMessage.id])
        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(store.conversations.first { $0.id == interruptedID }?.messages.count, 1)
    }

    @MainActor func testDeletingQueuedCurrentWorkCannotRecreateDeletedConversation() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let deletedID = store.activeConversationID
        store.send("一个刚发出的待删除问题")
        XCTAssertTrue(store.conversations.contains { $0.id == deletedID })
        store.deleteConversation(deletedID)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.conversations.isEmpty)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertTrue(restarted.conversations.isEmpty)
    }

    @MainActor func testUnreadableCanonicalHistoryPreservesCopyWithoutRevivingLegacyArchive() async throws {
        let vault = try temporaryVault()
        try vault.save([message("不应复活的旧归档")], as: "conversation-100")
        try Data("invalid history json".utf8).write(to: vault.directory.appendingPathComponent("conversation-history.json"))
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertNotNil(store.notice)
        let files = try FileManager.default.contentsOfDirectory(atPath: vault.directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("conversation-history.recovery-") })
    }
}
