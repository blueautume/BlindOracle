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

/// An unstructured race is intentional: a StoreKit operation may ignore
/// cancellation. The timeout resumes the caller without waiting for that task,
/// and the gate discards its eventual result before it can freeze a route.
@MainActor private final class AppTransactionEvidenceRace {
    private var continuation: CheckedContinuation<Result<AppTransactionRouteEvidence, Error>, Never>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    func run(provider: any AppTransactionEvidenceProviding, request: AppTransactionEvidenceRequest,
             timeout: TimeInterval) async -> Result<AppTransactionRouteEvidence, Error> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            work = Task {
                let result: Result<AppTransactionRouteEvidence, Error>
                do { result = .success(try await provider.evidence(for: request)) }
                catch { result = .failure(error) }
                self.finish(result)
            }
            timer = Task {
                do { try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000)) }
                catch { return }
                self.finish(.failure(AppServiceLaunchTimeout()))
            }
        }
    }
    private func finish(_ result: Result<AppTransactionRouteEvidence, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel(); timer?.cancel(); work = nil; timer = nil
        continuation.resume(returning: result)
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
    private let logger = Logger(subsystem: "com.lihao.BlindOracle", category: "AppServiceBootstrap")
    private let provider: any AppTransactionEvidenceProviding
    private let contextStore: AppServiceContextStore
    private let bundleID: String
    private let reporter: any AppLaunchDiagnosticReporting
    private let timing: AppServiceLaunchTiming
    private let metadata: AppLaunchDiagnosticMetadata
    private let launchID = UUID()
    private var flight: Task<Void, Never>?
    private var flightID: UUID?
    private var hasFailed = false
    private var reportedEvents = 0
    init(provider: any AppTransactionEvidenceProviding = StoreKitAppTransactionEvidence(),
         contextStore: AppServiceContextStore = .process, bundleID: String = Bundle.main.bundleIdentifier ?? "",
         reporter: (any AppLaunchDiagnosticReporting)? = nil, timing: AppServiceLaunchTiming = .standard,
         metadata: AppLaunchDiagnosticMetadata = .current) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let fixture = arguments.contains("--ui-testing-local") && arguments.contains("--ui-testing-service-environment-failure")
        if fixture {
            self.provider = AppLaunchFailureUIFixture(); self.contextStore = AppServiceContextStore()
            self.timing = AppServiceLaunchTiming(automaticRequestTimeout: 0.1, automaticTotalTimeout: 0.2,
                                                manualRefreshTimeout: 0.1, recoveryReadTimeout: 0.1, retryDelays: [])
        } else { self.provider = provider; self.contextStore = contextStore; self.timing = timing }
        #else
        self.provider = provider; self.contextStore = contextStore; self.timing = timing
        #endif
        self.bundleID = bundleID; self.metadata = metadata
        if let reporter { self.reporter = reporter }
        else if provider is StoreKitAppTransactionEvidence && !AppServiceBootstrapPolicy.isUnitTestHost
                    && !ProcessInfo.processInfo.arguments.contains("--ui-testing-local") {
            self.reporter = QueuedAppLaunchDiagnosticReporter.shared
        } else { self.reporter = DisabledAppLaunchDiagnosticReporter() }
    }
    func resolve() async {
        await resolve(for: .current)
    }
    /// May display an App Store authentication prompt. Call only from a deliberate user action.
    func retryFromUser() async {
        await resolve(for: .userInitiatedRefresh)
    }
    func resumeDiagnostics() async {
        let reporter = self.reporter
        Task { await reporter.flush() }
        if failure?.kind == .taskCancelled, flight == nil { await resolve() }
    }
    private func resolve(for request: AppTransactionEvidenceRequest) async {
        guard flight == nil else { return }
        if let selected = contextStore.snapshot() { failure = nil; state = .ready(selected); return }
        failure = nil; state = .resolving
        let id = UUID(); flightID = id
        let reporter = self.reporter
        Task { await reporter.flush() }
        // View.task cancellation must not cancel the app-owned verification.
        let running = Task { [weak self] in
            guard let self else { return }
            await self.perform(request: request, id: id)
            if self.flightID == id { self.flight = nil; self.flightID = nil }
        }
        flight = running
        await running.value
    }
    private func perform(request initialRequest: AppTransactionEvidenceRequest, id: UUID) async {
        let started = ProcessInfo.processInfo.systemUptime
        var request = initialRequest
        let automatic = initialRequest == .current
        let limit = automatic ? min(3, timing.retryDelays.count + 1) : 2
        for attempt in 1...max(1, limit) {
            guard flightID == id else { return }
            let attemptID = id
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let timeout: TimeInterval
            if automatic { timeout = min(timing.automaticRequestTimeout, max(0.001, timing.automaticTotalTimeout - elapsed)) }
            else { timeout = request == .userInitiatedRefresh ? timing.manualRefreshTimeout : timing.recoveryReadTimeout }
            let result = await AppTransactionEvidenceRace().run(provider: provider, request: request, timeout: timeout)
            guard flightID == id else { return }
            do {
                let evidence = try result.get()
                let context = try AppServiceBootstrapPolicy.resolve(evidence, expectedBundleID: bundleID)
                let selected = try contextStore.freeze(context)
                failure = nil; state = .ready(selected)
                if hasFailed {
                    emit(attemptID: attemptID, request: request, outcome: .recovered, attempt: attempt, started: started,
                         code: "env_recovered", chain: [], environment: selected.environment == .production ? .production : .sandbox)
                }
                return
            } catch {
                hasFailed = true
                let failure = AppServiceLaunchFailure(error: error)
                let chain = AppLaunchDiagnosticError.chain(for: error)
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let delay = automatic && attempt <= timing.retryDelays.count ? max(0, timing.retryDelays[attempt - 1]) : 0
                let withinBudget = !automatic || elapsed + delay + 0.001 < timing.automaticTotalTimeout
                let retry = attempt < limit && withinBudget && AppServiceLaunchFailure.isTransient(error)
                let outcome: AppLaunchDiagnosticEvent.Outcome = retry ? .retrying
                    : failure.kind == .timedOut ? .timedOut : failure.kind == .taskCancelled ? .taskCancelled : .failed
                emit(attemptID: attemptID, request: request, outcome: outcome, attempt: attempt, started: started,
                     code: failure.diagnosticCode, chain: chain)
                if !retry {
                    self.failure = failure; state = .recoveryRequired
                    return
                }
                if automatic {
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch {
                        self.failure = AppServiceLaunchFailure(error: CancellationError()); state = .recoveryRequired
                        return
                    }
                } else { request = .recoveryRead }
            }
        }
    }
    private func emit(attemptID: UUID, request: AppTransactionEvidenceRequest, outcome: AppLaunchDiagnosticEvent.Outcome,
                      attempt: Int, started: TimeInterval, code: String, chain: [AppLaunchDiagnosticError],
                      environment: AppLaunchDiagnosticEvent.VerifiedEnvironment = .unknown) {
        let event = AppLaunchDiagnosticEvent(launchID: launchID, attemptID: attemptID, metadata: metadata,
            phase: request, outcome: outcome, attempt: attempt, elapsed: ProcessInfo.processInfo.systemUptime - started,
            diagnosticCode: code, errorChain: chain, environment: environment)
        diagnosticText = event.safeText
        if outcome == .recovered {
            logger.info("phase=\(request.rawValue, privacy: .public) outcome=recovered event=\(event.eventID.uuidString, privacy: .public)")
        } else if outcome != .taskCancelled {
            logger.error("phase=\(request.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) diagnostic=\(code, privacy: .public) event=\(event.eventID.uuidString, privacy: .public)")
        }
        guard reportedEvents < 40 else { return }
        reportedEvents += 1
        let reporter = self.reporter
        Task { await reporter.report(event) }
    }
}
