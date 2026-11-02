import XCTest
@testable import BlindOracle

final class ConversationalIntakeTests: XCTestCase {
    @MainActor func testChangingMethodWhileCollectingReplacesTheOldRequirementsAndStillWaitsForConfirmation() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let question = "只用八字看看我的事业"
        store.send(question)
        try await waitUntilIdle(store)
        XCTAssertFalse(store.canConfirmIntake)
        store.send("改成08:30")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.methods, [.bazi])
        XCTAssertEqual(store.pendingPlan?.question, question)
        store.send("改用塔罗")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.methods, [.tarot])
        XCTAssertEqual(store.pendingPlan?.mandatoryMethods, [.tarot])
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
    }

    func testNaturalConfirmationRequiresAnUnambiguousAffirmativeAnswer() {
        XCTAssertTrue(ConversationalIntake.isConfirmation("没有问题，开始解析。"))
        XCTAssertTrue(ConversationalIntake.isConfirmation("确认，开始"))
        XCTAssertFalse(ConversationalIntake.isConfirmation("没有问题吗？"))
        XCTAssertFalse(ConversationalIntake.isConfirmation("没问题，先别开始"))
        XCTAssertFalse(ConversationalIntake.isConfirmation("出生时间有问题，改成09:45"))
    }

    @MainActor func testDecliningAnotherPersonsDetailsCanConfirmSharedEventOnly() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.send("我们这次合作关系如何安排")
        try await waitUntilIdle(store)
        store.send("张三")
        try await waitUntilIdle(store)
        store.send("不想提供")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertEqual(store.pendingPlan?.reviewedParticipants?.count, 0)
        store.confirmPendingIntake()
        XCTAssertNotNil(store.pendingInteraction)
        XCTAssertNil(store.pendingPlan)
        XCTAssertFalse(store.pendingInteraction?.plan.methods.contains(where: \.usesPersonalProfile) ?? true)
    }

    func testScopedDateAnswerCanIncludeChineseClockAndExplicitBeijingTime() throws {
        let person = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "张三")], to: []).profiles.first)
        var plan = OraclePlan(intent: "核对资料", subject: "本人", methods: [.bazi], requiredFields: [], note: "", question: "事业")
        plan.requestedProfileID = person.id; plan.requestedFields = [.birthDate]
        let answer = ConversationalIntake.answer("1995年1月2日早上八点半，北京时间", plan: plan, profiles: [person])
        let saved = try XCTUnwrap(ProfileDirectory.applying(answer.updates, to: [person]).profiles.first)
        XCTAssertEqual(saved.birthDateText, "1995-01-02")
        XCTAssertEqual(saved.birthTimeText, "08:30")
        XCTAssertEqual(saved.birthTimeZoneID, "Asia/Shanghai")
        XCTAssertEqual(saved.sex, "未提供")
    }

    @MainActor func testExplicitNameAnswerDoesNotCreateAPersonCalledWoJiaoZhangSan() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.send("只用八字看看我的事业")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.requestedFields, [.name])
        store.send("我叫张三")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.map(\.resolvedName), ["张三"])
        XCTAssertEqual(store.pendingPlan?.participantIDs, store.profiles.map(\.id))
    }

    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-intake-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    private func namedPerson() throws -> OracleProfile {
        try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "张三")], to: []).profiles.first)
    }

    private func personWithBirth(_ name: String, date: String = "1995-01-02", time: String? = "08:30") throws -> OracleProfile {
        let update = ProfileUpdate(name: name, sex: "男", birthDate: date, birthTime: time,
                                   birthTimeZoneID: "Asia/Shanghai", birthPlace: "北京")
        return try XCTUnwrap(ProfileDirectory.applying([update], to: []).profiles.first)
    }

    @MainActor private func awaiting(_ field: OracleField, for person: OracleProfile, in store: OracleStore) -> String {
        let question = "只用八字看看\(person.resolvedName)的事业"
        var plan = OraclePlan(intent: "事业安排", subject: "他人", methods: [.bazi], requiredFields: [],
                              note: "", question: question)
        plan.participantIDs = [person.id]
        plan.mandatoryMethods = [.bazi]
        plan.preparationStage = .collecting
        plan.requestedProfileID = person.id
        plan.requestedFields = [field]
        store.pendingPlan = plan
        store.phase = .awaitingIntake
        store.messages = [ChatMessage(role: .user, content: question),
                          ChatMessage(role: .assistant, content: "请补充\(person.resolvedName)的\(field.title)。", kind: .intake)]
        return question
    }

    @MainActor private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isBusy)
    }

    @MainActor private func completeRequestedInteractions(_ store: OracleStore) {
        for _ in 0..<6 {
            guard let session = store.pendingInteraction, let request = session.currentRequest else { return }
            let response: OracleInteractionResponse
            switch request.kind {
            case .coins: response = .init(requestID: request.id, lines: [7, 7, 7, 7, 7, 7])
            case .numbers: response = .init(requestID: request.id, numbers: [8, 8, 6])
            case .tarot:
                let draws = zip(["major-00", "cups-01", "swords-14"], TarotDeck.positions).map {
                    TarotDraw(cardID: $0.0, isReversed: false, position: $0.1)
                }
                response = .init(requestID: request.id, tarotDraws: draws, revealedCount: 3)
            }
            store.completeInteraction(response, sessionID: session.id)
        }
        XCTFail("交互没有按当前步骤依次结束")
    }

    @MainActor func testReadySummaryCannotStartReadingUntilExplicitConfirmation() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.send("未来一周适合推进手头的计划吗？")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertEqual(store.pendingPlan?.preparationStage, .confirming)
        XCTAssertEqual(store.messages.last?.kind, .intake)
        XCTAssertFalse(store.showIntake)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertTrue(store.runs.isEmpty)

        store.confirmPendingIntake()
        completeRequestedInteractions(store)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.runs.first?.input.question, "未来一周适合推进手头的计划吗？")
    }

    @MainActor func testTarotWaitsForSummaryConfirmationBeforeShowingDrawInteraction() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.send("用塔罗看看这次选择有哪些启发")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showInteraction)
        XCTAssertTrue(store.runs.isEmpty)
        store.confirmPendingIntake()
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .tarot)
        XCTAssertTrue(store.showInteraction)
        XCTAssertTrue(store.runs.isEmpty)
    }

    @MainActor func testAnswerPreservesOriginalQuestionAndNeedsFreshSummaryConfirmation() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = try namedPerson()
        store.saveProfile(person)
        let question = "只用八字看看张三的事业"
        store.send(question)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.preparationStage, .collecting)
        XCTAssertFalse(store.canConfirmIntake)
        XCTAssertEqual(store.pendingPlan?.requestedProfileID, person.id)
        XCTAssertTrue((1...2).contains(store.pendingPlan?.requestedFields?.count ?? 0))
        store.send("张三，男，出生日期1995-01-02，出生时间08:30，出生时区Asia/Shanghai，出生地北京")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.preparationStage, .confirming)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertEqual(store.pendingPlan?.reviewedParticipants?.map(\.id), [person.id])
        XCTAssertEqual(store.pendingPlan?.reviewedParticipants?.first?.birthDateText, "1995-01-02")
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
        store.send("张三出生时间09:45")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.preparationStage, .confirming)
        XCTAssertEqual(store.pendingPlan?.reviewedParticipants?.first?.birthTimeText, "09:45")
        XCTAssertTrue(store.runs.isEmpty)
        store.send("确认，开始")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.runs.first?.input.question, question)
        XCTAssertEqual(store.runs.first?.input.participants?.first?.birthDateText, "1995-01-02")
        XCTAssertEqual(store.runs.first?.input.participants?.first?.birthTimeText, "09:45")
    }

    @MainActor func testStrictMethodWithExplicitlyUnknownRequiredDataReportsMissingDataAndDoesNotRun() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = try namedPerson()
        store.saveProfile(person)
        store.send("这次只用八字看看张三的事业")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.pendingPlan?.mandatoryMethods?.contains(.bazi) == true)
        store.send("张三出生日期不确定")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.profiles.first { $0.id == person.id }?.declaredUnknownFields?.contains(.birthDate) == true)
        XCTAssertFalse(store.canConfirmIntake)
        XCTAssertTrue(store.messages.last?.content.contains("出生日期") == true)
        store.confirmPendingIntake()
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertNotNil(store.pendingPlan)
    }

    @MainActor func testMixedReadingRecordsSkippedMethodsAndExplainsThemAfterConfirmation() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.saveProfile(try namedPerson())
        let question = "看看张三接下来的事业和近期安排如何"
        store.send(question)
        try await waitUntilIdle(store)
        store.send("张三出生日期不确定，出生时间不确定，出生时区不确定，出生地不确定，性别不确定")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertFalse(store.pendingPlan?.omittedMethods?.isEmpty ?? true)
        XCTAssertTrue(store.runs.isEmpty)
        store.confirmPendingIntake()
        completeRequestedInteractions(store)
        try await waitUntilIdle(store)
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertFalse(run.plan.omittedMethods?.isEmpty ?? true)
        let text = try XCTUnwrap(run.synthesis?.text)
        XCTAssertTrue(text.contains("未采用") || text.contains("跳过") || text.contains("未参与") || text.contains("无法通过"))
    }

    @MainActor func testPendingConfirmationSurvivesChatSwitchAndRelaunchWithoutStartingRun() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let question = "明天适合推进手头的安排吗？"
        store.send(question)
        try await waitUntilIdle(store)
        let conversationID = store.activeConversationID
        XCTAssertTrue(store.canConfirmIntake)
        store.newConversation()
        store.openConversation(conversationID)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertTrue(store.runs.isEmpty)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.activeConversationID, conversationID)
        XCTAssertEqual(restarted.pendingPlan?.question, question)
        XCTAssertEqual(restarted.pendingPlan?.preparationStage, .confirming)
        XCTAssertTrue(restarted.canConfirmIntake)
        XCTAssertFalse(restarted.showIntake)
        XCTAssertTrue(restarted.runs.isEmpty)
    }

    @MainActor func testCollectOnlyStatementSavesProfileWithoutCreatingConfirmationOrRun() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.send("姓名：张三，出生日期1995年1月2日")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.filter { $0.resolvedName == "张三" }.count, 1)
        XCTAssertNil(store.pendingPlan)
        XCTAssertFalse(store.canConfirmIntake)
        XCTAssertFalse(store.showIntake)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertTrue(store.runs.isEmpty)
    }

    @MainActor func testAmbiguousClockWaitsForPeriodAndPreservesHalfHourAndOriginalQuestion() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = try personWithBirth("张三", time: nil)
        store.saveProfile(person)
        let question = awaiting(.birthTime, for: person, in: store)
        store.send("8点半")
        try await waitUntilIdle(store)
        XCTAssertNil(store.profiles.first { $0.id == person.id }?.birthTimeText)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.preparationStage, .collecting)
        XCTAssertTrue(store.messages.last?.content.contains("上午") == true)
        XCTAssertFalse(store.canConfirmIntake)
        XCTAssertTrue(store.runs.isEmpty)

        store.send("早上")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.id == person.id }?.birthTimeText, "08:30")
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.preparationStage, .confirming)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertTrue(store.runs.isEmpty)
    }

    @MainActor func testScopedBirthdayAnswerCannotAssignExplicitSelfBirthdayToPendingOtherPerson() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let other = try personWithBirth("张三"), own = try personWithBirth("李四", date: "1996-03-04")
        store.saveProfile(other); store.saveProfile(own)
        store.selfProfileID = own.id
        let question = awaiting(.birthDate, for: other, in: store)
        store.send("我的生日1991-02-03")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.id == other.id }?.birthDate, other.birthDate)
        XCTAssertEqual(store.profiles.first { $0.id == other.id }?.birthDateText, "1995-01-02")
        XCTAssertEqual(store.profiles.first { $0.id == own.id }?.birthDateText, "1991-02-03")
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
    }

    @MainActor func testLibraryCorrectionAfterSummaryRequiresNewReviewAndCannotBeOverwrittenByConfirmation() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = try personWithBirth("张三")
        store.saveProfile(person)
        let question = "只用八字看看张三的事业"
        store.send(question)
        try await waitUntilIdle(store)
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertEqual(store.pendingPlan?.reviewedParticipants?.first?.birthDateText, "1995-01-02")

        let correction = ProfileDirectory.applying([ProfileUpdate(id: person.id, birthDate: "2001-02-03")], to: store.profiles)
        let updated = try XCTUnwrap(correction.profiles.first { $0.id == person.id })
        store.saveProfile(updated)
        let messageCount = store.messages.count
        store.confirmPendingIntake()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.profiles.first { $0.id == person.id }?.birthDateText, "2001-02-03")
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.reviewedParticipants?.first?.birthDateText, "2001-02-03")
        XCTAssertGreaterThan(store.messages.count, messageCount)
        XCTAssertEqual(store.messages.last?.kind, .intake)
        XCTAssertTrue(store.messages.last?.content.contains("2001-02-03") == true)
        XCTAssertTrue(store.canConfirmIntake)
    }

    @MainActor func testThreeNumbersCollectedInChatReachMeihuaBeforeCoinInteractionCompletes() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let question = "用梅花报数，看看这次出行如何安排"
        store.send(question)
        try await waitUntilIdle(store)
        XCTAssertTrue(store.canConfirmIntake)
        store.confirmPendingIntake()
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .numbers)
        XCTAssertFalse(store.showInteraction)
        XCTAssertTrue(store.runs.isEmpty)
        store.send("8，8，6")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .coins)
        XCTAssertEqual(store.pendingInteraction?.input.numbers, [8, 8, 6])
        XCTAssertTrue(store.showInteraction)
        completeRequestedInteractions(store)
        try await waitUntilIdle(store)
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.input.question, question)
        XCTAssertEqual(run.input.numbers, [8, 8, 6])
        let result = try XCTUnwrap(run.results.first { $0.method == .meihua })
        XCTAssertEqual(result.rows.first { $0.label == "所留数字" }?.value, "8、8、6")
        XCTAssertEqual(result.rows.first { $0.label == "本卦" }?.value, "坤为地")
    }
}
