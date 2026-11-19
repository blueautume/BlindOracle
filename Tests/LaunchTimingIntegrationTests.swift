import XCTest
@testable import BlindOracle

final class LaunchTimingIntegrationTests: XCTestCase {
    private let warmupPreferenceKey = "oracle.firstLaunchNetworkReachable"

    @MainActor func testFirstLaunchStartsOneProbeAndPersistsConnectivityAfterSuccess() async throws {
        let suite = "BlindOracle.FirstLaunchNetwork." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = LaunchTimingReadinessSpy()
        let warmup = FirstLaunchNetworkWarmup(readiness: probe, defaults: defaults)
        let callsBeforeStart = await probe.calls
        XCTAssertEqual(callsBeforeStart, 0)

        warmup.startIfNeeded()
        warmup.startIfNeeded()
        await eventually { defaults.bool(forKey: self.warmupPreferenceKey) }

        let nextLaunch = FirstLaunchNetworkWarmup(readiness: probe, defaults: defaults)
        nextLaunch.startIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testFirstLaunchCanRetryAfterNetworkPermissionWasUnavailable() async throws {
        let suite = "BlindOracle.FirstLaunchNetwork." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = LaunchTimingReadinessSpy(failureCount: 1)
        let firstLaunch = FirstLaunchNetworkWarmup(readiness: probe, defaults: defaults)
        firstLaunch.startIfNeeded()
        await eventually { await probe.calls == 1 }
        firstLaunch.startIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let callsBeforeRelaunch = await probe.calls
        XCTAssertEqual(callsBeforeRelaunch, 1)
        XCTAssertFalse(defaults.bool(forKey: warmupPreferenceKey))

        let nextLaunch = FirstLaunchNetworkWarmup(readiness: probe, defaults: defaults)
        nextLaunch.startIfNeeded()
        await eventually { defaults.bool(forKey: self.warmupPreferenceKey) }
        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testSignInRecoveryRechecksConnectivityAfterStartupProbeWasDenied() async throws {
        let suite = "BlindOracle.FirstLaunchNetwork." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let startup = LaunchTimingReadinessSpy(failureCount: 1)
        let recovery = LaunchTimingReadinessSpy(failureCount: 1)
        let warmup = FirstLaunchNetworkWarmup(readiness: startup, recoveryReadiness: recovery, defaults: defaults,
                                            recoveryWindow: .seconds(1), retryInterval: .milliseconds(10))
        warmup.startIfNeeded()
        await eventually { await startup.calls == 1 }

        let reachable = await warmup.waitForSignInNetwork()
        XCTAssertTrue(reachable)
        XCTAssertTrue(defaults.bool(forKey: warmupPreferenceKey))
        let probes = await recovery.calls
        XCTAssertEqual(probes, 2)
    }

    @MainActor func testSignInRecoveryEndsWhenConnectivityRemainsUnavailable() async throws {
        let suite = "BlindOracle.FirstLaunchNetwork." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recovery = LaunchTimingReadinessSpy(failureCount: .max)
        let warmup = FirstLaunchNetworkWarmup(recoveryReadiness: recovery, defaults: defaults,
                                            recoveryWindow: .milliseconds(80), retryInterval: .milliseconds(10))

        let reachable = await warmup.waitForSignInNetwork()
        XCTAssertFalse(reachable)
        XCTAssertFalse(defaults.bool(forKey: warmupPreferenceKey))
        let probes = await recovery.calls
        XCTAssertGreaterThan(probes, 0)
    }

    @MainActor func testVerificationWaitsForDiagnosticHTTPToStopAndDeliveryResumesOnlyAfterSDKEnds() async {
        let transport = LaunchTimingHTTPSpy()
        let reporter = QueuedAppLaunchDiagnosticReporter(transport: transport, fileURL: nil)
        let event = AppLaunchDiagnosticEvent(launchID: UUID(), attemptID: UUID(),
            metadata: AppLaunchDiagnosticMetadata(appVersion: "3.0.33", appBuild: "59", osVersion: "27.2"),
            phase: .current, outcome: .failed, attempt: 1, elapsed: 0.1,
            diagnosticCode: "env_network", errorChain: [])
        await reporter.report(event)
        let oldDelivery = Task { await reporter.flush() }
        await eventually { await transport.sentCount == 1 }

        let sdk = LaunchTimingSDKSpy()
        let coordinator = AppServiceLaunchCoordinator(provider: sdk, contextStore: AppServiceContextStore(),
            bundleID: "com.lihao.BlindOracle", reporter: reporter)
        let verification = Task { await coordinator.resolve() }
        await eventually { await transport.cancelObserved }
        let beforeDrain = await sdk.calls
        XCTAssertEqual(beforeDrain, 0, "StoreKit cannot start while the cancelled diagnostic HTTP is still draining.")

        await transport.finishFirstRequest()
        await oldDelivery.value
        await eventually { await sdk.calls == 1 }
        await reporter.flush()
        let duringSDK = await transport.sentCount
        XCTAssertEqual(duringSDK, 1, "Diagnostics must remain paused throughout the SDK operation.")

        await sdk.finish()
        await verification.value
        guard case .ready = coordinator.state else { return XCTFail("Verified evidence should finish launch.") }
        await eventually { await transport.sentCount == 2 }
        let references = await transport.references
        XCTAssertEqual(references, [event.eventID, event.eventID], "An interrupted delivery must retain its idempotent event ID.")
        await reporter.setDeliveryAllowed(false)
    }

    @MainActor private func eventually(_ predicate: @escaping () async -> Bool,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected asynchronous state did not arrive.", file: file, line: line)
    }
}

private actor LaunchTimingReadinessSpy: AppLaunchNetworkReadinessProviding {
    private let failureCount: Int
    private(set) var calls = 0

    init(failureCount: Int = 0) {
        self.failureCount = failureCount
    }

    func check() async throws {
        calls += 1
        if calls <= failureCount { throw URLError(.dataNotAllowed) }
    }
}

private actor LaunchTimingHTTPSpy: AppLaunchDiagnosticTransport {
    private(set) var references: [UUID] = []
    private(set) var cancelObserved = false
    private var completion: CheckedContinuation<Void, Never>?
    var sentCount: Int { references.count }

    func send(_ event: AppLaunchDiagnosticEvent) async -> AppLaunchDiagnosticDeliveryResult {
        references.append(event.eventID)
        guard references.count == 1 else { return .accepted }
        await withTaskCancellationHandler {
            await withCheckedContinuation { completion = $0 }
        } onCancel: {
            Task { await self.markCancelled() }
        }
        return .accepted
    }
    private func markCancelled() { cancelObserved = true }
    func finishFirstRequest() { completion?.resume(); completion = nil }
}

private actor LaunchTimingSDKSpy: AppTransactionEvidenceProviding {
    private(set) var calls = 0
    private var completion: CheckedContinuation<Void, Never>?
    func evidence(for request: AppTransactionEvidenceRequest) async throws -> AppTransactionRouteEvidence {
        calls += 1
        await withCheckedContinuation { completion = $0 }
        return .verified(environment: .production, bundleID: "com.lihao.BlindOracle", jws: "synthetic-verified-proof")
    }
    func finish() { completion?.resume(); completion = nil }
}
