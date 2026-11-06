import XCTest
@testable import BlindOracle

@MainActor final class ReadingExecutionStoreTests: XCTestCase {
    private struct Fixture {
        let store: OracleStore
        let original: OracleRun
        let reference: ChatMessage
        let vault: LocalVault
        let key: String
        let taskDirectory: URL
    }

    func testChangedTargetStartsFreshEvenWhenPlannerSaysReplyOrContinuation() async throws {
        let examples: [(String, String, ConversationUnderstanding.Relation)] = [
            ("明天呢", "明天是否有课程安排？", .continuation),
            ("那算一下明天", "明天是否有课程安排？", .continuation),
            ("那算一下下个季度", "下个季度的课程安排如何？", .continuation),
            ("预算换成五千，按这个条件推演", "预算为五千时，这项计划如何安排？", .changedConditions),
            ("Then calculate for next weekend", "How should I arrange the course next weekend?", .continuation)
        ]
        for (raw, expanded, relation) in examples {
            let fixture = try makeFixture(raw: raw, expanded: expanded, relation: relation,
                                          operation: "calculate", coverage: "changed", proposedAction: "reply")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // LocalVault persists ISO-8601 dates at whole-second precision.
            // Compare the actual restored snapshot before and after routing,
            // rather than the higher-precision object used to create its file.
            let oldBytes = try encoder.encode(XCTUnwrap(fixture.store.runs.first))
            fixture.store.send(raw)
            try await waitUntilIdle(fixture.store)
            let pending = try XCTUnwrap(fixture.store.pendingPlan, raw)
            XCTAssertEqual(pending.question, expanded, raw)
            XCTAssertEqual(pending.methods, fixture.original.plan.methods, raw)
            XCTAssertNil(pending.baseRunID, raw)
            XCTAssertTrue(pending.castingProfile?.currentPlace.isEmpty == true, raw)
            XCTAssertNil(pending.castingProfile?.currentLongitude, raw)
            XCTAssertTrue(fixture.store.showIntake, raw)
            XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id], raw)
            XCTAssertEqual(try encoder.encode(XCTUnwrap(fixture.store.runs.first)), oldBytes, raw)
            let persistedRun = try XCTUnwrap(fixture.vault.load([OracleRun].self, from: "readings", fallback: []).first)
            XCTAssertEqual(try encoder.encode(persistedRun), oldBytes, raw)
            XCTAssertEqual(ExecutionStoreURLProtocol.accepts(for: fixture.key), ["application/json"], raw)
        }
    }

    func testConfirmedNewTargetUsesRealNewInstantAndSeedWithoutChangingOldRun() async throws {
        let raw = "那算一下明天"
        let fixture = try makeFixture(raw: raw, expanded: "明天是否有课程安排？", operation: "calculate", coverage: "changed")
        let before = Date()
        fixture.store.send(raw)
        try await waitUntilIdle(fixture.store)
        XCTAssertTrue(fixture.store.confirmGroupIntake(profiles: [], numbers: [], save: false, castingProfile: castingSite()))
        try await waitUntilIdle(fixture.store)
        let fresh = try XCTUnwrap(fixture.store.runs.last)
        XCTAssertEqual(fixture.store.runs.count, 2)
        XCTAssertNotEqual(fresh.id, fixture.original.id)
        XCTAssertEqual(fresh.input.question, "明天是否有课程安排？")
        XCTAssertGreaterThanOrEqual(fresh.input.castingDate, before)
        XCTAssertLessThanOrEqual(fresh.input.castingDate, Date())
        XCTAssertNotEqual(fresh.input.seed, fixture.original.input.seed)
        XCTAssertEqual(fixture.store.runs.first?.input.castingDate, fixture.original.input.castingDate)
        XCTAssertEqual(fixture.store.runs.first?.results.map(\.id), fixture.original.results.map(\.id))
        XCTAssertEqual(fresh.synthesis?.text, "隔离测试回答。")
    }

    func testRecastRequiresNewCardsAndCoinsInsteadOfReusingConfirmedInteraction() async throws {
        for method in [OracleMethod.tarot, .liuyao] {
            let raw = "请为同一件事重新推演"
            let fixture = try makeFixture(raw: raw, expanded: "今天的课程安排如何？", method: method,
                                          operation: "recast", coverage: "existing", proposedAction: "reply")
            fixture.store.send(raw)
            try await waitUntilIdle(fixture.store)
            let pending = try XCTUnwrap(fixture.store.pendingPlan)
            XCTAssertNil(pending.baseRunID)
            XCTAssertTrue(fixture.store.confirmGroupIntake(profiles: [], numbers: [], save: false))
            let session = try XCTUnwrap(fixture.store.pendingInteraction)
            XCTAssertEqual(session.currentRequest?.kind, method == .tarot ? .tarot : .coins)
            XCTAssertNotEqual(session.input.seed, fixture.original.input.seed)
            XCTAssertNotEqual(session.input.castingDate, fixture.original.input.castingDate)
            XCTAssertTrue(session.input.tarotDraws?.isEmpty != false)
            XCTAssertTrue(session.input.manualLines.isEmpty)
            XCTAssertNil(session.draft)
            XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id])
            fixture.store.cancelPendingReading()
        }
    }

    func testBareRecastKeepsSelectedFollowUpTargetInsteadOfOldCastQuestion() async throws {
        for target in ["下周课程安排如何？", "预算为三千且不聘外援时，如何安排课程？"] {
            let fixture = try makeFixture(raw: "再算一下", expanded: "今天的课程安排如何？", operation: "recast",
                                          coverage: "changed", referenceQuestion: target)
            fixture.store.send("再算一下")
            try await waitUntilIdle(fixture.store)
            XCTAssertEqual(fixture.store.pendingPlan?.question, target)
            XCTAssertNil(fixture.store.pendingPlan?.baseRunID)
            XCTAssertEqual(fixture.store.runs.first?.input.question, fixture.original.input.question)
            XCTAssertNotEqual(fixture.store.pendingPlan?.question, fixture.original.input.question)
        }
    }

    func testExplicitAnswerDoesNotGetUpgradedByIntakeFieldsOrNamedMethodMentions() async throws {
        for raw in ["不要重算，只解释原来的建议", "如果改到下周会怎样，不用现在重算", "Please explain the saved result without recalculating", "他说“重新算一下”，这是什么意思？"] {
            let fixture = try makeFixture(raw: raw, expanded: raw, operation: "answer", coverage: "existing",
                                          proposedAction: "intake", methods: [.tarot], mandatory: [.tarot])
            fixture.store.send(raw)
            try await waitUntilIdle(fixture.store)
            XCTAssertNil(fixture.store.pendingPlan, raw)
            XCTAssertNil(fixture.store.pendingInteraction, raw)
            XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id], raw)
            XCTAssertEqual(fixture.store.messages.last?.content, "隔离测试回答。", raw)
            XCTAssertEqual(ExecutionStoreURLProtocol.accepts(for: fixture.key), ["application/json", "text/event-stream"], raw)
        }
    }

    func testLegacyTimeExpansionStillRepliesButDirectUnnamedCalculationStartsIntake() async throws {
        for (raw, action, shouldCalculate) in [("下半年呢", "intake", false), ("那算一下下周", "reply", true)] {
            let fixture = try makeFixture(raw: raw, expanded: "接着原课程安排询问\(raw)", operation: "legacy",
                                          coverage: "changed", proposedAction: action, methods: [.xiaoliuren])
            fixture.store.send(raw)
            try await waitUntilIdle(fixture.store)
            XCTAssertEqual(fixture.store.pendingPlan != nil, shouldCalculate, raw)
            XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id], raw)
        }
    }

    func testCalculateWithinExistingCoverageDoesNotRecast() async throws {
        let raw = "具体看看这个安排的第一步"
        let fixture = try makeFixture(raw: raw, expanded: "原课程安排的第一步如何落实？", operation: "calculate",
                                      coverage: "existing", proposedAction: "intake", methods: [.tarot])
        fixture.store.send(raw)
        try await waitUntilIdle(fixture.store)
        XCTAssertNil(fixture.store.pendingPlan)
        XCTAssertNil(fixture.store.pendingInteraction)
        XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id])
    }

    func testClarifyAndCollectCannotBeUpgradedByLegacyMandatoryMethods() async throws {
        for operation in ["clarify", "collect"] {
            let raw = operation == "collect" ? "只保存资料，暂不推演" : "先确认我指的是哪件事"
            let fixture = try makeFixture(raw: raw, expanded: raw, operation: operation, coverage: "unknown",
                                          proposedAction: "intake", methods: [.tarot], mandatory: [.tarot])
            fixture.store.send(raw)
            try await waitUntilIdle(fixture.store)
            XCTAssertNil(fixture.store.pendingPlan)
            XCTAssertNil(fixture.store.pendingInteraction)
            XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id])
            XCTAssertEqual(ExecutionStoreURLProtocol.accepts(for: fixture.key), ["application/json"])
        }
    }

    func testInvalidNewIntentOrReferenceClarifiesWithoutRecasting() async throws {
        for invalid in ["evidence", "null", "enum", "reference"] {
            let raw = "那算一下新的安排"
            let fixture = try makeFixture(raw: raw, expanded: "新安排下的课程如何？", operation: "calculate",
                                          coverage: "changed", invalid: invalid)
            fixture.store.send(raw)
            try await waitUntilIdle(fixture.store)
            XCTAssertNil(fixture.store.pendingPlan, invalid)
            XCTAssertNil(fixture.store.pendingInteraction, invalid)
            XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id], invalid)
            XCTAssertEqual(ExecutionStoreURLProtocol.accepts(for: fixture.key), ["application/json"], invalid)
        }
    }

    func testChangedParticipantUsesRequestedPersonWhileKeepingOldPersonsReading() async throws {
        var other = OracleProfile(); other.name = "林舟"
        let raw = "换成林舟，计算他的课程安排"
        let fixture = try makeFixture(raw: raw, expanded: "林舟今天的课程安排如何？", relation: .changedParticipants,
                                      operation: "calculate", coverage: "changed", person: other)
        fixture.store.saveProfile(other)
        fixture.store.send(raw)
        try await waitUntilIdle(fixture.store)
        let pending = try XCTUnwrap(fixture.store.pendingPlan)
        XCTAssertEqual(pending.participantIDs, [other.id])
        XCTAssertEqual(fixture.store.intakeParticipants.map(\.id), [other.id])
        XCTAssertNil(pending.baseRunID)
        XCTAssertEqual(fixture.store.runs.first?.input.profile.id, fixture.original.input.profile.id)
        XCTAssertEqual(fixture.store.runs.first?.results.map(\.id), fixture.original.results.map(\.id))
    }

    func testAdditionalCapabilityKeepsOriginalScopeAndCastingSnapshot() async throws {
        let raw = "加上八字分析长期的安排"
        let fixture = try makeFixture(raw: raw, expanded: "结合八字分析原课程安排的长期方向", operation: "calculate",
                                      coverage: "additional", proposedAction: "reply", methods: [.bazi], mandatory: [.bazi])
        fixture.store.send(raw)
        try await waitUntilIdle(fixture.store)
        let pending = try XCTUnwrap(fixture.store.pendingPlan)
        XCTAssertEqual(pending.baseRunID, fixture.original.id)
        XCTAssertEqual(pending.question, fixture.original.input.question)
        XCTAssertEqual(pending.castingProfile?.currentLongitude, fixture.original.input.profile.currentLongitude)
        XCTAssertTrue(pending.methods.contains(.bazi))
        XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id])
    }

    func testPendingScopeReplacementInvalidatesOldDrawAndPersistsCancelledTask() async throws {
        let raw = "那算一下下个季度"
        let fixture = try makeFixture(raw: raw, expanded: "下个季度的课程安排如何？", method: .tarot,
                                      operation: "calculate", coverage: "changed")
        let oldTask = UUID()
        let folder = fixture.taskDirectory.appendingPathComponent(ServiceEnvironment.current.serverTaskID(for: oldTask).uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Isolated admitted task with no signed-in owner: ending cannot be
        // acknowledged yet, so the durable cancellation must remain queued.
        let taskRecord: [String: Any] = ["ownerID": "fixture-owner", "admissionToken": "isolated-fixture",
            "logicalTaskID": oldTask.uuidString, "serviceEnvironment": ServiceEnvironment.current.rawValue]
        try JSONSerialization.data(withJSONObject: taskRecord).write(to: folder.appendingPathComponent("task.json"))
        var oldPlan = fixture.original.plan
        oldPlan.quotaTaskID = oldTask
        oldPlan.castingProfile = castingSite()
        let oldSession = OracleInteractionSession(input: fixture.original.input, plan: oldPlan,
            requests: [.init(method: .tarot, kind: .tarot, prompt: "选择原问题的牌")])
        fixture.store.pendingInteraction = oldSession
        fixture.store.send(raw)
        try await waitUntilIdle(fixture.store)
        let fresh = try XCTUnwrap(fixture.store.pendingPlan)
        XCTAssertEqual(fresh.question, "下个季度的课程安排如何？")
        XCTAssertNotEqual(fresh.quotaTaskID, oldTask)
        XCTAssertNil(fixture.store.pendingInteraction)
        await fixture.store.flushQuotaEnds()
        let ends = fixture.vault.load([String: String].self, from: ServiceEnvironment.current.endIntentsFilename, fallback: [:])
        XCTAssertEqual(ends[oldTask.uuidString.lowercased()], "cancelled")
        fixture.store.completeInteraction(.init(requestID: oldSession.currentRequest!.id,
            tarotDraws: oldSession.input.tarotDraws ?? [], revealedCount: 3), sessionID: oldSession.id)
        XCTAssertEqual(fixture.store.pendingPlan?.question, fresh.question)
        XCTAssertNil(fixture.store.pendingInteraction)
        XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id])
    }

    func testAnswerWhileFormIsPendingDoesNotConsumeOrCancelItsFinalStageTask() async throws {
        let raw = "先解释一下刚才的建议"
        let fixture = try makeFixture(raw: raw, expanded: raw, operation: "answer", coverage: "existing")
        let taskID = UUID()
        var pending = fixture.original.plan
        pending.quotaTaskID = taskID
        fixture.store.pendingPlan = pending
        fixture.store.send(raw)
        try await waitUntilIdle(fixture.store)
        XCTAssertEqual(fixture.store.pendingPlan?.quotaTaskID, taskID)
        XCTAssertEqual(fixture.store.pendingPlan?.question, pending.question)
        XCTAssertEqual(fixture.store.pendingPlan?.castingProfile, pending.castingProfile)
        XCTAssertEqual(fixture.store.messages.last?.content, "隔离测试回答。")
        let ends = fixture.vault.load([String: String].self, from: ServiceEnvironment.current.endIntentsFilename, fallback: [:])
        XCTAssertNil(ends[taskID.uuidString.lowercased()])
        XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id])
    }

    func testNonFactualProfileTextCannotWriteBeforeOrAfterPlanningOrBindSelf() async throws {
        let cases: [(String, String, Bool)] = [
            ("假设我叫陈平，出生日期为1990-01-02；计算这个假设下的安排", "calculate", false),
            ("他说：“我叫陈平，出生日期为1990-01-02。”请解释这句话", "answer", false),
            ("如果我叫陈平，出生日期为1990-01-02，应该提供哪些资料？", "clarify", false),
            ("例如：我叫陈平，出生日期为1990-01-02；只记录这个例子", "collect", false),
            ("假设我叫陈平，出生日期为1990-01-02，这段话如何理解？", "legacy", false),
            ("假设我叫陈平，出生日期为1990-01-02；计算这个假设下的安排", "calculate", true),
            ("他说：“我叫陈平，出生日期为1990-01-02。”请解释这句话", "answer", true)
        ]
        for (raw, operation, offline) in cases {
            var own = OracleProfile(); own.name = "原本人"
            var chen = OracleProfile(); chen.name = "陈平"
            chen.birthDate = Date(timeIntervalSince1970: 788_918_400)
            chen.birthDateText = "1995-01-01"
            let updates: [[String: Any]] = [["id": chen.id.uuidString, "name": "陈平", "birthDate": "1990-01-02"]]
            let fixture = try makeFixture(raw: raw, expanded: raw, relation: .newQuestion, operation: operation,
                coverage: "changed", methods: [.xiaoliuren], plannedProfileUpdates: updates, failPlanning: offline)
            fixture.store.saveProfile(own); fixture.store.saveProfile(chen)
            fixture.store.selfProfileID = own.id; fixture.store.checkpoint()
            let expected = fixture.store.profiles
            // Preserve separate exact baselines: in-memory Date precision is
            // higher than LocalVault's ISO-8601 representation. Every field in
            // both representations must remain unchanged by the message.
            let expectedPersisted = fixture.vault.load([OracleProfile].self, from: "profiles", fallback: [])
            XCTAssertFalse(ProfileFactPolicy.allowsPersistence(in: raw), raw)
            fixture.store.send(raw)
            try await waitUntilIdle(fixture.store)
            XCTAssertEqual(fixture.store.profiles, expected, raw)
            XCTAssertEqual(fixture.store.selfProfileID, own.id, raw)
            XCTAssertEqual(fixture.vault.load([OracleProfile].self, from: "profiles", fallback: []), expectedPersisted, raw)
            XCTAssertEqual(fixture.vault.load(UUID?.self, from: "self-profile-id", fallback: nil), own.id, raw)
            XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id], raw)
        }
    }

    func testHypotheticalUnknownNameStaysInFormInsteadOfCreatingPermanentProfile() async throws {
        var hypothetical = OracleProfile(); hypothetical.name = "林舟"
        let raw = "假设姓名为林舟；计算林舟的课程安排"
        let fixture = try makeFixture(raw: raw, expanded: raw, relation: .newQuestion, operation: "calculate",
                                      coverage: "changed", methods: [.tarot], person: hypothetical)
        fixture.store.send(raw)
        try await waitUntilIdle(fixture.store)
        XCTAssertTrue(fixture.store.profiles.isEmpty)
        XCTAssertTrue(fixture.vault.load([OracleProfile].self, from: "profiles", fallback: []).isEmpty)
        let pending = try XCTUnwrap(fixture.store.pendingPlan)
        XCTAssertTrue(pending.participantNames?.contains("林舟") == true)
        XCTAssertTrue(fixture.store.showIntake)
    }

    func testRealProfileCorrectionStillPersistsWithoutChangingSelfBinding() async throws {
        var own = OracleProfile(); own.name = "原本人"
        var chen = OracleProfile(); chen.name = "陈平"
        chen.birthDate = Date(timeIntervalSince1970: 788_918_400); chen.birthDateText = "1995-01-01"
        let raw = "陈平，出生日期更正为1990-01-02，是真实资料，请保存。"
        let fixture = try makeFixture(raw: raw, expanded: raw, relation: .newQuestion, operation: "collect",
            coverage: "existing", plannedProfileUpdates: [["id": chen.id.uuidString, "name": "陈平", "birthDate": "1990-01-02"]])
        fixture.store.saveProfile(own); fixture.store.saveProfile(chen)
        fixture.store.selfProfileID = own.id; fixture.store.checkpoint()
        XCTAssertTrue(ProfileFactPolicy.allowsPersistence(in: raw))
        fixture.store.send(raw)
        try await waitUntilIdle(fixture.store)
        XCTAssertEqual(fixture.store.profiles.first { $0.id == chen.id }?.birthDateText, "1990-01-02")
        XCTAssertEqual(fixture.vault.load([OracleProfile].self, from: "profiles", fallback: []).first { $0.id == chen.id }?.birthDateText, "1990-01-02")
        XCTAssertEqual(fixture.store.selfProfileID, own.id)
        XCTAssertNil(fixture.store.pendingPlan)
    }

    func testAffirmativeCalculationClauseSurvivesGreetingConsultationAndPendingCancellation() async throws {
        let examples = [
            ("谢谢，算一下新目标", false),
            ("六爻原理是什么，同时算新方案", false),
            ("不要算旧安排，算新目标", true),
            ("Thanks, calculate the new plan", false)
        ]
        for (raw, hasPending) in examples {
            let expanded = "新的目标和方案应当如何安排？"
            let fixture = try makeFixture(raw: raw, expanded: expanded, operation: "calculate", coverage: "changed")
            if hasPending { fixture.store.pendingPlan = fixture.original.plan }
            fixture.store.send(raw)
            try await waitUntilIdle(fixture.store)
            XCTAssertEqual(fixture.store.pendingPlan?.question, expanded, raw)
            XCTAssertNil(fixture.store.pendingPlan?.baseRunID, raw)
            XCTAssertTrue(fixture.store.showIntake, raw)
            XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id], raw)
            // The planner must be called; a premature answer would stream
            // without consuming the structured plan response.
            XCTAssertEqual(ExecutionStoreURLProtocol.accepts(for: fixture.key), ["application/json"], raw)
        }
    }

    func testFreshIntakeUsesCurrentProfileByIdentityAndOnlyFallsBackToArchivedPersonWhenMissing() async throws {
        for hasCurrentProfile in [true, false] {
            var archived = OracleProfile(); archived.name = "陈平"
            archived.birthDate = Date(timeIntervalSince1970: 788_918_400)
            archived.birthDateText = "1995-01-01"
            var current = archived
            current.birthDate = Date(timeIntervalSince1970: 820_454_400)
            current.birthDateText = "1996-01-01"
            let fixture = try makeFixture(raw: "重新起卦", expanded: "今天的课程安排如何？", method: .tarot,
                operation: "recast", coverage: "existing", originalParticipants: [archived])
            if hasCurrentProfile { fixture.store.saveProfile(current) }
            fixture.store.send("重新起卦")
            try await waitUntilIdle(fixture.store)
            let expected = hasCurrentProfile ? current : archived
            let branch = hasCurrentProfile ? "current profile" : "archived-only profile"
            XCTAssertEqual(fixture.store.intakeParticipants.map(\.id), [archived.id], branch)
            XCTAssertEqual(fixture.store.intakeParticipants.first?.birthDate, expected.birthDate, branch)
            XCTAssertEqual(fixture.store.intakeParticipants.first?.birthDateText, expected.birthDateText, branch)
            XCTAssertTrue(fixture.store.confirmGroupIntake(profiles: fixture.store.intakeParticipants, numbers: [], save: true))
            XCTAssertEqual(fixture.store.pendingInteraction?.input.readingParticipants.first?.birthDate, expected.birthDate)
            XCTAssertEqual(fixture.store.profiles.first { $0.id == archived.id }?.birthDateText, expected.birthDateText)
            XCTAssertEqual(fixture.store.runs.first?.input.readingParticipants.first?.birthDate, archived.birthDate)
            XCTAssertEqual(fixture.store.runs.first?.input.readingParticipants.first?.birthDateText, archived.birthDateText)
            XCTAssertEqual(fixture.store.runs.map(\.id), [fixture.original.id])
            fixture.store.cancelPendingReading()
        }
    }

    private func castingSite() -> OracleProfile {
        var place = OracleProfile()
        place.currentPlace = "上海市黄浦区"; place.currentLatitude = 31.2304; place.currentLongitude = 121.4737
        place.currentTimeZoneID = "Asia/Shanghai"
        return place
    }

    private func makeFixture(raw: String, expanded: String, relation: ConversationUnderstanding.Relation = .continuation,
                             method: OracleMethod = .xiaoliuren, operation: String, coverage: String,
                             proposedAction: String = "reply", methods: [OracleMethod] = [], mandatory: [OracleMethod] = [],
                             person: OracleProfile? = nil, invalid: String? = nil, referenceQuestion: String? = nil,
                             plannedProfileUpdates: [[String: Any]] = [], failPlanning: Bool = false,
                             originalParticipants: [OracleProfile] = []) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("execution-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory)
        var originalPlan = OraclePlan(intent: "课程安排", subject: "事件", methods: [method], requiredFields: [], note: "", question: "今天的课程安排如何？")
        if !originalParticipants.isEmpty { originalPlan.subject = originalParticipants.count > 1 ? "多人" : "他人" }
        originalPlan.castingProfile = castingSite()
        let initialProfile = CastingLocationDraft.applying(castingSite(), to: originalParticipants.first ?? OracleProfile())
        var input = OracleInput(question: originalPlan.question, profile: initialProfile,
                                castingDate: Date(timeIntervalSince1970: 1_730_000_000), seed: 42,
                                subject: originalPlan.subject, participants: originalParticipants)
        if method == .tarot {
            input.tarotDraws = zip(["major-00", "cups-01", "swords-14"], TarotDeck.positions).map {
                TarotDraw(cardID: $0.0, isReversed: false, position: $0.1)
            }
        } else if method == .liuyao { input.manualLines = [7, 8, 8, 7, 8, 7] }
        var result = OracleResult(method: method, headline: "原推演结果", rows: [])
        result.tarotDraws = input.tarotDraws
        let original = OracleRun(input: input, plan: originalPlan, results: [result],
                                 synthesis: .init(text: "原问题的解读。"), completedAt: input.castingDate)
        let reference = ChatMessage(role: .assistant, content: "原问题的解读。", kind: .reading, runID: original.id,
                                    resolvedQuestion: referenceQuestion)
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: original.input.question), reference])
        try vault.save([original], as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]), as: ConversationHistory.filename)
        var understanding: [String: Any] = ["relation": relation.rawValue, "resolvedQuestion": expanded,
            "referenceMessageID": invalid == "reference" ? UUID().uuidString : reference.id.uuidString,
            "execution": ["operation": invalid == "enum" ? "invalid" : operation, "coverage": coverage,
                          "evidence": invalid == "evidence" ? "并未说过的指令" : raw]]
        if invalid == "null" { understanding["execution"] = NSNull() }
        if operation == "legacy" { understanding.removeValue(forKey: "execution") }
        var proposal: [String: Any] = ["action": proposedAction, "intent": "课程安排", "subject": person == nil ? "事件" : "他人",
            "methods": methods.map(\.rawValue), "mandatoryMethods": mandatory.map(\.rawValue), "requiredFields": [],
            "note": "请核对资料。", "understanding": understanding]
        proposal["profileUpdates"] = plannedProfileUpdates
        if let person { proposal["participantIDs"] = [person.id.uuidString]; proposal["participantNames"] = [person.resolvedName] }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: proposal), as: UTF8.self)
        let key = UUID().uuidString
        ExecutionStoreURLProtocol.install(failPlanning ? "__isolated_offline__" : content, for: key)
        addTeardownBlock { ExecutionStoreURLProtocol.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExecutionStoreURLProtocol.self]
        let client = DeepSeekClient(accessToken: key, sessionConfiguration: configuration)
        let taskDirectory = directory.appendingPathComponent("isolated-task-tickets")
        let quotaEnds = AIQuotaTaskService(directory: taskDirectory,
            sessions: AccountSessionManager(vault: ExecutionEmptySessionVault()))
        return Fixture(store: OracleStore(vault: vault, bootstrapCredential: false, aiClient: client, quotaEndService: quotaEnds),
                       original: original, reference: reference, vault: vault, key: key, taskDirectory: taskDirectory)
    }

    private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while store.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy)
    }
}

private final class ExecutionEmptySessionVault: AccountSessionStorage {
    func load() throws -> AccountSession? { nil }
    func save(_ session: AccountSession) throws {}
    func delete() throws {}
}

private final class ExecutionStoreURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var plans: [String: String] = [:]
    private static var requests: [String: [String]] = [:]
    static func install(_ plan: String, for key: String) { lock.withLock { plans["Bearer " + key] = plan; requests["Bearer " + key] = [] } }
    static func remove(_ key: String) { lock.withLock { _ = plans.removeValue(forKey: "Bearer " + key); _ = requests.removeValue(forKey: "Bearer " + key) } }
    static func accepts(for key: String) -> [String] { lock.withLock { requests["Bearer " + key] ?? [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
        let plan = Self.lock.withLock { () -> String? in
            Self.requests[key, default: []].append(accept)
            return Self.plans[key]
        }
        if plan == "__isolated_offline__" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        guard let plan, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": accept]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let streamText = requestPurpose() == "synthesize" ? #"{"text":"隔离测试回答。"}"# : "隔离测试回答。"
        let body: [String: Any] = accept == "application/json"
            ? ["choices": [["message": ["content": plan], "finish_reason": "stop"]]]
            : ["choices": [["delta": ["content": streamText]]]]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return }
        if accept == "application/json" { client?.urlProtocol(self, didLoad: json) }
        else { client?.urlProtocol(self, didLoad: Data(("data: " + String(decoding: json, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    private func requestPurpose() -> String? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["purpose"] as? String
    }
    override func stopLoading() {}
}
