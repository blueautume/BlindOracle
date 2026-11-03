import XCTest
@testable import BlindOracle

/// Opt-in only: BLINDORACLE_LIVE_SMOKE=1 in the test scheme. Uses synthetic fixture data.
final class LiveIntegrationTests: XCTestCase {
    private func liveClient() throws -> DeepSeekClient {
        guard ProcessInfo.processInfo.environment["BLINDORACLE_LIVE_SMOKE"] == "1" else { throw XCTSkip("Live API smoke is opt-in") }
        // Unsigned simulator hosts cannot always access the keychain. The
        // ignored Debug-only fixture is read in memory and never logged.
        let bundled = Bundle.main.url(forResource: "dev-key", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let key = KeychainStore.shared.string() ?? bundled, !key.isEmpty else { throw XCTSkip("Development key unavailable") }
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
        let client = try liveClient()
        let registry = PluginRegistry()
        let question = "请只用塔罗三张牌，帮我梳理是否接下一个新工作项目，以及接之前需要考虑什么。请先让我抽牌，最后用中文解读。"
        let plan = try await client.plan(question: question, profile: OracleProfile(), plugins: registry.descriptors, history: [])
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
        let reading = try await client.synthesize(run: run, weights: PreferenceLearning.initial, history: [], onProgress: { stage in
            await progress.append(stage)
        }) { collector.append($0) }
        XCTAssertFalse(reading.text.isEmpty)
        XCTAssertEqual(collector.text, reading.text)
        XCTAssertGreaterThan(reading.text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count, 80)
        let stages = await progress.snapshot()
        XCTAssertEqual(stages, [.preparing, .requesting, .writing, .validating])
    }

    @MainActor func testStagedTarotUsesRealPlannerAndSynthesisAcrossFiveSavedCards() async throws {
        guard ProcessInfo.processInfo.environment["BLINDORACLE_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Live API smoke is opt-in")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("staged-tarot-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OracleStore(vault: LocalVault(directory: directory))
        guard store.hasCredential else { throw XCTSkip("The test host could not load the bundled credential") }
        guard !store.localOnly else { throw XCTSkip("The test host is configured for local-only answers") }
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
        _ = try XCTUnwrap(store.hasCredential && !store.localOnly ? true : nil, "The test host needs a usable credential and network mode")
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
