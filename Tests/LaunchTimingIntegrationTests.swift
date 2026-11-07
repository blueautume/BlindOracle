import XCTest
@testable import BlindOracle

final class LaunchTimingIntegrationTests: XCTestCase {
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
