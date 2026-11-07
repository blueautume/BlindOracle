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
        await reporter.report(second)
        clock.advance(61)
        await reporter.flush()
        let count = await reporter.pendingCount()
        let sent = await transport.events
        XCTAssertEqual(count, 0)
        XCTAssertEqual(sent.map(\.eventID), [first.eventID, first.eventID, second.eventID])
    }

    private func fixture(chain: [AppLaunchDiagnosticError] = []) -> AppLaunchDiagnosticEvent {
        AppLaunchDiagnosticEvent(launchID: UUID(), attemptID: UUID(),
            metadata: AppLaunchDiagnosticMetadata(appVersion: "3.0.32", appBuild: "58", osVersion: "26.1"),
            phase: .current, outcome: .failed, attempt: 1, elapsed: 0.5, diagnosticCode: "env_network", errorChain: chain)
    }
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
