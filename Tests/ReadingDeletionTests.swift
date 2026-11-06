import XCTest
@testable import BlindOracle

final class ReadingDeletionTests: XCTestCase {
    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reading-deletion-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    private func plan(_ question: String) -> OraclePlan {
        OraclePlan(intent: "具体问事", subject: "事件", methods: [.xiaoliuren], requiredFields: [], note: "", question: question)
    }

    private func reading(_ question: String) -> OracleRun {
        var run = OracleRun(input: OracleInput(question: question, profile: OracleProfile(), seed: 42, participants: []), plan: plan(question))
        run.results = [OracleResult(method: .xiaoliuren, headline: "已留存的本地结果", rows: [.init("时宫", "大安")])]
        run.synthesis = ReadingSynthesis(text: "已留存的解读文字")
        run.completedAt = Date(timeIntervalSince1970: 100)
        return run
    }

    @MainActor private func beginQueuedCalculation(in store: OracleStore) throws -> UUID {
        let pending = plan("仍在进行的本地推演")
        store.pendingPlan = pending
        store.messages.append(ChatMessage(role: .assistant, content: "请确认这次问题。", kind: .intake))
        var casting = OracleProfile()
        casting.currentPlace = "北京市朝阳区"
        casting.currentLatitude = 39.9; casting.currentLongitude = 116.4
        casting.currentTimeZoneID = "Asia/Shanghai"
        store.confirmGroupIntake(profiles: [], numbers: [], save: false, castingProfile: casting)
        XCTAssertEqual(store.phase, .calculating)
        XCTAssertNil(store.pendingInteraction)
        return try XCTUnwrap(store.runs.last?.id)
    }

    @MainActor private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isBusy)
    }

    @MainActor func testOnlyTheSpecifiedUUIDIsDeletedWhenQuestionsAreIdentical() throws {
        let vault = try temporaryVault()
        let removed = reading("同一问题")
        let retained = reading("同一问题")
        try vault.save([removed, retained], as: "readings")
        let store = OracleStore(vault: vault, bootstrapCredential: false)

        store.deleteReading(id: removed.id)

        XCTAssertEqual(store.runs.map(\.id), [retained.id])
        XCTAssertEqual(store.runs.first?.synthesis?.text, retained.synthesis?.text)
        store.retrySynthesis(removed)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.runs.map(\.id), [retained.id])
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.runs.map(\.id), [retained.id])
    }

    @MainActor func testDeletionClearsCurrentAndArchivedLinksButPreservesTextPeopleAndPendingQuestion() throws {
        let vault = try temporaryVault()
        let removed = reading("删除盘面，保留对话")
        let retained = reading("另一份盘面")
        var person = OracleProfile(); person.name = "张三"; person.birthDateText = "1995-01-02"
        var pending = plan("尚未确认的新问题")
        pending.preparationStage = .confirming
        pending.reviewedParticipants = []
        let currentReply = ChatMessage(role: .assistant, content: "当前聊天中的旧解读原文。", kind: .reading, runID: removed.id)
        let archivedReply = ChatMessage(role: .assistant, content: "归档聊天中的旧解读原文。", kind: .reading, runID: removed.id)
        let otherReply = ChatMessage(role: .assistant, content: "另一份推演仍能查看。", kind: .reading, runID: retained.id)
        let current = OracleConversation(messages: [currentReply, otherReply], pendingPlan: pending)
        let archived = OracleConversation(messages: [archivedReply])
        try vault.save([removed, retained], as: "readings")
        try vault.save([person], as: "profiles")
        try vault.save(Optional(person.id), as: "self-profile-id")
        try vault.save(OracleConversationArchive(activeConversationID: current.id, conversations: [current, archived]), as: ConversationHistory.filename)
        let store = OracleStore(vault: vault, bootstrapCredential: false)

        store.deleteReading(id: removed.id)

        XCTAssertEqual(store.activeConversationID, current.id)
        XCTAssertEqual(store.messages.prefix(2).map(\.id), [currentReply.id, otherReply.id])
        XCTAssertNil(store.messages.first?.runID)
        XCTAssertEqual(store.messages.first?.deletedRunID, removed.id)
        XCTAssertEqual(store.messages.first?.content, currentReply.content)
        XCTAssertEqual(store.messages.first?.kind, .reading)
        XCTAssertEqual(store.messages.first { $0.id == otherReply.id }?.runID, retained.id)
        XCTAssertEqual(store.pendingPlan?.question, pending.question)
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.profiles.map(\.id), [person.id])
        XCTAssertEqual(store.profiles.first?.birthDateText, person.birthDateText)
        XCTAssertEqual(store.selfProfileID, person.id)

        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.runs.map(\.id), [retained.id])
        XCTAssertNil(restarted.messages.first?.runID)
        XCTAssertEqual(restarted.messages.first?.deletedRunID, removed.id)
        XCTAssertEqual(restarted.messages.first?.content, currentReply.content)
        let oldChat = try XCTUnwrap(restarted.conversations.first { $0.id == archived.id })
        XCTAssertEqual(oldChat.messages.map(\.id), [archivedReply.id])
        XCTAssertNil(oldChat.messages.first?.runID)
        XCTAssertEqual(oldChat.messages.first?.deletedRunID, removed.id)
        XCTAssertEqual(oldChat.messages.first?.content, archivedReply.content)
        XCTAssertFalse(restarted.conversations.flatMap(\.messages).contains { $0.runID == removed.id })
        XCTAssertEqual(restarted.messages.first { $0.id == otherReply.id }?.runID, retained.id)
        XCTAssertEqual(restarted.pendingPlan?.question, pending.question)
        XCTAssertEqual(restarted.profiles.map(\.id), [person.id])
        XCTAssertEqual(restarted.profiles.first?.birthDateText, person.birthDateText)
        XCTAssertEqual(restarted.selfProfileID, person.id)
        let legacySnapshot = vault.load([ChatMessage].self, from: "conversation", fallback: [])
        XCTAssertFalse(legacySnapshot.contains { $0.runID == removed.id })
    }

    @MainActor func testDeletingLatestReferencedReadingCannotFallBackToAnOlderQuestion() throws {
        let vault = try temporaryVault()
        let older = reading("上一件事")
        let latest = reading("刚才这件事")
        let olderReply = ChatMessage(role: .assistant, content: "上一件事的答复。", kind: .reading, runID: older.id)
        let latestReply = ChatMessage(role: .assistant, content: "刚才这件事的答复。", kind: .reading, runID: latest.id)
        let chat = OracleConversation(messages: [olderReply, latestReply])
        try vault.save([older, latest], as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: chat.id, conversations: [chat]), as: ConversationHistory.filename)
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(store.latestRun?.id, latest.id)

        store.deleteReading(id: latest.id)

        XCTAssertEqual(store.runs.map(\.id), [older.id])
        XCTAssertNil(store.latestRun)
        XCTAssertEqual(store.messages.last?.deletedRunID, latest.id)
        XCTAssertEqual(store.messages.last?.content, latestReply.content)
        XCTAssertNil(OracleStore(vault: vault, bootstrapCredential: false).latestRun)
    }

    @MainActor func testUnknownAndRepeatedDeletionAreIdempotent() throws {
        let vault = try temporaryVault()
        let removed = reading("只删一次")
        let retained = reading("一直保留")
        try vault.save([removed, retained], as: "readings")
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let conversationID = store.activeConversationID
        let message = ChatMessage(role: .assistant, content: "这段文字保留。", kind: .reading, runID: retained.id)
        store.messages = [message]

        store.deleteReading(id: UUID())
        XCTAssertEqual(store.runs.map(\.id), [removed.id, retained.id])
        XCTAssertEqual(store.messages.map(\.id), [message.id])
        XCTAssertEqual(store.messages.first?.runID, retained.id)
        store.deleteReading(id: removed.id)
        store.deleteReading(id: removed.id)
        store.deleteReading(id: UUID())

        XCTAssertEqual(store.activeConversationID, conversationID)
        XCTAssertEqual(store.runs.map(\.id), [retained.id])
        XCTAssertEqual(store.messages.map(\.id), [message.id])
        XCTAssertEqual(store.messages.first?.runID, retained.id)
        XCTAssertEqual(OracleStore(vault: vault, bootstrapCredential: false).runs.map(\.id), [retained.id])
    }

    @MainActor func testDeletingQueuedCalculationCancelsItAndLateCallbacksCannotRestoreTheRun() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let runID = try beginQueuedCalculation(in: store)
        let originalText = store.messages.map(\.content)

        // No suspension: the task created by confirmGroupIntake is still queued.
        store.deleteReading(id: runID)
        XCTAssertFalse(store.isBusy)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertEqual(store.messages.map(\.content), originalText)
        XCTAssertFalse(store.messages.contains { $0.runID == runID })
        XCTAssertFalse(store.activities.contains { $0.status == .running })
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertTrue(restarted.runs.isEmpty)
        XCTAssertFalse(restarted.messages.contains { $0.runID == runID })
    }

    @MainActor func testDeletingQueuedSynthesisCannotAppendAnAnswerOrRestoreTheRun() async throws {
        let vault = try temporaryVault()
        let saved = reading("重试解读中删除")
        try vault.save([saved], as: "readings")
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let reply = ChatMessage(role: .assistant, content: "此前已经显示的文字。", kind: .reading, runID: saved.id)
        store.messages = [reply]
        store.retrySynthesis(saved)
        XCTAssertEqual(store.phase, .synthesizing)

        store.deleteReading(id: saved.id)
        XCTAssertFalse(store.isBusy)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertEqual(store.messages.map(\.id), [reply.id])
        XCTAssertEqual(store.messages.first?.content, reply.content)
        XCTAssertNil(store.messages.first?.runID)
        XCTAssertTrue(OracleStore(vault: vault, bootstrapCredential: false).runs.isEmpty)
    }

    @MainActor func testDeletingAnotherRunDoesNotCancelActiveCalculation() async throws {
        let vault = try temporaryVault()
        let old = reading("删除较早记录")
        try vault.save([old], as: "readings")
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let activeID = try beginQueuedCalculation(in: store)

        store.deleteReading(id: old.id)
        XCTAssertEqual(store.phase, .calculating)
        XCTAssertTrue(store.isBusy)
        try await waitUntilIdle(store)

        let completed = try XCTUnwrap(store.runs.first { $0.id == activeID })
        XCTAssertEqual(store.runs.map(\.id), [activeID])
        XCTAssertEqual(completed.results.map(\.method), [.xiaoliuren])
        XCTAssertNotNil(completed.completedAt)
        XCTAssertNotNil(completed.synthesis)
        XCTAssertTrue(store.messages.contains { $0.kind == .reading && $0.runID == activeID })
        XCTAssertEqual(OracleStore(vault: vault, bootstrapCredential: false).runs.map(\.id), [activeID])
    }

    @MainActor func testDeletingAnotherRunDoesNotCancelQueuedSynthesis() async throws {
        let vault = try temporaryVault()
        let old = reading("删除其它记录")
        let active = reading("本条继续解读")
        try vault.save([old, active], as: "readings")
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        store.retrySynthesis(active)

        store.deleteReading(id: old.id)
        XCTAssertEqual(store.phase, .synthesizing)
        try await waitUntilIdle(store)

        XCTAssertEqual(store.runs.map(\.id), [active.id])
        XCTAssertTrue(store.messages.contains { $0.kind == .reading && $0.runID == active.id && !$0.content.isEmpty })
        XCTAssertNotNil(store.runs.first?.completedAt)
        XCTAssertFalse(store.activities.contains { $0.status == .cancelled })
    }
}
