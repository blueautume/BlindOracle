import Foundation
import StoreKit
import Combine
import OSLog

struct AppServiceContext: Sendable, Equatable {
    enum Source: Sendable, Equatable { case appleVerified, ownerSandbox, debugFixture }
    let environment: ServiceEnvironment
    let appTransactionJWS: String?
    let source: Source
    var appleLoginProof: String? { environment == .sandbox && source == .appleVerified ? appTransactionJWS : nil }
}

enum AppServiceBootstrapError: Error, Equatable {
    case unverified, unsupportedEnvironment, wrongApplication, missingProof, alreadyResolved
}

enum AppTransactionEvidenceRequest: String, Codable, Sendable, Equatable {
    case current, userInitiatedRefresh, recoveryRead
}

struct AppServiceLaunchTimeout: Error, Sendable { }

/// Closed, non-personal reasons; never retain the unverified payload or error description.
enum AppTransactionVerificationFailureReason: String, Sendable, Equatable {
    case revokedCertificate, invalidCertificateChain, invalidDeviceVerification
    case invalidEncoding, invalidSignature, missingRequiredProperties, unknown

    init(_ error: VerificationResult<AppTransaction>.VerificationError) {
        switch error {
        case .revokedCertificate: self = .revokedCertificate
        case .invalidCertificateChain: self = .invalidCertificateChain
        case .invalidDeviceVerification: self = .invalidDeviceVerification
        case .invalidEncoding: self = .invalidEncoding
        case .invalidSignature: self = .invalidSignature
        case .missingRequiredProperties: self = .missingRequiredProperties
        @unknown default: self = .unknown
        }
    }

    var diagnosticCode: String {
        switch self {
        case .revokedCertificate: return "env_v_revoked"
        case .invalidCertificateChain: return "env_v_chain"
        case .invalidDeviceVerification: return "env_v_device"
        case .invalidEncoding: return "env_v_encoding"
        case .invalidSignature: return "env_v_signature"
        case .missingRequiredProperties: return "env_v_properties"
        case .unknown: return "env_unverified"
        }
    }
}

enum AppTransactionEvidenceError: Error, Sendable, Equatable {
    case unverified(AppTransactionVerificationFailureReason)
}

struct AppServiceLaunchFailure: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case network, userCancelled, requestCancelled, taskCancelled, timedOut, unverified, unavailable, unsupportedEnvironment
        case wrongApplication, missingProof, internalFailure
    }
    let kind: Kind
    let diagnosticCode: String

    init(error: Error) {
        if let evidence = error as? AppTransactionEvidenceError {
            switch evidence {
            case .unverified(let reason):
                kind = .unverified; diagnosticCode = reason.diagnosticCode
            }
        } else if let policy = error as? AppServiceBootstrapError {
            switch policy {
            case .unverified: kind = .unverified; diagnosticCode = "env_unverified"
            case .unsupportedEnvironment: kind = .unsupportedEnvironment; diagnosticCode = "env_unsupported"
            case .wrongApplication: kind = .wrongApplication; diagnosticCode = "env_wrong_app"
            case .missingProof: kind = .missingProof; diagnosticCode = "env_missing_proof"
            case .alreadyResolved: kind = .internalFailure; diagnosticCode = "env_internal"
            }
        } else if error is AppServiceLaunchTimeout {
            kind = .timedOut; diagnosticCode = "env_timeout"
        } else if error is CancellationError {
            kind = .taskCancelled; diagnosticCode = "env_task_cancelled"
        } else if let storeError = error as? StoreKitError {
            switch storeError {
            case .userCancelled: kind = .userCancelled; diagnosticCode = "env_user_cancelled"
            case .networkError(let underlying):
                if underlying.code == .cancelled {
                    kind = .requestCancelled; diagnosticCode = "env_request_cancelled"
                } else { kind = .network; diagnosticCode = "env_network" }
            case .systemError(let underlying):
                let inner = underlying as NSError
                if underlying is CancellationError { kind = .taskCancelled; diagnosticCode = "env_task_cancelled" }
                else if inner.domain == NSURLErrorDomain {
                    kind = inner.code == URLError.cancelled.rawValue ? .requestCancelled : .network
                    diagnosticCode = kind == .requestCancelled ? "env_request_cancelled" : "env_network"
                } else if inner.domain == NSCocoaErrorDomain && inner.code == NSUserCancelledError {
                    kind = .userCancelled; diagnosticCode = "env_user_cancelled"
                } else {
                    kind = .unavailable; diagnosticCode = "env_store_unavailable"
                }
            default: kind = .unavailable; diagnosticCode = "env_store_unavailable"
            }
        } else {
            let cocoa = error as NSError
            if cocoa.domain == NSURLErrorDomain {
                kind = cocoa.code == URLError.cancelled.rawValue ? .requestCancelled : .network
                diagnosticCode = kind == .requestCancelled ? "env_request_cancelled" : "env_network"
            } else if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError {
                kind = .userCancelled; diagnosticCode = "env_user_cancelled"
            } else if cocoa.domain == SKErrorDomain && cocoa.code == SKError.paymentCancelled.rawValue {
                kind = .userCancelled; diagnosticCode = "env_user_cancelled"
            } else {
                kind = .internalFailure; diagnosticCode = "env_internal"
            }
        }
    }

    /// Only retrieval failures are retried. Verification, entitlement, storefront,
    /// presentation, explicit user cancellation and task cancellation are terminal.
    static func isTransient(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        if error is AppServiceLaunchTimeout { return true }
        if let store = error as? StoreKitError {
            switch store {
            case .unknown: return true
            case .networkError(let underlying): return isTransient(underlying, depth: depth + 1)
            case .systemError(let underlying): return isTransient(underlying, depth: depth + 1)
            default: return false
            }
        }
        let cocoa = error as NSError
        if ["ASDErrorDomain", "SKInternalErrorDomain"].contains(cocoa.domain),
           let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTransient(underlying, depth: depth + 1)
        }
        guard cocoa.domain == NSURLErrorDomain else { return false }
        let codes: [URLError.Code] = [.timedOut, .cancelled, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable, .dataNotAllowed,
                .backgroundSessionWasDisconnected]
        return codes.contains { $0.rawValue == cocoa.code }
    }
}

enum AppTransactionRouteEvidence: Sendable {
    enum Environment: Sendable, Equatable { case production, sandbox, unsupported }
    case verified(environment: Environment, bundleID: String, jws: String)
    case unverified
}

protocol AppTransactionEvidenceProviding: Sendable {
    func evidence(for request: AppTransactionEvidenceRequest) async throws -> AppTransactionRouteEvidence
}

struct StoreKitAppTransactionEvidence: AppTransactionEvidenceProviding {
    func evidence(for request: AppTransactionEvidenceRequest) async throws -> AppTransactionRouteEvidence {
        let result: VerificationResult<AppTransaction>
        switch request {
        case .current, .recoveryRead: result = try await AppTransaction.shared
        // The launch coordinator exposes this only through the explicit user retry action.
        case .userInitiatedRefresh: result = try await AppTransaction.refresh()
        }
        let transaction: AppTransaction
        switch result {
        case .verified(let verified): transaction = verified
        case .unverified(_, let error):
            throw AppTransactionEvidenceError.unverified(AppTransactionVerificationFailureReason(error))
        }
        let environment: AppTransactionRouteEvidence.Environment
        if transaction.environment == .production { environment = .production }
        else if transaction.environment == .sandbox { environment = .sandbox }
        else { environment = .unsupported }
        return .verified(environment: environment, bundleID: transaction.bundleID, jws: result.jwsRepresentation)
    }
}

enum AppServiceBootstrapPolicy {
    static func resolve(_ evidence: AppTransactionRouteEvidence, expectedBundleID: String) throws -> AppServiceContext {
        guard case let .verified(environment, bundleID, jws) = evidence else { throw AppServiceBootstrapError.unverified }
        guard bundleID == expectedBundleID, !expectedBundleID.isEmpty else { throw AppServiceBootstrapError.wrongApplication }
        guard !jws.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppServiceBootstrapError.missingProof }
        let resolved: ServiceEnvironment
        switch environment {
        case .production: resolved = .production
        case .sandbox: resolved = .sandbox
        case .unsupported: throw AppServiceBootstrapError.unsupportedEnvironment
        }
        return AppServiceContext(environment: resolved, appTransactionJWS: jws, source: .appleVerified)
    }

    static var isUnitTestHost: Bool {
        #if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("--ui-testing-local") { return false }
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }

    static var developmentContext: AppServiceContext? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-local") || isUnitTestHost {
            #if BLINDORACLE_SANDBOX
            let environment = ServiceEnvironment.sandbox
            #else
            let environment = ServiceEnvironment.production
            #endif
            return AppServiceContext(environment: environment, appTransactionJWS: nil, source: .debugFixture)
        }
        #endif
        #if BLINDORACLE_SANDBOX
        return AppServiceContext(environment: .sandbox, appTransactionJWS: nil, source: .ownerSandbox)
        #else
        return nil
        #endif
    }
}

/// The selected route and proof are immutable for the entire process. There is no defaults or metadata fallback.
final class AppServiceContextStore: @unchecked Sendable {
    static let process = AppServiceContextStore(initial: AppServiceBootstrapPolicy.developmentContext)
    private let lock = NSLock()
    private var value: AppServiceContext?
    init(initial: AppServiceContext? = nil) { value = initial }
    func snapshot() -> AppServiceContext? { lock.lock(); defer { lock.unlock() }; return value }
    @discardableResult func freeze(_ context: AppServiceContext) throws -> AppServiceContext {
        lock.lock(); defer { lock.unlock() }
        if let value {
            guard value == context else { throw AppServiceBootstrapError.alreadyResolved }
            return value
        }
        value = context; return context
    }
    func requireContext() -> AppServiceContext {
        guard let selected = snapshot() else { preconditionFailure("Service context must resolve before constructing services") }
        return selected
    }
}

struct AppServiceLaunchTiming: Sendable {
    var automaticRequestTimeout: TimeInterval = 4
    var automaticTotalTimeout: TimeInterval = 15
    var manualRefreshTimeout: TimeInterval = 60
    var recoveryReadTimeout: TimeInterval = 4
    var retryDelays: [TimeInterval] = [1, 2]
    static let standard = Self()
}

/// UI deadlines do not cancel or release a StoreKit call. Some SDK operations
/// ignore cancellation; keeping the underlying task prevents overlapping calls.
@MainActor private final class AppTransactionEvidenceSerialRunner {
    private var continuation: CheckedContinuation<Result<AppTransactionRouteEvidence, Error>, Never>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    var isRunning: Bool { work != nil }
    var onLateCompletion: ((Result<AppTransactionRouteEvidence, Error>) -> Void)?
    func run(provider: any AppTransactionEvidenceProviding, request: AppTransactionEvidenceRequest,
             timeout: TimeInterval, clock: @escaping @MainActor () -> TimeInterval) async -> Result<AppTransactionRouteEvidence, Error> {
        precondition(work == nil, "StoreKit requests must remain serial until actual completion")
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            work = Task {
                let result: Result<AppTransactionRouteEvidence, Error>
                do { result = .success(try await provider.evidence(for: request)) }
                catch { result = .failure(error) }
                self.complete(result)
            }
            timer = Task {
                let started = clock()
                while clock() - started < max(0.001, timeout) {
                    let remaining = max(0.001, timeout - (clock() - started))
                    do { try await Task.sleep(nanoseconds: UInt64(min(0.1, remaining) * 1_000_000_000)) }
                    catch { return }
                }
                guard let continuation = self.continuation else { return }
                self.continuation = nil; self.timer = nil
                continuation.resume(returning: .failure(AppServiceLaunchTimeout()))
                // Keep work alive and busy. Its late evidence is discarded.
            }
        }
    }
    private func complete(_ result: Result<AppTransactionRouteEvidence, Error>) {
        timer?.cancel(); timer = nil; work = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            onLateCompletion?(result)
        }
    }
}

#if DEBUG
private struct AppLaunchFailureUIFixture: AppTransactionEvidenceProviding {
    func evidence(for request: AppTransactionEvidenceRequest) async throws -> AppTransactionRouteEvidence {
        throw URLError(.notConnectedToInternet)
    }
}
#endif

@MainActor final class AppServiceLaunchCoordinator: ObservableObject {
    enum State: Equatable { case resolving, recoveryRequired, ready(AppServiceContext) }
    @Published private(set) var state: State = .resolving
    @Published private(set) var failure: AppServiceLaunchFailure?
    @Published private(set) var diagnosticText = ""
    @Published private(set) var isWaitingForNetwork = false
    @Published private(set) var isWaitingForStoreKit = false
    private let logger = Logger(subsystem: "com.lihao.BlindOracle", category: "AppServiceBootstrap")
    private let provider: any AppTransactionEvidenceProviding
    private let readiness: any AppLaunchNetworkReadinessProviding
    private let contextStore: AppServiceContextStore
    private let bundleID: String
    private let reporter: any AppLaunchDiagnosticReporting
    private let timing: AppServiceLaunchTiming
    private let metadata: AppLaunchDiagnosticMetadata
    private let launchID = UUID()
    private let sdk = AppTransactionEvidenceSerialRunner()
    private var pathObserver: AppLaunchNetworkPathObserver?
    private var flight: Task<Void, Never>?
    private var flightID: UUID?
    private var hasFailed = false
    private var reportedEvents = 0
    private var applicationActive: Bool
    private var activeSince: TimeInterval?
    private var accumulatedActive: TimeInterval = 0
    private var activeWaiters: [CheckedContinuation<Void, Never>] = []
    private var automaticRecoveryAllowed = false
    private var recoveryRuns = 0
    private var pendingRecoverySignal = false
    private var pendingSDKRequest: AppTransactionEvidenceRequest?
    private var lateTerminalVeto = false
    private var deliveryGeneration = 0
    private var deliveryEnableTask: Task<Void, Never>?

    init(provider: any AppTransactionEvidenceProviding = StoreKitAppTransactionEvidence(),
         contextStore: AppServiceContextStore = .process, bundleID: String = Bundle.main.bundleIdentifier ?? "",
         reporter: (any AppLaunchDiagnosticReporting)? = nil, timing: AppServiceLaunchTiming = .standard,
         metadata: AppLaunchDiagnosticMetadata = .current,
         readiness: (any AppLaunchNetworkReadinessProviding)? = nil, initiallyActive: Bool? = nil) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let networkFixture = arguments.contains("--ui-testing-local") && arguments.contains("--ui-testing-service-network-recovery")
        let fixture = arguments.contains("--ui-testing-local") && (arguments.contains("--ui-testing-service-environment-failure") || networkFixture)
        if fixture {
            self.provider = AppLaunchFailureUIFixture(); self.contextStore = AppServiceContextStore()
            self.timing = AppServiceLaunchTiming(automaticRequestTimeout: 0.1, automaticTotalTimeout: 0.2,
                                                manualRefreshTimeout: 0.1, recoveryReadTimeout: 0.1, retryDelays: [])
        } else { self.provider = provider; self.contextStore = contextStore; self.timing = timing }
        let live = !fixture && provider is StoreKitAppTransactionEvidence && !AppServiceBootstrapPolicy.isUnitTestHost
            && !arguments.contains("--ui-testing-local")
        #else
        self.provider = provider; self.contextStore = contextStore; self.timing = timing
        let live = provider is StoreKitAppTransactionEvidence
        #endif
        self.bundleID = bundleID; self.metadata = metadata
        #if DEBUG
        if networkFixture { self.readiness = DelayedAppLaunchNetworkReadinessUIFixture() }
        else { self.readiness = readiness ?? (live ? HTTPSAppLaunchNetworkReadiness() : ImmediateAppLaunchNetworkReadiness()) }
        #else
        self.readiness = readiness ?? (live ? HTTPSAppLaunchNetworkReadiness() : ImmediateAppLaunchNetworkReadiness())
        #endif
        applicationActive = initiallyActive ?? !live
        activeSince = applicationActive ? ProcessInfo.processInfo.systemUptime : nil
        self.reporter = reporter ?? (live ? QueuedAppLaunchDiagnosticReporter.shared : DisabledAppLaunchDiagnosticReporter())
        sdk.onLateCompletion = { [weak self] result in self?.underlyingDidFinish(result) }
        if live {
            pathObserver = AppLaunchNetworkPathObserver { [weak self] in
                Task { @MainActor in await self?.networkDidChange() }
            }
        }
    }
    func resolve() async { await resolve(for: .current) }
    /// The only path that invokes AppTransaction.refresh().
    func retryFromUser() async {
        guard !sdk.isRunning else { isWaitingForStoreKit = true; return }
        recoveryRuns = 0
        await resolve(for: .userInitiatedRefresh)
    }
    func setApplicationActive(_ active: Bool) async {
        let becameActive = active && !applicationActive
        if applicationActive != active {
            if let activeSince { accumulatedActive += ProcessInfo.processInfo.systemUptime - activeSince }
            applicationActive = active
            activeSince = active ? ProcessInfo.processInfo.systemUptime : nil
        }
        if !active { await pauseDelivery(); return }
        if becameActive { pendingRecoverySignal = true }
        let waiters = activeWaiters; activeWaiters = []
        for waiter in waiters { waiter.resume() }
        if becameActive { await recoverFromSignal() }
        scheduleDeliveryWhenIdle()
    }
    func networkDidChange() async {
        pendingRecoverySignal = true
        await recoverFromSignal()
    }
    /// Kept for callers that request a foreground retry; it shares all gates.
    func resumeDiagnostics() async {
        pendingRecoverySignal = true
        await recoverFromSignal()
        scheduleDeliveryWhenIdle()
    }
    private func recoverFromSignal() async {
        guard pendingRecoverySignal, applicationActive, flight == nil, !sdk.isRunning,
              automaticRecoveryAllowed, recoveryRuns < 2 else { return }
        pendingRecoverySignal = false; recoveryRuns += 1
        await resolve(for: .recoveryRead)
    }
    private func activeTime() -> TimeInterval {
        accumulatedActive + (activeSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
    }
    private func waitUntilActive() async {
        while !applicationActive {
            await withCheckedContinuation { activeWaiters.append($0) }
        }
    }
    private func pauseDelivery() async {
        deliveryGeneration += 1; deliveryEnableTask?.cancel(); deliveryEnableTask = nil
        await reporter.setDeliveryAllowed(false)
    }
    private func scheduleDeliveryWhenIdle() {
        deliveryGeneration += 1
        let generation = deliveryGeneration
        deliveryEnableTask?.cancel()
        guard applicationActive, flight == nil, !sdk.isRunning, !isWaitingForNetwork else { return }
        deliveryEnableTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, self.deliveryGeneration == generation, self.applicationActive,
                  self.flight == nil, !self.sdk.isRunning, !self.isWaitingForNetwork else { return }
            await self.reporter.setDeliveryAllowed(true)
        }
    }
    private func resolve(for request: AppTransactionEvidenceRequest) async {
        guard flight == nil else { return }
        guard !sdk.isRunning else { isWaitingForStoreKit = true; return }
        if let selected = contextStore.snapshot() {
            failure = nil; state = .ready(selected); scheduleDeliveryWhenIdle(); return
        }
        failure = nil; state = .resolving; automaticRecoveryAllowed = false; pendingRecoverySignal = false
        let id = UUID(); flightID = id
        let running = Task { [weak self] in
            guard let self else { return }
            await self.pauseDelivery()
            await self.waitUntilActive()
            await self.perform(request: request, id: id)
            if self.flightID == id {
                self.flight = nil; self.flightID = nil
                self.isWaitingForStoreKit = self.sdk.isRunning
                if self.pendingRecoverySignal, self.automaticRecoveryAllowed, !self.sdk.isRunning {
                    Task { [weak self] in await self?.recoverFromSignal() }
                }
                self.scheduleDeliveryWhenIdle()
            }
        }
        flight = running
        await running.value
    }
    private func perform(request initialRequest: AppTransactionEvidenceRequest, id: UUID) async {
        let wallStarted = ProcessInfo.processInfo.systemUptime
        isWaitingForNetwork = true
        var probeFailed = false
        do { try await readiness.check() }
        catch {
            probeFailed = true; hasFailed = true
            await emit(attemptID: id, request: initialRequest, outcome: .retrying, attempt: 1, started: wallStarted,
                 code: "env_network", chain: AppLaunchDiagnosticError.chain(for: error))
        }
        isWaitingForNetwork = false
        await waitUntilActive()
        guard flightID == id else { return }
        let started = activeTime() // Network permission waiting consumes no verification budget.
        var request = probeFailed ? AppTransactionEvidenceRequest.current : initialRequest
        let automatic = initialRequest != .userInitiatedRefresh
        let limit = probeFailed ? 1 : automatic ? min(3, timing.retryDelays.count + 1) : 2
        for attempt in 1...max(1, limit) {
            await waitUntilActive()
            guard flightID == id, !sdk.isRunning else { return }
            let elapsed = activeTime() - started
            let readTimeout = request == .recoveryRead ? timing.recoveryReadTimeout : timing.automaticRequestTimeout
            let timeout = request == .userInitiatedRefresh ? timing.manualRefreshTimeout
                : automatic ? min(readTimeout, max(0.001, timing.automaticTotalTimeout - elapsed)) : readTimeout
            let clock: @MainActor () -> TimeInterval = request == .userInitiatedRefresh
                ? { ProcessInfo.processInfo.systemUptime } : { [weak self] in self?.activeTime() ?? 0 }
            pendingSDKRequest = request
            lateTerminalVeto = false
            let result = await sdk.run(provider: provider, request: request, timeout: timeout, clock: clock)
            if !sdk.isRunning { pendingSDKRequest = nil }
            await waitUntilActive()
            guard flightID == id else { return }
            do {
                let evidence = try result.get()
                let context = try AppServiceBootstrapPolicy.resolve(evidence, expectedBundleID: bundleID)
                failure = nil; state = .ready(try contextStore.freeze(context)); automaticRecoveryAllowed = false
                if hasFailed {
                    await emit(attemptID: id, request: request, outcome: .recovered, attempt: attempt, started: wallStarted,
                         code: "env_recovered", chain: [], environment: context.environment == .production ? .production : .sandbox)
                }
                return
            } catch {
                hasFailed = true
                let failure = AppServiceLaunchFailure(error: error)
                let chain = AppLaunchDiagnosticError.chain(for: error)
                let delay = automatic && attempt <= timing.retryDelays.count ? max(0, timing.retryDelays[attempt - 1]) : 0
                let transient = AppServiceLaunchFailure.isTransient(error)
                let manualRecovery = request == .userInitiatedRefresh && Self.permitsInternalRecoveryRead(error)
                let withinBudget = !automatic || activeTime() - started + delay + 0.001 < timing.automaticTotalTimeout
                let retry = attempt < limit && withinBudget && !sdk.isRunning && !lateTerminalVeto && (transient || manualRecovery)
                let outcome: AppLaunchDiagnosticEvent.Outcome = retry ? .retrying
                    : failure.kind == .timedOut ? .timedOut : failure.kind == .taskCancelled ? .taskCancelled : .failed
                await emit(attemptID: id, request: request, outcome: outcome, attempt: attempt, started: wallStarted,
                     code: failure.diagnosticCode, chain: chain)
                if !retry || lateTerminalVeto {
                    self.failure = failure; state = .recoveryRequired; isWaitingForStoreKit = sdk.isRunning
                    automaticRecoveryAllowed = !lateTerminalVeto && (transient || manualRecovery || failure.kind == .taskCancelled)
                    if !automaticRecoveryAllowed { pendingRecoverySignal = false }
                    return
                }
                if automatic {
                    let delayStart = activeTime()
                    while activeTime() - delayStart < delay {
                        await waitUntilActive()
                        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                    }
                } else {
                    // The closing authentication prompt's foreground hint is
                    // consumed by this one recovery read, not another run.
                    pendingRecoverySignal = false
                    request = .recoveryRead
                }
            }
        }
    }
    /// Private codes are not declared to mean a network fault. This narrow rule
    /// only permits one fresh, fully verified shared read after a manual failure.
    static func permitsInternalRecoveryRead(_ error: Error) -> Bool {
        guard let store = error as? StoreKitError, case .systemError(let underlying) = store else { return false }
        let cocoa = underlying as NSError
        return cocoa.domain == "SKInternalErrorDomain" && cocoa.code == 21
    }
    private func underlyingDidFinish(_ result: Result<AppTransactionRouteEvidence, Error>) {
        isWaitingForStoreKit = false
        let allowsInternalRead = pendingSDKRequest == .userInitiatedRefresh
        pendingSDKRequest = nil
        do {
            _ = try AppServiceBootstrapPolicy.resolve(try result.get(), expectedBundleID: bundleID)
        } catch {
            let failure = AppServiceLaunchFailure(error: error)
            if !AppServiceLaunchFailure.isTransient(error) && !(allowsInternalRead && Self.permitsInternalRecoveryRead(error)) {
                // Keep the already reported timeout and copy text consistent.
                // Late terminal errors only decide whether another read is safe.
                lateTerminalVeto = failure.kind != .taskCancelled
                automaticRecoveryAllowed = failure.kind == .taskCancelled
                pendingRecoverySignal = false
                scheduleDeliveryWhenIdle(); return
            }
        }
        // Never freeze late evidence. At most two recovery runs may re-read it.
        automaticRecoveryAllowed = true; pendingRecoverySignal = true
        Task { [weak self] in
            guard let self else { return }
            await self.recoverFromSignal()
            self.scheduleDeliveryWhenIdle()
        }
    }
    private func emit(attemptID: UUID, request: AppTransactionEvidenceRequest, outcome: AppLaunchDiagnosticEvent.Outcome,
                      attempt: Int, started: TimeInterval, code: String, chain: [AppLaunchDiagnosticError],
                      environment: AppLaunchDiagnosticEvent.VerifiedEnvironment = .unknown) async {
        let event = AppLaunchDiagnosticEvent(launchID: launchID, attemptID: attemptID, metadata: metadata,
            phase: request, outcome: outcome, attempt: attempt, elapsed: ProcessInfo.processInfo.systemUptime - started,
            diagnosticCode: code, errorChain: chain, environment: environment)
        diagnosticText = event.safeText
        if outcome == .recovered { logger.info("phase=\(request.rawValue, privacy: .public) outcome=recovered event=\(event.eventID.uuidString, privacy: .public)") }
        else if outcome != .taskCancelled { logger.error("phase=\(request.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) diagnostic=\(code, privacy: .public) event=\(event.eventID.uuidString, privacy: .public)") }
        guard reportedEvents < 40 else { return }
        reportedEvents += 1
        await reporter.report(event)
    }
}
