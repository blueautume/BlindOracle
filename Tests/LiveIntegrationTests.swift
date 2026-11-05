import XCTest
@testable import BlindOracle

/// Opt in using BLINDORACLE_LIVE_SMOKE=1.
/// These requests use synthetic fixture data.
final class LiveIntegrationTests: XCTestCase {
    private func liveClient() throws -> DeepSeekClient {
        guard ProcessInfo.processInfo.environment["BLINDORACLE_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Live API smoke is opt-in")
        }
        // Read the ignored bundled fixture in memory; never log credentials.
        let bundled = Bundle.main.url(forResource: "dev-key", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let key = KeychainStore.shared.string() ?? bundled
        guard let key, !key.isEmpty else { throw XCTSkip("Development key unavailable") }
        return DeepSeekClient(apiKey: key)
    }

    @MainActor func testMissingChinaDistrictUsesDeepSeekAndAppleGeocoding() async throws {
        let client = try liveClient()
        let catalog = ChinaDistrictCatalog.shared
        let beijing = try XCTUnwrap(catalog.provinces.first { $0.id == "110000" })
        let miyun = try XCTUnwrap(catalog.children(of: beijing).first { $0.id == "110118" })
        XCTAssertNil(miyun.localPlace)
        let place: LocalPlace
        do {
            place = try await LocationService.resolveChinaDistrict(miyun, using: client)
        } catch {
            let report = await client.lastSuccessfulConnection
            XCTFail("Unresolved public district; DeepSeek model: \(report?.actualModel ?? "no successful response"); \(error.localizedDescription)")
            return
        }
        XCTAssertEqual(place.name, "北京市密云区")
        XCTAssertEqual(place.timeZone, OracleProfile.defaultChinaTimeZoneID)
        XCTAssertTrue((40.2...41.0).contains(place.latitude))
        XCTAssertTrue((116.5...117.6).contains(place.longitude))
        let report = await client.lastSuccessfulConnection
        XCTAssertEqual(report?.host, "api.deepseek.com")
        print("DeepSeek \(report?.actualModel ?? "unknown"), Apple validated \(place.name): \(place.latitude), \(place.longitude)")
    }

    @MainActor func testMissingChinaCityUsesDeepSeekAndAppleGeocoding() async throws {
        let client = try liveClient()
        let catalog = ChinaDistrictCatalog.shared
        let hubei = try XCTUnwrap(catalog.provinces.first { $0.id == "420000" })
        let xiangyang = try XCTUnwrap(catalog.children(of: hubei).first { $0.id == "420600" })
        XCTAssertEqual(xiangyang.wholeAreaSelectionTitle, "全市")
        XCTAssertNil(xiangyang.localPlace)
        let place = try await LocationService.resolveChinaDistrict(xiangyang, using: client)
        XCTAssertEqual(place.name, "湖北省襄阳市")
        XCTAssertEqual(place.timeZone, OracleProfile.defaultChinaTimeZoneID)
        XCTAssertTrue((31.5...33.0).contains(place.latitude))
        XCTAssertTrue((111.0...113.0).contains(place.longitude))
        let report = await client.lastSuccessfulConnection
        XCTAssertEqual(report?.host, "api.deepseek.com")
        print("DeepSeek \(report?.actualModel ?? "unknown"), Apple validated \(place.name): \(place.latitude), \(place.longitude)")
    }

    func testTarotInteractivePlanAndChineseReadingWithPro() async throws {
        try await assertLiveTarotPlanAndReading()
    }


    @MainActor func testScreenshotTarotActivationAfterMeihuaWithDeepSeek() async throws {
        try await assertLiveScreenshotTarotActivationAfterMeihua()
    }


    @MainActor private func assertLiveScreenshotTarotActivationAfterMeihua() async throws {
        let client = try liveClient()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-tarot-activation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory)
        var profile = OracleProfile(); profile.currentTimeZoneID = "Asia/Shanghai"
        let originalQuestion = "这是虚构的功能测试。今晚打算进入线上语聊房与朋友短聊，请用梅花易数看今晚的运势和参与时的注意事项。"
        let plan = OraclePlan(intent: "今晚的安排", subject: "事件", methods: [.meihua],
            requiredFields: [], note: "", question: originalQuestion)
        let input = OracleInput(question: originalQuestion, profile: profile, castingDate: Date(), seed: 73,
            subject: "事件", participants: [])
        let meihua = try await MeihuaPlugin().calculate(input)
        XCTAssertTrue([.complete, .partial].contains(meihua.status))
        XCTAssertFalse(meihua.rows.isEmpty)
        var original = OracleRun(input: input, plan: plan, results: [meihua])
        original.synthesis = ReadingSynthesis(text: "现有梅花盘可供安排今晚的交流作参考，先交代交流目的，再决定停留多久。", alternatives: [])
        original.completedAt = input.castingDate
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: originalQuestion),
            ChatMessage(role: .assistant, content: original.synthesis!.text, kind: .reading, runID: original.id)])
        try vault.save([original], as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]),
            as: ConversationHistory.filename)
        let store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        defer { if store.isBusy { store.stop() } }
        XCTAssertTrue(store.hasCredential)

        let planningStarted = Date()
        store.send("用塔罗牌计算今晚的运势")
        try await waitForLiveTarot(store, stage: "DeepSeek screenshot Tarot activation")
        let planningReport = await client.lastSuccessfulConnection
        assertLiveResponse(planningReport)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(planningReport?.checkedAt), planningStarted)
        XCTAssertNil(store.notice)
        XCTAssertEqual(store.runs.map(\.id), [original.id], "The missing Tarot spread must be drawn before interpretation")
        if let pending = store.pendingPlan {
            XCTAssertTrue(pending.methods.contains(.tarot))
            XCTAssertTrue(Set(pending.methods).isSubset(of: [.meihua, .tarot]))
            XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false,
                sessionID: store.intakeSessionID))
            try await waitForLiveTarot(store, stage: "DeepSeek screenshot Tarot intake")
        }
        let session = try XCTUnwrap(store.pendingInteraction, "The screenshot request must activate Tarot instead of only replying from Meihua")
        XCTAssertEqual(session.requests.map(\.kind), [.tarot])
        XCTAssertEqual(session.currentRequest?.tarotPositions, TarotDeck.positions)
        XCTAssertNil(session.input.tarotDraws)
        let synthesisStarted = Date()
        let draws = try confirmLiveTarotCards(["cups-02", "pentacles-06", "swords-04"], in: store)
        try await waitForLiveTarot(store, stage: "DeepSeek screenshot Tarot synthesis")

        let run = try XCTUnwrap(store.latestRun)
        XCTAssertNotEqual(run.id, original.id)
        let tarot = try XCTUnwrap(run.results.first { $0.method == .tarot })
        XCTAssertEqual(tarot.status, .complete)
        XCTAssertEqual(tarot.tarotDraws, draws)
        XCTAssertEqual(run.input.tarotDraws, draws)
        XCTAssertEqual(tarot.evidence.count, 3)
        let synthesis = try XCTUnwrap(run.synthesis, "The activated Tarot reading must finish its real provider synthesis")
        XCTAssertFalse(synthesis.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(store.messages.last?.runID, run.id)
        XCTAssertEqual(store.messages.last?.content, synthesis.text)
        XCTAssertEqual(store.runs.first?.results.map(\.id), [meihua.id])
        XCTAssertEqual(store.runs.first?.results.first?.rows, meihua.rows)
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertNil(store.notice)
        let synthesisReport = await client.lastSuccessfulConnection
        assertLiveResponse(synthesisReport)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(synthesisReport?.checkedAt), synthesisStarted)
        recordJourneyText(synthesis.text, stage: "DeepSeek screenshot Tarot activation after Meihua")
    }

    @MainActor func testReadingVoiceMatrixWithDeepSeek() async throws {
        try await assertLiveReadingVoiceMatrix()
    }


    @MainActor func testConversationUnderstandingWithDeepSeek() async throws {
        try await assertLiveConversationUnderstanding()
    }


    @MainActor private func assertLiveConversationUnderstanding() async throws {
        let client = try liveClient()
        var chen = OracleProfile(); chen.name = "陈平"
        var li = OracleProfile(); li.name = "李岚"
        let marketQuestion = ChatMessage(role: .user, content: "我们一起办周末市集，应该怎么谈合作？")
        let marketAnswer = ChatMessage(role: .assistant, content: "先谈清预算和当天的分工。")
        let workQuestion = ChatMessage(role: .user, content: "陈平这周的工作怎么样？")
        let workPlan = OraclePlan(intent: "本周工作", subject: "他人", methods: [.xiaoliuren],
                                  requiredFields: [], note: "", question: workQuestion.content)
        let workRun = OracleRun(input: OracleInput(question: workQuestion.content, profile: chen, seed: 42,
                                                   subject: "他人", participants: [chen]),
                                plan: workPlan, results: [OracleResult(method: .xiaoliuren, headline: "测试工作盘", rows: [])])
        let workAnswer = ChatMessage(role: .assistant, content: "陈平本周可以先核对工作分工。", kind: .reading, runID: workRun.id)
        let loveQuestion = ChatMessage(role: .user, content: "感情呢，今天")
        let loveAnswer = ChatMessage(role: .assistant, content: "今天可以观察对方会不会主动联系。")
        let transcript = [marketQuestion, marketAnswer, workQuestion, workAnswer, loveQuestion, loveAnswer]
        let history = ContextCompressor.history(messages: transcript, summary: .init(), language: .simplifiedChinese)
        let references = ConversationPlanningReference.candidates(in: transcript, runs: [workRun])
        let plugins = PluginRegistry().descriptors
        let scenarios: [(name: String, raw: String, relation: ConversationUnderstanding.Relation,
                         anchors: [ChatMessage], topicWords: [String])] = [
            ("time-range", "再看看这周", .continuation, [loveQuestion, loveAnswer], ["感情", "情感"]),
            ("older-topic", "回到最开始那件合作，先问清哪一条？", .continuation, [marketQuestion, marketAnswer], ["市集", "合作"]),
            ("changed-participant", "刚才问陈平工作的那题，换成李岚呢？", .changedParticipants, [workQuestion, workAnswer], ["李岚"])
        ]
        let tasks = scenarios.map { scenario in
            Task { @MainActor in
                let plan = try await client.plan(question: scenario.raw, profile: OracleProfile(), plugins: plugins,
                                                 history: history, profiles: [chen, li], existingRun: workRun,
                                                 references: references, language: .simplifiedChinese)
                let stage = "DeepSeek \(scenario.name)"
                let understanding = try XCTUnwrap(plan.understanding, stage)
                let anchored = understanding.referenceMessageID.map { id in scenario.anchors.contains { $0.id == id } } == true
                print("[CONVERSATION_PLAN] \(stage) | \(plan.action ?? "nil") | \(understanding.relation.rawValue) | anchored=\(anchored) | \(understanding.resolvedQuestion)")
                XCTAssertEqual(understanding.relation, scenario.relation, stage)
                XCTAssertTrue(anchored, stage)
                XCTAssertTrue(scenario.topicWords.contains { understanding.resolvedQuestion.contains($0) }, stage)
                if scenario.name == "time-range" {
                    XCTAssertTrue(["这周", "本周", "这一周"].contains { understanding.resolvedQuestion.contains($0) }, stage)
                    XCTAssertFalse(["陈平", "李岚"].contains { understanding.resolvedQuestion.contains($0) }, stage)
                }
                if scenario.name == "changed-participant" {
                    XCTAssertFalse(understanding.resolvedQuestion.contains("陈平"), stage)
                }
                let report = await client.lastSuccessfulConnection
                assertLiveResponse(report)
            }
        }
        for (scenario, task) in zip(scenarios, tasks) {
            do { try await task.value }
            catch { XCTFail("DeepSeek \(scenario.name): \(error.localizedDescription)") }
        }
    }

    @MainActor private func assertLiveReadingVoiceMatrix() async throws {
        let clients = try OracleVoiceStyle.allCases.map { voice in (voice, try liveClient()) }
        let question = "这是虚构练习。朋友邀我一起办周末创意市集，场地已定，费用分摊和当天分工还没说清。这个项目靠谱吗？"
        let followUp = "对方说先开工，费用和分工以后再谈。我今天该怎么回复？"
        let draws = zip([("wands-03", false), ("pentacles-06", true), ("major-11", false)], TarotDeck.positions)
            .map { card, position in TarotDraw(cardID: card.0, isReversed: card.1, position: position) }
        let input = OracleInput(question: question, profile: OracleProfile(), castingDate: Date(timeIntervalSince1970: 1_730_000_000),
                                seed: 42, subject: "事件", tarotDraws: draws, participants: [])
        let plan = OraclePlan(intent: "合作决策", subject: "事件", methods: [.tarot], requiredFields: [], note: "", question: question)
        let result = try await TarotPlugin().calculate(input)
        XCTAssertEqual(result.status, .complete)
        let run = OracleRun(input: input, plan: plan, results: [result])
        let prior = ReadingSynthesis(text: "建议先把费用分摊和分工说清，再决定要不要接。", alternatives: [])
        var priorRun = run
        priorRun.synthesis = prior
        let followUpRun = priorRun
        let history = [AIConversationTurn(role: "user", content: question), .init(role: "assistant", content: prior.text)]

        // The follow-up uses a fixed prior reply so each voice sees the same history.
        // Retain every sample as an attachment for comparison without brittle word matching.
        let tasks = clients.map { voice, client in
            Task { @MainActor in
                let stage = "voice DeepSeek \(voice.rawValue)"
                let initialStream = StreamCollector()
                let initial = try await client.synthesize(run: run, weights: [:], history: [],
                                                          language: .simplifiedChinese, voice: voice) { initialStream.append($0) }
                XCTAssertEqual(initialStream.text, initial.text, stage)
                XCTAssertTrue(initial.alternatives.isEmpty, stage)
                let initialReport = await client.lastSuccessfulConnection
                assertLiveResponse(initialReport)
                recordJourneyText(initial.text, stage: "\(stage) initial")

                let followUpStream = StreamCollector()
                let reply = try await client.followUp(question: followUp, run: followUpRun, profile: run.input.profile,
                                                      history: history, language: .simplifiedChinese, voice: voice) { followUpStream.append($0) }
                XCTAssertEqual(followUpStream.text, reply, stage)
                let followUpReport = await client.lastSuccessfulConnection
                assertLiveResponse(followUpReport)
                recordJourneyText(reply, stage: "\(stage) follow-up")
            }
        }
        for ((voice, _), task) in zip(clients, tasks) {
            do { try await task.value }
            catch { XCTFail("DeepSeek \(voice.rawValue): \(error.localizedDescription)") }
        }
    }

    private func assertLiveTarotPlanAndReading() async throws {
        let client = try liveClient()
        let registry = PluginRegistry()
        let question = "请只用塔罗三张牌，帮我梳理是否接下一个新工作项目，以及接之前需要考虑什么。请先让我抽牌，最后用中文解读。"
        let history: [AIConversationTurn] = []
        let plan = try await client.plan(question: question, profile: OracleProfile(), plugins: registry.descriptors, history: history)
        let planningReport = await client.lastSuccessfulConnection
        assertLiveResponse(planningReport)
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [.tarot])
        XCTAssertTrue(plan.requiredFields.isEmpty)
        XCTAssertEqual(plan.interactions?.map(\.kind), [.tarot])
        let selected = zip(TarotDeck.shuffled(seed: 42).prefix(3), TarotDeck.positions).map {
            TarotDraw(cardID: $0.0.id, isReversed: TarotDeck.isReversed(seed: 42, cardID: $0.0.id), position: $0.1)
        }
        let input = OracleInput(question: question, profile: OracleProfile(), seed: 42, tarotDraws: selected)
        let results = await registry.calculate(input, methods: plan.methods) { _ in }
        XCTAssertEqual(results.first?.tarotDraws, selected)
        let run = OracleRun(input: input, plan: plan, results: results)
        let collector = StreamCollector()
        let progress = LiveProgressCollector()
        let reading = try await client.synthesize(run: run, weights: PreferenceLearning.initial, history: history, onProgress: { stage in
            await progress.append(stage)
        }) { collector.append($0) }
        XCTAssertFalse(reading.text.isEmpty)
        XCTAssertEqual(collector.text, reading.text)
        XCTAssertGreaterThan(reading.text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count, 80)
        let stages = await progress.snapshot()
        XCTAssertEqual(stages, [.preparing, .requesting, .writing, .validating])
        let readingReport = await client.lastSuccessfulConnection
        assertLiveResponse(readingReport)
    }

    private func assertLiveResponse(_ report: AIConnectionReport?) {
        XCTAssertEqual(report?.host, DeepSeekConfiguration.endpoint.host)
        XCTAssertEqual(report?.finishReason, "stop")
        XCTAssertTrue(DeepSeekClient.modelsMatch(requested: DeepSeekConfiguration.defaultModel, returned: report?.actualModel ?? ""))
    }

    @MainActor func testStagedTarotUsesRealPlannerAndSynthesisAcrossFiveSavedCards() async throws {
        guard ProcessInfo.processInfo.environment["BLINDORACLE_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Live API smoke is opt-in")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("staged-tarot-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OracleStore(vault: LocalVault(directory: directory))
        guard store.hasCredential else { throw XCTSkip("The test host could not load the bundled credential") }
        XCTAssertEqual(DeepSeekConfiguration.model(), "deepseek-v4-pro")
        defer { if store.isBusy { store.stop() } }

        let originalQuestion = "这是虚构练习。两人打算一起办一次周末创意市集，分工和预算都没定。请只用塔罗三张牌，告诉我现在应该直接答应合作，还是先暂缓并核对条件？"
        store.send(originalQuestion)
        try await waitForLiveTarot(store, stage: "initial plan")
        let initialPlan = try XCTUnwrap(store.pendingPlan)
        XCTAssertEqual(initialPlan.action, "intake")
        XCTAssertEqual(initialPlan.methods, [.tarot])
        try await assertLiveTarotResponse(store, stage: "initial plan")
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false, sessionID: store.intakeSessionID))
        let initialCards = try confirmLiveTarotCards(["major-11", "pentacles-02", "swords-02"], in: store)
        try await waitForLiveTarot(store, stage: "three cards")
        let first = try await liveTarotStage(store, expected: initialCards, stage: "three cards")

        // The request starts with the substantive follow-up, so it goes through
        // the remote planner instead of the local short-command shortcut.
        store.send("还是刚才那份市集合作。已有牌面能区分最大阻力是分工没谈清，还是资源不足吗？我想在原来的牌阵上加抽一张，专门澄清这个分岔。")
        try await waitForLiveTarot(store, stage: "clarification proposal")
        let offeredReply = try XCTUnwrap(store.messages.last)
        XCTAssertEqual(offeredReply.runID, first.id)
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertNil(store.pendingPlan)
        try await assertLiveTarotResponse(store, stage: "reply before proposal")
        recordLiveTarotText(offeredReply.content, stage: "reply before proposal")
        let proposal = try XCTUnwrap(store.tarotClarificationOffer(for: offeredReply), "The remote planner did not surface a valid one-card offer")
        store.acceptTarotClarification(messageID: offeredReply.id)
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.tarotClarification?.focus, proposal.focus)
        let fourth = try confirmLiveTarotCards(["pentacles-03"], in: store)
        try await waitForLiveTarot(store, stage: "four cards")
        let second = try await liveTarotStage(store, expected: initialCards + fourth, stage: "four cards")
        XCTAssertEqual(second.plan.baseRunID, first.id)
        XCTAssertEqual(second.input.tarotClarificationRounds?.last?.request.focus, proposal.focus)

        let secondFocus = "澄清开始前最值得先确认的一个条件是什么？"
        store.send("再补一张，\(secondFocus)")
        let secondRequest = try XCTUnwrap(store.pendingInteraction?.currentRequest?.tarotClarification)
        XCTAssertTrue(secondRequest.focus.contains("最值得先确认"))
        let fifth = try confirmLiveTarotCards(["swords-01"], in: store)
        try await waitForLiveTarot(store, stage: "five cards")
        let third = try await liveTarotStage(store, expected: initialCards + fourth + fifth, stage: "five cards")
        XCTAssertEqual(third.plan.baseRunID, second.id)
        XCTAssertEqual(third.input.tarotClarificationRounds?.last?.request.id, secondRequest.id)
        XCTAssertEqual(store.runs.first?.input.tarotDraws, initialCards)
        XCTAssertTrue((store.runs.first?.input.tarotClarificationRounds ?? []).isEmpty)
        XCTAssertNil(third.synthesis?.tarotClarification)

        store.send("再补一张")
        XCTAssertNil(store.pendingInteraction)
        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(store.runs.count, 3)
        XCTAssertTrue(store.messages.last?.content.contains("五张") == true)
    }

    @MainActor private func waitForLiveTarot(_ store: OracleStore, stage: String) async throws {
        let deadline = Date().addingTimeInterval(240)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        _ = try XCTUnwrap(store.isBusy ? nil : true, "Timed out waiting for \(stage)")
    }

    @MainActor private func confirmLiveTarotCards(_ ids: [String], in store: OracleStore) throws -> [TarotDraw] {
        let session = try XCTUnwrap(store.pendingInteraction)
        let request = try XCTUnwrap(session.currentRequest)
        XCTAssertEqual(request.kind, .tarot)
        XCTAssertEqual(request.tarotPositions.count, ids.count)
        let draws = try zip(ids, request.tarotPositions).map { id, position in
            let card = try XCTUnwrap(session.availableTarotCards.first { $0.id == id })
            return TarotDraw(cardID: card.id, isReversed: TarotDeck.isReversed(seed: session.seed, cardID: card.id), position: position)
        }
        store.completeInteraction(.init(requestID: request.id, tarotDraws: draws, revealedCount: draws.count), sessionID: session.id)
        return draws
    }

    @MainActor private func liveTarotStage(_ store: OracleStore, expected: [TarotDraw], stage: String) async throws -> OracleRun {
        let run = try XCTUnwrap(store.latestRun)
        let result = try XCTUnwrap(run.results.first { $0.method == .tarot })
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.evidence.count, expected.count)
        XCTAssertEqual(run.input.tarotDraws, Array(expected.prefix(3)))
        XCTAssertEqual((run.input.tarotClarificationRounds ?? []).map(\.draw), Array(expected.dropFirst(3)))
        XCTAssertEqual(result.tarotDraws, run.input.tarotDraws)
        XCTAssertEqual(result.tarotClarificationRounds, run.input.tarotClarificationRounds)
        let synthesis = try XCTUnwrap(run.synthesis, "The \(stage) synthesis did not complete")
        XCTAssertEqual(store.messages.last?.content, synthesis.text)
        try await assertLiveTarotResponse(store, stage: stage)
        let orientations = expected.map { "\($0.cardID):\($0.isReversed ? "reversed" : "upright")" }.joined(separator: ", ")
        recordLiveTarotText(synthesis.text, stage: "\(stage) [\(orientations)]")
        return run
    }

    @MainActor private func assertLiveTarotResponse(_ store: OracleStore, stage: String, since: Date? = nil) async throws {
        let report = await store.client.lastSuccessfulConnection
        let response = try XCTUnwrap(report, "No live response for \(stage)")
        let actual = try XCTUnwrap(response.actualModel)
        XCTAssertTrue(DeepSeekClient.modelsMatch(requested: "deepseek-v4-pro", returned: actual))
        XCTAssertEqual(response.finishReason, "stop")
        if let since { XCTAssertGreaterThanOrEqual(response.checkedAt, since, "No fresh live response for \(stage)") }
        XCTAssertNil(store.notice, "Unexpected store fallback during \(stage)")
    }

    private func recordLiveTarotText(_ text: String, stage: String) {
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        print("[STAGED_TAROT_LIVE] \(stage) | \(firstLine)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "Staged Tarot synthetic response: \(stage)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testSyntheticCareerRelationshipAndTravelJourneysWithPro() async throws {
        guard ProcessInfo.processInfo.environment["BLINDORACLE_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Live API smoke is opt-in")
        }
        let journeys: [(name: String, method: OracleMethod, question: String, followUp: String)] = [
            ("career", .xiaoliuren,
             "这是虚构练习。现岗位稳定，有个新岗位自主权更大，但主管没明确试用期目标。请只用小六壬，告诉我现在应先接受，还是先留在原岗位核对条件？",
             "还是这个岗位选择。如果对方不愿明确试用期目标，我现在最先该做什么？请给一个动作。"),
            ("relationship", .tarot,
             "这是虚构练习。最近一周，对方两次取消见面但都没有提新时间。请只用塔罗三张牌，告诉我该继续主动约，还是等对方提出时间？",
             "还是刚才这段关系。牌面能知道对方是不是已经不在乎我吗？如果不能，我该观察哪一件事？"),
            ("travel", .liuyao,
             "这是虚构练习。周末要去邻市看一场展览，场馆没确认开放时段。我可以周六上午或下午出发，周日也能调整。请只用六爻，告诉我先准备哪一个方案？",
             "还是这次行程。你能直接断定周六上午几点出发一定顺利吗？如果不能，给我一个实际的出发条件。")
        ]
        // Each journey gets its own conversation and vault. Collect every
        // outcome even if one scenario encounters a routing or provider error.
        let tasks = journeys.map { journey in
            Task { @MainActor in
                try await runSyntheticJourney(name: journey.name, method: journey.method, question: journey.question, followUp: journey.followUp)
            }
        }
        for (journey, task) in zip(journeys, tasks) {
            do { try await task.value }
            catch { XCTFail("\(journey.name): \(error.localizedDescription)") }
        }
    }

    @MainActor private func runSyntheticJourney(name: String, method: OracleMethod, question: String, followUp: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(name)-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OracleStore(vault: LocalVault(directory: directory))
        _ = try XCTUnwrap(store.hasCredential ? true : nil, "The test host needs a usable credential and network mode")
        defer { if store.isBusy { store.stop() } }

        let initialRequest = Date()
        store.send(question)
        try await waitForLiveTarot(store, stage: "\(name) initial plan")
        let plan = try XCTUnwrap(store.pendingPlan, "\(name) should produce a fresh intake")
        XCTAssertEqual(plan.action, "intake")
        XCTAssertEqual(plan.methods, [method])
        XCTAssertNil(plan.baseRunID)
        try await assertLiveTarotResponse(store, stage: "\(name) initial plan", since: initialRequest)
        let synthesisRequest = Date()
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false, sessionID: store.intakeSessionID))
        if method == .tarot {
            _ = try confirmLiveTarotCards(["cups-02", "pentacles-06", "swords-04"], in: store)
        } else if method == .liuyao {
            let session = try XCTUnwrap(store.pendingInteraction)
            let request = try XCTUnwrap(session.currentRequest)
            XCTAssertEqual(request.kind, .coins)
            store.completeInteraction(.init(requestID: request.id, lines: [7, 8, 8, 9, 7, 8]), sessionID: session.id)
        } else {
            XCTAssertNil(store.pendingInteraction)
        }
        try await waitForLiveTarot(store, stage: "\(name) initial synthesis")
        let original = try XCTUnwrap(store.latestRun)
        let initial = try XCTUnwrap(original.synthesis, "\(name) first synthesis did not complete")
        XCTAssertEqual(original.results.map(\.method), [method])
        try await assertLiveTarotResponse(store, stage: "\(name) initial synthesis", since: synthesisRequest)
        recordJourneyText(initial.text, stage: "\(name) initial")

        for repeatIndex in 0..<(name == "career" ? 2 : 1) {
            let started = Date()
            store.send(followUp)
            try await waitForLiveTarot(store, stage: "\(name) follow-up")
            XCTAssertNil(store.pendingInteraction, "An ordinary follow-up should preserve the draw")
            XCTAssertNil(store.pendingPlan, "An ordinary follow-up should not ask for new intake")
            XCTAssertEqual(store.runs.map(\.id), [original.id])
            let reply = try XCTUnwrap(store.messages.last)
            XCTAssertEqual(reply.role, .assistant)
            XCTAssertEqual(reply.runID, original.id)
            try await assertLiveTarotResponse(store, stage: "\(name) follow-up", since: started)
            recordJourneyText(reply.content, stage: "\(name) follow-up \(repeatIndex + 1)")
        }

        guard name == "travel" else { return }
        let supplementRequest = Date()
        store.send("还是刚才的行程，在原结果上只加上小六壬，辅助选择出发节奏。请保留已有结果，不重新投掷。")
        try await waitForLiveTarot(store, stage: "travel supplement")
        XCTAssertNil(store.pendingInteraction)
        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(store.runs.count, 2)
        let supplemented = try XCTUnwrap(store.latestRun)
        let supplementText = try XCTUnwrap(supplemented.synthesis?.text)
        let originalSixLines = try XCTUnwrap(original.results.first { $0.method == .liuyao })
        XCTAssertEqual(supplemented.plan.baseRunID, original.id)
        XCTAssertEqual(supplemented.input.manualLines, original.input.manualLines)
        XCTAssertEqual(supplemented.results.first { $0.method == .liuyao }?.id, originalSixLines.id)
        XCTAssertTrue(supplemented.results.contains { $0.method == .xiaoliuren && ($0.status == .complete || $0.status == .partial) })
        try await assertLiveTarotResponse(store, stage: "travel supplement", since: supplementRequest)
        recordJourneyText(supplementText, stage: "travel supplement")

        let newRequest = Date()
        store.send("换个问题。只用塔罗三张牌，我应该接受新的远程工作邀请，还是留在目前的团队？")
        try await waitForLiveTarot(store, stage: "travel to career new topic")
        let fresh = try XCTUnwrap(store.pendingPlan)
        XCTAssertEqual(fresh.action, "intake")
        XCTAssertEqual(fresh.methods, [.tarot])
        XCTAssertNil(fresh.baseRunID)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(store.runs.count, 2)
        try await assertLiveTarotResponse(store, stage: "travel to career new topic", since: newRequest)
        print("[JOURNEY_LIVE] travel to career | fresh Tarot intake, original runs unchanged")
    }

    private func recordJourneyText(_ text: String, stage: String) {
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let first = text.split(whereSeparator: { "。！？\n".contains($0) }).first.map(String.init) ?? text
        print("[JOURNEY_LIVE] \(stage) | \(first)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "Synthetic journey: \(stage)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRelationshipFollowUpWithReversedFourOfSwordsUsesSavedFacts() async throws {
        let client = try liveClient()
        let original = "这是虚构练习。最近一周，对方两次取消见面但都没有提新时间。该继续主动约，还是等对方提出时间？"
        let profile = OracleProfile()
        let draws = zip(["cups-02", "pentacles-06", "swords-04"], TarotDeck.positions).map { id, position in
            TarotDraw(cardID: id, isReversed: true, position: position)
        }
        let input = OracleInput(question: original, profile: profile, seed: 42, subject: "事件", tarotDraws: draws, participants: [])
        let plan = OraclePlan(intent: "见面安排", subject: "事件", methods: [.tarot], requiredFields: [], note: "", question: original)
        let result = try await TarotPlugin().calculate(input)
        XCTAssertEqual(result.status, .complete)
        let prior = ReadingSynthesis(text: "建议先等对方提出具体见面时间。", alternatives: [])
        let run = OracleRun(input: input, plan: plan, results: [result], synthesis: prior)
        let collector = StreamCollector()
        let text = try await client.followUp(
            question: "还是刚才这段关系。牌面能知道对方是不是已经不在乎我吗？如果不能，我该观察哪一件事？",
            run: run, profile: profile, history: [.init(role: "user", content: original), .init(role: "assistant", content: prior.text)]
        ) { collector.append($0) }
        XCTAssertEqual(collector.text, text)
        let report = await client.lastSuccessfulConnection
        let model = try XCTUnwrap(report?.actualModel)
        XCTAssertTrue(DeepSeekClient.modelsMatch(requested: "deepseek-v4-pro", returned: model))
        XCTAssertEqual(report?.finishReason, "stop")
        recordJourneyText(text, stage: "relationship focused retest")
    }

    func testPlannerLocalPluginsAndStreamingReading() async throws {
        let client = try liveClient()
        let registry = PluginRegistry()
        var profile = OracleProfile()
        profile.displayName = "合成测试档案"; profile.familyName = "王"; profile.givenName = "明"; profile.sex = "男"
        profile.birthDate = ISO8601DateFormatter().date(from: "1992-08-15T04:00:00Z")
        profile.birthPlace = "上海"; profile.birthLatitude = 31.2304; profile.birthLongitude = 121.4737
        profile.currentTimeZoneID = "Asia/Shanghai"
        let question = "我想梳理接下来一个月的工作节奏，怎样安排手头计划更稳妥？"
        let plan = try await client.plan(question: question, profile: profile, plugins: registry.descriptors, history: [])
        XCTAssertFalse(plan.methods.isEmpty)
        XCTAssertTrue(plan.methods.allSatisfy { registry.plugin($0) != nil })
        let input = OracleInput(question: question, profile: profile, numbers: [12,23,6], seed: 42)
        let results = await registry.calculate(input, methods: plan.methods) { _ in }
        XCTAssertFalse(results.isEmpty)
        let run = OracleRun(input: input, plan: plan, results: results)
        let collector = StreamCollector()
        let reading = try await client.synthesize(run: run, weights: PreferenceLearning.initial, history: []) { collector.append($0) }
        XCTAssertFalse(reading.text.isEmpty)
        XCTAssertTrue(reading.alternatives.isEmpty || reading.alternatives.count == 2)
        XCTAssertEqual(collector.text, reading.text)
    }

    func testNamedPeopleAreCollectedIncrementallyAndJointReadingRetainsBothResults() async throws {
        let client = try liveClient()
        let registry = PluginRegistry()
        let firstText = "先留存两个人的资料：姓名：张三，男，1995年1月2日出生；姓名：李四，女，1996年3月4日出生。先保存资料，不要算卦。"
        // Match OracleStore: explicit local facts are saved before asking the
        // model to route the message; model extraction can supplement them.
        var people = ProfileDirectory.applying(ProfileDirectory.parseExplicitUpdates(in: firstText, profiles: []), to: []).profiles
        let first = try await client.plan(question: firstText, profile: OracleProfile(), plugins: registry.descriptors, history: [], profiles: people)
        XCTAssertEqual(first.action, "collect")
        XCTAssertTrue(first.methods.isEmpty)
        let firstUpdates = ProfileDirectory.groundedUpdates(first.profileUpdates ?? [], in: firstText, profiles: people)
        people = ProfileDirectory.applying(firstUpdates, to: people).profiles
        XCTAssertEqual(Set(people.map(\.resolvedName)), ["张三", "李四"])
        let secondText = "补充张三的出生时间08:30，出生时区Asia/Shanghai；李四的出生时间不确定，出生时区Asia/Shanghai。只补充资料。"
        let history = [AIConversationTurn(role: "user", content: firstText), AIConversationTurn(role: "assistant", content: first.note)]
        people = ProfileDirectory.applying(ProfileDirectory.parseExplicitUpdates(in: secondText, profiles: people), to: people).profiles
        XCTAssertEqual(people.first { $0.resolvedName == "张三" }?.birthTimeText, "08:30")
        let second = try await client.plan(question: secondText, profile: OracleProfile(), plugins: registry.descriptors, history: history, profiles: people)
        XCTAssertEqual(second.action, "collect")
        let secondUpdates = ProfileDirectory.groundedUpdates(second.profileUpdates ?? [], in: secondText, profiles: people)
        people = ProfileDirectory.applying(secondUpdates, to: people).profiles
        XCTAssertEqual(people.first { $0.resolvedName == "张三" }?.birthTimeText, "08:30")
        XCTAssertEqual(people.first { $0.resolvedName == "李四" }?.birthDateText, "1996-03-04")
        XCTAssertEqual(people.first { $0.resolvedName == "李四" }?.birthTimeKnown, false)
        let question = "请只用八字，联合看看张三和李四的友情相处与沟通建议，分别保留两个人的资料。"
        let plan = try await client.plan(question: question, profile: OracleProfile(), plugins: registry.descriptors, history: history, profiles: people)
        XCTAssertEqual(plan.subject, "多人")
        XCTAssertEqual(plan.methods, [.bazi])
        let selected = Set(plan.participantIDs ?? [])
        XCTAssertEqual(selected, Set(people.map(\.id)))
        let input = OracleInput(question: question, profile: people[0], seed: 42, subject: "多人", participants: people, relationship: "友情")
        let results = await registry.calculate(input, methods: plan.methods) { _ in }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.compactMap(\.participantID)), Set(people.map(\.id)))
        let run = OracleRun(input: input, plan: plan, results: results)
        let reading = try await client.synthesize(run: run, weights: PreferenceLearning.initial, history: []) { _ in }
        XCTAssertTrue(reading.text.contains("张三"))
        XCTAssertTrue(reading.text.contains("李四"))
    }
}

private actor LiveProgressCollector {
    private var stages: [AIReadingProgress] = []
    func append(_ stage: AIReadingProgress) { stages.append(stage) }
    func snapshot() -> [AIReadingProgress] { stages }
}

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var content = ""
    var text: String { lock.lock(); defer { lock.unlock() }; return content }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; content += value }
}
