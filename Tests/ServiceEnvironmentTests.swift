import XCTest
import StoreKit
@testable import BlindOracle

final class ServiceEnvironmentTests: XCTestCase {
    func testCompiledDefaultAndAllServiceRoutesUseOneEnvironment() {
        #if BLINDORACLE_SANDBOX
        XCTAssertEqual(ServiceEnvironment.current, .sandbox)
        #else
        XCTAssertEqual(ServiceEnvironment.current, .production)
        #endif
        XCTAssertEqual(ServiceEnvironment.production.baseURL.absoluteString, "https://wellecho.cn/xiazi-api/v1/")
        XCTAssertEqual(ServiceEnvironment.sandbox.baseURL.absoluteString, "https://wellecho.cn/xiazi-sandbox-api/v1/")
        XCTAssertEqual(AccountAPI.baseURL, ServiceEnvironment.current.baseURL)
        XCTAssertEqual(DeepSeekConfiguration.endpoint, ServiceEnvironment.current.aiEndpoint)
        #if BLINDORACLE_SANDBOX
        let ownerSandbox = true
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "OracleServiceEnvironmentResolution") as? String, "OwnerSandbox")
        #else
        let ownerSandbox = false
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "OracleServiceEnvironmentResolution") as? String, "AppleVerified")
        #endif
        // Build metadata is not a route authority: an automatic archive can resolve verified Sandbox at runtime.
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "OracleServiceEnvironment") as? String, ownerSandbox ? "Sandbox" : "Production")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, ownerSandbox ? "瞎子·测试" : "瞎子")
        if let englishInfo = Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: "en"),
           let values = try? PropertyListSerialization.propertyList(from: Data(contentsOf: englishInfo), format: nil) as? [String: String] {
            XCTAssertEqual(values["CFBundleDisplayName"], ownerSandbox ? "BlindOracle·Test" : "BlindOracle")
        } else { XCTFail("The English display name must retain its matching environment") }
        XCTAssertEqual(ServiceEnvironment.sandbox.aiEndpoint.absoluteString, "https://wellecho.cn/xiazi-sandbox-api/v1/ai/chat/completions/")
    }

    func testProductionNamespacesRemainStableAndSandboxUsesSeparateStorageAndTaskIDs() {
        let production = ServiceEnvironment.production; let sandbox = ServiceEnvironment.sandbox
        XCTAssertEqual(production.sessionKeychainService, "com.lihao.BlindOracle.wellecho.account")
        XCTAssertEqual(production.taskDirectoryName, "ai-task-requests")
        XCTAssertEqual(production.endIntentsFilename, "pending-ai-task-ends")
        XCTAssertNotEqual(production.sessionKeychainService, sandbox.sessionKeychainService)
        XCTAssertNotEqual(production.taskDirectoryName, sandbox.taskDirectoryName)
        XCTAssertNotEqual(production.endIntentsFilename, sandbox.endIntentsFilename)
        let logicalID = UUID()
        XCTAssertEqual(production.serverTaskID(for: logicalID), logicalID)
        XCTAssertNotEqual(sandbox.serverTaskID(for: logicalID), logicalID)
        XCTAssertEqual(sandbox.serverTaskID(for: logicalID), sandbox.serverTaskID(for: logicalID))
        XCTAssertNotEqual(sandbox.serverTaskID(for: logicalID), sandbox.serverTaskID(for: UUID()))
        XCTAssertEqual(production.storeKitEnvironment, "Production")
        XCTAssertEqual(sandbox.storeKitEnvironment, "Sandbox")
    }

    func testSandboxSaveAndInvalidationNeverRemoveTheProductionKeychainSession() throws {
        let testPrefix = "BlindOracle.EnvironmentTests." + UUID().uuidString + "."
        let production = AccountSessionVault(service: testPrefix + ServiceEnvironment.production.sessionKeychainService)
        let sandbox = AccountSessionVault(service: testPrefix + ServiceEnvironment.sandbox.sessionKeychainService)
        defer { try? production.delete(); try? sandbox.delete() }
        let first = try fixtureSession("production"); let second = try fixtureSession("sandbox")
        try production.save(first)
        XCTAssertNil(try sandbox.load(), "A new sandbox installation must require its own Apple sign-in")
        try sandbox.save(second)
        XCTAssertEqual(try production.load(), first)
        XCTAssertEqual(try sandbox.load(), second)
        try sandbox.delete()
        XCTAssertNil(try sandbox.load())
        XCTAssertEqual(try production.load(), first, "Sandbox logout/invalidation must not touch the production session")
        try sandbox.save(second)
        try production.delete()
        XCTAssertEqual(try sandbox.load(), second, "Production invalidation cannot invalidate the sandbox session")
    }

    func testOnlyVerifiedAppleEvidenceSelectsProductionOrSandboxAndCarriesSandboxLoginProof() throws {
        let production = try AppServiceBootstrapPolicy.resolve(.verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: "fixture-production-proof"), expectedBundleID: "com.lihao.BlindOracle")
        let sandbox = try AppServiceBootstrapPolicy.resolve(.verified(environment: .sandbox, bundleID: "com.lihao.BlindOracle", jws: "fixture-sandbox-proof"), expectedBundleID: "com.lihao.BlindOracle")
        XCTAssertEqual(production.environment, .production); XCTAssertNil(production.appleLoginProof)
        XCTAssertEqual(sandbox.environment, .sandbox); XCTAssertEqual(sandbox.appleLoginProof, "fixture-sandbox-proof")
        XCTAssertEqual(sandbox.source, .appleVerified)
        let owner = AppServiceContext(environment: .sandbox, appTransactionJWS: nil, source: .ownerSandbox)
        XCTAssertNil(owner.appleLoginProof)
    }

    func testUnverifiedUnknownWrongAppAndMissingProofHaveNoFallbackRoute() {
        let cases: [AppTransactionRouteEvidence] = [
            .unverified,
            .verified(environment: .unsupported, bundleID: "com.lihao.BlindOracle", jws: "fixture-proof"),
            .verified(environment: .sandbox, bundleID: "com.someone.other", jws: "fixture-proof"),
            .verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: " \n")
        ]
        for evidence in cases {
            XCTAssertThrowsError(try AppServiceBootstrapPolicy.resolve(evidence, expectedBundleID: "com.lihao.BlindOracle"))
        }
    }

    func testFrozenContextCannotBeReplacedByAnotherEnvironmentOrAnotherProof() throws {
        let storage = AppServiceContextStore()
        let original = AppServiceContext(environment: .production, appTransactionJWS: "fixture-original", source: .appleVerified)
        try storage.freeze(original)
        XCTAssertNoThrow(try storage.freeze(original))
        XCTAssertThrowsError(try storage.freeze(AppServiceContext(environment: .sandbox, appTransactionJWS: "fixture-sandbox", source: .appleVerified)))
        XCTAssertThrowsError(try storage.freeze(AppServiceContext(environment: .production, appTransactionJWS: "fixture-late", source: .appleVerified)))
        XCTAssertEqual(storage.snapshot(), original)
    }

    @MainActor func testFailedEnvironmentResolutionShowsRecoveryWithoutFreezingOrReadingAccountStateAndCanRetry() async {
        let storage = AppServiceContextStore()
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled), .success(.verified(environment: .sandbox, bundleID: "com.lihao.BlindOracle", jws: "fixture-retry-proof"))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
        XCTAssertEqual(coordinator.state, .resolving); XCTAssertNil(storage.snapshot())
        await coordinator.resolve()
        XCTAssertEqual(coordinator.state, .recoveryRequired); XCTAssertNil(storage.snapshot())
        XCTAssertEqual(coordinator.failure?.kind, .unavailable)
        let firstRequests = await provider.requests
        XCTAssertEqual(firstRequests, [.current], "Launch must never trigger App Store authentication.")
        await coordinator.retryFromUser()
        guard case .ready(let selected) = coordinator.state else { return XCTFail("Verified retry should complete preparation") }
        XCTAssertEqual(selected.environment, .sandbox); XCTAssertEqual(selected.appleLoginProof, "fixture-retry-proof")
        XCTAssertEqual(storage.snapshot(), selected)
        XCTAssertNil(coordinator.failure)
        let allRequests = await provider.requests
        XCTAssertEqual(allRequests, [.current, .userInitiatedRefresh])
    }

    @MainActor func testEnvironmentResolutionIsSingleFlightAndDoesNotPublishReadyBeforeVerification() async {
        let storage = AppServiceContextStore(); let provider = DelayedAppTransactionEvidence()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
        let flight = Task { await coordinator.resolve() }
        await provider.waitUntilStarted()
        XCTAssertEqual(coordinator.state, .resolving); XCTAssertNil(storage.snapshot())
        await coordinator.resolve()
        await coordinator.retryFromUser()
        let calls = await provider.calls; XCTAssertEqual(calls, 1)
        await provider.complete()
        await flight.value
        guard case .ready(let selected) = coordinator.state else { return XCTFail("The completed proof should select the route") }
        XCTAssertEqual(selected.environment, .production)
        await coordinator.resolve()
        await coordinator.retryFromUser()
        let finalCalls = await provider.calls; XCTAssertEqual(finalCalls, 1)
    }

    @MainActor func testOwnerPresetNeverRequestsAppTransactionOrChangesItsEnvironment() async {
        let owner = AppServiceContext(environment: .sandbox, appTransactionJWS: nil, source: .ownerSandbox)
        let storage = AppServiceContextStore(initial: owner)
        let provider = ScriptedAppTransactionEvidence([.failure(URLError(.notConnectedToInternet))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        XCTAssertEqual(coordinator.state, .ready(owner))
        let calls = await provider.calls; XCTAssertEqual(calls, 0)
    }

    @MainActor func testRepeatedAutomaticResolutionNeverCallsRefreshAfterFailure() async {
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled), .failure(StoreKitError.notEntitled)])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(), bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        await coordinator.resolve()
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .current])
        XCTAssertEqual(coordinator.state, .recoveryRequired)
        XCTAssertEqual(coordinator.failure?.kind, .unavailable)
    }

    @MainActor func testUserCancellingRefreshKeepsRecoveryAndDoesNotSelectEitherRoute() async {
        let storage = AppServiceContextStore()
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled), .failure(StoreKitError.userCancelled)])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        await coordinator.retryFromUser()
        XCTAssertEqual(coordinator.state, .recoveryRequired)
        XCTAssertEqual(coordinator.failure?.kind, .userCancelled)
        XCTAssertEqual(coordinator.failure?.diagnosticCode, "env_user_cancelled")
        XCTAssertNil(storage.snapshot())
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .userInitiatedRefresh])
    }

    @MainActor func testTransientRefreshCanRecoverWithOneSharedReadWithoutAnotherPrompt() async {
        let storage = AppServiceContextStore()
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled),
            .failure(StoreKitError.networkError(URLError(.notConnectedToInternet))),
            .success(.verified(environment: .sandbox, bundleID: "com.lihao.BlindOracle", jws: "fixture-refreshed-proof"))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        await coordinator.retryFromUser()
        guard case .ready(let context) = coordinator.state else { return XCTFail("A verified recovery read must recover launch") }
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .userInitiatedRefresh, .recoveryRead])
        XCTAssertEqual(context.environment, .sandbox)
        XCTAssertEqual(context.appleLoginProof, "fixture-refreshed-proof")
        XCTAssertNil(coordinator.failure)
    }

    @MainActor func testRefreshedUnverifiedWrongBundleUnsupportedAndEmptyProofStillHaveNoRoute() async {
        let results: [Result<AppTransactionRouteEvidence, Error>] = [
            .success(.unverified),
            .failure(AppTransactionEvidenceError.unverified(.invalidSignature)),
            .failure(AppTransactionEvidenceError.unverified(.invalidDeviceVerification)),
            .success(.verified(environment: .sandbox, bundleID: "another.bundle", jws: "fixture-proof")),
            .success(.verified(environment: .unsupported, bundleID: "com.lihao.BlindOracle", jws: "fixture-proof")),
            .success(.verified(environment: .sandbox, bundleID: "com.lihao.BlindOracle", jws: ""))
        ]
        let kinds: [AppServiceLaunchFailure.Kind] = [.unverified, .unverified, .unverified, .wrongApplication, .unsupportedEnvironment, .missingProof]
        for (result, kind) in zip(results, kinds) {
            let storage = AppServiceContextStore()
            let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled), result])
            let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
            await coordinator.resolve()
            await coordinator.retryFromUser()
            XCTAssertEqual(coordinator.state, .recoveryRequired)
            XCTAssertEqual(coordinator.failure?.kind, kind)
            XCTAssertNil(storage.snapshot())
            let requests = await provider.requests
            XCTAssertEqual(requests, [.current, .userInitiatedRefresh])
        }
    }

    @MainActor func testDoubleTappingUserRefreshIsSingleFlightAndFrozenContextNeverRefreshesAgain() async {
        let storage = AppServiceContextStore()
        let provider = DelayedAppTransactionEvidence()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
        let first = Task { await coordinator.retryFromUser() }
        await provider.waitUntilStarted()
        await coordinator.retryFromUser()
        XCTAssertEqual(coordinator.state, .resolving)
        let during = await provider.requests
        XCTAssertEqual(during, [.userInitiatedRefresh])
        await provider.complete()
        await first.value
        let frozen = storage.snapshot()
        await coordinator.retryFromUser()
        await coordinator.resolve()
        XCTAssertEqual(storage.snapshot(), frozen)
        XCTAssertNil(coordinator.failure)
        let after = await provider.requests
        XCTAssertEqual(after, [.userInitiatedRefresh])
    }

    func testLaunchDiagnosticsUseClosedCodesWithoutErrorMessagesOrArbitraryDomains() {
        let secret = "synthetic-sensitive-value-must-never-be-a-diagnostic"
        let opaque = NSError(domain: secret, code: 123, userInfo: [NSLocalizedDescriptionKey: secret])
        XCTAssertEqual(AppServiceLaunchFailure(error: opaque).kind, .internalFailure)
        XCTAssertEqual(AppServiceLaunchFailure(error: opaque).diagnosticCode, "env_internal")
        XCTAssertEqual(AppServiceLaunchFailure(error: StoreKitError.systemError(opaque)).kind, .unavailable)
        XCTAssertEqual(AppServiceLaunchFailure(error: StoreKitError.systemError(opaque)).diagnosticCode, "env_store_unavailable")
        XCTAssertEqual(AppServiceLaunchFailure(error: CancellationError()).kind, .taskCancelled)
        XCTAssertEqual(AppServiceLaunchFailure(error: URLError(.cancelled)).kind, .requestCancelled)
        XCTAssertEqual(AppServiceLaunchFailure(error: StoreKitError.systemError(URLError(.timedOut))).kind, .network)
        let verification = AppTransactionVerificationFailureReason(VerificationResult<AppTransaction>.VerificationError.invalidDeviceVerification)
        XCTAssertEqual(verification, .invalidDeviceVerification)
        XCTAssertEqual(AppServiceLaunchFailure(error: AppTransactionEvidenceError.unverified(verification)).diagnosticCode, "env_v_device")
    }

    @MainActor func testAutomaticTransientRecoveryUsesOnlyThreeSharedReadsAndReportsRecovery() async {
        let reporter = CapturingLaunchReporter()
        let provider = ScriptedAppTransactionEvidence([.failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.cancelled)), .success(.verified(environment: .sandbox, bundleID: "com.lihao.BlindOracle", jws: "private-proof"))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", reporter: reporter,
            timing: AppServiceLaunchTiming(retryDelays: [0, 0]))
        await coordinator.resolve()
        guard case .ready(let context) = coordinator.state else { return XCTFail("Transient reads should recover") }
        XCTAssertEqual(context.environment, .sandbox)
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .current, .current])
        await reporter.waitForEvents(3)
        let events = await reporter.events
        XCTAssertEqual(events.map(\.outcome), [.retrying, .retrying, .recovered])
        XCTAssertEqual(events.map(\.diagnosticCode), ["env_network", "env_request_cancelled", "env_recovered"])
        XCTAssertEqual(Set(events.map(\.attemptID)).count, 1, "All retries from one launch action share its attempt reference")
        XCTAssertFalse(coordinator.diagnosticText.contains("private-proof"))
    }

    @MainActor func testAutomaticNetworkFailureStopsAfterThreeAttemptsWithoutSelectingARoute() async {
        let provider = ScriptedAppTransactionEvidence(Array(repeating: .failure(URLError(.timedOut)), count: 4))
        let storage = AppServiceContextStore()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage,
            bundleID: "com.lihao.BlindOracle", timing: AppServiceLaunchTiming(retryDelays: [0, 0]))
        await coordinator.resolve()
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .current, .current])
        XCTAssertEqual(coordinator.state, .recoveryRequired); XCTAssertNil(storage.snapshot())
        XCTAssertEqual(coordinator.failure?.diagnosticCode, "env_network")
    }

    func testOnlyTransientRetrievalErrorsAreRetryable() {
        XCTAssertTrue(AppServiceLaunchFailure.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(AppServiceLaunchFailure.isTransient(StoreKitError.unknown))
        XCTAssertFalse(AppServiceLaunchFailure.isTransient(StoreKitError.notEntitled))
        XCTAssertFalse(AppServiceLaunchFailure.isTransient(StoreKitError.notAvailableInStorefront))
        XCTAssertFalse(AppServiceLaunchFailure.isTransient(StoreKitError.userCancelled))
        XCTAssertFalse(AppServiceLaunchFailure.isTransient(CancellationError()))
        XCTAssertFalse(AppServiceLaunchFailure.isTransient(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(AppServiceLaunchFailure.isTransient(AppServiceBootstrapError.wrongApplication))
        XCTAssertFalse(AppServiceLaunchFailure.isTransient(AppTransactionEvidenceError.unverified(.invalidSignature)))
        let wrapped = NSError(domain: "ASDErrorDomain", code: 500, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        XCTAssertTrue(AppServiceLaunchFailure.isTransient(StoreKitError.systemError(wrapped)))
    }

    @MainActor func testCancelledViewCallerDoesNotCancelOwnedVerification() async {
        let provider = DelayedAppTransactionEvidence()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(), bundleID: "com.lihao.BlindOracle")
        let caller = Task { await coordinator.resolve() }
        await provider.waitUntilStarted()
        caller.cancel()
        await provider.complete()
        await caller.value
        guard case .ready = coordinator.state else { return XCTFail("View cancellation must not cancel app verification") }
        XCTAssertNil(coordinator.failure)
    }

    @MainActor func testTimeoutReturnsBeforeUncooperativeStoreKitAndDiscardsLateVerifiedEvidence() async {
        let provider = DelayedAppTransactionEvidence()
        let storage = AppServiceContextStore()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle",
            timing: AppServiceLaunchTiming(automaticRequestTimeout: 0.01, automaticTotalTimeout: 0.02, retryDelays: []))
        await coordinator.resolve()
        XCTAssertEqual(coordinator.state, .recoveryRequired)
        XCTAssertEqual(coordinator.failure?.kind, .timedOut)
        XCTAssertNil(storage.snapshot())
        await provider.complete()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(coordinator.state, .recoveryRequired)
        XCTAssertNil(storage.snapshot(), "A late result from the timed-out request must never freeze routing")
    }

    @MainActor func testTaskCancellationCanResumeOnForegroundWithoutPretendingUserCancelled() async {
        let provider = ScriptedAppTransactionEvidence([.failure(CancellationError()),
            .success(.verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: "proof"))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(), bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        XCTAssertEqual(coordinator.failure?.diagnosticCode, "env_task_cancelled")
        let first = await provider.requests
        XCTAssertEqual(first, [.current])
        await coordinator.resumeDiagnostics()
        guard case .ready = coordinator.state else { return XCTFail("Foreground may resume a cancelled task") }
    }

    func testAppleLoginUsesCapturedRouteAndOnlyAutomaticSandboxSendsVerifiedAppTransactionJWS() async throws {
        defer { BootstrapURLProtocol.handler = nil }
        let contexts = [
            AppServiceContext(environment: .sandbox, appTransactionJWS: "fixture-sandbox-jws", source: .appleVerified),
            AppServiceContext(environment: .production, appTransactionJWS: "fixture-production-jws", source: .appleVerified),
            AppServiceContext(environment: .sandbox, appTransactionJWS: nil, source: .ownerSandbox)
        ]
        for context in contexts {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BootstrapURLProtocol.self]
            let api = AccountAPI(configuration: config, context: context)
            BootstrapURLProtocol.handler = { request in
                XCTAssertEqual(request.url, context.environment.baseURL.appendingPathComponent("auth/apple/"))
                let body = try JSONSerialization.jsonObject(with: BootstrapURLProtocol.body(request)) as? [String: String]
                XCTAssertEqual(body?["app_transaction_jws"], context.appleLoginProof)
                XCTAssertEqual(body?["challenge_id"], "fixture-challenge")
                return Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"user":{"id":"fixture-user","display_name":"Test","created_at":"2026-11-06T00:00:00Z"}}"#.utf8)
            }
            _ = try await api.signIn(challengeID: "fixture-challenge", identityToken: "fixture-identity", authorizationCode: "fixture-code", fullName: nil)
        }
    }

    private func fixtureSession(_ tag: String) throws -> AccountSession {
        try AccountSession(response: AccountTokenResponse(accessToken: "fixture-access-" + tag, refreshToken: "fixture-refresh-" + tag, expiresIn: 3600,
            user: AccountUser(id: UUID().uuidString, displayName: tag, email: nil, createdAt: "2026-11-06T00:00:00Z")), appleUserID: "fixture-apple-" + tag)
    }
}

private actor CapturingLaunchReporter: AppLaunchDiagnosticReporting {
    private(set) var events: [AppLaunchDiagnosticEvent] = []
    func report(_ event: AppLaunchDiagnosticEvent) async { events.append(event) }
    func flush() async { }
    func waitForEvents(_ count: Int) async {
        for _ in 0..<1000 {
            if events.count >= count { return }
            await Task.yield()
        }
    }
}

private actor ScriptedAppTransactionEvidence: AppTransactionEvidenceProviding {
    private var results: [Result<AppTransactionRouteEvidence, Error>]
    private(set) var requests: [AppTransactionEvidenceRequest] = []
    var calls: Int { requests.count }
    init(_ results: [Result<AppTransactionRouteEvidence, Error>]) { self.results = results }
    func evidence(for request: AppTransactionEvidenceRequest) async throws -> AppTransactionRouteEvidence {
        requests.append(request)
        guard !results.isEmpty else { throw URLError(.badServerResponse) }
        return try results.removeFirst().get()
    }
}

private actor DelayedAppTransactionEvidence: AppTransactionEvidenceProviding {
    private var continuation: CheckedContinuation<AppTransactionRouteEvidence, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var requests: [AppTransactionEvidenceRequest] = []
    var calls: Int { requests.count }
    func evidence(for request: AppTransactionEvidenceRequest) async throws -> AppTransactionRouteEvidence {
        requests.append(request); started = true
        startContinuation?.resume(); startContinuation = nil
        return await withCheckedContinuation { self.continuation = $0 }
    }
    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { self.startContinuation = $0 }
    }
    func complete() {
        continuation?.resume(returning: .verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: "fixture-delayed-proof"))
        continuation = nil
    }
}

private final class BootstrapURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let data = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; result.append(bytes, count: count) }
        return result
    }
}
