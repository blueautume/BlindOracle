import XCTest
@testable import BlindOracle

final class ReadingContinuationStoreTests: XCTestCase {
    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reading-continuation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    private func fixture(_ method: OracleMethod) async throws -> OracleRun {
        var person = OracleProfile(); person.name = "陈平"; person.currentTimeZoneID = "Asia/Shanghai"
        let question = "这次出行如何安排？"
        let plan = OraclePlan(intent: "出行安排", subject: "事件", methods: [method], requiredFields: [], note: "", question: question)
        var input = OracleInput(question: question, profile: person, castingDate: Date(timeIntervalSince1970: 1_730_000_000), seed: 73, subject: "事件", participants: [])
        if method == .liuyao {
            input.manualLines = [6, 7, 8, 9, 7, 8]
            input.interactionResponses = [.init(requestID: "liuyao", lines: input.manualLines)]
        } else {
            let draws = zip(["major-00", "cups-01", "swords-14"], TarotDeck.positions).enumerated().map {
                TarotDraw(cardID: $0.element.0, isReversed: $0.offset == 1, position: $0.element.1)
            }
            input.tarotDraws = draws
            input.interactionResponses = [.init(requestID: "tarot", tarotDraws: draws, revealedCount: 3)]
        }
        let result: OracleResult
        if method == .liuyao { result = try await LiuyaoPlugin().calculate(input) }
        else { result = try await TarotPlugin().calculate(input) }
        XCTAssertTrue([OracleResultStatus.complete, .partial].contains(result.status))
        var run = OracleRun(input: input, plan: plan, results: [result])
        run.synthesis = ReadingSynthesis(text: "先核对行程，再稳步推进。", alternatives: [])
        run.completedAt = input.castingDate
        // LocalVault stores dates at ISO-8601 second precision. Start with that
        // persisted representation so comparisons still detect any later change.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OracleRun.self, from: encoder.encode(run))
    }

    @MainActor private func restoredStore(run: OracleRun, vault: LocalVault) throws -> OracleStore {
        let messages = [ChatMessage(role: .user, content: run.input.question),
                        ChatMessage(role: .assistant, content: run.synthesis!.text, kind: .reading, runID: run.id)]
        let conversation = OracleConversation(messages: messages)
        try vault.save([run], as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]), as: ConversationHistory.filename)
        return OracleStore(vault: vault, bootstrapCredential: false)
    }

    private func snapshot(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    @MainActor private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isBusy)
    }

    @MainActor private func assertContinues(_ question: String, in store: OracleStore, original: OracleRun) async throws {
        store.send(question)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.map(\.id), [original.id])
        XCTAssertEqual(try snapshot(store.runs[0].input), try snapshot(original.input))
        XCTAssertEqual(try snapshot(store.runs[0].results), try snapshot(original.results))
        XCTAssertEqual(store.messages.last?.role, .assistant)
        XCTAssertEqual(store.messages.last?.runID, original.id)
        XCTAssertFalse(store.messages.last?.content.isEmpty ?? true)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showIntake)
        XCTAssertFalse(store.showInteraction)
        XCTAssertFalse(store.canConfirmIntake)
    }

    @MainActor func testLiuyaoDetailQuestionsKeepOriginalSixLinesAndNeverAskForAnotherCast() async throws {
        let original = try await fixture(.liuyao)
        let store = try restoredStore(run: original, vault: temporaryVault())
        for question in ["这个卦象里的建议具体是什么意思？", "动爻和变卦之间有什么联系？", "不要重新算，只解释世应关系。"] {
            try await assertContinues(question, in: store, original: original)
        }
        XCTAssertEqual(store.runs[0].input.manualLines, [6, 7, 8, 9, 7, 8])
    }

    @MainActor func testTarotQuestionsKeepSelectedCardsPositionsOrientationsAndSeed() async throws {
        let original = try await fixture(.tarot)
        let store = try restoredStore(run: original, vault: temporaryVault())
        for question in ["第二张牌为什么是逆位？", "能解释一下建议牌和现状牌的关系吗？"] {
            try await assertContinues(question, in: store, original: original)
        }
        XCTAssertEqual(store.runs[0].input.tarotDraws, original.input.tarotDraws)
        XCTAssertEqual(store.runs[0].input.seed, 73)
    }

    @MainActor func testFollowUpsRemainAttachedToTheSameReadingAcrossRelaunch() async throws {
        let original = try await fixture(.liuyao)
        let vault = try temporaryVault()
        let store = try restoredStore(run: original, vault: vault)
        try await assertContinues("这段解释可以再具体一点吗？", in: store, original: original)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.latestRun?.id, original.id)
        try await assertContinues("那我接下来应该注意什么？", in: restarted, original: original)
        XCTAssertEqual(restarted.messages.filter { $0.role == .assistant && $0.runID == original.id }.count, 3)
    }

    @MainActor func testExplicitNewLiuyaoRequestStillWaitsForConfirmationAndThenStartsFreshCoins() async throws {
        let original = try await fixture(.liuyao)
        let store = try restoredStore(run: original, vault: temporaryVault())
        store.send("重新起卦，只用六爻看看明天出行是否顺利")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertEqual(store.pendingPlan?.methods, [.liuyao])
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.map(\.id), [original.id])
        store.confirmPendingIntake()
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .coins)
        XCTAssertTrue(store.pendingInteraction?.input.manualLines.isEmpty ?? false)
        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(try snapshot(store.runs[0].input), try snapshot(original.input))
    }

    @MainActor func testNewConversationDoesNotReuseAnotherConversationsReading() async throws {
        let original = try await fixture(.liuyao)
        let store = try restoredStore(run: original, vault: temporaryVault())
        store.newConversation()
        XCTAssertNil(store.latestRun)
        store.send("只用六爻看看明天出行是否顺利")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.map(\.id), [original.id])
        XCTAssertFalse(store.messages.contains { $0.runID == original.id })
    }

    @MainActor func testDeletingLatestReadingCannotReuseAnOlderReadingForDetails() async throws {
        let older = try await fixture(.liuyao)
        let latest = try await fixture(.tarot)
        let vault = try temporaryVault()
        let store = try restoredStore(run: older, vault: vault)
        store.runs.append(latest)
        store.messages.append(ChatMessage(role: .assistant, content: "最近的塔罗解读。", kind: .reading, runID: latest.id))
        store.deleteReading(id: latest.id)
        XCTAssertNil(store.latestRun)
        let before = store.messages.count
        store.send("这个卦里的建议是什么意思？")
        try await waitUntilIdle(store)
        XCTAssertFalse(store.messages.dropFirst(before).contains { $0.runID == older.id })
        XCTAssertEqual(store.runs.map(\.id), [older.id])
    }

    @MainActor func testMostRecentTranscriptReferenceWinsOverReadingCreationOrder() async throws {
        let older = try await fixture(.liuyao)
        let newer = try await fixture(.tarot)
        let store = try restoredStore(run: older, vault: temporaryVault())
        store.runs.append(newer)
        store.messages = [ChatMessage(role: .assistant, content: "最近创建的塔罗结果。", kind: .reading, runID: newer.id),
                          ChatMessage(role: .assistant, content: "现在继续讨论较早的六爻结果。", runID: older.id)]
        XCTAssertEqual(store.latestRun?.id, older.id)
        store.send("这里的动爻应该怎么理解？")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.messages.last?.runID, older.id)
        XCTAssertEqual(store.runs.map(\.id), [older.id, newer.id])
        XCTAssertEqual(try snapshot(store.runs[0].input), try snapshot(older.input))
        XCTAssertEqual(try snapshot(store.runs[1].input), try snapshot(newer.input))
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
    }

    @MainActor func testBareRecastPreservesTheOriginalQuestionAndMethodButRequestsFreshCoins() async throws {
        let original = try await fixture(.liuyao)
        let store = try restoredStore(run: original, vault: temporaryVault())
        store.send("重新起卦")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertEqual(store.pendingPlan?.question, original.input.question)
        XCTAssertEqual(store.pendingPlan?.methods, [.liuyao])
        XCTAssertEqual(store.pendingPlan?.subject, original.plan.subject)
        XCTAssertEqual(store.runs.map(\.id), [original.id])
        store.confirmPendingIntake()
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .coins)
        XCTAssertEqual(store.pendingInteraction?.input.question, original.input.question)
        XCTAssertTrue(store.pendingInteraction?.input.manualLines.isEmpty ?? false)
        XCTAssertEqual(try snapshot(store.runs[0].input), try snapshot(original.input))
    }

    @MainActor func testProfileUpdateWithExplicitRecastPreparesANewReadingUsingUpdatedPeople() async throws {
        var original = try await fixture(.liuyao)
        original.input.participants = [original.input.profile]
        original.plan.participantIDs = [original.input.profile.id]
        original.plan.participantNames = [original.input.profile.resolvedName]
        let store = try restoredStore(run: original, vault: temporaryVault())
        store.saveProfile(original.input.profile)
        store.send("陈平出生时间为09:30，重新起卦")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.id == original.input.profile.id }?.birthTimeText, "09:30")
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertEqual(store.pendingPlan?.question, original.input.question)
        XCTAssertEqual(store.pendingPlan?.methods, [.liuyao])
        XCTAssertEqual(store.pendingPlan?.participantIDs, original.plan.participantIDs)
        XCTAssertNil(store.pendingInteraction)
        store.confirmPendingIntake()
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .coins)
        XCTAssertEqual(store.pendingInteraction?.input.readingParticipants.first?.birthTimeText, "09:30")
        XCTAssertEqual(try snapshot(store.runs[0].input), try snapshot(original.input))
    }

    @MainActor func testExplicitProfileCorrectionIsSavedWithoutChangingTheExistingReadingSnapshot() async throws {
        let original = try await fixture(.liuyao)
        let store = try restoredStore(run: original, vault: temporaryVault())
        _ = store.applyProfileUpdates([ProfileUpdate(name: "陈平", birthDate: "1992-06-15", birthTime: "08:30", birthTimeZoneID: "Asia/Shanghai")])
        store.send("陈平出生时间为09:30，先不算")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.resolvedName == "陈平" }?.birthTimeText, "09:30")
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(try snapshot(store.runs[0].input), try snapshot(original.input))
        XCTAssertEqual(store.runs.map(\.id), [original.id])
    }
}
