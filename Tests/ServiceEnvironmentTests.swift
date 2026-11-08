import XCTest
import StoreKit
import Combine
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

    @MainActor func testUserCancellingRefreshGetsOneReadButUnverifiedEvidenceStillHasNoRoute() async {
        let storage = AppServiceContextStore()
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled), .failure(StoreKitError.userCancelled), .success(.unverified)])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        await coordinator.retryFromUser()
        XCTAssertEqual(coordinator.state, .recoveryRequired)
        XCTAssertEqual(coordinator.failure?.kind, .unverified)
        XCTAssertEqual(coordinator.failure?.diagnosticCode, "env_unverified")
        XCTAssertNil(storage.snapshot())
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .userInitiatedRefresh, .recoveryRead])
    }

    @MainActor func testCancelledRefreshCanRecoverWithVerifiedSharedEvidenceWithoutAnotherProbeOrPrompt() async {
        let readiness = ScriptedLaunchReadiness([.success(()), .success(())])
        let reporter = CapturingLaunchReporter()
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled), .failure(StoreKitError.userCancelled),
            .success(.verified(environment: .sandbox, bundleID: "com.lihao.BlindOracle", jws: "verified-after-cancel"))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", reporter: reporter, readiness: readiness)
        await coordinator.resolve()
        await coordinator.retryFromUser()
        guard case .ready(let context) = coordinator.state else { return XCTFail("Only a verified shared result may recover cancelled authentication") }
        XCTAssertEqual(context.environment, .sandbox)
        XCTAssertEqual(context.appTransactionJWS, "verified-after-cancel")
        let requests = await provider.requests
        let probes = await readiness.calls
        XCTAssertEqual(requests, [.current, .userInitiatedRefresh, .recoveryRead])
        XCTAssertEqual(probes, 2, "The cancellation read must not start another network permission probe")
        let events = await reporter.events
        let cancellation = events.first { $0.diagnosticCode == "env_user_cancelled" }
        let recovery = events.last { $0.outcome == .recovered }
        XCTAssertEqual(cancellation?.outcome, .retrying)
        XCTAssertEqual(cancellation?.attemptID, recovery?.attemptID)
        XCTAssertEqual(recovery?.attempt, 2)
    }

    @MainActor func testStartupUserCancellationDoesNotCreateAManualCancellationAllowance() async {
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.userCancelled)])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(), bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        await coordinator.networkDidChange()
        await coordinator.setApplicationActive(false)
        await coordinator.setApplicationActive(true)
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current])
        XCTAssertEqual(coordinator.failure?.kind, .userCancelled)
    }

    @MainActor func testCancellationReadNetworkFailureStaysTerminalUntilANewExplicitManualAction() async {
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled), .failure(StoreKitError.userCancelled),
            .failure(URLError(.notConnectedToInternet)),
            .success(.verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: "new-manual-proof"))])
        let storage = AppServiceContextStore()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        await coordinator.retryFromUser()
        await coordinator.setApplicationActive(false)
        await coordinator.setApplicationActive(true)
        await coordinator.networkDidChange()
        await coordinator.resumeDiagnostics()
        await coordinator.resolve()
        let before = await provider.requests
        XCTAssertEqual(before, [.current, .userInitiatedRefresh, .recoveryRead])
        XCTAssertNil(storage.snapshot()); XCTAssertEqual(coordinator.failure?.kind, .network)
        await coordinator.retryFromUser()
        guard case .ready = coordinator.state else { return XCTFail("A new explicit retry may start its own operation") }
        let after = await provider.requests
        XCTAssertEqual(after, [.current, .userInitiatedRefresh, .recoveryRead, .userInitiatedRefresh])
    }

    @MainActor func testCancellationReadStillEnforcesEveryTrustBoundaryWithoutFurtherReads() async {
        let results: [Result<AppTransactionRouteEvidence, Error>] = [.success(.unverified),
            .failure(AppTransactionEvidenceError.unverified(.invalidSignature)),
            .success(.verified(environment: .production, bundleID: "wrong.application", jws: "proof")),
            .success(.verified(environment: .unsupported, bundleID: "com.lihao.BlindOracle", jws: "proof")),
            .success(.verified(environment: .sandbox, bundleID: "com.lihao.BlindOracle", jws: " "))]
        for result in results {
            let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled), .failure(StoreKitError.userCancelled), result])
            let storage = AppServiceContextStore()
            let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage, bundleID: "com.lihao.BlindOracle")
            await coordinator.resolve()
            await coordinator.retryFromUser()
            await coordinator.networkDidChange()
            await coordinator.setApplicationActive(false)
            await coordinator.setApplicationActive(true)
            XCTAssertEqual(coordinator.state, .recoveryRequired)
            XCTAssertNil(storage.snapshot())
            let requests = await provider.requests
            XCTAssertEqual(requests, [.current, .userInitiatedRefresh, .recoveryRead])
        }
    }

    @MainActor func testCancelledRefreshReadTimeoutNeverGrantsOrSchedulesAnotherReadFromLateResults() async {
        let lateResults: [Result<AppTransactionRouteEvidence, Error>] = [
            .success(.verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: "late-proof-must-not-grant")),
            .failure(URLError(.timedOut)), .failure(StoreKitError.userCancelled)]
        for late in lateResults {
            let provider = ControlledCancellationReadEvidence()
            let storage = AppServiceContextStore()
            let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage,
                bundleID: "com.lihao.BlindOracle", timing: AppServiceLaunchTiming(recoveryReadTimeout: 0.01, retryDelays: []))
            await coordinator.resolve()
            await coordinator.retryFromUser()
            XCTAssertTrue(coordinator.isWaitingForStoreKit)
            XCTAssertEqual(coordinator.failure?.kind, .timedOut)
            await coordinator.retryFromUser() // Not accepted while the timed-out SDK call is actually in flight.
            await coordinator.setApplicationActive(false)
            await coordinator.setApplicationActive(true)
            await coordinator.networkDidChange()
            await provider.complete(late)
            for _ in 0..<1000 {
                if !coordinator.isWaitingForStoreKit { break }
                await Task.yield()
            }
            await coordinator.resumeDiagnostics()
            await coordinator.networkDidChange()
            await coordinator.setApplicationActive(false)
            await coordinator.setApplicationActive(true)
            let requests = await provider.requests
            let maximum = await provider.maximumConcurrent
            XCTAssertEqual(requests, [.current, .userInitiatedRefresh, .recoveryRead])
            XCTAssertEqual(maximum, 1)
            XCTAssertNil(storage.snapshot(), "A late verified result cannot grant access or earn another shared read")
            XCTAssertEqual(coordinator.state, .recoveryRequired)
        }
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
        XCTAssertTrue(coordinator.isWaitingForStoreKit)
        XCTAssertNil(storage.snapshot())
        await coordinator.retryFromUser()
        await coordinator.networkDidChange()
        let beforeCompletion = await provider.requests
        XCTAssertEqual(beforeCompletion, [.current], "UI timeout must not release the actual StoreKit call")
        await provider.complete(evidence: .verified(environment: .production, bundleID: "wrong.application", jws: "late-proof"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(coordinator.state, .recoveryRequired)
        XCTAssertEqual(coordinator.failure?.kind, .timedOut, "Late results must not silently rewrite the reported timeout")
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

    @MainActor func testNetworkPermissionWaitFinishesBeforeAnyStoreKitAttemptAndContinuesAutomatically() async {
        let readiness = ControlledLaunchReadiness()
        let provider = ScriptedAppTransactionEvidence([.success(.verified(environment: .sandbox,
            bundleID: "com.lihao.BlindOracle", jws: "verified-proof"))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", readiness: readiness)
        let work = Task { await coordinator.resolve() }
        await readiness.waitUntilStarted()
        XCTAssertTrue(coordinator.isWaitingForNetwork)
        let before = await provider.requests
        XCTAssertEqual(before, [])
        await readiness.complete(.success(()))
        await work.value
        guard case .ready(let context) = coordinator.state else { return XCTFail("Network completion must drive verification without a button") }
        XCTAssertEqual(context.environment, .sandbox)
        XCTAssertFalse(coordinator.isWaitingForNetwork)
    }

    @MainActor func testFailedReadinessStillAllowsOneFullyVerifiedCachedTransaction() async {
        let readiness = ScriptedLaunchReadiness([.failure(URLError(.notConnectedToInternet))])
        let provider = ScriptedAppTransactionEvidence([.success(.verified(environment: .sandbox,
            bundleID: "com.lihao.BlindOracle", jws: "cached-apple-proof"))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", readiness: readiness)
        await coordinator.resolve()
        guard case .ready(let context) = coordinator.state else { return XCTFail("A verified cache must not depend on the health endpoint") }
        XCTAssertEqual(context.environment, .sandbox)
        let calls = await provider.requests
        XCTAssertEqual(calls, [.current])
    }

    @MainActor func testFailedNetworkProbeDoesNotBurnThreeReadsAndNetworkHintRequiresFreshProbe() async {
        let readiness = ScriptedLaunchReadiness([.failure(URLError(.notConnectedToInternet)), .success(())])
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.unknown),
            .success(.verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: "fresh-proof"))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", readiness: readiness)
        await coordinator.resolve()
        let before = await provider.requests
        XCTAssertEqual(before, [.current])
        XCTAssertEqual(coordinator.state, .recoveryRequired)
        await coordinator.networkDidChange()
        guard case .ready = coordinator.state else { return XCTFail("A later transport-ready probe should recover") }
        let probes = await readiness.calls
        XCTAssertEqual(probes, 2)
        let after = await provider.requests
        XCTAssertEqual(after, [.current, .recoveryRead])
    }

    @MainActor func testInternal21ManualFailureGetsExactlyOneVerifiedRecoveryRead() async {
        let internalError = StoreKitError.systemError(NSError(domain: "SKInternalErrorDomain", code: 21))
        XCTAssertFalse(AppServiceLaunchFailure.isTransient(internalError), "Do not label an undocumented code as a known network fault")
        let provider = ScriptedAppTransactionEvidence([.failure(StoreKitError.notEntitled), .failure(internalError),
            .success(.verified(environment: .sandbox, bundleID: "com.lihao.BlindOracle", jws: "recovered-proof"))])
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(), bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        await coordinator.retryFromUser()
        guard case .ready = coordinator.state else { return XCTFail("One shared recovery should be allowed after the manual internal error") }
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .userInitiatedRefresh, .recoveryRead])
    }

    @MainActor func testClosingAuthenticationForegroundHintCannotAddMoreThanOneCancellationRead() async {
        let provider = ManualCancellationLaunchEvidence()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(), bundleID: "com.lihao.BlindOracle")
        await coordinator.resolve()
        let manual = Task { await coordinator.retryFromUser() }
        await provider.waitForRefresh()
        await coordinator.setApplicationActive(false)
        await coordinator.setApplicationActive(true)
        await provider.cancelRefresh()
        await manual.value
        await coordinator.networkDidChange()
        await coordinator.setApplicationActive(true)
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .userInitiatedRefresh, .recoveryRead])
        XCTAssertEqual(coordinator.failure?.kind, .unavailable)
    }

    @MainActor func testInactiveTimeDoesNotConsumeAutomaticDeadlineOrPermitBackgroundSDKCalls() async throws {
        let provider = DelayedAppTransactionEvidence()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", timing: AppServiceLaunchTiming(automaticRequestTimeout: 0.02,
                automaticTotalTimeout: 0.04, retryDelays: []), initiallyActive: false)
        let work = Task { await coordinator.resolve() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = await provider.requests
        XCTAssertEqual(before, [])
        await coordinator.setApplicationActive(true)
        await provider.waitUntilStarted()
        await coordinator.setApplicationActive(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.state, .resolving)
        XCTAssertNil(coordinator.failure)
        await provider.complete()
        await coordinator.setApplicationActive(true)
        await work.value
        guard case .ready = coordinator.state else { return XCTFail("Inactive time must not exhaust the automatic deadline") }
    }

    @MainActor func testLateVerifiedResultIsDiscardedAndOnlyAFreshSerialReadCanSelectEnvironment() async {
        let provider = LateThenFreshLaunchEvidence()
        let storage = AppServiceContextStore()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: storage,
            bundleID: "com.lihao.BlindOracle", timing: AppServiceLaunchTiming(automaticRequestTimeout: 0.01,
                automaticTotalTimeout: 0.02, recoveryReadTimeout: 1, retryDelays: []))
        await coordinator.resolve()
        XCTAssertNil(storage.snapshot()); XCTAssertTrue(coordinator.isWaitingForStoreKit)
        await coordinator.retryFromUser()
        let busyRequests = await provider.requests
        XCTAssertEqual(busyRequests, [.current])
        await provider.completeFirst()
        for _ in 0..<1000 {
            if case .ready = coordinator.state { break }
            await Task.yield()
        }
        guard case .ready(let context) = coordinator.state else { return XCTFail("Actual completion should permit a bounded fresh read") }
        XCTAssertEqual(context.environment, .production)
        XCTAssertEqual(context.appTransactionJWS, "fresh-production-proof")
        let requests = await provider.requests
        let maximum = await provider.maximumConcurrent
        XCTAssertEqual(requests, [.current, .recoveryRead]); XCTAssertEqual(maximum, 1)
    }

    @MainActor func testLateUserCancellationPermitsOnlyOneReadAfterTheActualSDKFinishes() async {
        let provider = ManualCancellationLaunchEvidence()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", timing: AppServiceLaunchTiming(manualRefreshTimeout: 0.01, retryDelays: []))
        await coordinator.resolve()
        await coordinator.retryFromUser()
        XCTAssertTrue(coordinator.isWaitingForStoreKit)
        await coordinator.setApplicationActive(false)
        await coordinator.setApplicationActive(true)
        await provider.cancelRefresh()
        for _ in 0..<1000 {
            if await provider.requests.count >= 3 { break }
            await Task.yield()
        }
        await coordinator.networkDidChange()
        await coordinator.setApplicationActive(true)
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .userInitiatedRefresh, .recoveryRead])
        XCTAssertFalse(coordinator.isWaitingForStoreKit)
    }

    @MainActor func testLateCancellationDuringPersistenceStillGetsOnlyOneDedicatedRead() async {
        let provider = ManualCancellationLaunchEvidence()
        let reporter = BlockingTimeoutLaunchReporter()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", reporter: reporter,
            timing: AppServiceLaunchTiming(manualRefreshTimeout: 0.01, retryDelays: []))
        await coordinator.resolve()
        let manual = Task { await coordinator.retryFromUser() }
        await reporter.waitForTimeoutReport()
        // Keep timeout persistence suspended until the late native completion
        // actually reaches the coordinator. A fixed number of yields does not
        // establish that ordering under a busy test runner.
        let nativeCompletion = expectation(description: "Late refresh cancellation reached the coordinator")
        let completionObservation = coordinator.$isWaitingForStoreKit.dropFirst().sink { waiting in
            if !waiting { nativeCompletion.fulfill() }
        }
        await provider.cancelRefresh()
        await fulfillment(of: [nativeCompletion], timeout: 2)
        completionObservation.cancel()
        let whilePersisting = await provider.requests
        XCTAssertEqual(whilePersisting, [.current, .userInitiatedRefresh], "The original flight must finish persistence before a dedicated read starts")
        await reporter.release()
        await manual.value
        // The original flight schedules the dedicated read in a separate Task;
        // awaiting manual.value does not await that child's SDK request.
        for _ in 0..<200 {
            if await provider.requests.count >= 3, coordinator.state == .recoveryRequired,
               coordinator.failure?.kind == .unavailable, !coordinator.isWaitingForStoreKit { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.state, .recoveryRequired)
        XCTAssertEqual(coordinator.failure?.kind, .unavailable)
        XCTAssertFalse(coordinator.isWaitingForStoreKit)
        await coordinator.setApplicationActive(false)
        await coordinator.setApplicationActive(true)
        await coordinator.networkDidChange()
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current, .userInitiatedRefresh, .recoveryRead], "The late cancel allowance must not become a generic retry loop")
    }

    @MainActor func testLateWrongApplicationDuringPersistenceVetoesAllAutomaticRecovery() async {
        let provider = DelayedAppTransactionEvidence()
        let reporter = BlockingTimeoutLaunchReporter()
        let coordinator = AppServiceLaunchCoordinator(provider: provider, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", reporter: reporter,
            timing: AppServiceLaunchTiming(automaticRequestTimeout: 0.01, automaticTotalTimeout: 0.02, retryDelays: []))
        let work = Task { await coordinator.resolve() }
        await reporter.waitForTimeoutReport()
        await provider.complete(evidence: .verified(environment: .sandbox, bundleID: "wrong.application", jws: "untrusted-late-proof"))
        for _ in 0..<30 { await Task.yield() }
        await reporter.release()
        await work.value
        await coordinator.setApplicationActive(false)
        await coordinator.setApplicationActive(true)
        await coordinator.networkDidChange()
        let requests = await provider.requests
        XCTAssertEqual(requests, [.current])
        XCTAssertEqual(coordinator.state, .recoveryRequired)
    }

    func testHTTPSReadinessAcceptsServerErrorsAsConnectivityWithoutUsingBusinessEnvironment() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LaunchReadinessURLProtocol.self]
        let readiness = HTTPSAppLaunchNetworkReadiness(configuration: configuration)
        XCTAssertTrue(configuration.waitsForConnectivity)
        try await readiness.check()
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

private actor ControlledLaunchReadiness: AppLaunchNetworkReadinessProviding {
    private var continuation: CheckedContinuation<Void, Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    func check() async throws {
        started = true; startWaiter?.resume(); startWaiter = nil
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func complete(_ result: Result<Void, Error>) { continuation?.resume(with: result); continuation = nil }
}

private actor BlockingTimeoutLaunchReporter: AppLaunchDiagnosticReporting {
    private var waiting = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func report(_ event: AppLaunchDiagnosticEvent) async {
        guard event.diagnosticCode == "env_timeout" else { return }
        waiting = true; startedWaiter?.resume(); startedWaiter = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func flush() async { }
    func waitForTimeoutReport() async {
        if waiting { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor ScriptedLaunchReadiness: AppLaunchNetworkReadinessProviding {
    private var results: [Result<Void, Error>]
    private(set) var calls = 0
    init(_ results: [Result<Void, Error>]) { self.results = results }
    func check() async throws {
        calls += 1
        if !results.isEmpty { try results.removeFirst().get() }
    }
}

private actor ManualCancellationLaunchEvidence: AppTransactionEvidenceProviding {
    private var continuation: CheckedContinuation<AppTransactionRouteEvidence, Error>?
    private var refreshWaiter: CheckedContinuation<Void, Never>?
    private var refreshing = false
    private(set) var requests: [AppTransactionEvidenceRequest] = []
    func evidence(for request: AppTransactionEvidenceRequest) async throws -> AppTransactionRouteEvidence {
        requests.append(request)
        guard request == .userInitiatedRefresh else { throw StoreKitError.notEntitled }
        refreshing = true; refreshWaiter?.resume(); refreshWaiter = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitForRefresh() async {
        if refreshing { return }
        await withCheckedContinuation { refreshWaiter = $0 }
    }
    func cancelRefresh() { continuation?.resume(throwing: StoreKitError.userCancelled); continuation = nil }
}

private actor ControlledCancellationReadEvidence: AppTransactionEvidenceProviding {
    private var continuation: CheckedContinuation<AppTransactionRouteEvidence, Error>?
    private(set) var requests: [AppTransactionEvidenceRequest] = []
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    func evidence(for request: AppTransactionEvidenceRequest) async throws -> AppTransactionRouteEvidence {
        requests.append(request); concurrent += 1; maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        switch request {
        case .current: throw StoreKitError.notEntitled
        case .userInitiatedRefresh: throw StoreKitError.userCancelled
        case .recoveryRead: return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }
    func complete(_ result: Result<AppTransactionRouteEvidence, Error>) { continuation?.resume(with: result); continuation = nil }
}

private actor LateThenFreshLaunchEvidence: AppTransactionEvidenceProviding {
    private var continuation: CheckedContinuation<AppTransactionRouteEvidence, Never>?
    private(set) var requests: [AppTransactionEvidenceRequest] = []
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    func evidence(for request: AppTransactionEvidenceRequest) async throws -> AppTransactionRouteEvidence {
        requests.append(request); concurrent += 1; maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        if requests.count == 1 { return await withCheckedContinuation { continuation = $0 } }
        return .verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: "fresh-production-proof")
    }
    func completeFirst() {
        continuation?.resume(returning: .verified(environment: .sandbox, bundleID: "com.lihao.BlindOracle", jws: "late-sandbox-proof"))
        continuation = nil
    }
}

private final class LaunchReadinessURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url, HTTPSAppLaunchNetworkReadiness.endpoint)
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let response = HTTPURLResponse(url: HTTPSAppLaunchNetworkReadiness.endpoint, statusCode: 503,
            httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
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
    func complete(evidence: AppTransactionRouteEvidence = .verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: "fixture-delayed-proof")) {
        continuation?.resume(returning: evidence)
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
