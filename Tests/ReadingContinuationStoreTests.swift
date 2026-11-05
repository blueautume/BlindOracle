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
        run.synthesis = ReadingSynthesis(text: "先核对行程，再稳步推进。")
        run.completedAt = input.castingDate
        // LocalVault stores dates at ISO-8601 second precision. Start with that
        // persisted representation so comparisons still detect any later change.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OracleRun.self, from: encoder.encode(run))
    }

    private func personalFixture() async throws -> OracleRun {
        let merged = ProfileDirectory.applying([ProfileUpdate(name: "陈平", sex: "男", birthDate: "1992-06-15",
            birthTime: "08:30", birthTimeZoneID: "Asia/Shanghai", birthPlace: "上海",
            birthLatitude: 31.2304, birthLongitude: 121.4737)], to: [])
        var person = try XCTUnwrap(merged.profiles.first)
        person.currentTimeZoneID = "Asia/Shanghai"
        let question = "陈平接下来工作如何安排？"
        var plan = OraclePlan(intent: "工作安排", subject: "本人", methods: [.bazi, .xiaoliuren],
            requiredFields: [.birthDate, .birthTimeZone], note: "", question: question)
        plan.participantIDs = [person.id]; plan.participantNames = [person.resolvedName]
        let input = OracleInput(question: question, profile: person, castingDate: Date(timeIntervalSince1970: 1_730_000_000),
            seed: 73, subject: "本人", participants: [person])
        var bazi = try await BaziPlugin().calculate(input)
        bazi.participantID = person.id; bazi.participantName = person.resolvedName
        let immediate = try await XiaoliurenPlugin().calculate(input)
        XCTAssertTrue([OracleResultStatus.complete, .partial].contains(bazi.status))
        XCTAssertTrue([OracleResultStatus.complete, .partial].contains(immediate.status))
        var run = OracleRun(input: input, plan: plan, results: [bazi, immediate])
        run.synthesis = ReadingSynthesis(text: "先明确工作边界，再决定如何推进。")
        run.completedAt = input.castingDate
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OracleRun.self, from: encoder.encode(run))
    }

    private func eventFixture(method: OracleMethod = .meihua, person: OracleProfile? = nil) async throws -> OracleRun {
        let question = "今晚的运势如何？"
        let profile = person ?? OracleProfile()
        var plan = OraclePlan(intent: "今晚的安排", subject: person == nil ? "事件" : "本人", methods: [method],
            requiredFields: [], note: "", question: question)
        plan.participantIDs = person.map { [$0.id] } ?? []
        plan.participantNames = person.map { [$0.participantLabel] } ?? []
        let input = OracleInput(question: question, profile: profile,
            castingDate: Date(timeIntervalSince1970: 1_730_000_000), seed: 73, subject: plan.subject,
            participants: person.map { [$0] } ?? [])
        let results = await PluginRegistry().calculate(input, methods: [method]) { _ in }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.allSatisfy { [.complete, .partial].contains($0.status) })
        var run = OracleRun(input: input, plan: plan, results: results)
        run.synthesis = ReadingSynthesis(text: "先把今晚的安排交代清楚，再决定停留多久。")
        run.completedAt = input.castingDate
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OracleRun.self, from: encoder.encode(run))
    }

    private var methodActivationCases: [(OracleMethod, String)] {
        [(.bazi, "八字"), (.ziwei, "紫微斗数"), (.liuyao, "六爻"), (.meihua, "梅花易数"),
         (.qimen, "奇门遁甲"), (.xiaoliuren, "小六壬"), (.chenggu, "称骨"),
         (.xingming, "姓名五格"), (.astrology, "西方占星"), (.tarot, "塔罗牌")]
    }

    private func activationProfile() throws -> OracleProfile {
        var person = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "陈平", sex: "男",
            birthDate: "1992-06-15", birthTime: "08:30", birthTimeZoneID: "Asia/Shanghai", birthPlace: "上海",
            birthLatitude: 31.2304, birthLongitude: 121.4737)], to: []).profiles.first)
        person.familyName = "陈"; person.givenName = "平"
        person.currentTimeZoneID = "Asia/Shanghai"
        return person
    }

    @MainActor private func completeRequestedInteraction(_ method: OracleMethod, in store: OracleStore) throws -> [TarotDraw] {
        let session = try XCTUnwrap(store.pendingInteraction, "\(method) must request its actual user interaction")
        let request = try XCTUnwrap(session.currentRequest)
        XCTAssertEqual(session.requests.map(\.method), [method])
        let draws: [TarotDraw]
        let response: OracleInteractionResponse
        switch method {
        case .tarot:
            XCTAssertEqual(request.kind, .tarot)
            XCTAssertEqual(request.tarotPositions, TarotDeck.positions)
            XCTAssertNil(session.input.tarotDraws)
            draws = zip(session.availableTarotCards.prefix(3), request.tarotPositions).map { card, position in
                TarotDraw(cardID: card.id, isReversed: TarotDeck.isReversed(seed: session.seed, cardID: card.id), position: position)
            }
            response = .init(requestID: request.id, tarotDraws: draws, revealedCount: 3)
        case .liuyao:
            XCTAssertEqual(request.kind, .coins)
            draws = []
            response = .init(requestID: request.id, lines: [6, 7, 8, 9, 7, 8])
        default:
            XCTFail("Unexpected interaction for \(method)")
            return []
        }
        store.completeInteraction(response, sessionID: session.id)
        return draws
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
        for question in ["第二张牌为什么是逆位？", "能解释一下建议牌和现状牌的关系吗？", "不用补牌，只解释建议牌。", "什么情况下可以补牌？"] {
            try await assertContinues(question, in: store, original: original)
        }
        XCTAssertEqual(store.runs[0].input.tarotDraws, original.input.tarotDraws)
        XCTAssertEqual(store.runs[0].input.seed, 73)
    }

    @MainActor func testExplicitCardExplanationGoesStraightToTheSavedSpread() async throws {
        let original = try await fixture(.tarot)
        let store = try restoredStore(run: original, vault: temporaryVault())
        try await assertContinues("第二张牌为什么是逆位？", in: store, original: original)
        XCTAssertFalse(store.activities.contains { $0.text == "选择适用方法与所需资料" })
        XCTAssertNil(store.messages.last?.tarotClarificationOffer)
    }

    @MainActor func testNamedNewTopicStartsAnIndependentTarotSpread() async throws {
        let original = try await fixture(.tarot)
        let originalData = try snapshot(original)
        let store = try restoredStore(run: original, vault: temporaryVault())
        let question = "用塔罗看看我下周的面试会不会顺利"
        store.send(question)
        try await waitUntilIdle(store)

        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.methods, [.tarot])
        XCTAssertNil(store.pendingPlan?.baseRunID)
        XCTAssertTrue(store.showIntake)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.tarotPositions, TarotDeck.positions)
        XCTAssertNil(store.pendingInteraction?.input.tarotDraws)
        XCTAssertNil(store.pendingInteraction?.input.tarotClarificationRounds)
        XCTAssertEqual(try snapshot(store.runs[0]), originalData)
    }

    @MainActor func testSwitchingTopicsMidDrawPreservesTheExactPendingSpreadInHistory() async throws {
        let vault = try temporaryVault()
        var store = OracleStore(vault: vault, bootstrapCredential: false)
        store.send("只用塔罗看看我该不该接这份插画合作？")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        let oldConversation = store.activeConversationID
        let session = try XCTUnwrap(store.pendingInteraction)
        let request = try XCTUnwrap(session.currentRequest)
        let draws = zip(session.availableTarotCards.prefix(3), request.tarotPositions).map { card, position in
            TarotDraw(cardID: card.id, isReversed: TarotDeck.isReversed(seed: session.seed, cardID: card.id), position: position)
        }
        let draft = OracleInteractionResponse(requestID: request.id, tarotDraws: draws, revealedCount: 1)
        store.saveInteractionProgress(draft, sessionID: session.id)

        store.send("换个话题，周末去郊外有什么要留意的？只用小六壬。")
        try await waitUntilIdle(store)
        XCTAssertNotEqual(store.activeConversationID, oldConversation)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.pendingPlan?.methods, [.xiaoliuren])
        store.completeInteraction(.init(requestID: request.id, tarotDraws: draws, revealedCount: 3), sessionID: session.id)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        try await waitUntilIdle(store)
        XCTAssertEqual(store.latestRun?.results.map(\.method), [.xiaoliuren])

        store = OracleStore(vault: vault, bootstrapCredential: false)
        store.openConversation(oldConversation)
        XCTAssertEqual(store.pendingInteraction?.id, session.id)
        XCTAssertEqual(store.pendingInteraction?.draft, draft)
        XCTAssertNil(store.latestRun)
    }

    @MainActor func testChangingMethodBeforeConfirmationKeepsUnsavedPeopleAndRejectsTheOldForm() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.send("只用八字看看今年换工作的方向。")
        try await waitUntilIdle(store)
        let oldForm = store.intakeSessionID
        let question = try XCTUnwrap(store.pendingPlan?.question)
        let person = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "周文", sex: "女", birthDate: "1994-06-12",
            birthTime: "09:20", birthTimeZoneID: "Asia/Shanghai")], to: []).profiles.first)
        store.saveIntakeDraft(profiles: [person], numbers: [], sessionID: oldForm)
        store.send("换成紫微")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.question, question.replacingOccurrences(of: "八字", with: OracleMethod.ziwei.progressName))
        XCTAssertEqual(store.pendingPlan?.methods, [.ziwei])
        XCTAssertEqual(store.intakeParticipants.first?.id, person.id)
        XCTAssertEqual(store.intakeParticipants.first?.birthTimeText, person.birthTimeText)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNotEqual(store.intakeSessionID, oldForm)
        XCTAssertFalse(store.confirmGroupIntake(profiles: [person], numbers: [], save: false, sessionID: oldForm))

        var newPerson = OracleProfile(); newPerson.name = "王安"
        store.saveProfile(newPerson)
        store.send("改用塔罗看王安")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.question, "改用塔罗看王安")
        XCTAssertEqual(store.pendingPlan?.methods, [.tarot])
        XCTAssertEqual(store.intakeParticipants.map(\.id), [newPerson.id])
    }

    @MainActor func testAddingTarotToAPendingFormKeepsItsMethodsUntilThePersonChanges() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        var chen = OracleProfile(); chen.name = "陈平"
        var li = OracleProfile(); li.name = "李岚"
        store.saveProfile(chen); store.saveProfile(li)
        store.send("只用八字看看陈平今年的工作")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.methods, [.bazi])

        store.send("加上塔罗")
        try await waitUntilIdle(store)
        XCTAssertEqual(Set(store.pendingPlan?.methods ?? []), [.bazi, .tarot])
        XCTAssertEqual(store.intakeParticipants.map(\.id), [chen.id])

        store.send("再用塔罗看看李岚的感情")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.methods, [.tarot])
        XCTAssertEqual(store.pendingPlan?.mandatoryMethods, [.tarot])
        XCTAssertEqual(store.intakeParticipants.map(\.id), [li.id])
        XCTAssertFalse(store.pendingPlan?.requiredFields.contains(.birthDate) ?? true)
        XCTAssertNil(store.pendingPlan?.baseRunID)
    }

    @MainActor func testSwitchingPersonAndThenAskingAboutBothUsesTheRightBirthCharts() async throws {
        let original = try await personalFixture()
        let originalData = try snapshot(original)
        let store = try restoredStore(run: original, vault: temporaryVault())
        let own = original.input.profile
        let other = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "李岚", sex: "女", birthDate: "1995-03-11",
            birthTime: "14:00", birthTimeZoneID: "Asia/Shanghai", birthPlace: "北京",
            birthLatitude: 39.9, birthLongitude: 116.4)], to: []).profiles.first)
        store.saveProfile(own); store.saveProfile(other); store.selfProfileID = own.id

        store.send("不看陈平了，换成李岚的工作怎么样？这次只用八字。")
        try await waitUntilIdle(store)
        XCTAssertNil(store.pendingPlan?.baseRunID)
        XCTAssertEqual(store.intakeParticipants.map(\.id), [other.id])
        XCTAssertTrue(store.confirmGroupIntake(profiles: store.intakeParticipants, numbers: [], save: false))
        try await waitUntilIdle(store)
        let second = try XCTUnwrap(store.latestRun)
        XCTAssertEqual(second.results.map(\.participantID), [other.id])
        XCTAssertTrue(second.reusedResultIDs?.isEmpty ?? true)
        XCTAssertEqual(try snapshot(store.runs[0]), originalData)

        store.send("那我和李岚适合合伙吗？也只用八字。")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.subject, "多人")
        XCTAssertNil(store.pendingPlan?.baseRunID)
        XCTAssertEqual(Set(store.intakeParticipants.map(\.id)), [own.id, other.id])
        XCTAssertTrue(store.confirmGroupIntake(profiles: store.intakeParticipants, numbers: [], save: false))
        try await waitUntilIdle(store)
        XCTAssertEqual(Set(store.latestRun?.results.compactMap(\.participantID) ?? []), [own.id, other.id])
        XCTAssertEqual(store.runs.count, 3)
    }

    @MainActor func testMixedQuestionAndSelfBirthdayUpdateStayWithSeparatePeople() async throws {
        let original = try await personalFixture()
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let other = original.input.profile
        let own = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "李岚", birthDate: "1995-03-11")], to: []).profiles.first)
        store.saveProfile(own); store.saveProfile(other); store.selfProfileID = own.id
        store.send("只用八字看看陈平的工作怎么样？我的生日是1990年1月2日。")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.id == own.id }?.birthDateText, "1990-01-02")
        XCTAssertEqual(store.profiles.first { $0.id == other.id }?.birthDate, other.birthDate)
        XCTAssertEqual(store.intakeParticipants.map(\.id), [other.id])
        XCTAssertTrue(store.runs.isEmpty)
    }

    @MainActor func testAnUnsavedColleagueNeverDefaultsToTheBoundSelfProfile() async throws {
        let original = try await personalFixture()
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let own = original.input.profile
        store.saveProfile(own); store.selfProfileID = own.id
        store.send("只用八字看看我同事王安的事业。")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.subject, "他人")
        XCTAssertFalse(store.intakeParticipants.contains { $0.id == own.id })
        XCTAssertTrue(store.runs.isEmpty)
    }

    @MainActor func testSharedTripAndPlainAcademicTopicSwitchStartIndependentEventReadings() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.send("只用小六壬看看我们两人周末坐高铁出行要注意什么？")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.intakeParticipants.isEmpty)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        try await waitUntilIdle(store)
        let trip = try XCTUnwrap(store.latestRun)
        XCTAssertEqual(trip.results.map(\.method), [.xiaoliuren])

        store.send("我考研初试该怎么安排复习？只用梅花易数。")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.methods, [.meihua])
        XCTAssertNil(store.pendingPlan?.baseRunID)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        try await waitUntilIdle(store)
        let study = try XCTUnwrap(store.latestRun)
        XCTAssertNotEqual(study.id, trip.id)
        XCTAssertEqual(study.results.map(\.method), [.meihua])
        XCTAssertEqual(store.runs.count, 2)
    }

    @MainActor func testMovingBudgetAndPenNameRouteToIndependentMethods() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let scenarios: [(String, OracleMethod)] = [
            ("只用奇门看看下个月搬家怎么安排交接。", .qimen),
            ("换个问题，只用梅花易数看看我该先核对哪笔日常开销。", .meihua),
            ("周文这个名字当笔名怎么样？只用姓名五格。", .xingming)
        ]
        let person = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "周文", familyName: "周", givenName: "文")], to: []).profiles.first)
        store.saveProfile(person)
        for (question, method) in scenarios {
            store.send(question)
            try await waitUntilIdle(store)
            XCTAssertEqual(store.pendingPlan?.methods, [method])
            XCTAssertNil(store.pendingPlan?.baseRunID)
            let people = method == .xingming ? store.intakeParticipants : []
            if method == .xingming { XCTAssertEqual(people.map(\.id), [person.id]) }
            XCTAssertTrue(store.confirmGroupIntake(profiles: people, numbers: [], save: false))
            try await waitUntilIdle(store)
            XCTAssertEqual(store.latestRun?.results.map(\.method), [method])
        }
        XCTAssertEqual(store.runs.count, scenarios.count)
    }

    @MainActor func testTarotClarificationsResumeAndReuseOtherMethodsThroughTheRoundLimit() async throws {
        var original = try await fixture(.tarot)
        let otherResult = try await XiaoliurenPlugin().calculate(original.input)
        original.plan.methods.append(.xiaoliuren)
        original.results.append(otherResult)
        let vault = try temporaryVault()
        var store = try restoredStore(run: original, vault: vault)
        var expected = try XCTUnwrap(original.input.tarotDraws)
        for index in 0..<2 {
            store.send(index == 0 ? "帮我补抽一张，出行最大的阻碍" : "再抽一张看看应优先确认什么")
            let session = try XCTUnwrap(store.pendingInteraction)
            let request = try XCTUnwrap(session.currentRequest)
            let card = try XCTUnwrap(session.availableTarotCards.first)
            XCTAssertEqual(session.availableTarotCards.count, 78 - expected.count)
            XCTAssertFalse(expected.contains { $0.cardID == card.id })
            let draw = TarotDraw(cardID: card.id, isReversed: TarotDeck.isReversed(seed: session.seed, cardID: card.id),
                                 position: try XCTUnwrap(request.tarotPositions.first))
            let response = OracleInteractionResponse(requestID: request.id, tarotDraws: [draw], revealedCount: 1)
            store.saveInteractionProgress(response, sessionID: session.id)
            store = OracleStore(vault: vault, bootstrapCredential: false)
            XCTAssertEqual(store.pendingInteraction?.draft, response)
            store.cancelTarotClarification(sessionID: session.id)
            XCTAssertNotNil(store.pendingInteraction)
            store.completeInteraction(response, sessionID: session.id)
            try await waitUntilIdle(store)
            let run = try XCTUnwrap(store.latestRun)
            expected.append(draw)
            XCTAssertEqual(run.input.tarotDraws, original.input.tarotDraws)
            XCTAssertEqual(run.input.tarotClarificationRounds?.map(\.draw), Array(expected.dropFirst(3)))
            XCTAssertEqual(run.results.first { $0.method == .xiaoliuren }?.id, otherResult.id)
            XCTAssertEqual(run.results.first { $0.method == .tarot }?.evidence.count, expected.count)
            XCTAssertEqual(run.input.seed, original.input.seed)
        }
        let last = try XCTUnwrap(store.latestRun)
        store.send("补一张")
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.count, 3)
        XCTAssertTrue(store.messages.last?.content.contains("五张") == true)
        store.retrySynthesis(last)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.latestRun?.input.tarotClarificationRounds, last.input.tarotClarificationRounds)
        XCTAssertEqual(store.runs.count, 3)
        store.send("重新抽")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.tarotPositions.count, 3)
        XCTAssertNil(store.pendingInteraction?.input.tarotDraws)
        XCTAssertNil(store.pendingInteraction?.input.tarotClarificationRounds)
        XCTAssertEqual(store.runs.count, 3)
    }

    @MainActor func testTarotClarificationOfferRequiresConfirmationAndInterruptedCommitKeepsDraw() async throws {
        let original = try await fixture(.tarot)
        let vault = try temporaryVault()
        let store = try restoredStore(run: original, vault: vault)
        store.messages.append(ChatMessage(role: .user, content: "怎样降低出行阻力？"))
        let offer = ChatMessage(role: .assistant, content: "先核对行程。", runID: original.id,
                                tarotClarificationOffer: .init(focus: "最大阻力", originalPosition: TarotDeck.positions[1]))
        store.messages.append(offer)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.tarotClarificationOffer(for: offer)?.focus, "最大阻力")
        store.acceptTarotClarification(messageID: offer.id)
        let session = try XCTUnwrap(store.pendingInteraction)
        let request = try XCTUnwrap(session.currentRequest)
        XCTAssertEqual(session.plan.followUpQuestion, "怎样降低出行阻力？")
        XCTAssertEqual(request.tarotClarification?.question, "怎样降低出行阻力？")
        let card = try XCTUnwrap(session.availableTarotCards.first)
        let draw = TarotDraw(cardID: card.id, isReversed: TarotDeck.isReversed(seed: session.seed, cardID: card.id),
                             position: try XCTUnwrap(request.tarotPositions.first))
        let response = OracleInteractionResponse(requestID: request.id, tarotDraws: [draw], revealedCount: 1)
        store.saveInteractionProgress(response, sessionID: session.id)
        let pendingArchive = try XCTUnwrap(vault.load(OracleConversationArchive?.self, from: ConversationHistory.filename, fallback: nil))
        store.completeInteraction(response, sessionID: session.id)
        try await waitUntilIdle(store)

        // A process exit after writing readings, before updating the transcript or calculating Tarot.
        var saved = try XCTUnwrap(store.latestRun)
        saved.results = []; saved.synthesis = nil; saved.completedAt = nil
        try vault.save([original, saved], as: "readings")
        try vault.save(pendingArchive, as: ConversationHistory.filename)
        let restored = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertNil(restored.pendingInteraction)
        XCTAssertEqual(restored.latestRun?.id, saved.id)
        XCTAssertEqual(restored.messages.last?.kind, .reading)
        restored.retrySynthesis(saved)
        try await waitUntilIdle(restored)
        XCTAssertEqual(restored.latestRun?.input.tarotClarificationRounds?.first?.draw, draw)
        XCTAssertEqual(restored.latestRun?.results.first { $0.method == .tarot }?.evidence.count, 4)
        XCTAssertEqual(restored.runs.count, 2)
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
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.pendingPlan?.methods, [.liuyao])
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.map(\.id), [original.id])
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
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
        XCTAssertTrue(store.showIntake)
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
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.pendingPlan?.question, original.input.question)
        XCTAssertEqual(store.pendingPlan?.methods, [.liuyao])
        XCTAssertEqual(store.pendingPlan?.subject, original.plan.subject)
        XCTAssertEqual(store.runs.map(\.id), [original.id])
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
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
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.pendingPlan?.question, original.input.question)
        XCTAssertEqual(store.pendingPlan?.methods, [.liuyao])
        XCTAssertEqual(store.pendingPlan?.participantIDs, original.plan.participantIDs)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertTrue(store.confirmGroupIntake(profiles: store.profiles.filter { original.plan.participantIDs?.contains($0.id) == true }, numbers: [], save: true))
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

    @MainActor func testAddingAnImmediateMethodCopiesExistingResultsAndRepeatedRequestsReuseTheMergedRun() async throws {
        for method in [OracleMethod.liuyao, .tarot] {
            let original = try await fixture(method)
            let originalData = try snapshot(original)
            let vault = try temporaryVault()
            let store = try restoredStore(run: original, vault: vault)
            let question = "加上小六壬看看"

            store.send(question)
            try await waitUntilIdle(store)

            XCTAssertEqual(store.runs.count, 2)
            let supplemented = try XCTUnwrap(store.runs.last)
            XCTAssertNotEqual(supplemented.id, original.id)
            XCTAssertEqual(supplemented.plan.baseRunID, original.id)
            XCTAssertEqual(supplemented.plan.followUpQuestion, question)
            XCTAssertEqual(supplemented.input.question, original.input.question)
            XCTAssertEqual(supplemented.input.seed, original.input.seed)
            XCTAssertEqual(supplemented.input.castingDate, original.input.castingDate)
            XCTAssertEqual(supplemented.input.manualLines, original.input.manualLines)
            XCTAssertEqual(supplemented.input.tarotDraws, original.input.tarotDraws)
            XCTAssertEqual(supplemented.input.interactionResponses, original.input.interactionResponses)
            XCTAssertEqual(supplemented.results.first { $0.method == method }?.id, original.results.first?.id)
            XCTAssertEqual(Set(supplemented.results.map(\.method)), [method, .xiaoliuren])
            XCTAssertEqual(Set(supplemented.reusedResultIDs ?? []), Set(original.results.map(\.id)))
            XCTAssertEqual(Set((supplemented.activities ?? []).compactMap(\.method)), [.xiaoliuren])
            XCTAssertEqual(try snapshot(store.runs[0]), originalData)
            XCTAssertNil(store.pendingPlan)
            XCTAssertNil(store.pendingInteraction)

            let restarted = OracleStore(vault: vault, bootstrapCredential: false)
            XCTAssertEqual(restarted.latestRun?.plan.baseRunID, original.id)
            XCTAssertEqual(restarted.latestRun?.plan.followUpQuestion, question)
            XCTAssertEqual(restarted.latestRun?.input.interactionResponses, original.input.interactionResponses)
            restarted.send("再用小六壬看看")
            try await waitUntilIdle(restarted)
            XCTAssertEqual(restarted.runs.map(\.id), [original.id, supplemented.id])
            XCTAssertEqual(restarted.messages.last?.runID, supplemented.id)
            XCTAssertEqual(try snapshot(restarted.runs[0]), originalData)
            XCTAssertEqual(restarted.runs[1].results.map(\.id), supplemented.results.map(\.id))
            XCTAssertEqual(restarted.runs[1].results.map(\.rows), supplemented.results.map(\.rows))
            XCTAssertNil(restarted.pendingPlan)
            XCTAssertNil(restarted.pendingInteraction)
        }
    }

    @MainActor func testAddingTarotResumesOnlyItsNewInteractionAndKeepsOriginalCoinResponse() async throws {
        let original = try await fixture(.liuyao)
        let originalData = try snapshot(original)
        let tarot = try await fixture(.tarot)
        let draws = try XCTUnwrap(tarot.input.tarotDraws)
        let vault = try temporaryVault()
        let store = try restoredStore(run: original, vault: vault)
        store.send("加上塔罗")
        try await waitUntilIdle(store)

        let session = try XCTUnwrap(store.pendingInteraction)
        XCTAssertEqual(session.plan.baseRunID, original.id)
        XCTAssertEqual(session.requests.map(\.kind), [.tarot])
        XCTAssertEqual(session.input.manualLines, original.input.manualLines)
        XCTAssertEqual(session.input.interactionResponses, original.input.interactionResponses)
        XCTAssertEqual(store.runs.map(\.id), [original.id])
        XCTAssertNil(store.pendingPlan)
        let draft = OracleInteractionResponse(requestID: "tarot", tarotDraws: Array(draws.prefix(1)), revealedCount: 0)
        store.saveInteractionProgress(draft, sessionID: session.id)

        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        let restored = try XCTUnwrap(restarted.pendingInteraction)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.requests.map(\.kind), [.tarot])
        XCTAssertEqual(restored.draft, draft)
        XCTAssertEqual(restored.input.manualLines, original.input.manualLines)
        let response = OracleInteractionResponse(requestID: "tarot", tarotDraws: draws, revealedCount: 3)
        restarted.completeInteraction(response, sessionID: restored.id)
        try await waitUntilIdle(restarted)

        XCTAssertEqual(restarted.runs.count, 2)
        let supplemented = try XCTUnwrap(restarted.runs.last)
        XCTAssertEqual(supplemented.results.first { $0.method == .liuyao }?.id, original.results.first?.id)
        XCTAssertEqual(Set((supplemented.activities ?? []).compactMap(\.method)), [.tarot])
        XCTAssertEqual(supplemented.input.seed, original.input.seed)
        XCTAssertEqual(supplemented.input.castingDate, original.input.castingDate)
        XCTAssertEqual(supplemented.input.tarotDraws, draws)
        XCTAssertEqual(supplemented.input.manualLines, original.input.manualLines)
        XCTAssertEqual(supplemented.input.interactionResponses?.count, 2)
        XCTAssertEqual(supplemented.input.interactionResponses?.first { $0.requestID == "liuyao" }, original.input.interactionResponses?.first)
        XCTAssertEqual(supplemented.input.interactionResponses?.first { $0.requestID == "tarot" }, response)
        XCTAssertEqual(try snapshot(restarted.runs[0]), originalData)
        XCTAssertNil(restarted.pendingInteraction)
    }

    @MainActor func testBareMethodSwitchAfterAReadingStartsOnlyTheRequestedNewInteraction() async throws {
        let original = try await fixture(.liuyao)
        let store = try restoredStore(run: original, vault: temporaryVault())
        store.send("改用塔罗")
        try await waitUntilIdle(store)
        let session = try XCTUnwrap(store.pendingInteraction)
        XCTAssertEqual(session.requests.map(\.kind), [.tarot])
        XCTAssertEqual(session.plan.baseRunID, original.id)
        XCTAssertEqual(session.input.question, original.input.question)
        XCTAssertEqual(session.input.manualLines, original.input.manualLines)
        XCTAssertEqual(store.runs.map(\.id), [original.id])
    }

    @MainActor func testScreenshotTarotRequestsActuallyDrawCardsAfterAMeihuaReading() async throws {
        for question in ["你再用塔罗牌再试试呢？", "用塔罗牌计算今晚的运势"] {
            let original = try await eventFixture()
            let originalData = try snapshot(original)
            let store = try restoredStore(run: original, vault: temporaryVault())
            store.send(question)
            try await waitUntilIdle(store)

            if let pending = store.pendingPlan {
                XCTAssertTrue(pending.methods.contains(.tarot), question)
                XCTAssertTrue(store.confirmGroupIntake(profiles: store.intakeParticipants, numbers: [], save: false), question)
                try await waitUntilIdle(store)
            }
            XCTAssertEqual(store.runs.map(\.id), [original.id], question)
            let draws = try completeRequestedInteraction(.tarot, in: store)
            try await waitUntilIdle(store)

            let run = try XCTUnwrap(store.runs.last)
            XCTAssertNotEqual(run.id, original.id, question)
            let result = try XCTUnwrap(run.results.first { $0.method == .tarot }, question)
            XCTAssertTrue([.complete, .partial].contains(result.status), question)
            XCTAssertEqual(run.input.tarotDraws, draws, question)
            XCTAssertEqual(result.tarotDraws, draws, question)
            XCTAssertEqual(store.messages.last?.runID, run.id, question)
            XCTAssertEqual(try snapshot(store.runs[0]), originalData, question)
            XCTAssertNil(store.pendingInteraction, question)
            XCTAssertNil(store.pendingPlan, question)
        }
    }

    @MainActor func testAllTenMethodsActivateFromNaturalRetryRequestsAndProduceTheirOwnResults() async throws {
        let person = try activationProfile()
        XCTAssertEqual(Set(methodActivationCases.map(\.0)), Set(OracleMethod.allCases))

        for (method, name) in methodActivationCases {
            let baseMethod: OracleMethod = method == .meihua ? .xiaoliuren : .meihua
            let original = try await eventFixture(method: baseMethod, person: person)
            let originalData = try snapshot(original)
            let store = try restoredStore(run: original, vault: temporaryVault())
            store.saveProfile(original.input.profile)
            let question = "再用\(name)再试试呢？"
            store.send(question)
            try await waitUntilIdle(store)

            if let pending = store.pendingPlan {
                XCTAssertTrue(pending.methods.contains(method), question)
                XCTAssertTrue(store.confirmGroupIntake(profiles: store.intakeParticipants, numbers: [], save: false), question)
                try await waitUntilIdle(store)
            }
            let draws: [TarotDraw]
            if method == .tarot || method == .liuyao {
                XCTAssertEqual(store.runs.map(\.id), [original.id], question)
                draws = try completeRequestedInteraction(method, in: store)
                try await waitUntilIdle(store)
            } else {
                draws = []
                XCTAssertNil(store.pendingInteraction, question)
            }

            XCTAssertEqual(store.runs.count, 2, question)
            let run = try XCTUnwrap(store.runs.last)
            XCTAssertNotEqual(run.id, original.id, question)
            let result = try XCTUnwrap(run.results.first { $0.method == method }, question)
            XCTAssertTrue([.complete, .partial].contains(result.status), question)
            XCTAssertFalse(result.rows.isEmpty, question)
            XCTAssertTrue(Set(run.results.map(\.method)).isSubset(of: [baseMethod, method]), question)
            if method == .tarot { XCTAssertEqual(result.tarotDraws, draws, question) }
            if method == .liuyao { XCTAssertEqual(run.input.manualLines, [6, 7, 8, 9, 7, 8], question) }
            XCTAssertEqual(store.messages.last?.runID, run.id, question)
            XCTAssertEqual(try snapshot(store.runs[0]), originalData, question)
            XCTAssertNil(store.pendingPlan, question)
            XCTAssertNil(store.pendingInteraction, question)
        }
    }

    @MainActor func testFirstNamedCalculationRunsOnlyTheRequestedMethodAcrossAllTenMethods() async throws {
        let person = try activationProfile()
        XCTAssertEqual(Set(methodActivationCases.map(\.0)), Set(OracleMethod.allCases))
        for (method, name) in methodActivationCases {
            let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
            store.saveProfile(person)
            store.selfProfileID = person.id
            let question = "用\(name)计算今晚的运势"
            store.send(question)
            try await waitUntilIdle(store)

            let plan = try XCTUnwrap(store.pendingPlan, question)
            XCTAssertEqual(plan.methods, [method], question)
            XCTAssertEqual(plan.mandatoryMethods, [method], question)
            XCTAssertNil(plan.baseRunID, question)
            XCTAssertTrue(store.showIntake, question)
            XCTAssertTrue(store.runs.isEmpty, question)
            XCTAssertNil(store.pendingInteraction, question)
            let descriptor = try XCTUnwrap(store.registry.descriptors.first { $0.method == method })
            XCTAssertTrue(Set(plan.requiredFields).isSubset(of: Set(descriptor.requiredFields + descriptor.optionalFields)), question)
            if !method.usesPersonalProfile {
                XCTAssertTrue(plan.requiredFields.isEmpty, "\(question) must not ask for unrelated birth details")
            }
            XCTAssertEqual(OracleInteractionPolicy.requests(for: plan).map(\.method),
                method == .tarot || method == .liuyao ? [method] : [], question)
            let participants = method.usesPersonalProfile ? store.intakeParticipants : []
            if method.usesPersonalProfile { XCTAssertEqual(participants.map(\.id), [person.id], question) }
            XCTAssertTrue(store.confirmGroupIntake(profiles: participants, numbers: [], save: false), question)
            try await waitUntilIdle(store)

            let draws: [TarotDraw]
            if method == .tarot || method == .liuyao {
                XCTAssertTrue(store.runs.isEmpty, question)
                draws = try completeRequestedInteraction(method, in: store)
                try await waitUntilIdle(store)
            } else {
                draws = []
                XCTAssertNil(store.pendingInteraction, question)
            }
            XCTAssertEqual(store.runs.count, 1, question)
            let run = try XCTUnwrap(store.latestRun, question)
            XCTAssertEqual(run.plan.methods, [method], question)
            XCTAssertEqual(run.results.map(\.method), [method], question)
            let result = try XCTUnwrap(run.results.first, question)
            XCTAssertTrue([.complete, .partial].contains(result.status), question)
            XCTAssertFalse(result.rows.isEmpty, question)
            if method == .tarot { XCTAssertEqual(result.tarotDraws, draws, question) }
            else { XCTAssertNil(run.input.tarotDraws, question) }
            if method == .liuyao { XCTAssertEqual(run.input.manualLines, [6, 7, 8, 9, 7, 8], question) }
            else { XCTAssertTrue(run.input.manualLines.isEmpty, question) }
            XCTAssertEqual(store.messages.last?.runID, run.id, question)
            XCTAssertNil(store.pendingPlan, question)
            XCTAssertNil(store.pendingInteraction, question)
        }
    }

    @MainActor func testPersonalMethodRetryRequestsOpenIntakeWhenRequiredDetailsAreMissing() async throws {
        for (method, name) in methodActivationCases where method.usesPersonalProfile {
            var person = OracleProfile(); person.name = "陈平"
            let original = try await eventFixture(person: person)
            let originalData = try snapshot(original)
            let store = try restoredStore(run: original, vault: temporaryVault())
            store.saveProfile(original.input.profile)
            let question = "再用\(name)再试试呢？"
            store.send(question)
            try await waitUntilIdle(store)

            let pending = try XCTUnwrap(store.pendingPlan, question)
            XCTAssertTrue(pending.methods.contains(method), question)
            XCTAssertTrue(store.showIntake, question)
            XCTAssertNil(store.pendingInteraction, question)
            XCTAssertEqual(store.runs.map(\.id), [original.id], question)
            let report = try XCTUnwrap(store.intakePreparationReport(for: store.intakeParticipants), question)
            let assessment = try XCTUnwrap(report.assessments.first { $0.method == method }, question)
            XCTAssertFalse(assessment.canExecute, question)
            let expectedMissing: OracleField = method == .xingming ? .surname : .birthDate
            XCTAssertTrue(assessment.blocking.contains { $0.field == expectedMissing }, question)
            XCTAssertEqual(try snapshot(store.runs[0]), originalData, question)
        }
    }

    @MainActor func testBirthTimeCorrectionRecalculatesOnlyBaziAndKeepsTheImmediateResult() async throws {
        let original = try await personalFixture()
        let originalData = try snapshot(original)
        let store = try restoredStore(run: original, vault: temporaryVault())
        store.saveProfile(original.input.profile)
        store.send("陈平出生时间为10:30，按新资料看看")
        try await waitUntilIdle(store)

        XCTAssertEqual(store.runs.count, 2)
        let supplemented = try XCTUnwrap(store.runs.last)
        let originalBazi = try XCTUnwrap(original.results.first { $0.method == .bazi })
        let updatedBazi = try XCTUnwrap(supplemented.results.first { $0.method == .bazi })
        let originalImmediate = try XCTUnwrap(original.results.first { $0.method == .xiaoliuren })
        XCTAssertNotEqual(updatedBazi.id, originalBazi.id)
        XCTAssertNotEqual(updatedBazi.rows.first { $0.label == "时柱" }?.value, originalBazi.rows.first { $0.label == "时柱" }?.value)
        XCTAssertEqual(supplemented.results.first { $0.method == .xiaoliuren }?.id, originalImmediate.id)
        XCTAssertEqual(supplemented.reusedResultIDs, [originalImmediate.id])
        XCTAssertEqual(Set((supplemented.activities ?? []).compactMap(\.method)), [.bazi])
        XCTAssertEqual(supplemented.input.readingParticipants.first?.birthTimeText, "10:30")
        XCTAssertEqual(supplemented.input.seed, original.input.seed)
        XCTAssertEqual(supplemented.input.castingDate, original.input.castingDate)
        XCTAssertEqual(try snapshot(store.runs[0]), originalData)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
    }

    @MainActor func testAddingAMethodWithMissingBirthDataUsesTheFormWithoutAnotherCoinCast() async throws {
        var original = try await fixture(.liuyao)
        original.input.participants = [original.input.profile]
        original.plan.participantIDs = [original.input.profile.id]
        original.plan.participantNames = [original.input.profile.resolvedName]
        let originalData = try snapshot(original)
        let store = try restoredStore(run: original, vault: temporaryVault())
        store.saveProfile(original.input.profile)
        store.send("加上八字看看")
        try await waitUntilIdle(store)

        let pending = try XCTUnwrap(store.pendingPlan)
        XCTAssertEqual(pending.baseRunID, original.id)
        XCTAssertEqual(pending.followUpQuestion, "加上八字看看")
        XCTAssertTrue(store.showIntake)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.map(\.id), [original.id])
        XCTAssertTrue(store.intakePreparationReport(for: store.intakeParticipants)?.assessments.contains {
            $0.method == .bazi && $0.blocking.contains { $0.field == .birthDate }
        } ?? false)
        let people = ProfileDirectory.applying([ProfileUpdate(id: original.input.profile.id, birthDate: "1992-06-15",
            birthTime: "08:30", birthTimeZoneID: "Asia/Shanghai", birthPlace: "上海",
            birthLatitude: 31.2304, birthLongitude: 121.4737)], to: [original.input.profile]).profiles
        XCTAssertTrue(store.confirmGroupIntake(profiles: people, numbers: [], save: false))
        try await waitUntilIdle(store)

        XCTAssertEqual(store.runs.count, 2)
        let supplemented = try XCTUnwrap(store.runs.last)
        XCTAssertEqual(supplemented.results.first { $0.method == .liuyao }?.id, original.results.first?.id)
        XCTAssertEqual(Set((supplemented.activities ?? []).compactMap(\.method)), [.bazi])
        XCTAssertEqual(supplemented.input.manualLines, original.input.manualLines)
        XCTAssertEqual(supplemented.input.interactionResponses, original.input.interactionResponses)
        XCTAssertEqual(try snapshot(store.runs[0]), originalData)
        XCTAssertNil(store.pendingInteraction)
    }

    @MainActor func testDeletingTheBaseCancelsPendingSupplementAndRejectsItsStaleInteraction() async throws {
        let original = try await fixture(.liuyao)
        let tarot = try await fixture(.tarot)
        let vault = try temporaryVault()
        let store = try restoredStore(run: original, vault: vault)
        store.send("加上塔罗")
        try await waitUntilIdle(store)
        let session = try XCTUnwrap(store.pendingInteraction)
        XCTAssertEqual(session.plan.baseRunID, original.id)

        store.deleteReading(id: original.id)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showIntake)
        XCTAssertFalse(store.showInteraction)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(store.runs.isEmpty)
        store.completeInteraction(.init(requestID: "tarot", tarotDraws: try XCTUnwrap(tarot.input.tarotDraws), revealedCount: 3), sessionID: session.id)
        try await waitUntilIdle(store)
        XCTAssertTrue(store.runs.isEmpty)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertNil(restarted.pendingPlan)
        XCTAssertNil(restarted.pendingInteraction)
        XCTAssertTrue(restarted.runs.isEmpty)
    }

    @MainActor func testDeletingBaseCancelsQueuedPlanningForItsPendingSupplement() async throws {
        let original = try await fixture(.liuyao)
        let vault = try temporaryVault()
        let store = try restoredStore(run: original, vault: vault)
        store.send("加上八字")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.baseRunID, original.id)

        store.send("这部分想了解得更详细一些")
        XCTAssertTrue(store.isBusy)
        // Cancel before the queued main-actor planning task gets its first turn.
        store.deleteReading(id: original.id)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showIntake)
        XCTAssertFalse(store.showInteraction)
        XCTAssertTrue(store.runs.isEmpty)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertNil(restarted.pendingPlan)
        XCTAssertNil(restarted.pendingInteraction)
    }

    @MainActor func testCompletedSupplementRemainsSelfContainedAfterDeletingItsBase() async throws {
        let original = try await fixture(.liuyao)
        let vault = try temporaryVault()
        let store = try restoredStore(run: original, vault: vault)
        store.send("加上小六壬看看")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.count, 2)
        let supplemented = try XCTUnwrap(store.runs.last)
        let supplementedData = try snapshot(supplemented)

        store.deleteReading(id: original.id)
        XCTAssertEqual(store.runs.map(\.id), [supplemented.id])
        XCTAssertEqual(store.latestRun?.id, supplemented.id)
        XCTAssertEqual(try snapshot(store.runs[0]), supplementedData)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.latestRun?.id, supplemented.id)
        XCTAssertEqual(Set(restarted.runs[0].results.map(\.method)), [.liuyao, .xiaoliuren])
        XCTAssertEqual(restarted.runs[0].input.manualLines, original.input.manualLines)
        XCTAssertEqual(restarted.runs[0].input.interactionResponses, original.input.interactionResponses)
        let restoredSupplement = try XCTUnwrap(restarted.latestRun)
        try await assertContinues("这里的建议应该怎样落实？", in: restarted, original: restoredSupplement)
    }

    @MainActor func testNegatedMethodMentionContinuesTheOriginalTarotWithoutOpeningAForm() async throws {
        let original = try await fixture(.tarot)
        let originalData = try snapshot(original)
        let store = try restoredStore(run: original, vault: temporaryVault())

        try await assertContinues("不用八字，继续解释原结果", in: store, original: original)

        XCTAssertEqual(store.runs[0].results.map(\.method), [.tarot])
        XCTAssertEqual(try snapshot(store.runs[0]), originalData)
        XCTAssertEqual(store.phase, .idle)
    }

    @MainActor func testSupplementalMeihuaNumbersUseTheFormAndKeepTheExistingSixLines() async throws {
        let original = try await fixture(.liuyao)
        let originalData = try snapshot(original)
        let store = try restoredStore(run: original, vault: temporaryVault())
        let question = "补算梅花，我要报数"
        store.send(question)
        try await waitUntilIdle(store)

        let pending = try XCTUnwrap(store.pendingPlan)
        XCTAssertEqual(pending.baseRunID, original.id)
        XCTAssertEqual(pending.followUpQuestion, question)
        XCTAssertEqual(Set(pending.methods), [.liuyao, .meihua])
        XCTAssertTrue(OracleInteractionPolicy.requests(for: pending).contains { $0.method == .meihua && $0.kind == .numbers })
        XCTAssertTrue(store.showIntake)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.map(\.id), [original.id])

        let numbers = [13, 27, 41]
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: numbers, save: false))
        try await waitUntilIdle(store)

        XCTAssertEqual(store.runs.count, 2)
        let supplemented = try XCTUnwrap(store.runs.last)
        let meihua = try XCTUnwrap(supplemented.results.first { $0.method == .meihua })
        XCTAssertEqual(supplemented.plan.baseRunID, original.id)
        XCTAssertEqual(supplemented.input.numbers, numbers)
        XCTAssertEqual(supplemented.input.seed, original.input.seed)
        XCTAssertEqual(supplemented.input.castingDate, original.input.castingDate)
        XCTAssertEqual(supplemented.input.manualLines, original.input.manualLines)
        XCTAssertEqual(supplemented.input.interactionResponses, original.input.interactionResponses)
        XCTAssertEqual(supplemented.results.first { $0.method == .liuyao }?.id, original.results.first?.id)
        XCTAssertEqual(Set((supplemented.activities ?? []).compactMap(\.method)), [.meihua])
        XCTAssertTrue(meihua.rows.first { $0.label == "起数过程" }?.value.contains("三数法") ?? false)
        XCTAssertEqual(meihua.rows.first { $0.label == "所留数字" }?.value, "13、27、41")
        XCTAssertEqual(try snapshot(store.runs[0]), originalData)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showInteraction)
    }
}
