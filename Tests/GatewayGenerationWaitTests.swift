import CryptoKit
import XCTest
@testable import BlindOracle

/// Exercises the managed transport, rather than a credential fixture that
/// bypasses quota admission. No request reaches a real server or provider.
@MainActor final class GatewayGenerationWaitTests: XCTestCase {
    func testOnlyKnownBusyResponsesWaitAndReplayTheSamePreparedRequest() async throws {
        for (status, code) in [(429, "generation_in_progress"), (429, "sandbox_installation_busy"), (409, "stage_running")] {
            let harness = try await WaitHarness.make(mode: .busy(status, code))
            defer { harness.dispose() }
            let journal = WaitJournal()
            let operation = Task { try await harness.checkConnection(journal: journal) }
            try await waitUntil { journal.waits == [true] }
            XCTAssertEqual(harness.server.snapshot.acceptedGenerations, 0)
            harness.server.releaseGenerationSlot()
            let result = try await operation.value
            XCTAssertEqual(result.actualModel, DeepSeekConfiguration.defaultModel)
            assertOnePreparedRequest(harness.server.snapshot)
            XCTAssertEqual(journal.waits, [true, false])
        }
    }

    func testStreamingBusyResponseNeverBecomesAnswerTextAndResumesOnlyOnce() async throws {
        let harness = try await WaitHarness.make(mode: .busy(429, "generation_in_progress"))
        defer { harness.dispose() }
        let journal = WaitJournal()
        let operation = Task {
            try await AIQuotaTaskScope.$stage.withValue(harness.stage(journal: journal)) {
                try await harness.client.followUp(question: "Synthetic follow-up", run: nil,
                    profile: OracleProfile(), history: [], language: .english) { journal.addPiece($0) }
            }
        }
        try await waitUntil { journal.waits == [true] }
        XCTAssertEqual(journal.text, "")
        harness.server.releaseGenerationSlot()
        let text = try await operation.value
        XCTAssertEqual(text, "Received. Continuing.")
        XCTAssertEqual(journal.text, text)
        XCTAssertFalse(text.contains("generation_in_progress"))
        assertOnePreparedRequest(harness.server.snapshot)
        XCTAssertEqual(journal.waits, [true, false])
    }

    func testTenThousandMessageFollowUpFitsTheGatewayAndRetainsCurrentContext() async throws {
        let harness = try await WaitHarness.make(mode: .ready)
        defer { harness.dispose() }
        let stage = AIQuotaStage(taskID: UUID(), stageID: "answer")
        let summary = "Previous conversation summary (profile records are stored separately):\nAn agreed date."
        let history = [AIConversationTurn(role: "assistant", content: summary)] + (0..<5_000).flatMap { index in
            [AIConversationTurn(role: "user", content: "Earlier question \(index)"),
             AIConversationTurn(role: "assistant", content: "Earlier answer \(index)")]
        }

        let reply = try await harness.followUp(stage: stage, question: "Continue with the earlier subject.",
            history: history, resolvedQuestion: "What does the saved conclusion mean?", citedQuestion: "The cited original question.")
        XCTAssertEqual(reply, "Received. Continuing.")

        let snapshot = harness.server.snapshot
        let attempt = try XCTUnwrap(snapshot.attempts.first)
        let messages = try assertRequestFitsGateway(attempt.body)
        XCTAssertEqual(snapshot.attempts.count, 1)
        XCTAssertEqual(snapshot.admissions, 1)
        XCTAssertEqual(attempt.stageID, stage.stageID)
        XCTAssertEqual(messages.first?.role, "system")
        XCTAssertEqual(messages.last?.role, "user")
        let current = try XCTUnwrap(messages.last?.content)
        XCTAssertTrue(current.contains("Continue with the earlier subject."))
        XCTAssertTrue(current.contains("The cited original question."))
        XCTAssertEqual(messages.dropFirst().first?.content, summary)
        let retainedHistory = Array(messages.dropFirst(2).dropLast())
        XCTAssertEqual(retainedHistory.first?.role, "user")
        XCTAssertEqual(retainedHistory.last?.content, "Earlier answer 4999")
        XCTAssertTrue(retainedHistory.enumerated().allSatisfy { index, message in
            message.role == (index.isMultiple(of: 2) ? "user" : "assistant")
        })
        XCTAssertFalse(retainedHistory.contains { $0.content == "Earlier question 0" })
    }

    func testFollowUpUsesActualUTF8AndEscapedJSONBudgets() async throws {
        let largeHistoryItems = [
            String(repeating: "问🧪", count: 40_000),
            String(repeating: "\u{0001}", count: 180_000)
        ]
        XCTAssertGreaterThan(largeHistoryItems[0].utf8.count, 262_144)
        XCTAssertLessThan(largeHistoryItems[1].utf8.count, 262_144)
        let encodedEscapes = try JSONSerialization.data(withJSONObject: ["content": largeHistoryItems[1]])
        XCTAssertGreaterThan(encodedEscapes.count, 1_048_576)

        for item in largeHistoryItems {
            let harness = try await WaitHarness.make(mode: .ready)
            defer { harness.dispose() }
            let oldTurn = [AIConversationTurn(role: "user", content: "Old question with a huge answer."),
                           AIConversationTurn(role: "assistant", content: item)]
            let recentTurn = [AIConversationTurn(role: "user", content: "Recent question"),
                              AIConversationTurn(role: "assistant", content: "Recent answer")]
            let stage = AIQuotaStage(taskID: UUID(), stageID: "answer")
            let reply = try await harness.followUp(stage: stage, question: "Current question", history: oldTurn + recentTurn)
            XCTAssertEqual(reply, "Received. Continuing.")
            let attempt = try XCTUnwrap(harness.server.snapshot.attempts.first)
            let sent = try assertRequestFitsGateway(attempt.body)
            XCTAssertEqual(sent.dropFirst().map(\.content), ["Recent question", "Recent answer", "Current question"])
        }
    }

    func testOversizedCurrentQuestionStopsBeforeAdmission() async throws {
        let harness = try await WaitHarness.make(mode: .ready)
        defer { harness.dispose() }
        let stage = AIQuotaStage(taskID: UUID(), stageID: "answer")
        let question = String(repeating: "问", count: 90_000)
        do {
            _ = try await harness.followUp(stage: stage, question: question, history: [])
            XCTFail("The request cannot make the current question fit by removing history")
        } catch {
            assertGateway(error, status: 413, code: "context_too_large")
        }
        XCTAssertEqual(harness.server.snapshot.admissions, 0)
        XCTAssertTrue(harness.server.snapshot.attempts.isEmpty)
    }

    func testCompatibleSavedRequestReplaysOriginalBytesAfterUpgrade() async throws {
        let harness = try await WaitHarness.make(mode: .ready)
        defer { harness.dispose() }
        let stage = AIQuotaStage(taskID: UUID(), stageID: "answer")
        let olderMessages = (0..<160).map { index in
            AIConversationTurn(role: index.isMultiple(of: 2) ? "user" : "assistant", content: "Stored message \(index)")
        }
        let original = try legacyFollowUpBody(history: olderMessages)
        XCTAssertLessThan(original.count, 1_048_576)
        try harness.seedLegacySnapshot(body: original, stage: stage, purpose: "follow_up")

        // Reopening a saved step must work even when the newly assembled
        // candidate could not be sent as a fresh request.
        let reply = try await harness.followUp(stage: stage, question: String(repeating: "问", count: 90_000), history: [])
        XCTAssertEqual(reply, "Received. Continuing.")
        let attempt = try XCTUnwrap(harness.server.snapshot.attempts.first)
        XCTAssertEqual(attempt.body, original)
        XCTAssertEqual(attempt.taskID, harness.serverTaskID(for: stage))
        XCTAssertEqual(attempt.stageID, stage.stageID)
    }

    func testSavedRequestThatCouldNotReachGatewayRebuildsFromOriginalOnSameStage() async throws {
        let harness = try await WaitHarness.make(mode: .ready)
        defer { harness.dispose() }
        let stage = AIQuotaStage(taskID: UUID(), stageID: "answer")
        let body = try legacyFollowUpBody(history: [
            AIConversationTurn(role: "user", content: "Old optional detail"),
            AIConversationTurn(role: "assistant", content: String(repeating: "\u{0001}", count: 180_000)),
            AIConversationTurn(role: "user", content: "Recent original question"),
            AIConversationTurn(role: "assistant", content: "Recent original answer")
        ])
        XCTAssertGreaterThan(body.count, 1_048_576)
        try harness.seedLegacySnapshot(body: body, stage: stage, purpose: "follow_up")

        let first = try await harness.followUp(stage: stage, question: "A later draft", history: [])
        let replay = try await harness.followUp(stage: stage, question: "Another later draft", history: [])
        XCTAssertEqual(first, "Received. Continuing.")
        XCTAssertEqual(replay, first)
        let attempts = harness.server.snapshot.attempts
        XCTAssertEqual(attempts.count, 2)
        let sent = try XCTUnwrap(attempts.first)
        XCTAssertTrue(attempts.allSatisfy { $0.stageID == stage.stageID && $0.taskID == harness.serverTaskID(for: stage) })
        XCTAssertTrue(attempts.allSatisfy { $0.body == sent.body }, "The rebuilt snapshot must be stored before retry")
        let messages = try assertRequestFitsGateway(sent.body)
        XCTAssertEqual(messages.first?.content, "Original system instructions")
        XCTAssertEqual(messages.last?.content, "Original current question")
        XCTAssertTrue(messages.contains { $0.content == "Recent original answer" })
        XCTAssertFalse(messages.contains { $0.content == "Old optional detail" })
        let options = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(options["purpose"] as? String, "follow_up")
        XCTAssertEqual(options["stream"] as? Bool, true)
        XCTAssertEqual(options["max_tokens"] as? Int, 3_499)
    }

    func testOtherLimitsAndNetworkTimeoutsDoNotAutomaticallyRetry() async throws {
        for mode in [WaitServer.Mode.rejected(429, "daily_budget"), .networkFailure(.timedOut)] {
            let harness = try await WaitHarness.make(mode: mode)
            defer { harness.dispose() }
            let journal = WaitJournal()
            do {
                _ = try await harness.checkConnection(journal: journal)
                XCTFail("An unrelated failure must remain explicit")
            } catch {
                switch mode {
                case .rejected(let status, let code): assertGateway(error, status: status, code: code)
                case .networkFailure(let code):
                    XCTAssertEqual((error as NSError).domain, NSURLErrorDomain)
                    XCTAssertEqual((error as NSError).code, code.rawValue)
                default: XCTFail("Unexpected fixture")
                }
            }
            XCTAssertEqual(harness.server.snapshot.attempts.count, 1)
            XCTAssertEqual(journal.waits, [])
        }
    }

    func testCancellingWhileWaitingPreventsAnyFurtherGenerationRequest() async throws {
        let harness = try await WaitHarness.make(mode: .busy(429, "generation_in_progress"), delay: .milliseconds(200))
        defer { harness.dispose() }
        let journal = WaitJournal()
        let operation = Task { try await harness.checkConnection(journal: journal) }
        try await waitUntil { journal.waits == [true] }
        let attempts = harness.server.snapshot.attempts.count
        operation.cancel()
        do { _ = try await operation.value; XCTFail("A stopped wait must not continue") }
        catch {
            XCTAssertTrue(error is CancellationError || (error as NSError).code == URLError.cancelled.rawValue)
        }
        harness.server.releaseGenerationSlot()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(harness.server.snapshot.attempts.count, attempts)
        XCTAssertEqual(harness.server.snapshot.acceptedGenerations, 0)
        XCTAssertEqual(journal.waits, [true, false])
    }

    func testAccountChangeWhileWaitingRejectsTheOldSessionBeforeSendingAgain() async throws {
        let harness = try await WaitHarness.make(mode: .busy(429, "generation_in_progress"), delay: .milliseconds(60))
        defer { harness.dispose() }
        let journal = WaitJournal()
        let operation = Task { try await harness.checkConnection(journal: journal) }
        try await waitUntil { journal.waits == [true] }
        try await harness.sessions.clear()
        harness.server.releaseGenerationSlot()
        do { _ = try await operation.value; XCTFail("The old account cannot resume its request") }
        catch { XCTAssertEqual(error as? AccountAPIError, .staleSession) }
        XCTAssertEqual(harness.server.snapshot.attempts.count, 1)
        XCTAssertEqual(harness.server.snapshot.acceptedGenerations, 0)
        XCTAssertEqual(journal.waits, [true, false])
    }

    func testAccountChangeInWaitCompletionCallbackRejectsTheJSONResponse() async throws {
        try await assertAccountChangeInWaitCompletion(streaming: false)
    }

    func testAccountChangeInWaitCompletionCallbackCancelsTheOpenSSETask() async throws {
        try await assertAccountChangeInWaitCompletion(streaming: true)
    }

    func testWithdrawingConsentWhileWaitingPreventsResendingTheSavedBody() async throws {
        let harness = try await WaitHarness.make(mode: .busy(429, "generation_in_progress"), delay: .milliseconds(60))
        defer { harness.dispose() }
        let journal = WaitJournal()
        let operation = Task { try await harness.checkConnection(journal: journal) }
        try await waitUntil { journal.waits == [true] }
        await harness.consent.revoke()
        harness.server.releaseGenerationSlot()
        do { _ = try await operation.value; XCTFail("Revoked consent must prevent another upload") }
        catch {
            guard case DeepSeekError.dataSharingConsentRequired = error else {
                return XCTFail("Expected the real consent gate, got \(error)")
            }
        }
        XCTAssertEqual(harness.server.snapshot.attempts.count, 1)
        XCTAssertEqual(harness.server.snapshot.acceptedGenerations, 0)
        XCTAssertEqual(journal.waits, [true, false])
    }

    func testWaitingHasATotalDeadlineAndReturnsTheOriginalSafeBusyError() async throws {
        let harness = try await WaitHarness.make(mode: .busy(429, "generation_in_progress"), timeout: .milliseconds(60))
        defer { harness.dispose() }
        let journal = WaitJournal()
        let started = ContinuousClock.now
        do { _ = try await harness.checkConnection(journal: journal); XCTFail("A busy server cannot wait forever") }
        catch { assertGateway(error, status: 429, code: "generation_in_progress") }
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(2))
        XCTAssertGreaterThan(harness.server.snapshot.attempts.count, 1)
        XCTAssertEqual(harness.server.snapshot.acceptedGenerations, 0)
        XCTAssertEqual(journal.waits, [true, false])
    }

    private func assertAccountChangeInWaitCompletion(streaming: Bool) async throws {
        let harness = try await WaitHarness.make(mode: .busy(429, "generation_in_progress"),
            keepSuccessfulStreamOpen: streaming)
        defer { harness.dispose() }
        let journal = WaitJournal()
        let sessions = harness.sessions
        let stage = AIQuotaStage(taskID: UUID(), stageID: "diagnostic", onGenerationWaitChanged: { waiting in
            journal.addWait(waiting)
            // This await runs after the successful response has arrived but
            // before gatewayData/gatewayBytes returns it to its caller.
            if !waiting { try? await sessions.clear() }
        })
        let operation = Task {
            try await AIQuotaTaskScope.$stage.withValue(stage) {
                if streaming {
                    _ = try await harness.client.followUp(question: "Synthetic follow-up", run: nil,
                        profile: OracleProfile(), history: [], language: .english) { journal.addPiece($0) }
                } else { _ = try await harness.client.checkConnection() }
            }
        }
        try await waitUntil { journal.waits == [true] }
        harness.server.releaseGenerationSlot()
        do { try await operation.value; XCTFail("A response cannot cross an account change in the progress callback") }
        catch { XCTAssertEqual(error as? AccountAPIError, .staleSession) }
        let remainingSession = await sessions.snapshot()
        XCTAssertNil(remainingSession)
        XCTAssertEqual(harness.server.snapshot.acceptedGenerations, 1,
            "The identity change must occur after a successful server response, not before sending")
        XCTAssertEqual(journal.waits, [true, false], "Cleanup must not deliver the completion callback twice")
        XCTAssertEqual(journal.text, "", "Old-identity SSE content cannot reach the caller")
        if streaming {
            try await waitUntil { harness.server.snapshot.cancelledSuccessfulStreams == 1 }
        }
    }

    private func assertRequestFitsGateway(_ body: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [AIConversationTurn] {
        struct Payload: Decodable {
            let messages: [AIConversationTurn]
        }
        let messages = try JSONDecoder().decode(Payload.self, from: body).messages
        XCTAssertLessThanOrEqual(body.count, 1_048_576, file: file, line: line)
        XCTAssertLessThanOrEqual(messages.count, 160, file: file, line: line)
        XCTAssertLessThanOrEqual(messages.reduce(0) { $0 + $1.content.utf8.count }, 262_144, file: file, line: line)
        return messages
    }

    private func legacyFollowUpBody(history: [AIConversationTurn]) throws -> Data {
        let messages = [AIConversationTurn(role: "system", content: "Original system instructions")] + history
            + [AIConversationTurn(role: "user", content: "Original current question")]
        return try JSONSerialization.data(withJSONObject: [
            "model": DeepSeekConfiguration.defaultModel,
            "purpose": "follow_up",
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "max_tokens": 3_499,
            "thinking": ["type": "enabled"]
        ], options: [.sortedKeys, .prettyPrinted])
    }

    private func assertOnePreparedRequest(_ snapshot: WaitServer.Snapshot,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(snapshot.attempts.count, 2, file: file, line: line)
        XCTAssertEqual(snapshot.admissions, 1, "Waiting must not create fresh task admissions", file: file, line: line)
        XCTAssertEqual(snapshot.acceptedGenerations, 1, "Busy retries must produce exactly one new answer", file: file, line: line)
        guard let first = snapshot.attempts.first else { return XCTFail("Missing prepared request", file: file, line: line) }
        XCTAssertFalse(first.body.isEmpty, file: file, line: line)
        XCTAssertFalse(first.taskID.isEmpty, file: file, line: line)
        XCTAssertFalse(first.stageID.isEmpty, file: file, line: line)
        XCTAssertFalse(first.idempotencyKey.isEmpty, file: file, line: line)
        XCTAssertTrue(snapshot.attempts.allSatisfy { $0 == first },
            "Body, logical task, stage, token and idempotency key must remain stable", file: file, line: line)
    }

    private func assertGateway(_ error: Error, status: Int, code: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case DeepSeekError.gateway(let actualStatus, let actualCode) = error else {
            return XCTFail("Expected a typed gateway error, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(actualStatus, status, file: file, line: line)
        XCTAssertEqual(actualCode, code, file: file, line: line)
        XCTAssertFalse(error.localizedDescription.contains("private-provider-body"), file: file, line: line)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WaitFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor private struct WaitHarness {
    private static let userID = "synthetic-wait-user"
    let key: String
    let directory: URL
    let defaults: UserDefaults
    let server: WaitServer
    let sessions: AccountSessionManager
    let consent: AIDataSharingConsentStore
    let client: DeepSeekClient
    let environment: ServiceEnvironment

    static func make(mode: WaitServer.Mode, timeout: Duration = .seconds(2),
                     delay: Duration = .milliseconds(10), keepSuccessfulStreamOpen: Bool = false) async throws -> WaitHarness {
        let key = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-wait-" + key)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BlindOracle.GatewayWait." + key))
        let server = WaitServer(mode: mode, keepSuccessfulStreamOpen: keepSuccessfulStreamOpen)
        WaitURLProtocol.install(server, key: key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WaitURLProtocol.self]
        let api = AccountAPI(configuration: configuration)
        let environment = ServiceEnvironment.current
        let saved = try AccountSession(response: .init(accessToken: key, refreshToken: "synthetic-refresh",
            expiresIn: 3600, user: .init(id: userID, displayName: "Synthetic", email: nil,
                createdAt: "2026-11-16T00:00:00Z")), appleUserID: nil)
        let sessions = AccountSessionManager(api: api, vault: WaitMemoryVault(saved))
        let quota = AIQuotaTaskService(directory: directory, api: api, sessions: sessions, environment: environment)
        let consent = AIDataSharingConsentStore(defaults: defaults)
        await consent.grant()
        let client = DeepSeekClient(accountSessions: sessions, quotaTasks: quota,
            sessionConfiguration: configuration, dataSharingConsent: consent,
            generationWaitPolicy: .init(timeout: timeout, initialDelay: delay, maximumDelay: delay))
        return WaitHarness(key: key, directory: directory, defaults: defaults, server: server,
            sessions: sessions, consent: consent, client: client, environment: environment)
    }

    func stage(journal: WaitJournal) -> AIQuotaStage {
        AIQuotaStage(taskID: UUID(), stageID: "diagnostic",
            onGenerationWaitChanged: { journal.addWait($0) })
    }

    func checkConnection(journal: WaitJournal) async throws -> AIConnectionReport {
        try await AIQuotaTaskScope.$stage.withValue(stage(journal: journal)) { try await client.checkConnection() }
    }

    func followUp(stage: AIQuotaStage, question: String, history: [AIConversationTurn],
                  resolvedQuestion: String? = nil, citedQuestion: String? = nil) async throws -> String {
        try await AIQuotaTaskScope.$stage.withValue(stage) {
            try await client.followUp(question: question, run: nil, profile: OracleProfile(), history: history,
                resolvedQuestion: resolvedQuestion, citedQuestion: citedQuestion, language: .english) { _ in }
        }
    }

    func serverTaskID(for stage: AIQuotaStage) -> String {
        environment.serverTaskID(for: stage.taskID).uuidString.lowercased()
    }

    func seedLegacySnapshot(body: Data, stage: AIQuotaStage, purpose: String) throws {
        let folder = directory.appendingPathComponent(serverTaskID(for: stage))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let task = try JSONSerialization.data(withJSONObject: [
            "ownerID": Self.userID, "admissionToken": "synthetic-legacy-admission",
            "serviceEnvironment": environment.rawValue, "logicalTaskID": stage.taskID.uuidString
        ])
        try task.write(to: folder.appendingPathComponent("task.json"))
        let digest = SHA256.hash(data: Data(stage.stageID.utf8)).map { String(format: "%02x", $0) }.joined()
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "body": body.base64EncodedString(), "purpose": purpose, "needsRepair": false
        ])
        try snapshot.write(to: folder.appendingPathComponent("stage-" + digest + ".json"))
    }

    func dispose() {
        WaitURLProtocol.remove(key: key)
        defaults.removePersistentDomain(forName: "BlindOracle.GatewayWait." + key)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class WaitJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Bool] = []
    private var pieces = ""
    var waits: [Bool] { lock.withLock { events } }
    var text: String { lock.withLock { pieces } }
    func addWait(_ value: Bool) { lock.withLock { events.append(value) } }
    func addPiece(_ value: String) { lock.withLock { pieces += value } }
}

private final class WaitMemoryVault: AccountSessionStorage {
    private var session: AccountSession?
    init(_ session: AccountSession) { self.session = session }
    func load() throws -> AccountSession? { session }
    func save(_ session: AccountSession) throws { self.session = session }
    func delete() throws { session = nil }
}

private enum WaitFixtureError: Error { case timedOut, unexpectedRequest }

private final class WaitServer: @unchecked Sendable {
    enum Mode { case ready, busy(Int, String), rejected(Int, String), networkFailure(URLError.Code) }
    struct Attempt: Equatable {
        var body: Data
        var taskID: String
        var stageID: String
        var token: String
        var idempotencyKey: String
    }
    struct Snapshot {
        var admissions = 0
        var acceptedGenerations = 0
        var attempts: [Attempt] = []
        var cancelledSuccessfulStreams = 0
    }
    enum Response { case body(Int, Data, String); case failure(URLError.Code) }
    private let lock = NSLock()
    private let mode: Mode
    let keepSuccessfulStreamOpen: Bool
    private var slotReleased = false
    private var state = Snapshot()
    var snapshot: Snapshot { lock.withLock { state } }
    init(mode: Mode, keepSuccessfulStreamOpen: Bool) {
        self.mode = mode
        self.keepSuccessfulStreamOpen = keepSuccessfulStreamOpen
    }
    func releaseGenerationSlot() { lock.withLock { slotReleased = true } }
    func didCancelSuccessfulStream() { lock.withLock { state.cancelledSuccessfulStreams += 1 } }

    func response(to request: URLRequest) throws -> Response {
        try lock.withLock {
            var path = request.url?.path ?? ""
            while path.hasSuffix("/") { path.removeLast() }
            let body = Self.body(request)
            if path.hasSuffix("/ai/tasks/start") {
                guard let data = try JSONSerialization.jsonObject(with: body) as? [String: String],
                      let id = data["task_id"] else { throw WaitFixtureError.unexpectedRequest }
                state.admissions += 1
                return .body(200, try JSONSerialization.data(withJSONObject: ["task_id": id, "state": "open",
                    "admission_token": "synthetic-wait-admission"]), "application/json")
            }
            if path.contains("/ai/tasks/"), path.hasSuffix("/end") { return .body(204, Data(), "application/json") }
            guard path.hasSuffix("/ai/chat/completions") else { throw WaitFixtureError.unexpectedRequest }
            state.attempts.append(Attempt(body: body,
                taskID: request.value(forHTTPHeaderField: "X-Task-ID") ?? "",
                stageID: request.value(forHTTPHeaderField: "X-Stage-ID") ?? "",
                token: request.value(forHTTPHeaderField: "X-Task-Token") ?? "",
                idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""))
            switch mode {
            case .networkFailure(let code): return .failure(code)
            case .rejected(let status, let code): return try rejected(status: status, code: code)
            case .busy(let status, let code) where !slotReleased: return try rejected(status: status, code: code)
            default: break
            }
            state.acceptedGenerations += 1
            let streaming = (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["stream"] as? Bool == true
            if streaming {
                let chunks: [[String: Any]] = [
                    ["model": DeepSeekConfiguration.defaultModel, "choices": [["delta": ["content": "Received. "], "finish_reason": NSNull()]]],
                    ["choices": [["delta": ["content": "Continuing."], "finish_reason": NSNull()]]],
                    ["choices": [["delta": [:], "finish_reason": "stop"]]]
                ]
                let text = try chunks.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
                    + "data: [DONE]\n\n"
                return .body(200, Data(text.utf8), "text/event-stream")
            }
            let completion: [String: Any] = ["model": DeepSeekConfiguration.defaultModel,
                "choices": [["message": ["content": "OK"], "finish_reason": "stop"]]]
            return .body(200, try JSONSerialization.data(withJSONObject: completion), "application/json")
        }
    }

    private func rejected(status: Int, code: String) throws -> Response {
        .body(status, try JSONSerialization.data(withJSONObject: ["error": ["code": code,
            "message": "private-provider-body"]]), "application/json")
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

private final class WaitURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: WaitServer] = [:]
    private let responseLock = NSLock()
    private var heldStreamServer: WaitServer?
    static func install(_ server: WaitServer, key: String) { lock.withLock { servers[key] = server } }
    static func remove(key: String) { _ = lock.withLock { servers.removeValue(forKey: key) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let key = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
            guard let server = Self.lock.withLock({ Self.servers[key] }), let url = request.url else {
                throw WaitFixtureError.unexpectedRequest
            }
            switch try server.response(to: request) {
            case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
            case .body(let status, let data, let contentType):
                let holdOpen = server.keepSuccessfulStreamOpen && status == 200 && contentType == "text/event-stream"
                if holdOpen { responseLock.withLock { heldStreamServer = server } }
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": contentType])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                if !holdOpen { client?.urlProtocolDidFinishLoading(self) }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        let server = responseLock.withLock {
            let server = heldStreamServer
            heldStreamServer = nil
            return server
        }
        server?.didCancelSuccessfulStream()
    }
}
