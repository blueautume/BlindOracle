import XCTest
@testable import BlindOracle

final class AppLaunchDiagnosticsTests: XCTestCase {
    func testPayloadAndCopyTextContainOnlyClosedDiagnosticsAndRandomReferences() throws {
        let secret = "private-account-jws-and-error-description"
        let error = NSError(domain: secret, code: Int.max, userInfo: [NSLocalizedDescriptionKey: secret,
            NSUnderlyingErrorKey: URLError(.networkConnectionLost)])
        let chain = AppLaunchDiagnosticError.chain(for: error)
        XCTAssertEqual(chain.first?.domain, .other)
        XCTAssertEqual(chain.first?.code, Int(Int32.max))
        XCTAssertEqual(chain.last?.domain, .url)
        let event = fixture(chain: chain)
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["schema_version", "event_id", "launch_id", "attempt_id", "app_version", "app_build",
            "os_version", "client_occurred_at", "phase", "outcome", "attempt", "elapsed_ms", "diagnostic_code", "error_chain", "verified_environment"]))
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        XCTAssertFalse(event.safeText.contains(secret))
        XCTAssertEqual(AppLaunchDiagnosticHTTPTransport.endpoint.absoluteString,
            "https://wellecho.cn/xiazi-api/v1/diagnostics/app-launch/")
    }

    func testMetadataMatchesServerNumericGrammarInsteadOfSendingPoisonEvents() {
        let bad = AppLaunchDiagnosticMetadata(appVersion: "1..2", appBuild: "58.1", osVersion: "26.1beta")
        XCTAssertEqual(bad.appVersion, "0"); XCTAssertEqual(bad.appBuild, "0"); XCTAssertEqual(bad.osVersion, "0")
        let long = AppLaunchDiagnosticMetadata(appVersion: "12345.1", appBuild: "12345678901", osVersion: "1.2.3.4.5")
        XCTAssertEqual(long.appVersion, "0"); XCTAssertEqual(long.appBuild, "0"); XCTAssertEqual(long.osVersion, "0")
        let valid = AppLaunchDiagnosticMetadata(appVersion: "3.0.32", appBuild: "58", osVersion: "26.1.0")
        XCTAssertEqual(valid.appVersion, "3.0.32"); XCTAssertEqual(valid.appBuild, "58"); XCTAssertEqual(valid.osVersion, "26.1.0")
    }

    func testHTTPTransportOnlyAccepts202AndClassifiesPermanentAndRetryableResponses() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LaunchDiagnosticURLProtocol.self]
        let transport = AppLaunchDiagnosticHTTPTransport(configuration: configuration)
        let cases: [(Int, AppLaunchDiagnosticDeliveryResult)] = [(202, .accepted), (400, .discard), (409, .discard),
            (413, .discard), (408, .retry), (429, .retry), (503, .retry), (200, .retry)]
        for (status, expected) in cases {
            LaunchDiagnosticURLProtocol.status = status
            let result = await transport.send(fixture())
            switch (result, expected) {
            case (.accepted, .accepted), (.discard, .discard), (.retry, .retry): break
            default: XCTFail("Unexpected delivery classification for HTTP \(status)")
            }
        }
    }

    func testOfflineQueuePersistsIsBoundedAndFlushesAfterBackoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.json")
        let clock = DiagnosticTestClock()
        let offline = DiagnosticTestTransport(results: [.retry])
        let reporter = QueuedAppLaunchDiagnosticReporter(transport: offline, fileURL: file, now: { clock.now })
        for _ in 0..<45 { await reporter.report(fixture()) }
        let beforeFlush = await offline.events.count
        XCTAssertEqual(beforeFlush, 0, "Recording diagnostics must never request network access")
        await reporter.flush()
        await reporter.flush()
        let count = await reporter.pendingCount()
        let calls = await offline.events.count
        XCTAssertEqual(count, 40); XCTAssertEqual(calls, 1, "An offline queue must back off rather than send on every new event")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let online = DiagnosticTestTransport(results: [])
        let restored = QueuedAppLaunchDiagnosticReporter(transport: online, fileURL: file, now: { clock.now })
        await restored.flush()
        let remaining = await restored.pendingCount()
        XCTAssertEqual(remaining, 28, "Each flush must stay below the endpoint rate limit")
        await restored.flush()
        let stillRemaining = await restored.pendingCount()
        XCTAssertEqual(stillRemaining, 28)
        clock.advance(61)
        await restored.flush()
        let nextRemaining = await restored.pendingCount()
        XCTAssertEqual(nextRemaining, 16)
    }

    func testQueueExpiresOldEventsAndDoesNotReidentifyFutureLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.json")
        let clock = DiagnosticTestClock()
        let transport = DiagnosticTestTransport(results: [.retry])
        let first = QueuedAppLaunchDiagnosticReporter(transport: transport, fileURL: file, now: { clock.now })
        await first.report(fixture())
        clock.advance(8 * 24 * 60 * 60)
        let second = QueuedAppLaunchDiagnosticReporter(transport: transport, fileURL: file, now: { clock.now })
        let count = await second.pendingCount()
        XCTAssertEqual(count, 0)
    }

    func testPermanentlyRejectedHeadIsDiscardedSoNewEventsCanBeDelivered() async {
        let clock = DiagnosticTestClock()
        let transport = DiagnosticTestTransport(results: [.retry, .discard, .accepted])
        let reporter = QueuedAppLaunchDiagnosticReporter(transport: transport, fileURL: nil, now: { clock.now })
        let first = fixture(); let second = fixture()
        await reporter.report(first)
        await reporter.flush()
        await reporter.report(second)
        clock.advance(61)
        await reporter.flush()
        let count = await reporter.pendingCount()
        let sent = await transport.events
        XCTAssertEqual(count, 0)
        XCTAssertEqual(sent.map(\.eventID), [first.eventID, first.eventID, second.eventID])
    }

    func testPausedReporterPersistsAndDeduplicatesWithoutSendingDuringVerification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.json")
        let transport = DiagnosticTestTransport(results: [])
        let reporter = QueuedAppLaunchDiagnosticReporter(transport: transport, fileURL: file, deliveryAllowed: false)
        let event = fixture()
        await reporter.report(event)
        await reporter.report(event)
        await reporter.flush()
        let pausedCount = await reporter.pendingCount()
        let pausedSent = await transport.events
        XCTAssertEqual(pausedCount, 1)
        XCTAssertTrue(pausedSent.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let restored = QueuedAppLaunchDiagnosticReporter(transport: transport, fileURL: file, deliveryAllowed: false)
        await restored.flush()
        let restoredSent = await transport.events
        XCTAssertTrue(restoredSent.isEmpty)
        await restored.setDeliveryAllowed(true)
        let delivered = await transport.events
        let finalCount = await restored.pendingCount()
        XCTAssertEqual(delivered.map(\.eventID), [event.eventID])
        XCTAssertEqual(finalCount, 0)
    }

    func testPauseWaitsForInFlightDeliveryToStopAndCancellationDoesNotBackOff() async {
        let started = expectation(description: "delivery started")
        let cancelled = expectation(description: "delivery cancellation requested")
        let transport = DiagnosticDrainTransport(started: started, cancelled: cancelled)
        let reporter = QueuedAppLaunchDiagnosticReporter(transport: transport, fileURL: nil)
        let first = fixture(); let second = fixture()
        await reporter.report(first)
        let flushing = Task { await reporter.flush() }
        await fulfillment(of: [started], timeout: 2)
        let completion = DiagnosticCompletion()
        let pause = Task {
            await reporter.setDeliveryAllowed(false)
            await completion.finish()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        let stoppedTooSoon = await completion.finished
        XCTAssertFalse(stoppedTooSoon, "Pausing must drain transport before StoreKit may begin")
        await reporter.report(second)
        let whileStopping = await transport.snapshot()
        XCTAssertEqual(whileStopping.events.map(\.eventID), [first.eventID])
        await transport.finishFirst(with: .cancelled)
        await pause.value
        await flushing.value
        let stopped = await transport.snapshot()
        let waitingCount = await reporter.pendingCount()
        XCTAssertEqual(stopped.active, 0)
        XCTAssertEqual(waitingCount, 2)
        await reporter.flush()
        let stillPaused = await transport.snapshot()
        XCTAssertEqual(stillPaused.events.count, 1)
        await reporter.setDeliveryAllowed(true)
        let resumed = await transport.snapshot()
        let finalCount = await reporter.pendingCount()
        XCTAssertEqual(resumed.events.map(\.eventID), [first.eventID, first.eventID, second.eventID])
        XCTAssertEqual(resumed.maximumActive, 1)
        XCTAssertEqual(finalCount, 0, "Pause cancellation must not consume the network-error backoff")
    }

    func testResumeWhileCancelledDeliveryDrainsNeverOverlapsOrDropsLateAcknowledgement() async {
        let started = expectation(description: "old delivery started")
        let cancelled = expectation(description: "old delivery cancelling")
        let transport = DiagnosticDrainTransport(started: started, cancelled: cancelled)
        let reporter = QueuedAppLaunchDiagnosticReporter(transport: transport, fileURL: nil)
        let events = [fixture(), fixture(), fixture()]
        for event in events { await reporter.report(event) }
        let flushing = Task { await reporter.flush() }
        await fulfillment(of: [started], timeout: 2)
        let pause = Task { await reporter.setDeliveryAllowed(false) }
        await fulfillment(of: [cancelled], timeout: 2)
        let resume = Task { await reporter.setDeliveryAllowed(true) }
        // The old request may have been accepted before its cancellation reached
        // the server. Its late result must not let that old flush continue.
        await transport.finishFirst(with: .accepted)
        await pause.value; await flushing.value; await resume.value
        let sent = await transport.snapshot()
        let count = await reporter.pendingCount()
        XCTAssertEqual(sent.maximumActive, 1)
        XCTAssertEqual(sent.active, 0)
        XCTAssertEqual(sent.events.map(\.eventID), [events[0].eventID] + events.map(\.eventID))
        XCTAssertEqual(count, 0)
    }

    func testCancelledDelayedEnableCannotReopenDeliveryAfterPause() async {
        let transport = DiagnosticTestTransport(results: [])
        let reporter = QueuedAppLaunchDiagnosticReporter(transport: transport, fileURL: nil, deliveryAllowed: false)
        await reporter.report(fixture())
        let staleEnable = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await reporter.setDeliveryAllowed(true)
        }
        staleEnable.cancel()
        await staleEnable.value
        await reporter.flush()
        let sent = await transport.events
        let count = await reporter.pendingCount()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(count, 1)
    }

    func testPausingHTTPDeliveryCancelsURLSessionBeforeReturningToVerification() async {
        for iteration in 0..<8 {
            let started = expectation(description: "URLSession started \(iteration)")
            let stopped = expectation(description: "URLSession stopped \(iteration)")
            DiagnosticInFlightURLProtocol.observer.configure(started: started, stopped: stopped)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DiagnosticInFlightURLProtocol.self]
            let reporter = QueuedAppLaunchDiagnosticReporter(
                transport: AppLaunchDiagnosticHTTPTransport(configuration: configuration), fileURL: nil)
            await reporter.report(fixture())
            let flushing = Task { await reporter.flush() }
            await fulfillment(of: [started], timeout: 2)
            await reporter.setDeliveryAllowed(false)
            await flushing.value
            // URLSession's native completion acknowledges the completed task.
            // URLProtocol.stopLoading is a separate asynchronous cleanup callback;
            // Foundation does not promise it precedes the task's completion.
            let nativeTask = DiagnosticInFlightURLProtocol.observer.originatingTask
            XCTAssertNotNil(nativeTask, "Observe the actual URLSession task rather than its protocol cleanup callback")
            XCTAssertEqual(nativeTask?.state, .completed,
                "The delivery gate must wait for the native task to complete (iteration \(iteration))")
            await fulfillment(of: [stopped], timeout: 2)
            XCTAssertEqual(DiagnosticInFlightURLProtocol.observer.stopCount, 1)
            let count = await reporter.pendingCount()
            XCTAssertEqual(count, 1)
            DiagnosticInFlightURLProtocol.observer.clear()
        }
    }

    private func fixture(chain: [AppLaunchDiagnosticError] = []) -> AppLaunchDiagnosticEvent {
        AppLaunchDiagnosticEvent(launchID: UUID(), attemptID: UUID(),
            metadata: AppLaunchDiagnosticMetadata(appVersion: "3.0.32", appBuild: "58", osVersion: "26.1"),
            phase: .current, outcome: .failed, attempt: 1, elapsed: 0.5, diagnosticCode: "env_network", errorChain: chain)
    }
}

private actor DiagnosticCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}

private actor DiagnosticDrainTransport: AppLaunchDiagnosticTransport {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    private var firstContinuation: CheckedContinuation<AppLaunchDiagnosticDeliveryResult, Never>?
    private var events: [AppLaunchDiagnosticEvent] = []
    private var active = 0
    private var maximumActive = 0
    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started; self.cancelled = cancelled
    }
    func send(_ event: AppLaunchDiagnosticEvent) async -> AppLaunchDiagnosticDeliveryResult {
        events.append(event); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        guard events.count == 1 else { return .accepted }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
                started.fulfill()
            }
        } onCancel: {
            Task { await self.cancellationRequested() }
        }
    }
    private func cancellationRequested() { cancelled.fulfill() }
    func finishFirst(with result: AppLaunchDiagnosticDeliveryResult) {
        firstContinuation?.resume(returning: result); firstContinuation = nil
    }
    func snapshot() -> (events: [AppLaunchDiagnosticEvent], active: Int, maximumActive: Int) {
        (events, active, maximumActive)
    }
}

private final class DiagnosticURLProtocolObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var started: XCTestExpectation?
    private var stopped: XCTestExpectation?
    private var stops = 0
    private var nativeTask: URLSessionTask?
    func configure(started: XCTestExpectation, stopped: XCTestExpectation) {
        lock.lock(); defer { lock.unlock() }
        self.started = started; self.stopped = stopped; stops = 0; nativeTask = nil
    }
    func clear() { lock.lock(); defer { lock.unlock() }; started = nil; stopped = nil; nativeTask = nil }
    func didStart(task: URLSessionTask?) { lock.lock(); nativeTask = task; let callback = started; lock.unlock(); callback?.fulfill() }
    func didStop() { lock.lock(); stops += 1; let callback = stopped; lock.unlock(); callback?.fulfill() }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    var originatingTask: URLSessionTask? { lock.lock(); defer { lock.unlock() }; return nativeTask }
}

private final class DiagnosticInFlightURLProtocol: URLProtocol {
    static let observer = DiagnosticURLProtocolObserver()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canInit(with task: URLSessionTask) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.observer.didStart(task: task) }
    override func stopLoading() { Self.observer.didStop() }
}

private actor DiagnosticTestTransport: AppLaunchDiagnosticTransport {
    private var results: [AppLaunchDiagnosticDeliveryResult]
    private(set) var events: [AppLaunchDiagnosticEvent] = []
    init(results: [AppLaunchDiagnosticDeliveryResult]) { self.results = results }
    func send(_ event: AppLaunchDiagnosticEvent) async -> AppLaunchDiagnosticDeliveryResult {
        events.append(event)
        return results.isEmpty ? .accepted : results.removeFirst()
    }
}

private final class DiagnosticTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private final class LaunchDiagnosticURLProtocol: URLProtocol {
    static var status = 202
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        XCTAssertEqual(url, AppLaunchDiagnosticHTTPTransport.endpoint)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
