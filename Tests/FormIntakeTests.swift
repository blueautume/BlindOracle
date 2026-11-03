import XCTest
@testable import BlindOracle

final class FormIntakeTests: XCTestCase {
    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("form-intake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    private func person(_ name: String = "张三", date: String = "1995-01-02", time: String = "08:30") throws -> OracleProfile {
        let patch = ProfileUpdate(name: name, sex: "男", birthDate: date, birthTime: time, birthTimeZoneID: "Asia/Shanghai", birthPlace: "北京")
        return try XCTUnwrap(ProfileDirectory.applying([patch], to: []).profiles.first)
    }

    private func plan(_ methods: [OracleMethod], people: [OracleProfile] = [], strict: Bool = false) -> OraclePlan {
        var plan = OraclePlan(intent: "统一填写", subject: people.count > 1 ? "多人" : "事件", methods: methods, requiredFields: [], note: "", question: "接下来应该怎样安排？")
        plan.participantIDs = people.map(\.id)
        plan.participantNames = people.map(\.resolvedName)
        if strict { plan.mandatoryMethods = methods }
        return plan
    }

    @MainActor private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isBusy)
    }

    @MainActor func testNewQuestionOpensOneFormWithoutStartingAReadingOrQuestioningOneFieldAtATime() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let question = "只用八字看看我的事业"
        store.send(question)
        try await waitUntilIdle(store)
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.phase, .awaitingIntake)
        XCTAssertNil(store.pendingPlan?.requestedProfileID)
        XCTAssertTrue(store.pendingPlan?.requestedFields?.isEmpty ?? true)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.messages.filter { $0.kind == .intake }.count, 1)
    }

    @MainActor func testOneCompleteSubmissionStartsCalculationOnceWithoutASecondChatConfirmation() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = try person()
        store.pendingPlan = plan([.bazi], people: [person], strict: true)
        store.showIntake = true
        XCTAssertTrue(store.confirmGroupIntake(profiles: [person], numbers: [], save: true))
        XCTAssertEqual(store.phase, .calculating)
        XCTAssertFalse(store.showIntake)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.runs[0].input.readingParticipants.map(\.id), [person.id])
        XCTAssertEqual(store.runs[0].input.readingParticipants.first?.birthTimeText, "08:30")
        XCTAssertEqual(store.profiles.map(\.id), [person.id])
        XCTAssertFalse(store.confirmGroupIntake(profiles: [person], numbers: [], save: true))
        XCTAssertEqual(store.runs.count, 1)
    }

    @MainActor func testStrictMissingFieldsStayInTheFormAndReportEveryRequiredGapTogether() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "张三")], to: []).profiles.first)
        let pending = plan([.ziwei], people: [person], strict: true)
        store.pendingPlan = pending; store.showIntake = true
        XCTAssertFalse(store.confirmGroupIntake(profiles: [person], numbers: [], save: true))
        XCTAssertTrue(store.showIntake)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertNotNil(store.pendingPlan)
        let report = try XCTUnwrap(store.intakePreparationReport(for: [person]))
        let fields = Set(report.missing.flatMap(\.fields))
        XCTAssertTrue(fields.isSuperset(of: [.birthDate, .birthTime, .gender]))
        XCTAssertFalse(fields.contains(.birthTimeZone))
        let notice = try XCTUnwrap(store.intakeError)
        for field in fields { XCTAssertTrue(notice.contains(field.title), "缺项必须一次完整告知：\(field.title)") }
    }

    @MainActor func testSavedAnonymousProfileKeepsItsCodeAndCanClearAnAlias() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let blank = OracleProfile()
        let code = blank.participantLabel
        XCTAssertEqual(code.count, 4)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        store.saveProfile(blank)

        let reopened = OracleStore(vault: vault, bootstrapCredential: false)
        var profile = try XCTUnwrap(reopened.profiles.first)
        XCTAssertEqual(profile.id, blank.id)
        XCTAssertEqual(profile.participantLabel, code)
        XCTAssertTrue(profile.resolvedName.isEmpty)
        XCTAssertNil(reopened.selfProfileID)
        profile.alias = "朋友 A"
        reopened.saveProfile(profile)
        XCTAssertEqual(reopened.profiles.first?.participantLabel, "朋友 A")
        profile.alias = nil
        reopened.saveProfile(profile)
        XCTAssertEqual(reopened.profiles.first?.participantLabel, code)
    }

    @MainActor func testAliasCollisionRequiresAnExplicitProfileSelection() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let named = try person(), anonymous = OracleProfile(alias: "张三")
        store.saveProfile(named); store.saveProfile(anonymous)
        var pending = plan([.tarot])
        pending.participantNames = ["张三"]
        XCTAssertTrue(store.defaultParticipants(for: pending).isEmpty)
        pending.participantIDs = [anonymous.id]
        XCTAssertEqual(store.defaultParticipants(for: pending).map(\.id), [anonymous.id])
    }

    @MainActor func testAnonymousPairCanConfirmTarotWithoutBirthDataOrNames() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let first = OracleProfile(), second = OracleProfile(alias: "同事")
        store.pendingPlan = plan([.tarot], people: [first, second], strict: true)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [first, second], numbers: [], save: false))
        let pending = try XCTUnwrap(store.pendingInteraction)
        XCTAssertEqual(pending.requests.map(\.kind), [.tarot])
        XCTAssertEqual(pending.input.readingParticipants.map(\.id), [first.id, second.id])
        XCTAssertEqual(pending.plan.participantNames, [first.participantLabel, "同事"])
        XCTAssertTrue(store.profiles.isEmpty)
    }

    @MainActor func testMissingBirthFactsCanUseANonPersonalMethodWithoutInventingBirthData() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = OracleProfile(alias: "邻居")
        store.pendingPlan = plan([.bazi], people: [person])
        XCTAssertTrue(store.confirmGroupIntake(profiles: [person], numbers: [], save: false))
        try await waitUntilIdle(store)
        let ordinary = try XCTUnwrap(store.runs.last)
        XCTAssertEqual(ordinary.plan.methods, [.xiaoliuren])
        XCTAssertEqual(ordinary.plan.omittedMethods?.map(\.method), [.bazi])
        XCTAssertNil(ordinary.input.readingParticipants.first?.birthDate)

        store.pendingPlan = plan([.bazi], people: [person], strict: true)
        XCTAssertFalse(store.confirmGroupIntake(profiles: [person], numbers: [], save: false))
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [person], numbers: [], save: false, useLocalFallback: true))
        try await waitUntilIdle(store)
        let explicit = try XCTUnwrap(store.runs.last)
        XCTAssertEqual(explicit.plan.methods, [.xiaoliuren])
        XCTAssertNil(explicit.input.readingParticipants.first?.birthDate)

        let group = plan([.bazi], people: [person, OracleProfile()], strict: true)
        store.pendingPlan = group
        XCTAssertFalse(store.confirmGroupIntake(profiles: [person], numbers: [], save: false, useLocalFallback: true))
        XCTAssertEqual(store.pendingPlan?.mandatoryMethods, [.bazi])
        XCTAssertEqual(store.pendingPlan?.draftParticipants?.map(\.id), [person.id])
    }

    @MainActor func testMixedSubmissionSkipsUnavailablePersonalMethodAndPreservesItsExplanation() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "张三")], to: []).profiles.first)
        store.pendingPlan = plan([.bazi, .xiaoliuren], people: [person])
        store.showIntake = true
        XCTAssertTrue(store.confirmGroupIntake(profiles: [person], numbers: [], save: false))
        try await waitUntilIdle(store)
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.results.filter { $0.status == .complete || $0.status == .partial }.map(\.method), [.xiaoliuren])
        XCTAssertEqual(run.results.first { $0.method == .bazi }?.status, .unavailable)
        XCTAssertEqual(run.plan.omittedMethods?.map(\.method), [.bazi])
        XCTAssertTrue(run.plan.omittedMethods?.first?.reason.contains("出生") == true)
        XCTAssertTrue(run.synthesis?.text.contains("八字") == true)
        XCTAssertFalse(store.showIntake)
        XCTAssertNil(store.pendingPlan)
    }

    @MainActor func testUnifiedGroupSubmissionKeepsIndependentSnapshotsForEveryPerson() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let first = try person("张三"), second = try person("李四", date: "1998-03-04", time: "17:45")
        var pending = plan([.bazi], people: [first, second], strict: true)
        pending.relationship = "友情"
        store.pendingPlan = pending; store.showIntake = true
        XCTAssertTrue(store.confirmGroupIntake(profiles: [first, second], numbers: [], save: true))
        try await waitUntilIdle(store)
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.input.readingParticipants.map(\.id), [first.id, second.id])
        XCTAssertEqual(run.input.readingParticipants.map(\.birthTimeText), ["08:30", "17:45"])
        XCTAssertEqual(run.input.relationship, "友情")
        XCTAssertEqual(Set(run.results.compactMap(\.participantID)), [first.id, second.id])
        var edited = first; edited.birthTimeText = "09:15"
        store.saveProfile(edited)
        XCTAssertEqual(store.runs.first?.input.readingParticipants.first?.birthTimeText, "08:30")
    }

    @MainActor func testSavedLegacyFieldQuestionResumesAsOneFormWithoutStartingAutomatically() throws {
        let vault = try temporaryVault()
        let person = try person()
        var pending = plan([.bazi], people: [person], strict: true)
        pending.preparationStage = .collecting
        pending.requestedProfileID = person.id; pending.requestedFields = [.birthDate]
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: pending.question), ChatMessage(role: .assistant, content: "旧版逐项询问的内容。", kind: .intake)], pendingPlan: pending)
        try vault.save([person], as: "profiles")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]), as: ConversationHistory.filename)
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.pendingPlan?.question, pending.question)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
    }

    @MainActor func testFollowUpToASubmittedReadingNeverReopensTheForm() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = try person()
        store.pendingPlan = plan([.bazi], people: [person])
        XCTAssertTrue(store.confirmGroupIntake(profiles: [person], numbers: [], save: false))
        try await waitUntilIdle(store)
        let id = try XCTUnwrap(store.runs.first?.id)
        store.send("刚才这些建议具体是什么意思？")
        try await waitUntilIdle(store)
        XCTAssertFalse(store.showIntake)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.map(\.id), [id])
        XCTAssertEqual(store.messages.last?.runID, id)
    }

    @MainActor func testDeferredFormCanReopenWithoutStartingOrDuplicatingAnIntakeMessage() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.send("只用八字看看我的事业")
        try await waitUntilIdle(store)
        let question = store.pendingPlan?.question
        let count = store.messages.filter { $0.kind == .intake }.count
        store.showIntake = false
        store.confirmPendingIntake()
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.messages.filter { $0.kind == .intake }.count, count)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
    }

    @MainActor func testCancelledDraftRestoresEveryPersonAndNumbersAfterReopeningAndRelaunch() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        store.send("用梅花报数看看接下来的安排")
        try await waitUntilIdle(store)
        let person = try person()
        store.saveIntakeDraft(profiles: [person], numbers: [8, 8, 6], sessionID: store.intakeSessionID)
        store.showIntake = false
        store.confirmPendingIntake()
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.intakeParticipants.map(\.id), [person.id])
        XCTAssertEqual(store.intakeParticipants.first?.birthTimeText, "08:30")
        XCTAssertEqual(store.intakeNumbers, [8, 8, 6])
        XCTAssertTrue(store.runs.isEmpty)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertTrue(restarted.showIntake)
        XCTAssertEqual(restarted.intakeParticipants.map(\.id), [person.id])
        XCTAssertEqual(restarted.intakeNumbers, [8, 8, 6])
        XCTAssertTrue(restarted.runs.isEmpty)
    }

    @MainActor func testAcceptedProfileUpdateMergesIntoACancelledDraftWithoutLosingUnsavedFields() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let saved = try person()
        store.saveProfile(saved)
        store.pendingPlan = plan([.bazi], people: [saved], strict: true)
        var draft = saved; draft.birthPlace = "上海"
        store.saveIntakeDraft(profiles: [draft], numbers: [], sessionID: store.intakeSessionID)
        store.showIntake = false
        XCTAssertEqual(store.profiles.first { $0.id == saved.id }?.birthPlace, "北京")
        let result = store.applyProfileUpdates([ProfileUpdate(id: saved.id, birthTime: "09:15")])
        XCTAssertEqual(result.appliedIDs, [saved.id])
        store.confirmPendingIntake()
        XCTAssertTrue(store.showIntake)
        let reopened = try XCTUnwrap(store.intakeParticipants.first)
        XCTAssertEqual(reopened.birthTimeText, "09:15")
        XCTAssertEqual(reopened.birthPlace, "上海")
        XCTAssertTrue(store.confirmGroupIntake(profiles: [reopened], numbers: [], save: true, sessionID: store.intakeSessionID))
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.id == saved.id }?.birthTimeText, "09:15")
        XCTAssertEqual(store.profiles.first { $0.id == saved.id }?.birthPlace, "上海")
        XCTAssertEqual(store.runs.first?.input.readingParticipants.first?.birthTimeText, "09:15")
        XCTAssertEqual(store.runs.first?.input.readingParticipants.first?.birthPlace, "上海")
    }

    @MainActor func testStaleFormSubmissionCannotStartOrOverwriteAnotherConversationsPreparation() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.send("只用八字看看我的事业")
        try await waitUntilIdle(store)
        let staleID = store.intakeSessionID
        store.newConversation()
        store.send("只用六爻看看明天是否出行")
        try await waitUntilIdle(store)
        let currentID = store.intakeSessionID
        let question = store.pendingPlan?.question
        let person = try person()
        XCTAssertNotEqual(staleID, currentID)
        store.saveIntakeDraft(profiles: [person], numbers: [1, 2, 3], sessionID: staleID)
        XCTAssertFalse(store.confirmGroupIntake(profiles: [person], numbers: [], save: true, sessionID: staleID))
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.intakeSessionID, currentID)
        XCTAssertTrue(store.showIntake)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.profiles.contains { $0.id == person.id })
    }

    @MainActor func testFormNumbersSatisfyTheNumberRequestWithoutAskingForThemAgainInChat() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        var pending = plan([.meihua])
        pending.interactions = [.init(method: .meihua, kind: .numbers)]
        store.pendingPlan = pending; store.showIntake = true
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [8, 8, 6], save: false))
        try await waitUntilIdle(store)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showIntake)
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.input.numbers, [8, 8, 6])
        XCTAssertEqual(run.results.first?.rows.first { $0.label == "所留数字" }?.value, "8、8、6")
    }

    @MainActor func testOneFormSubmissionStillRequiresTheUserToSelectAndRevealTarotCards() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.pendingPlan = plan([.tarot]); store.showIntake = true
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        XCTAssertFalse(store.showIntake)
        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .tarot)
        XCTAssertTrue(store.showInteraction)
        XCTAssertTrue(store.runs.isEmpty)
    }
}
