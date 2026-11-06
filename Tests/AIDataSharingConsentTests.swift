import XCTest
@testable import BlindOracle

final class AIDataSharingConsentTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        ConsentURLProtocol.reset()
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "BlindOracle.ConsentTests." + UUID().uuidString
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentURLProtocol.self]
        return configuration
    }

    func testConsentIsExplicitPersistentVersionedAndRevocable() async throws {
        let defaults = isolatedDefaults()
        let consent = AIDataSharingConsentStore(defaults: defaults)
        let initiallyAuthorized = await consent.isAuthorized()
        XCTAssertFalse(initiallyAuthorized)
        do { try await consent.requireAuthorization(); XCTFail("Permission must be explicit") }
        catch AIDataSharingConsentStore.ConsentError.required { }

        await consent.grant()
        let restored = AIDataSharingConsentStore(defaults: defaults)
        let restoredAuthorized = await restored.isAuthorized()
        XCTAssertTrue(restoredAuthorized)
        try await restored.requireAuthorization()

        let revised = AIDataSharingConsentStore(defaults: defaults,
            policyVersion: AIDataSharingConsentStore.currentPolicyVersion + 1)
        let revisedAuthorized = await revised.isAuthorized()
        XCTAssertFalse(revisedAuthorized, "A new notice requires a new decision")
        await revised.grant()
        let oldVersionAuthorized = await consent.isAuthorized()
        XCTAssertFalse(oldVersionAuthorized, "An unexpected version is not silently accepted")
        await revised.revoke()
        let revokedAuthorized = await revised.isAuthorized()
        XCTAssertFalse(revokedAuthorized)
    }

    func testUnconsentedPlanningSummaryAndStreamingNeverReachTransport() async throws {
        let consent = AIDataSharingConsentStore(defaults: isolatedDefaults())
        // Explicitly passing the real store disables the legacy DEBUG fixture
        // transport exemption, even though this uses a mock bearer credential.
        let client = DeepSeekClient(accessToken: "fixture-access", sessionConfiguration: configuration(), dataSharingConsent: consent)
        do { _ = try await client.plan(question: "synthetic question", profile: OracleProfile(), plugins: [], history: []); XCTFail("Planning must be blocked before its first request") }
        catch DeepSeekError.dataSharingConsentRequired { }
        do { _ = try await client.summarize(transcript: "synthetic conversation", previous: ""); XCTFail("Background summaries need permission too") }
        catch DeepSeekError.dataSharingConsentRequired { }
        do { _ = try await client.followUp(question: "synthetic follow-up", run: nil, profile: OracleProfile(), history: [], onDelta: { _ in }); XCTFail("Streaming must be blocked") }
        catch DeepSeekError.dataSharingConsentRequired { }
        XCTAssertEqual(ConsentURLProtocol.requestCount, 0)
    }

    func testUnconsentedRequestDoesNotRefreshAnExpiredAccountOrAdmitAQuotaTask() async throws {
        let config = configuration()
        let api = AccountAPI(configuration: config)
        let expired = try AccountSession(response: AccountTokenResponse(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresIn: 1,
            user: AccountUser(id: UUID().uuidString, displayName: "Synthetic", email: nil, createdAt: "2026-11-07T00:00:00Z")),
            appleUserID: nil, now: .distantPast)
        let sessions = AccountSessionManager(api: api, vault: ConsentMemoryVault(expired))
        let consent = AIDataSharingConsentStore(defaults: isolatedDefaults())
        let client = DeepSeekClient(accountSessions: sessions, sessionConfiguration: config, dataSharingConsent: consent)
        do { _ = try await client.checkConnection(); XCTFail("Permission must precede credential refresh and task admission") }
        catch DeepSeekError.dataSharingConsentRequired { }
        XCTAssertEqual(ConsentURLProtocol.requestCount, 0)
    }

    func testGrantAllowsMockRequestAndWithdrawalBlocksTheNextRequest() async throws {
        let consent = AIDataSharingConsentStore(defaults: isolatedDefaults())
        let client = DeepSeekClient(accessToken: "fixture-access", sessionConfiguration: configuration(), dataSharingConsent: consent)
        await consent.grant()
        let report = try await client.checkConnection()
        XCTAssertEqual(report.actualModel, "deepseek-v4-pro")
        XCTAssertEqual(ConsentURLProtocol.requestCount, 1)
        await consent.revoke()
        do { _ = try await client.checkConnection(); XCTFail("Withdrawal must stop future sends") }
        catch DeepSeekError.dataSharingConsentRequired { }
        XCTAssertEqual(ConsentURLProtocol.requestCount, 1)
    }
}

private final class ConsentMemoryVault: AccountSessionStorage {
    private var session: AccountSession?
    init(_ session: AccountSession?) { self.session = session }
    func load() throws -> AccountSession? { session }
    func save(_ session: AccountSession) throws { self.session = session }
    func delete() throws { session = nil }
}

private final class ConsentURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let body = #"{"model":"deepseek-v4-pro","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
