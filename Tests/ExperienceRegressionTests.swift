import XCTest
@testable import BlindOracle

/// Reproductions from the ten-dialogue experience audit. Planner mistakes are
/// deliberate: the app must preserve user intent and confirmed interaction data.
final class ExperienceRegressionTests: XCTestCase {
    private func vault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("experience-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    private func person() throws -> OracleProfile {
        var person = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "陈平", sex: "男", birthDate: "1992-06-15",
            birthTime: "08:30", birthTimeZoneID: "Asia/Shanghai", birthPlace: "上海",
            birthLatitude: 31.2304, birthLongitude: 121.4737)], to: []).profiles.first)
        person.currentPlace = "上海市黄浦区"
        person.currentLatitude = 31.2304; person.currentLongitude = 121.4737
        person.currentTimeZoneID = "Asia/Shanghai"
        return person
    }

    private func castingSite() -> OracleProfile {
        var site = OracleProfile()
        site.currentPlace = "上海市黄浦区"
        site.currentLatitude = 31.2304; site.currentLongitude = 121.4737
        site.currentTimeZoneID = "Asia/Shanghai"
        return site
    }

    private func client(action: String = "reply", methods: [OracleMethod] = [], note: String = "模拟回复",
                        stream: String = "三张牌对应现状、影响和建议，已选择的牌会保留。", reference: UUID? = nil, resolved: String = "") throws -> DeepSeekClient {
        let key = UUID().uuidString
        var proposal: [String: Any] = ["action": action, "intent": "体验回归", "subject": "事件",
            "methods": methods.map(\.rawValue), "requiredFields": [], "note": note, "profileUpdates": []]
        if let reference { proposal["understanding"] = ["relation": "continuation", "resolvedQuestion": resolved, "referenceMessageID": reference.uuidString] }
        AuditResponseProtocol.install(plan: String(decoding: try JSONSerialization.data(withJSONObject: proposal), as: UTF8.self),
                                      stream: stream, key: key)
        addTeardownBlock { AuditResponseProtocol.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditResponseProtocol.self]
        return DeepSeekClient(accessToken: key, sessionConfiguration: configuration)
    }

    @MainActor private func wait(_ store: OracleStore) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while store.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy)
    }

    @MainActor private func restore(_ run: OracleRun, vault: LocalVault, client: DeepSeekClient) throws -> OracleStore {
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: run.input.question),
            ChatMessage(role: .assistant, content: "先确认合作边界。", kind: .reading, runID: run.id)])
        try vault.save([run], as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]),
                       as: ConversationHistory.filename)
        return OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
    }

    @MainActor private func unfinishedTarot(client: DeepSeekClient) throws -> (OracleStore, OracleInteractionSession) {
        let vault = try vault()
        let question = "今晚跟朋友讨论合作该注意什么？"
        let plan = OraclePlan(intent: "合作安排", subject: "事件", methods: [.tarot], requiredFields: [], note: "", question: question)
        let input = OracleInput(question: question, profile: castingSite(), seed: 41, subject: "事件", participants: [])
        let request = OracleInteractionRequest(method: .tarot, kind: .tarot)
        var session = OracleInteractionSession(input: input, plan: plan, requests: [request])
        let draws = zip(session.availableTarotCards.prefix(3), request.tarotPositions).map {
            TarotDraw(cardID: $0.0.id, isReversed: TarotDeck.isReversed(seed: session.seed, cardID: $0.0.id), position: $0.1)
        }
        XCTAssertTrue(session.saveProgress(.init(requestID: request.id, tarotDraws: draws, revealedCount: 1)))
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: question),
            ChatMessage(role: .assistant, content: "请抽三张牌。", kind: .intake)], pendingInteraction: session)
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]),
                       as: ConversationHistory.filename)
        let store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        store.showInteraction = false
        return (store, session)
    }

    @MainActor func testHelpDuringAnUnfinishedDrawIsAnsweredWithoutDiscardingItsCards() async throws {
        let (store, session) = try unfinishedTarot(client: client(action: "intake", methods: [.bazi]))
        let question = "抽牌前我该怎么想问题，为什么要三张？"
        XCTAssertTrue(store.canSendWhileAwaitingInteraction(question))

        store.send(question)
        try await wait(store)

        XCTAssertEqual(store.messages.last?.role, .assistant)
        XCTAssertTrue(store.messages.last?.content.contains("三张牌") == true)
        XCTAssertEqual(store.pendingInteraction?.id, session.id)
        XCTAssertEqual(store.pendingInteraction?.draft, session.draft)
        XCTAssertEqual(store.phase, .awaitingInteraction)
        XCTAssertFalse(store.showInteraction)
        XCTAssertNil(store.pendingPlan)
        XCTAssertTrue(store.runs.isEmpty)
    }

    @MainActor func testNaturalCancelEndsTheDrawAndRejectsItsOldSheetSubmission() async throws {
        let (store, session) = try unfinishedTarot(client: client())
        store.send("取消这次抽牌")
        try await wait(store)

        XCTAssertNil(store.pendingInteraction)
        XCTAssertNil(store.pendingPlan)
        XCTAssertFalse(store.showInteraction)
        XCTAssertFalse(store.showIntake)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(store.canRetryAnalysis)
        let count = store.messages.count
        let draft = try XCTUnwrap(session.draft)
        store.completeInteraction(.init(requestID: draft.requestID, tarotDraws: draft.tarotDraws, revealedCount: 3), sessionID: session.id)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertEqual(store.messages.count, count)
    }

    @MainActor func testChangingToMeihuaDuringADrawKeepsTheTopicAndDoesNotReopenOldCards() async throws {
        let service = try client(action: "intake", methods: [.meihua], stream: #"{"text":"先确认合作分工。","alternatives":[]}"#)
        let (store, session) = try unfinishedTarot(client: service)
        store.send("先不抽了，改用梅花看看同一件事")
        try await wait(store)

        XCTAssertNil(store.pendingInteraction)
        if let pending = store.pendingPlan {
            XCTAssertEqual(pending.methods, [.meihua])
            XCTAssertTrue(pending.question.contains("合作"))
            XCTAssertFalse(pending.question.contains("同一件事"))
            XCTAssertTrue(store.confirmGroupIntake(profiles: store.intakeParticipants, numbers: [], save: false, castingProfile: castingSite()))
            try await wait(store)
        }
        XCTAssertNil(store.pendingInteraction)
        XCTAssertNotEqual(store.pendingInteraction?.id, session.id)
        let reading = try XCTUnwrap(store.runs.last)
        XCTAssertEqual(reading.results.map(\.method), [.meihua])
        XCTAssertNil(reading.input.tarotDraws)
        XCTAssertTrue(reading.input.question.contains("合作"))
    }

    @MainActor func testRetractingAnOldBirthTimeMarksItUnknownWithoutChangingTheHistoricalReading() async throws {
        let vault = try vault()
        let person = try person()
        let question = "陈平今年的工作方向如何？"
        let plan = OraclePlan(intent: "工作", subject: "本人", methods: [.bazi], requiredFields: [], note: "", question: question)
        let run = OracleRun(input: OracleInput(question: question, profile: person, seed: 41, participants: [person]), plan: plan,
            results: [OracleResult(method: .bazi, headline: "此前的八字", rows: [])])
        let store = try restore(run, vault: vault, client: client(action: "collect"))
        store.saveProfile(person); store.selfProfileID = person.id

        store.send("我不知道几点出生，之前那个八点半不准。")
        try await wait(store)

        let updated = try XCTUnwrap(store.profiles.first { $0.id == person.id })
        XCTAssertFalse(updated.birthTimeKnown)
        XCTAssertTrue(updated.unknownFields.contains(.birthTime))
        XCTAssertEqual(store.runs.first?.input.profile.birthTimeText, "08:30")
        XCTAssertEqual(store.runs.first?.input.profile.birthTimeKnown, true)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertFalse(try XCTUnwrap(restarted.profiles.first).birthTimeKnown)
        XCTAssertTrue(try XCTUnwrap(restarted.profiles.first).unknownFields.contains(.birthTime))
    }

    @MainActor func testOnlyHerAfterAProfileUpdateUsesTheOtherParticipantsSavedResult() async throws {
        let own = try person()
        let other = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "李岚", sex: "女", birthDate: "1995-03-11",
            birthTime: "14:00", birthTimeZoneID: "Asia/Shanghai")], to: []).profiles.first)
        let question = "陈平和李岚合伙开店应该先谈清什么？"
        let plan = OraclePlan(intent: "合作", subject: "多人", methods: [.bazi], requiredFields: [], note: "", question: question)
        var first = OracleResult(method: .bazi, headline: "陈平的结果", rows: []); first.participantID = own.id
        var second = OracleResult(method: .bazi, headline: "李岚的结果", rows: []); second.participantID = other.id
        let run = OracleRun(input: OracleInput(question: question, profile: own, seed: 41, subject: "多人", participants: [own, other]),
                            plan: plan, results: [first, second])
        let service = try client(action: "clarify", note: "你指哪件事？", stream: "只看李岚，先明确她的分工。")
        let store = try restore(run, vault: vault(), client: service)
        store.saveProfile(own); store.saveProfile(other); store.selfProfileID = own.id
        var withdrawn = own; withdrawn.birthTimeKnown = false; withdrawn.birthTimeText = nil
        withdrawn.unknownFields.insert(.birthTime); withdrawn.declaredUnknownFields = [.birthTime]
        store.saveProfile(withdrawn)
        store.messages.append(ChatMessage(role: .user, content: "我不知道几点出生，之前那个八点半不准。"))
        store.messages.append(ChatMessage(role: .assistant, content: "已更新资料。"))

        store.send("只看她呢，先不看我。")
        try await wait(store)

        XCTAssertEqual(store.messages.last?.content, "只看李岚，先明确她的分工。")
        XCTAssertTrue(store.messages.last?.resolvedQuestion?.contains("李岚") == true)
        XCTAssertEqual(store.messages.last?.runID, run.id)
        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.runs.first?.input.readingParticipants.map(\.id), [own.id, other.id])
    }

    @MainActor func testOnlyHerAfterUpdatingAThirdPersonDoesNotSilentlyChooseTheOldPartner() async throws {
        let own = try person()
        let other = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "李岚", sex: "女", birthDate: "1995-03-11",
            birthTime: "14:00", birthTimeZoneID: "Asia/Shanghai")], to: []).profiles.first)
        let third = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "王安", sex: "女", birthDate: "1993-07-20",
            birthTime: "10:00", birthTimeZoneID: "Asia/Shanghai")], to: []).profiles.first)
        let question = "陈平和李岚合伙开店应该先谈清什么？"
        let plan = OraclePlan(intent: "合作", subject: "多人", methods: [.bazi], requiredFields: [], note: "", question: question)
        var first = OracleResult(method: .bazi, headline: "陈平的结果", rows: []); first.participantID = own.id
        var second = OracleResult(method: .bazi, headline: "李岚的结果", rows: []); second.participantID = other.id
        let run = OracleRun(input: OracleInput(question: question, profile: own, seed: 41, subject: "多人", participants: [own, other]),
            plan: plan, results: [first, second])
        let clarification = "你指的是李岚还是王安？"
        let store = try restore(run, vault: vault(), client: client(action: "clarify", note: clarification))
        store.saveProfile(own); store.saveProfile(other); store.saveProfile(third); store.selfProfileID = own.id
        store.messages.append(ChatMessage(role: .user, content: "补充王安的资料：出生日期1993-07-20，出生时间10:00，出生时区Asia/Shanghai。"))
        store.messages.append(ChatMessage(role: .assistant, content: "已保存王安的资料。"))

        store.send("只看她呢，先不看我。")
        try await wait(store)

        XCTAssertEqual(store.messages.last?.content, clarification)
        XCTAssertNil(store.messages.last?.runID)
        XCTAssertFalse(store.messages.last?.resolvedQuestion?.contains("李岚") == true)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.runs.first?.input.readingParticipants.map(\.id), [own.id, other.id])
    }

    @MainActor func testFollowUpAfterRetractingTimeRecalculatesThreePillarsInsteadOfReusingTheOldLuckCycles() async throws {
        let person = try person()
        let question = "陈平开店合作应该先确认什么？"
        let plan = OraclePlan(intent: "合作", subject: "本人", methods: [.bazi], requiredFields: [], note: "", question: question)
        let input = OracleInput(question: question, profile: person, seed: 41, subject: "本人", participants: [person])
        var result = try await BaziPlugin().calculate(input)
        result.participantID = person.id; result.participantName = person.participantLabel
        let run = OracleRun(input: input, plan: plan, results: [result])
        let anchor = ChatMessage(role: .assistant, content: "此前按已知时刻解读。", kind: .reading, runID: run.id)
        let vault = try vault()
        try vault.save([run], as: "readings")
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: question), anchor])
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]), as: ConversationHistory.filename)
        let service = try client(stream: #"{"text":"出生时刻已撤回，这次按三柱看。","alternatives":[]}"#,
                                 reference: anchor.id, resolved: "只看陈平的开店合作应该先确认什么。")
        let store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: service)
        var updated = person; updated.birthTimeKnown = false; updated.unknownFields.insert(.birthTime)
        updated.declaredUnknownFields = [.birthTime]
        store.saveProfile(updated); store.selfProfileID = person.id

        store.send("还是刚才的合作，只看陈平接下来怎么安排？")
        try await wait(store)

        XCTAssertEqual(store.runs.count, 2)
        let latest = try XCTUnwrap(store.runs.last)
        XCTAssertFalse(latest.input.profile.birthTimeKnown)
        XCTAssertEqual(latest.results.first?.status, .partial)
        XCTAssertEqual(latest.results.first?.rows.first { $0.label == "时柱" }?.value, "未知，未计算")
        XCTAssertTrue(store.messages.last?.content.contains("三柱") == true)
        XCTAssertEqual(store.runs.first?.input.profile.birthTimeKnown, true)
    }

    @MainActor func testSameSecondPersistedTimeRetractionSurvivesRelaunchAndRecalculatesWithoutOldLuckCycles() async throws {
        var person = try person()
        let sameSecond = Date(timeIntervalSince1970: 1_730_000_000)
        person.updatedAt = sameSecond
        let question = "陈平开店合作应该先确认什么？"
        let plan = OraclePlan(intent: "合作", subject: "本人", methods: [.bazi], requiredFields: [], note: "", question: question)
        let input = OracleInput(question: question, profile: person, seed: 41, subject: "本人", participants: [person])
        var result = try await BaziPlugin().calculate(input)
        result.participantID = person.id; result.participantName = person.participantLabel
        XCTAssertNotEqual(result.rows.first { $0.label == "时柱" }?.value, "未知，未计算")
        XCTAssertTrue(result.rows.contains { $0.label.hasPrefix("大运") })
        let run = OracleRun(input: input, plan: plan, results: [result])
        let anchor = ChatMessage(role: .assistant, content: "此前按已知时刻解读。", kind: .reading, runID: run.id)
        let vault = try vault()
        try vault.save([run], as: "readings")
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: question), anchor])
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]),
            as: ConversationHistory.filename)
        var withdrawn = person; withdrawn.birthTimeKnown = false; withdrawn.birthTimeText = nil
        withdrawn.unknownFields.insert(.birthTime); withdrawn.declaredUnknownFields = [.birthTime]
        withdrawn.updatedAt = sameSecond
        // Both snapshots are written and reloaded through the real ISO-8601
        // vault format, which preserves only whole-second timestamps.
        try vault.save([withdrawn], as: "profiles")
        try vault.save(Optional(person.id), as: "self-profile-id")
        let service = try client(stream: #"{"text":"出生时刻已撤回，这次按三柱看。","alternatives":[]}"#,
            reference: anchor.id, resolved: "陈平的开店合作接下来应该怎么安排？")
        let restarted = OracleStore(vault: vault, bootstrapCredential: false, aiClient: service)
        XCTAssertEqual(restarted.profiles.first?.updatedAt, restarted.runs.first?.input.profile.updatedAt)
        XCTAssertFalse(try XCTUnwrap(restarted.profiles.first).birthTimeKnown)
        XCTAssertTrue(try XCTUnwrap(restarted.runs.first).input.profile.birthTimeKnown)

        restarted.send("还是刚才的合作，接下来怎么安排？")
        try await wait(restarted)

        XCTAssertEqual(restarted.runs.count, 2)
        let latest = try XCTUnwrap(restarted.runs.last)
        let recalculated = try XCTUnwrap(latest.results.first { $0.method == .bazi })
        XCTAssertNotEqual(recalculated.id, result.id)
        XCTAssertFalse(latest.input.profile.birthTimeKnown)
        XCTAssertEqual(recalculated.status, .partial)
        XCTAssertEqual(recalculated.rows.first { $0.label == "时柱" }?.value, "未知，未计算")
        XCTAssertFalse(recalculated.rows.contains { $0.label.hasPrefix("大运") || $0.label == "起运" || $0.label == "交运公历" })
        XCTAssertTrue(restarted.messages.last?.content.contains("三柱") == true)
        XCTAssertEqual(restarted.runs.first?.input.profile.birthTimeText, "08:30")
        XCTAssertTrue(restarted.runs.first?.input.profile.birthTimeKnown == true)
    }

    @MainActor func testRejectingOldCardsInNaturalLanguageStartsAFreshSpreadEvenWhenPlannerReplies() async throws {
        let question = "该不该接下新的合作项目？"
        let draws = zip(["major-00", "cups-01", "swords-14"], TarotDeck.positions).map {
            TarotDraw(cardID: $0.0, isReversed: false, position: $0.1)
        }
        let input = OracleInput(question: question, profile: OracleProfile(), seed: 41, subject: "事件", tarotDraws: draws, participants: [])
        let plan = OraclePlan(intent: "合作", subject: "事件", methods: [.tarot], requiredFields: [], note: "", question: question)
        let result = try await TarotPlugin().calculate(input)
        let run = OracleRun(input: input, plan: plan, results: [result])
        let store = try restore(run, vault: vault(), client: client(action: "intake", methods: [.tarot]))

        store.send("别用旧牌，换一组新的。")
        try await wait(store)

        let pending = try XCTUnwrap(store.pendingPlan)
        XCTAssertEqual(pending.methods, [.tarot])
        XCTAssertNil(pending.baseRunID)
        XCTAssertTrue(pending.question.contains("合作"))
        let previousReview = store.intakeSessionID
        store.showIntake = false
        store.send("我是想重新抽三张牌，不是解释旧结果。")
        try await wait(store)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.methods, [.tarot])
        XCTAssertNotEqual(store.intakeSessionID, previousReview)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        let session = try XCTUnwrap(store.pendingInteraction)
        XCTAssertEqual(session.currentRequest?.kind, .tarot)
        XCTAssertNil(session.input.tarotDraws)
        XCTAssertNil(session.draft)
        XCTAssertEqual(store.runs.first?.input.tarotDraws, draws)
    }

    @MainActor func testPreparationQuestionsNeverCreateAReadingEvenWhenPlannerSuggestsIntake() async throws {
        for question in ["我先问问，用塔罗算要准备什么资料？", "我只是问问，不是现在算。", "先别发起抽牌，告诉我塔罗和六爻有什么区别。"] {
            let store = OracleStore(vault: try vault(), bootstrapCredential: false,
                aiClient: try client(action: "intake", methods: [.tarot, .liuyao], stream: "可以先了解规则，确认要算时再开始。"))
            store.send(question)
            try await wait(store)
            XCTAssertNil(store.pendingPlan, question)
            XCTAssertNil(store.pendingInteraction, question)
            XCTAssertFalse(store.showIntake, question)
            XCTAssertFalse(store.showInteraction, question)
            XCTAssertTrue(store.runs.isEmpty, question)
            XCTAssertEqual(store.phase, .idle, question)
            XCTAssertEqual(store.messages.last?.role, .assistant, question)
        }
    }

    @MainActor func testCombiningTarotAndBaziRetainsTheExistingTopicAndOnlyAsksForMissingDetails() async throws {
        let question = "今晚和朋友谈合作应该先谈清什么？"
        let input = OracleInput(question: question, profile: castingSite(), seed: 41, subject: "事件", participants: [])
        let plan = OraclePlan(intent: "合作", subject: "事件", methods: [.meihua], requiredFields: [], note: "", question: question)
        let run = OracleRun(input: input, plan: plan, results: [try await MeihuaPlugin().calculate(input)])
        let store = try restore(run, vault: vault(), client: client(action: "clarify", note: "你指哪件合作？"))

        store.send("用塔罗和八字一起看看还是刚才那件合作。")
        try await wait(store)

        let pending = try XCTUnwrap(store.pendingPlan)
        XCTAssertEqual(pending.baseRunID, run.id)
        XCTAssertTrue(Set(pending.methods).isSuperset(of: [.tarot, .bazi]))
        XCTAssertTrue(pending.question.contains("合作"))
        XCTAssertFalse(pending.question.contains("刚才那件"))
        XCTAssertNotEqual(pending.action, "clarify")
        XCTAssertTrue(store.showIntake)
        let report = try XCTUnwrap(store.intakePreparationReport(for: store.intakeParticipants))
        XCTAssertFalse(report.canProceed)
        XCTAssertTrue(report.assessments.contains { $0.method == .bazi && !$0.blocking.isEmpty })
        XCTAssertEqual(store.runs.map(\.id), [run.id])
        XCTAssertFalse(store.messages.last?.content.contains("哪件合作") ?? true)
    }

    @MainActor func testOnlyTarotExcludesTheOldMeihuaWhetherItsCardsAreNewOrAlreadySaved() async throws {
        for hasSavedCards in [false, true] {
            let question = "先用梅花看看今晚和朋友谈合作的安排。"
            let draws = zip(["major-00", "cups-01", "swords-14"], TarotDeck.positions).map {
                TarotDraw(cardID: $0.0, isReversed: false, position: $0.1)
            }
            let input = OracleInput(question: question, profile: castingSite(), seed: 41, subject: "事件",
                tarotDraws: hasSavedCards ? draws : nil, participants: [])
            let methods: [OracleMethod] = hasSavedCards ? [.meihua, .tarot] : [.meihua]
            let plan = OraclePlan(intent: "合作", subject: "事件", methods: methods, requiredFields: [], note: "", question: question)
            var results = [try await MeihuaPlugin().calculate(input)]
            if hasSavedCards { results.append(try await TarotPlugin().calculate(input)) }
            let run = OracleRun(input: input, plan: plan, results: results)
            let service = try client(action: "supplement", methods: [.meihua, .tarot],
                stream: #"{"text":"按塔罗看，先确认合作条款。","alternatives":[]}"#)
            let store = try restore(run, vault: vault(), client: service)

            store.send("只要塔罗不要八字。")
            try await wait(store)

            if hasSavedCards {
                let latest = try XCTUnwrap(store.runs.last)
                XCTAssertNotEqual(latest.id, run.id)
                XCTAssertEqual(latest.plan.methods, [.tarot])
                XCTAssertEqual(latest.results.map(\.method), [.tarot])
                XCTAssertEqual(latest.results.first?.id, results.last?.id)
                XCTAssertFalse(latest.input.question.contains("梅花"))
                XCTAssertNil(store.pendingInteraction)
            } else {
                let session = try XCTUnwrap(store.pendingInteraction)
                XCTAssertEqual(session.plan.methods, [.tarot])
                XCTAssertEqual(session.currentRequest?.method, .tarot)
                XCTAssertFalse(session.input.question.contains("梅花"))
                XCTAssertNil(session.input.tarotDraws)
            }
            XCTAssertEqual(store.runs.first?.results.map(\.id), results.map(\.id))
        }
    }

    @MainActor func testSwitchingFromBlockedZiweiToBaziUpdatesTheQuestionAndAllowsThreePillars() async throws {
        let vault = try vault()
        var person = try person(); person.birthTimeKnown = false; person.sex = "未提供"
        person.unknownFields.formUnion([.birthTime, .gender])
        let question = "用紫微看陈平今年工作上的机会"
        var plan = OraclePlan(intent: "工作机会", subject: "本人", methods: [.ziwei], requiredFields: [.birthDate, .birthTime, .birthTimeZone, .gender],
                              note: "请确认出生资料", question: question)
        plan.mandatoryMethods = [.ziwei]; plan.participantIDs = [person.id]; plan.participantNames = [person.resolvedName]
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: question)], pendingPlan: plan)
        try vault.save([person], as: "profiles")
        try vault.save(Optional(person.id), as: "self-profile-id")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]), as: ConversationHistory.filename)
        let store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: try client(action: "intake", methods: [.bazi]))

        store.send("那只用八字，不要紫微，还是看刚才的工作。")
        try await wait(store)

        let pending = try XCTUnwrap(store.pendingPlan)
        XCTAssertEqual(pending.methods, [.bazi])
        XCTAssertEqual(pending.mandatoryMethods, [.bazi])
        XCTAssertFalse(pending.question.contains("紫微"))
        XCTAssertTrue(pending.question.contains("工作"))
        XCTAssertFalse(pending.requiredFields.contains(.birthTime))
        XCTAssertFalse(pending.requiredFields.contains(.gender))
        XCTAssertTrue(store.canConfirmIntake)
    }
}

private final class AuditResponseProtocol: URLProtocol, @unchecked Sendable {
    private struct Fixture { var plan: String; var stream: String }
    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]

    static func install(plan: String, stream: String, key: String) {
        lock.withLock { fixtures["Bearer " + key] = Fixture(plan: plan, stream: stream) }
    }
    static func remove(_ key: String) { lock.withLock { _ = fixtures.removeValue(forKey: "Bearer " + key) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        guard let fixture = Self.lock.withLock({ Self.fixtures[authorization] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let streaming = request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
        let body: [String: Any] = streaming
            ? ["choices": [["delta": ["content": fixture.stream]]]]
            : ["choices": [["message": ["content": fixture.plan], "finish_reason": "stop"]]]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: streaming ? Data(("data: " + String(decoding: data, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8) : data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
