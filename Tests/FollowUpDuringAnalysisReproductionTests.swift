import XCTest
@testable import BlindOracle

/// The original reproduction now verifies recovery through the real store,
/// account and quota path, with the old server generation surviving disconnect.
@MainActor final class FollowUpDuringAnalysisReproductionTests: XCTestCase {
    private let original = "我想问一下，我明天运势如何？"
    private let followUp = "我想试一下明天的运势如何"

    func testAppendingDuringPlanningWaitsAndAutomaticallyContinues() async throws {
        let context = try await makeContext()
        defer { context.cleanUp() }
        try await startAndAppend(context)
        XCTAssertTrue(context.store.isBusy)
        XCTAssertNil(context.store.notice)
        XCTAssertFalse(context.store.canRetryAnalysis)
        XCTAssertTrue(isWaiting(context))
        XCTAssertEqual(context.store.messages.filter { $0.role == .user }.map(\.content), [original, followUp])
        try await waitUntil("the old HTTP consumer detaches", context: context) { context.server.snapshot.detachedConsumers == 1 }
        context.server.releaseOriginalGeneration()
        try await waitUntil("the follow-up finishes automatically", context: context) { !context.store.isBusy }

        let snapshot = context.server.snapshot
        XCTAssertNil(context.store.notice)
        XCTAssertFalse(context.store.canRetryAnalysis)
        XCTAssertEqual(context.store.messages.last?.content, FollowUpRegressionServer.acceptedNote)
        XCTAssertEqual(snapshot.successfulQuestions, [followUp])
        XCTAssertEqual(Set(snapshot.requests.map(\.taskID)).count, 2)
        XCTAssertEqual(snapshot.admittedTasks.count, 2, "Waiting must reuse the prepared quota request")
        let replacements = snapshot.requests.filter { $0.question == followUp }
        XCTAssertGreaterThanOrEqual(replacements.count, 2, "The busy rejection must actually have occurred")
        XCTAssertEqual(Set(replacements.map(\.taskID)).count, 1)
        XCTAssertEqual(Set(replacements.map(\.stageID)).count, 1)
        XCTAssertEqual(Set(replacements.map(\.idempotencyKey)).count, 1)
        XCTAssertEqual(Set(replacements.map(\.body)).count, 1)
        XCTAssertFalse(context.store.activities.contains { $0.status == .failed })
        XCTAssertEqual(context.store.messages.filter { $0.role == .user }.map(\.content), [original, followUp])
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
            "scenario": "append while old planning generation is running",
            "busy_rejections": snapshot.rejectedGenerations,
            "new_provider_generations": snapshot.successfulQuestions.count,
            "message_count": context.store.messages.filter { $0.role == .user }.count,
            "waiting_succeeded": true, "notice": context.store.notice ?? ""
        ], options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "follow-up-during-analysis-fixed"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSendingAfterAnExplicitStopAlsoWaitsForTheOldServerGeneration() async throws {
        let context = try await makeContext()
        defer { context.cleanUp() }
        context.store.send(original)
        try await waitUntil("the first generation starts", context: context) { context.server.snapshot.requests.count == 1 }
        context.store.stop()
        XCTAssertFalse(context.store.isBusy)
        context.store.send(followUp)
        try await waitUntil("the new question waits", context: context) {
            context.server.snapshot.rejectedGenerations > 0 && isWaiting(context)
        }
        XCTAssertTrue(context.store.isBusy)
        XCTAssertNil(context.store.notice)
        context.server.releaseOriginalGeneration()
        try await waitUntil("the new question finishes", context: context) { !context.store.isBusy }
        XCTAssertEqual(context.server.snapshot.successfulQuestions, [followUp])
        XCTAssertEqual(context.store.messages.last?.content, FollowUpRegressionServer.acceptedNote)
    }

    func testStoppingDuringTheWaitKeepsMessagesAndPreventsAutomaticResubmission() async throws {
        let context = try await makeContext()
        defer { context.cleanUp() }
        try await startAndAppend(context)
        context.store.stop()
        XCTAssertFalse(context.store.isBusy)
        XCTAssertTrue(context.store.canRetryAnalysis)
        try await Task.sleep(for: .milliseconds(50))
        let stoppedRequests = context.server.snapshot.requests.count
        context.server.releaseOriginalGeneration()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(context.server.snapshot.requests.count, stoppedRequests)
        XCTAssertTrue(context.server.snapshot.successfulQuestions.isEmpty)
        XCTAssertEqual(context.store.messages.filter { $0.role == .user }.map(\.content), [original, followUp])
    }

    func testAnotherAdditionCancelsTheOldWaitAndOnlyProcessesTheLatestQuestion() async throws {
        let context = try await makeContext()
        defer { context.cleanUp() }
        try await startAndAppend(context)
        let latest = "再补充一下，我更关心明天的工作安排"
        context.store.send(latest)
        try await waitUntil("the latest question owns the wait", context: context) {
            context.server.snapshot.requests.contains { $0.question == latest }
                && isWaiting(context)
        }
        context.server.releaseOriginalGeneration()
        try await waitUntil("the latest question finishes", context: context) { !context.store.isBusy }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(context.store.notice)
        XCTAssertEqual(context.server.snapshot.successfulQuestions, [latest])
        XCTAssertEqual(context.store.messages.filter { $0.role == .user }.map(\.content), [original, followUp, latest])
        XCTAssertEqual(context.store.messages.filter { $0.role == .assistant && $0.content == FollowUpRegressionServer.acceptedNote }.count, 1)
    }

    func testSwitchingConversationCancelsTheWaitWithoutRestoringOldMessages() async throws {
        let context = try await makeContext()
        defer { context.cleanUp() }
        try await startAndAppend(context)
        let oldConversation = context.store.activeConversationID
        context.store.newConversation()
        XCTAssertNotEqual(context.store.activeConversationID, oldConversation)
        XCTAssertTrue(context.store.messages.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        let stoppedRequests = context.server.snapshot.requests.count
        context.server.releaseOriginalGeneration()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(context.server.snapshot.requests.count, stoppedRequests)
        XCTAssertTrue(context.store.messages.isEmpty)
        XCTAssertTrue(context.store.activities.isEmpty)
        XCTAssertFalse(context.store.isBusy)
        XCTAssertNil(context.store.notice)
    }

    func testClearingHistoryCancelsTheWaitAndNeverRestoresTheDeletedQuestions() async throws {
        let context = try await makeContext()
        defer { context.cleanUp() }
        try await startAndAppend(context)
        context.store.clearConversationHistory()
        try await Task.sleep(for: .milliseconds(50))
        let stoppedRequests = context.server.snapshot.requests.count
        context.server.releaseOriginalGeneration()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(context.server.snapshot.requests.count, stoppedRequests)
        XCTAssertTrue(context.store.messages.isEmpty)
        XCTAssertTrue(context.store.conversations.isEmpty)
        XCTAssertTrue(context.store.activities.isEmpty)
        XCTAssertFalse(context.store.isBusy)
        XCTAssertFalse(context.store.canRetryAnalysis)
    }

    private func startAndAppend(_ context: FollowUpRegressionContext) async throws {
        context.store.send(original)
        try await waitUntil("the first generation starts", context: context) { context.server.snapshot.requests.count == 1 }
        XCTAssertEqual(context.store.phase, .planning)
        context.store.send(followUp)
        try await waitUntil("the replacement waits instead of failing", context: context) {
            context.server.snapshot.rejectedGenerations > 0 && isWaiting(context)
        }
    }

    private func isWaiting(_ context: FollowUpRegressionContext) -> Bool {
        context.store.status.contains("等待上一份回答完成")
            || context.store.status.contains("Waiting for the previous reply to finish")
    }

    private func makeContext() async throws -> FollowUpRegressionContext {
        let key = UUID().uuidString
        let server = FollowUpRegressionServer()
        FollowUpRegressionURLProtocol.install(server, key: key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-regression-" + key, isDirectory: true)
        let suiteName = "BlindOracle.FollowUpRegression." + key
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FollowUpRegressionURLProtocol.self]
        let api = AccountAPI(configuration: configuration)
        let saved = try AccountSession(response: .init(accessToken: key, refreshToken: "synthetic-refresh",
            expiresIn: 3600, user: .init(id: "synthetic-user", displayName: "Synthetic", email: nil,
                createdAt: "2026-11-16T00:00:00Z")), appleUserID: nil)
        let sessions = AccountSessionManager(api: api, vault: FollowUpRegressionVault(saved))
        let quota = AIQuotaTaskService(directory: directory.appendingPathComponent("quota"), api: api, sessions: sessions)
        let consent = AIDataSharingConsentStore(defaults: defaults)
        await consent.grant()
        let client = DeepSeekClient(accountSessions: sessions, quotaTasks: quota, manageQuota: true,
            sessionConfiguration: configuration, dataSharingConsent: consent,
            generationWaitPolicy: .init(timeout: .seconds(3), initialDelay: .milliseconds(20), maximumDelay: .milliseconds(20)))
        let store = OracleStore(vault: LocalVault(directory: directory.appendingPathComponent("vault")),
            bootstrapCredential: false, aiClient: client, quotaEndService: quota, castingDefaults: defaults)
        return FollowUpRegressionContext(store: store, server: server, key: key, directory: directory,
                                         defaults: defaults, suiteName: suiteName)
    }

    private func waitUntil(_ step: String, context: FollowUpRegressionContext, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                let details = "step=\(step); phase=\(context.store.phase.rawValue); notice=\(context.store.notice ?? "nil"); status=\(context.store.status); server=\(context.server.snapshot)"
                let attachment = XCTAttachment(string: details)
                attachment.name = "follow-up-regression-timeout"
                attachment.lifetime = .keepAlways
                add(attachment)
                throw FollowUpRegressionFailure.timedOut(details)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor private struct FollowUpRegressionContext {
    let store: OracleStore
    let server: FollowUpRegressionServer
    let key: String
    let directory: URL
    let defaults: UserDefaults
    let suiteName: String
    func cleanUp() {
        if store.isBusy { store.stop() }
        FollowUpRegressionURLProtocol.remove(key: key)
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private enum FollowUpRegressionFailure: Error { case timedOut(String), unexpectedRequest, missingQuotaHeaders }

private final class FollowUpRegressionVault: AccountSessionStorage {
    private var session: AccountSession?
    init(_ session: AccountSession) { self.session = session }
    func load() throws -> AccountSession? { session }
    func save(_ session: AccountSession) throws { self.session = session }
    func delete() throws { session = nil }
}

private final class FollowUpRegressionServer: @unchecked Sendable {
    static let acceptedNote = "已收到追加问题。你最想了解哪一方面？"
    struct Request: Hashable {
        let taskID: String
        let stageID: String
        let idempotencyKey: String
        let body: Data
        let question: String
    }
    struct Snapshot {
        var admittedTasks: [String] = []
        var requests: [Request] = []
        var rejectedGenerations = 0
        var detachedConsumers = 0
        var generationStillRunning = true
        var successfulQuestions: [String] = []
    }
    enum Response { case hold; case json(Int, Data) }
    private let lock = NSLock()
    private var state = Snapshot()
    private var firstRequestID: String?
    var snapshot: Snapshot { lock.withLock { state } }
    func releaseOriginalGeneration() { lock.withLock { state.generationStillRunning = false } }

    func response(to request: URLRequest) throws -> Response {
        try lock.withLock {
            let path = (request.url?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.hasSuffix("ai/tasks/start") {
                let body = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: String]
                guard let id = body?["task_id"] else { throw FollowUpRegressionFailure.unexpectedRequest }
                state.admittedTasks.append(id)
                return .json(200, try JSONSerialization.data(withJSONObject: ["task_id": id,
                    "state": "open", "admission_token": "synthetic-admission"]))
            }
            if path.contains("ai/tasks/"), path.hasSuffix("/end") { return .json(204, Data()) }
            guard path.hasSuffix("ai/chat/completions") else { throw FollowUpRegressionFailure.unexpectedRequest }
            guard let taskID = request.value(forHTTPHeaderField: "X-Task-ID"),
                  request.value(forHTTPHeaderField: "X-Task-Token") == "synthetic-admission",
                  let stageID = request.value(forHTTPHeaderField: "X-Stage-ID"), stageID.hasPrefix("plan:"),
                  let idempotency = request.value(forHTTPHeaderField: "Idempotency-Key"),
                  state.admittedTasks.contains(taskID) else { throw FollowUpRegressionFailure.missingQuotaHeaders }
            let body = Self.body(request)
            let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let turns = payload?["messages"] as? [[String: Any]] ?? []
            let content = turns.last?["content"] as? String ?? ""
            let firstLine = content.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? content
            let question = firstLine.hasPrefix("用户本条消息：") ? String(firstLine.dropFirst("用户本条消息：".count)) : firstLine
            state.requests.append(Request(taskID: taskID, stageID: stageID, idempotencyKey: idempotency, body: body, question: question))
            if firstRequestID == nil {
                firstRequestID = idempotency
                return .hold
            }
            if state.generationStillRunning {
                state.rejectedGenerations += 1
                return .json(429, Data(#"{"error":{"code":"generation_in_progress","message":"当前账号已有回答生成中，请等待完成。"}}"#.utf8))
            }
            state.successfulQuestions.append(question)
            let plan: [String: Any] = ["action": "clarify", "intent": "Clarify", "subject": "事件", "methods": [],
                "requiredFields": [], "note": Self.acceptedNote,
                "understanding": ["relation": "ambiguous", "resolvedQuestion": question]]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
            let envelope: [String: Any] = ["model": DeepSeekConfiguration.defaultModel,
                "choices": [["message": ["content": text], "finish_reason": "stop"]]]
            return .json(200, try JSONSerialization.data(withJSONObject: envelope))
        }
    }

    func detach(_ request: URLRequest) {
        lock.withLock {
            guard let firstRequestID, request.value(forHTTPHeaderField: "Idempotency-Key") == firstRequestID,
                  state.detachedConsumers == 0 else { return }
            state.detachedConsumers += 1
        }
    }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(bytes, count: count)
        }
        return data
    }
}

private final class FollowUpRegressionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: FollowUpRegressionServer] = [:]
    static func install(_ server: FollowUpRegressionServer, key: String) { lock.withLock { servers[key] = server } }
    static func remove(key: String) { _ = lock.withLock { servers.removeValue(forKey: key) } }
    private var server: FollowUpRegressionServer? {
        let key = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        return Self.lock.withLock { Self.servers[key] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server, let url = request.url else { throw FollowUpRegressionFailure.unexpectedRequest }
            switch try server.response(to: request) {
            case .hold: return
            case .json(let status, let data):
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { server?.detach(request) }
}
