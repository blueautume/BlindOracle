import XCTest
@testable import BlindOracle

@MainActor final class AutomaticMethodWorkflowTests: XCTestCase {
    private let shortTerm: Set<OracleMethod> = [.tarot, .liuyao, .meihua, .qimen, .xiaoliuren]
    private let longTerm: Set<OracleMethod> = [.bazi, .ziwei, .astrology]

    func testShortTermCareerChoiceCompletesBothMethodsWithOneIntake() async throws {
        let question = "最近的工作，该进还是该守？"
        let fixture = try await fixture(question: question, proposedMethods: [.tarot])
        let plan = try await askForIntake(question, in: fixture)
        XCTAssertEqual(Set(plan.methods), [.tarot, .liuyao])
        XCTAssertTrue((plan.mandatoryMethods ?? []).isEmpty)
        XCTAssertTrue(fixture.store.runs.isEmpty)
        XCTAssertNil(fixture.store.pendingInteraction, "Planning alone must not start a draw or cast.")
        XCTAssertTrue(fixture.store.confirmGroupIntake(profiles: fixture.store.intakeParticipants, numbers: [],
                                                        castingProfile: fixture.person))

        let methods = try completeInteractions(in: fixture.store)
        XCTAssertEqual(methods.count, 2)
        XCTAssertEqual(Set(methods), [.tarot, .liuyao])
        try await waitUntilSettled(fixture.store)
        XCTAssertEqual(fixture.store.runs.count, 1)
        let run = try XCTUnwrap(fixture.store.runs.first)
        XCTAssertEqual(run.input.question, question)
        XCTAssertEqual(Set(run.results.map(\.method)), [.tarot, .liuyao])
        XCTAssertTrue(run.results.allSatisfy { [.complete, .partial].contains($0.status) })
        XCTAssertEqual(run.synthesis?.text, WorkflowTransport.answer)
        XCTAssertEqual(WorkflowTransport.requests(for: fixture.key), ["plan", "synthesize"])
    }

    func testAutomaticSelectionsRespondToPhrasingTimeHorizonAndScope() async throws {
        let cases: [(String, [OracleMethod], Set<OracleMethod>)] = [
            ("现在转岗，还是继续待在原团队？", [], [.tarot, .liuyao]),
            ("Should I accept the offer or stay in my role?", [.tarot], [.tarot, .liuyao]),
            ("接下来两周工作进展如何？", [.tarot], [.meihua, .xiaoliuren]),
            ("未来五年我的事业发展趋势怎么样？", [.tarot], [.bazi, .ziwei]),
            ("未来五年我的事业趋势如何；眼下这份工作，该进还是该守？", [.tarot], [.tarot, .liuyao, .bazi, .ziwei])
        ]
        for (question, proposed, expected) in cases {
            let fixture = try await fixture(question: question, proposedMethods: proposed)
            let plan = try await askForIntake(question, in: fixture)
            XCTAssertEqual(plan.question, question)
            XCTAssertEqual(Set(plan.methods), expected, question)
            XCTAssertEqual(plan.methods.count, expected.count, "No duplicate methods for \(question)")
            XCTAssertTrue((plan.mandatoryMethods ?? []).isEmpty, question)
            XCTAssertEqual(WorkflowTransport.requests(for: fixture.key), ["plan"], question)
        }
    }

    func testScopeRichCareerQuestionUsesShortAndLongMethodsWithABoundedPlan() async throws {
        let question = "我想判断这周该不该接新工作，还想了解入职后三个月能否适应，以及未来五年对事业和收入的影响。"
        let fixture = try await fixture(question: question, proposedMethods: [])
        let plan = try await askForIntake(question, in: fixture)
        let methods = Set(plan.methods)
        XCTAssertFalse(methods.isDisjoint(with: shortTerm))
        XCTAssertFalse(methods.isDisjoint(with: longTerm))
        XCTAssertEqual(methods, [.liuyao, .tarot, .meihua, .xiaoliuren, .bazi, .ziwei])
        XCTAssertTrue(methods.isSubset(of: shortTerm.union(longTerm)))
    }

    func testExplicitOnlyAndExcludedMethodsRemainUserControlled() async throws {
        let explicitCases: [(String, Set<OracleMethod>)] = [
            ("眼下我该不该接这份工作？只用塔罗，其他方法不要加。", [.tarot]),
            ("只用八字和塔罗看这份工作该不该接，别用六爻。", [.bazi, .tarot])
        ]
        for (question, expected) in explicitCases {
            let fixture = try await fixture(question: question, proposedMethods: [.qimen, .xiaoliuren])
            let plan = try await askForIntake(question, in: fixture)
            XCTAssertEqual(Set(plan.methods), expected, question)
            XCTAssertEqual(Set(plan.mandatoryMethods ?? []), expected, question)
        }

        for exclusion in ["眼下这份工作，我该进还是该守？不要用塔罗。",
                          "Should I take the offer or wait? Please do not use Tarot."] {
            let fixture = try await fixture(question: exclusion, proposedMethods: [.tarot])
            let plan = try await askForIntake(exclusion, in: fixture)
            XCTAssertFalse(plan.methods.contains(.tarot))
            XCTAssertTrue(plan.methods.contains(.liuyao))
            XCTAssertTrue(Set(plan.methods).isSubset(of: shortTerm))
            XCTAssertTrue((plan.mandatoryMethods ?? []).isEmpty)
        }
    }

    func testExplicitMethodCanBeCombinedWithOtherRelevantMethodsOnRequest() async throws {
        let question = "先用八字看看，也结合其他方法判断眼下该不该接新工作。"
        let fixture = try await fixture(question: question, proposedMethods: [.xiaoliuren])
        let plan = try await askForIntake(question, in: fixture)
        XCTAssertEqual(Set(plan.methods), [.bazi, .liuyao, .tarot])
        XCTAssertEqual(plan.mandatoryMethods, [.bazi])
        XCTAssertTrue(fixture.store.runs.isEmpty)
        XCTAssertNil(fixture.store.pendingInteraction)
    }

    func testAmbiguousReferenceAndConsultationDoNotStartAReading() async throws {
        let reference = "那件事的情况会怎么样？"
        let ambiguous = try await fixture(question: reference, proposedMethods: [.tarot, .liuyao], relation: .ambiguous)
        ambiguous.store.send(reference)
        try await waitUntilSettled(ambiguous.store)
        assertNoReadingWork(ambiguous.store)
        XCTAssertEqual(WorkflowTransport.requests(for: ambiguous.key), ["plan"])

        let consultation = "塔罗和六爻有什么区别？"
        let explaining = try await fixture(question: consultation, proposedMethods: [.tarot, .liuyao])
        explaining.store.send(consultation)
        try await waitUntilSettled(explaining.store)
        assertNoReadingWork(explaining.store)
        XCTAssertEqual(WorkflowTransport.requests(for: explaining.key), ["follow_up"])
        XCTAssertEqual(explaining.store.messages.last?.content, WorkflowTransport.answer)
    }

    func testCoveredFollowUpUsesExistingResultWithoutOpeningAnotherForm() async throws {
        let question = "刚才这份工作选择，能举例说说怎样核对试用期条款吗？"
        let fixture = try await fixture(question: question, proposedMethods: [.bazi, .ziwei], action: "reply",
                                        operation: .answer, coverage: .existing, relation: .continuation)
        let oldRun = try XCTUnwrap(fixture.store.runs.first)
        fixture.store.send(question)
        try await waitUntilSettled(fixture.store)
        assertNoReadingWork(fixture.store, keeping: [oldRun.id])
        XCTAssertEqual(fixture.store.runs.first?.results.map(\.id), oldRun.results.map(\.id))
        XCTAssertEqual(fixture.store.runs.first?.input.tarotDraws, oldRun.input.tarotDraws)
        XCTAssertEqual(fixture.store.messages.last?.runID, oldRun.id)
        XCTAssertEqual(fixture.store.messages.last?.content, WorkflowTransport.answer)
        XCTAssertEqual(WorkflowTransport.requests(for: fixture.key), ["plan", "follow_up"])
    }

    func testSameTopicWithNewLongTermDimensionAddsResultsWithoutDrawingTarotAgain() async throws {
        let question = "同一份工作，再看接下来五年的事业发展趋势。"
        let fixture = try await fixture(question: question, proposedMethods: [.tarot], action: "supplement",
                                        coverage: .additional, relation: .continuation)
        let original = try XCTUnwrap(fixture.store.runs.first)
        let originalResult = try XCTUnwrap(original.results.first)
        fixture.store.send(question)
        try await waitUntilSettled(fixture.store)
        if let pending = fixture.store.pendingPlan {
            XCTAssertEqual(pending.baseRunID, original.id)
            XCTAssertTrue(fixture.store.confirmGroupIntake(profiles: fixture.store.intakeParticipants, numbers: []))
        }
        XCTAssertFalse(try completeInteractions(in: fixture.store).contains(.tarot), "Adding a dimension must keep the saved draw.")
        try await waitUntilSettled(fixture.store)

        XCTAssertEqual(fixture.store.runs.count, 2)
        let supplement = try XCTUnwrap(fixture.store.runs.last)
        XCTAssertEqual(supplement.plan.baseRunID, original.id)
        XCTAssertFalse(Set(supplement.results.map(\.method)).isDisjoint(with: longTerm))
        XCTAssertTrue(supplement.reusedResultIDs?.contains(originalResult.id) == true)
        XCTAssertEqual(supplement.input.seed, original.input.seed)
        XCTAssertEqual(supplement.input.tarotDraws, original.input.tarotDraws)
        XCTAssertEqual(fixture.store.runs.first?.results.map(\.id), [originalResult.id])
        XCTAssertEqual(WorkflowTransport.requests(for: fixture.key), ["plan", "synthesize"])
    }

    func testChangingToIndependentTopicDoesNotInheritEarlierMethodsOrReading() async throws {
        let question = "换个话题，未来五年我的事业发展趋势怎么样？"
        let fixture = try await fixture(question: question, proposedMethods: [.tarot], action: "reply",
                                        relatedHistory: true)
        let original = try XCTUnwrap(fixture.store.runs.first)
        let plan = try await askForIntake(question, in: fixture)
        XCTAssertEqual(plan.question, question)
        XCTAssertNil(plan.baseRunID)
        XCTAssertEqual(Set(plan.methods), [.bazi, .ziwei])
        XCTAssertNil(fixture.store.pendingInteraction)
        XCTAssertEqual(fixture.store.runs.map(\.id), [original.id])
        XCTAssertEqual(fixture.store.runs.first?.input.tarotDraws, original.input.tarotDraws)
        XCTAssertEqual(WorkflowTransport.requests(for: fixture.key), ["plan"])
    }

    private struct Fixture {
        let store: OracleStore
        let person: OracleProfile
        let key: String
    }

    private func fixture(question: String, proposedMethods: [OracleMethod], action: String = "intake",
                         operation: ReadingExecutionIntent.Operation = .calculate,
                         coverage: ReadingExecutionIntent.Coverage = .changed,
                         relation: ConversationUnderstanding.Relation = .newQuestion,
                         relatedHistory: Bool = false) async throws -> Fixture {
        let key = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-method-workflow-" + key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "BlindOracle.AutomaticMethodWorkflow." + key
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            WorkflowTransport.remove(key)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let vault = LocalVault(directory: directory)
        var person = OracleProfile(familyName: "陈", givenName: "平", sex: "男",
                                   birthDate: Date(timeIntervalSince1970: 708_568_200),
                                   birthTimeZoneID: "Asia/Shanghai", birthPlace: "上海市黄浦区",
                                   birthLatitude: 31.23, birthLongitude: 121.47,
                                   currentPlace: "上海市黄浦区", currentLatitude: 31.23, currentLongitude: 121.47)
        person.birthTimeKnown = true
        try vault.save([person], as: "profiles")
        try vault.save(Optional(person.id), as: "self-profile-id")
        var referenceID: UUID?
        if relatedHistory || relation == .continuation {
            referenceID = try await seedEarlierCareerReading(person: person, vault: vault)
        }
        var understanding: [String: Any] = [
            "relation": relation.rawValue,
            "resolvedQuestion": question,
            "execution": ["operation": operation.rawValue, "coverage": coverage.rawValue, "evidence": question]
        ]
        if relation == .continuation { understanding["referenceMessageID"] = referenceID?.uuidString }
        let proposal: [String: Any] = [
            "action": action, "intent": "职业选择", "subject": "本人", "methods": proposedMethods.map(\.rawValue),
            "requiredFields": [], "mandatoryMethods": [], "note": "请核对本次资料。", "understanding": understanding
        ]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: proposal), as: UTF8.self)
        let response = try JSONSerialization.data(withJSONObject: [
            "model": DeepSeekConfiguration.defaultModel,
            "choices": [["message": ["content": content], "finish_reason": "stop"]]
        ])
        WorkflowTransport.install(response, for: key)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkflowTransport.self]
        let consent = AIDataSharingConsentStore(defaults: defaults)
        await consent.grant()
        let client = DeepSeekClient(accessToken: key, sessionConfiguration: configuration, dataSharingConsent: consent)
        let quota = AIQuotaTaskService(directory: directory.appendingPathComponent("quota"),
                                       sessions: AccountSessionManager(vault: NoAccountSession()))
        let store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client, quotaEndService: quota,
                                castingDefaults: defaults)
        return Fixture(store: store, person: person, key: key)
    }

    private func seedEarlierCareerReading(person: OracleProfile, vault: LocalVault) async throws -> UUID {
        let question = "这周我要不要接这份新工作？"
        var plan = OraclePlan(intent: "职业选择", subject: "本人", methods: [.tarot], requiredFields: [], note: "", question: question)
        plan.participantIDs = [person.id]
        plan.participantNames = [person.participantLabel]
        var input = OracleInput(question: question, profile: person, castingDate: Date(timeIntervalSince1970: 1_730_000_000),
                                seed: 73, subject: "本人", participants: [person])
        input.tarotDraws = zip(["major-00", "cups-01", "swords-14"], TarotDeck.positions).map {
            TarotDraw(cardID: $0.0, isReversed: false, position: $0.1)
        }
        let results = await PluginRegistry().calculate(input, methods: [.tarot]) { _ in }
        XCTAssertEqual(results.map(\.status), [.complete])
        let run = OracleRun(input: input, plan: plan, results: results, synthesis: .init(text: "旧职业问事解读。"),
                            completedAt: input.castingDate)
        let reply = ChatMessage(role: .assistant, content: "旧职业问事解读。", kind: .reading, runID: run.id)
        let conversation = OracleConversation(messages: [ChatMessage(role: .user, content: question), reply])
        try vault.save([run], as: "readings")
        try vault.save(OracleConversationArchive(activeConversationID: conversation.id, conversations: [conversation]),
                       as: ConversationHistory.filename)
        return reply.id
    }

    private func askForIntake(_ question: String, in fixture: Fixture) async throws -> OraclePlan {
        fixture.store.send(question)
        try await waitUntilSettled(fixture.store)
        XCTAssertTrue(fixture.store.showIntake, question)
        return try XCTUnwrap(fixture.store.pendingPlan, question)
    }

    private func completeInteractions(in store: OracleStore) throws -> [OracleMethod] {
        var methods: [OracleMethod] = []
        while let session = store.pendingInteraction, methods.count < OracleMethod.allCases.count {
            let request = try XCTUnwrap(session.currentRequest)
            let response: OracleInteractionResponse
            switch request.kind {
            case .coins:
                response = .init(requestID: request.id, lines: [7, 8, 7, 8, 7, 8])
            case .tarot:
                let draws = zip(session.availableTarotCards.prefix(3), request.tarotPositions).map { card, position in
                    TarotDraw(cardID: card.id, isReversed: TarotDeck.isReversed(seed: session.seed, cardID: card.id), position: position)
                }
                response = .init(requestID: request.id, tarotDraws: draws, revealedCount: 3)
            case .numbers:
                response = .init(requestID: request.id, numbers: [17, 29, 41])
            }
            methods.append(request.method)
            store.completeInteraction(response, sessionID: session.id)
        }
        XCTAssertNil(store.pendingInteraction)
        return methods
    }

    private func waitUntilSettled(_ store: OracleStore) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while store.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy, store.notice ?? store.status)
    }

    private func assertNoReadingWork(_ store: OracleStore, keeping ids: [UUID] = []) {
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showIntake)
        XCTAssertEqual(store.runs.map(\.id), ids)
    }
}

private final class NoAccountSession: AccountSessionStorage {
    func load() throws -> AccountSession? { nil }
    func save(_ session: AccountSession) throws {}
    func delete() throws {}
}

private final class WorkflowTransport: URLProtocol, @unchecked Sendable {
    static let answer = "模拟解读已完成。"
    private struct Script {
        let plannerResponse: Data
        var requests: [String] = []
    }
    private static let lock = NSLock()
    private static var scripts: [String: Script] = [:]

    static func install(_ response: Data, for key: String) {
        lock.withLock { scripts["Bearer " + key] = Script(plannerResponse: response) }
    }

    static func remove(_ key: String) {
        lock.withLock { _ = scripts.removeValue(forKey: "Bearer " + key) }
    }

    static func requests(for key: String) -> [String] {
        lock.withLock { scripts["Bearer " + key]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let purpose = requestPurpose() ?? "unrecognized"
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let plannerResponse = Self.lock.withLock { () -> Data? in
            Self.scripts[authorization]?.requests.append(purpose)
            return Self.scripts[authorization]?.plannerResponse
        }
        let content: Data?
        switch purpose {
        case "plan": content = plannerResponse
        case "follow_up", "synthesize": content = streamedResponse(purpose: purpose)
        default: content = nil
        }
        let contentType = purpose == "plan" ? "application/json" : "text/event-stream"
        guard let content, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": contentType]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: content)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func streamedResponse(purpose: String) -> Data? {
        let text = purpose == "synthesize" ? "{\"text\":\"\(Self.answer)\"}" : Self.answer
        let body = ["choices": [["delta": ["content": text]]]]
        guard let frame = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return Data(("data: " + String(decoding: frame, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8)
    }

    private func requestPurpose() -> String? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var count = stream.read(&buffer, maxLength: buffer.count)
            while count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                count = stream.read(&buffer, maxLength: buffer.count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["purpose"] as? String
    }
}
