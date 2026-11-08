import XCTest
@testable import BlindOracle

final class AIGatewayFailureTests: XCTestCase {
    private let cases: [(Int, [String])] = [
        (429, ["daily_budget", "daily_limit", "task_service_limit", "global_daily_budget", "service_busy", "throttled",
               "generation_in_progress", "service_retry_limit", "stage_retry_limit", "stage_repair_limit", "task_stage_limit", "upstream_rejected",
               "sandbox_installation_daily_budget", "sandbox_installation_daily_limit", "sandbox_installation_busy", "sandbox_installation_retry_limit"]),
        (502, ["upstream_rejected", "upstream_unavailable", "upstream_interrupted", "gateway_interrupted", "worker_interrupted"]),
        (503, ["service_not_configured", "cache_not_configured", "response_cache_unavailable", "settlement_unavailable"]),
        (401, ["authentication_required", "not_authenticated", "authentication_failed"]),
        (402, ["quota_exhausted", "refund_debt"]), (403, ["account_disabled"]),
        (400, ["invalid_body", "invalid_messages", "invalid_json", "invalid_purpose", "model_not_allowed", "invalid_budget",
               "invalid_request_id", "invalid_task_id", "invalid_stage_id", "invalid_fingerprint", "invalid_repair"]),
        (413, ["context_too_large"]), (426, ["update_required"]),
        (409, ["stage_running", "task_running", "idempotency_conflict", "stage_payload_conflict", "task_final_stage_exists"]),
        (410, ["task_closed"])
    ]

    func testKnownCodesSurviveRealCompletionAndStreamingTransportsWithoutAutomaticRetries() async throws {
        for (status, codes) in cases {
            for code in codes {
                for streaming in [false, true] {
                    let key = UUID().uuidString
                    GatewayFailureURLProtocol.install(.init(status: status, body: try body(code)), for: key)
                    defer { GatewayFailureURLProtocol.remove(key) }
                    let client = DeepSeekClient(accessToken: key, sessionConfiguration: configuration())
                    let receivedError: Error
                    do {
                        if streaming {
                            _ = try await client.followUp(question: "Synthetic request", run: nil, profile: OracleProfile(), history: [],
                                language: .english) { _ in XCTFail("An error response must never be emitted as answer text") }
                        } else { _ = try await client.checkConnection() }
                        XCTFail("Expected \(status) / \(code)"); continue
                    } catch { receivedError = error }
                    assertGateway(receivedError, status: status, code: code)
                    XCTAssertEqual(GatewayFailureURLProtocol.count(for: key), 1, "A rejected request must not be generated again automatically: \(code)")
                }
            }
        }
    }

    func testAccountAdmissionFailureRetainsItsCodeAndDoesNotReachTheGenerationEndpoint() async throws {
        for (status, code) in [(429, "throttled"), (429, "daily_budget"), (402, "quota_exhausted"), (403, "account_disabled"), (410, "task_closed"),
                               (429, "sandbox_installation_daily_budget"), (429, "sandbox_installation_daily_limit"),
                               (429, "sandbox_installation_busy"), (429, "sandbox_installation_retry_limit")] {
            let key = UUID().uuidString
            GatewayFailureURLProtocol.install(.init(status: status, body: try body(code)), for: key)
            defer { GatewayFailureURLProtocol.remove(key) }
            let api = AccountAPI(configuration: configuration())
            let session = try AccountSession(response: .init(accessToken: key, refreshToken: "synthetic-refresh",
                expiresIn: 3600, user: .init(id: "synthetic-user", displayName: "Synthetic", email: nil, createdAt: "2026-11-07T00:00:00Z")),
                appleUserID: "synthetic-apple-user")
            let manager = AccountSessionManager(api: api, vault: GatewayFailureVault(session))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let tasks = AIQuotaTaskService(directory: directory, api: api, sessions: manager)
            let client = DeepSeekClient(accountSessions: manager, quotaTasks: tasks, sessionConfiguration: configuration())
            do { _ = try await client.checkConnection(); XCTFail("Expected admission failure") }
            catch { assertGateway(error, status: status, code: code) }
            XCTAssertEqual(GatewayFailureURLProtocol.paths(for: key).count, 1)
            XCTAssertEqual(GatewayFailureURLProtocol.paths(for: key).first,
                           AccountAPI.baseURL.appendingPathComponent("ai/tasks/start/").path)
        }
    }

    func testDescriptionsDistinguishDailyLimitGlobalBusyPersonalGenerationAndRetriesInBothLanguages() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLanguage.$override.withValue(language) {
                let daily = AIGatewayFailure.error(status: 429, code: "daily_budget").localizedDescription
                let global = AIGatewayFailure.error(status: 429, code: "global_daily_budget").localizedDescription
                let busy = AIGatewayFailure.error(status: 429, code: "service_busy").localizedDescription
                let running = AIGatewayFailure.error(status: 429, code: "generation_in_progress").localizedDescription
                let retry = AIGatewayFailure.error(status: 429, code: "service_retry_limit").localizedDescription
                let stage = AIGatewayFailure.error(status: 429, code: "stage_retry_limit").localizedDescription
                XCTAssertEqual(Set([daily, global, busy, running, retry, stage]).count, 6)
                XCTAssertTrue(daily.contains(language.isEnglish ? "tomorrow" : "明天"))
                XCTAssertTrue(daily.contains(language.isEnglish ? "remaining allowance" : "剩余额度"))
                for (status, codes) in cases {
                    for code in codes {
                        let message = AIGatewayFailure.error(status: status, code: code).localizedDescription.lowercased()
                        XCTAssertFalse(message.isEmpty)
                        for hidden in ["deepseek", "api", "token", "密钥", "模型", "cny", "人民币", "private-backend-detail"] {
                            XCTAssertFalse(message.contains(hidden), "A public error must not expose \(hidden): \(code)")
                        }
                    }
                }
            }
        }
    }

    func testUnknownMalformedOversizedAndStatusMismatchedErrorsNeverExposeRawServerDetails() throws {
        let secret = "private-backend-detail"
        let bodies = [
            try body("not_a_known_gateway_code"), Data("<html>\(secret)</html>".utf8),
            Data("{\"error\":{\"message\":\"\(secret)\"}}".utf8),
            Data("{\"error\":{\"code\":42,\"message\":\"\(secret)\"}}".utf8),
            try JSONSerialization.data(withJSONObject: ["error": ["code": "daily_budget", "message": String(repeating: secret, count: 800)]])
        ]
        for body in bodies {
            let error = AIGatewayFailure.error(status: 429, body: body)
            guard case DeepSeekError.http(429) = error else { return XCTFail("Untrusted or overlarge envelopes must use a safe fallback") }
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
        guard case .http(500) = AIGatewayFailure.error(status: 500, code: "quota_exhausted") else {
            return XCTFail("A mismatched status must not suggest buying more allowance")
        }
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLanguage.$override.withValue(language) {
                let directlyConstructed = DeepSeekError.gateway(status: 429, code: secret)
                XCTAssertFalse(directlyConstructed.localizedDescription.contains(secret))
            }
        }
    }

    func testSharedTestInstallationLimitsPreserveAllowanceWithoutBlamingTheAccount() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLanguage.$override.withValue(language) {
                for code in ["sandbox_installation_daily_budget", "sandbox_installation_daily_limit"] {
                    let message = AIGatewayFailure.error(status: 429, code: code).localizedDescription
                    XCTAssertEqual(message, language.isEnglish
                        ? "The test service has reached its daily limit. Try again tomorrow. Your remaining allowance is preserved."
                        : "测试服务今日已达使用上限，请明日重试。剩余额度会保留。")
                    XCTAssertFalse(message.lowercased().contains("you’ve reached"))
                    XCTAssertFalse(message.lowercased().contains("replenish"))
                    XCTAssertFalse(message.contains("补充额度"))
                }
                let busy = AIGatewayFailure.error(status: 429, code: "sandbox_installation_busy").localizedDescription
                let retry = AIGatewayFailure.error(status: 429, code: "sandbox_installation_retry_limit").localizedDescription
                XCTAssertEqual(busy, AIGatewayFailure.error(status: 429, code: "service_busy").localizedDescription)
                XCTAssertEqual(retry, AIGatewayFailure.error(status: 429, code: "service_retry_limit").localizedDescription)
                let running = AIGatewayFailure.error(status: 429, code: "generation_in_progress").localizedDescription
                XCTAssertNotEqual(busy, running); XCTAssertNotEqual(retry, running)
            }
        }
    }

    func testSharedTestLimitCodesRequire429AndDoNotAcceptMalformedAliases() {
        let codes = ["sandbox_installation_daily_budget", "sandbox_installation_daily_limit", "sandbox_installation_busy", "sandbox_installation_retry_limit"]
        for code in codes {
            for status in [200, 400, 402, 403, 409, 500, 502, 503] {
                guard case .http(let actualStatus) = AIGatewayFailure.error(status: status, code: code) else {
                    return XCTFail("A test-installation limit must require its exact 429/code pair")
                }
                XCTAssertEqual(actualStatus, status)
            }
            for malformed in [code + " ", code.uppercased(), code + ".private-details"] {
                guard case .http(429) = AIGatewayFailure.error(status: 429, code: malformed) else {
                    return XCTFail("Unrecognized aliases must not select test-limit copy")
                }
            }
        }
    }

    func testStreamingErrorBodyReadIsBoundedEvenWhenTheResponseNeverFinishes() async throws {
        let key = UUID().uuidString
        let cancelled = expectation(description: "Overlarge rejected stream is canceled")
        GatewayFailureURLProtocol.install(.init(status: 429,
            body: Data(repeating: 32, count: AIGatewayFailure.maximumBodyBytes), finishes: false, cancelled: cancelled), for: key)
        defer { GatewayFailureURLProtocol.remove(key) }
        let client = DeepSeekClient(accessToken: key, sessionConfiguration: configuration())
        do {
            _ = try await client.followUp(question: "Synthetic request", run: nil, profile: OracleProfile(), history: []) { _ in
                XCTFail("Rejected bytes cannot become an answer")
            }
            XCTFail("Expected a bounded error")
        } catch { guard case DeepSeekError.http(429) = error else { return XCTFail("Expected safe HTTP fallback") } }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(GatewayFailureURLProtocol.count(for: key), 1)
    }

    func testHTTP200StreamErrorUsesOnlyTheKnownCodeAndNeverTheProviderMessage() async throws {
        let key = UUID().uuidString
        let payload = "data: " + String(decoding: try body("upstream_interrupted"), as: UTF8.self) + "\n\n"
        GatewayFailureURLProtocol.install(.init(status: 200, body: Data(payload.utf8)), for: key)
        defer { GatewayFailureURLProtocol.remove(key) }
        let client = DeepSeekClient(accessToken: key, sessionConfiguration: configuration())
        do {
            _ = try await client.followUp(question: "Synthetic request", run: nil, profile: OracleProfile(), history: []) { _ in
                XCTFail("Provider errors cannot be delivered as answer text")
            }
            XCTFail("Expected interrupted stream")
        } catch { assertGateway(error, status: 502, code: "upstream_interrupted") }
    }

    func testHealthyCompletionAndStreamingRemainReadable() async throws {
        let key = UUID().uuidString
        let content = #"{"model":"deepseek-v4-pro","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#
        GatewayFailureURLProtocol.install(.init(status: 200, body: Data(content.utf8)), for: key)
        defer { GatewayFailureURLProtocol.remove(key) }
        let completion = DeepSeekClient(accessToken: key, sessionConfiguration: configuration())
        let report = try await completion.checkConnection()
        XCTAssertEqual(report.finishReason, "stop")
        let stream = "data: {\"model\":\"deepseek-v4-pro\",\"choices\":[{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        GatewayFailureURLProtocol.install(.init(status: 200, body: Data(stream.utf8)), for: key)
        let streaming = DeepSeekClient(accessToken: key, sessionConfiguration: configuration())
        let answer = try await streaming.followUp(question: "Synthetic request", run: nil, profile: OracleProfile(), history: []) { _ in }
        XCTAssertEqual(answer, "OK")
    }

    private func assertGateway(_ error: Error, status: Int, code: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case DeepSeekError.gateway(let actualStatus, let actualCode) = error else {
            return XCTFail("Expected a known gateway error for \(status) / \(code)", file: file, line: line)
        }
        XCTAssertEqual(actualStatus, status, file: file, line: line)
        XCTAssertEqual(actualCode, code, file: file, line: line)
        XCTAssertFalse(error.localizedDescription.contains("private-backend-detail"), file: file, line: line)
    }

    private func body(_ code: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "private-backend-detail"],
                                                    "retry_after_seconds": 60, "retry_at": "2026-11-08T00:00:00+08:00"])
    }
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayFailureURLProtocol.self]
        return configuration
    }
}

private final class GatewayFailureVault: AccountSessionStorage {
    private var value: AccountSession?
    init(_ value: AccountSession) { self.value = value }
    func load() throws -> AccountSession? { value }
    func save(_ value: AccountSession) throws { self.value = value }
    func delete() throws { value = nil }
}

private final class GatewayFailureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture {
        var status: Int
        var body: Data
        var finishes = true
        var cancelled: XCTestExpectation? = nil
    }
    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]
    private static var requests: [String: [String]] = [:]
    static func install(_ fixture: Fixture, for key: String) {
        lock.withLock { fixtures[key] = fixture; requests[key] = [] }
    }
    static func remove(_ key: String) { lock.withLock { fixtures.removeValue(forKey: key); requests.removeValue(forKey: key) } }
    static func count(for key: String) -> Int { paths(for: key).count }
    static func paths(for key: String) -> [String] { lock.withLock { requests[key] ?? [] } }
    private var key: String { String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7)) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let fixture = try XCTUnwrap(Self.lock.withLock { () -> Fixture? in
                Self.requests[key, default: []].append(request.url?.path ?? "")
                return Self.fixtures[key]
            })
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: fixture.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Retry-After": "60"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.body)
            if fixture.finishes { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        let expectation = Self.lock.withLock { Self.fixtures[key]?.cancelled }
        expectation?.fulfill()
    }
}
