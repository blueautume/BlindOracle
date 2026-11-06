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

enum AppTransactionEvidenceRequest: String, Sendable, Equatable {
    case current, userInitiatedRefresh
}

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
        case network, cancelled, unverified, unavailable, unsupportedEnvironment
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
        } else if error is CancellationError {
            kind = .cancelled; diagnosticCode = "env_cancelled"
        } else if let storeError = error as? StoreKitError {
            switch storeError {
            case .userCancelled: kind = .cancelled; diagnosticCode = "env_cancelled"
            case .networkError: kind = .network; diagnosticCode = "env_network"
            case .systemError(let underlying):
                let inner = underlying as NSError
                if inner.domain == NSURLErrorDomain {
                    kind = inner.code == URLError.cancelled.rawValue ? .cancelled : .network
                    diagnosticCode = kind == .cancelled ? "env_cancelled" : "env_network"
                } else if inner.domain == NSCocoaErrorDomain && inner.code == NSUserCancelledError {
                    kind = .cancelled; diagnosticCode = "env_cancelled"
                } else {
                    kind = .unavailable; diagnosticCode = "env_store_unavailable"
                }
            default: kind = .unavailable; diagnosticCode = "env_store_unavailable"
            }
        } else {
            let cocoa = error as NSError
            if cocoa.domain == NSURLErrorDomain {
                kind = cocoa.code == URLError.cancelled.rawValue ? .cancelled : .network
                diagnosticCode = kind == .cancelled ? "env_cancelled" : "env_network"
            } else if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError {
                kind = .cancelled; diagnosticCode = "env_cancelled"
            } else {
                kind = .internalFailure; diagnosticCode = "env_internal"
            }
        }
    }
}

/// No arbitrary domain, description, userInfo, payload, or account identifier reaches logging.
private struct AppServiceErrorDiagnostic {
    enum Domain: String { case url, storeKit, storeKitInternal, appStore, cocoa, bootstrap, other }
    let domain: Domain
    let code: Int

    init(_ error: Error) {
        let diagnosticError: Error
        if let storeError = error as? StoreKitError, case .systemError(let underlying) = storeError { diagnosticError = underlying }
        else { diagnosticError = error }
        let cocoa = diagnosticError as NSError
        code = cocoa.code
        if diagnosticError is AppServiceBootstrapError || diagnosticError is AppTransactionEvidenceError {
            domain = .bootstrap
        } else {
            switch cocoa.domain {
            case NSURLErrorDomain: domain = .url
            case "StoreKit.StoreKitError", "SKErrorDomain": domain = .storeKit
            case "SKInternalErrorDomain": domain = .storeKitInternal
            case "ASDErrorDomain": domain = .appStore
            case NSCocoaErrorDomain: domain = .cocoa
            default: domain = .other
            }
        }
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
        case .current: result = try await AppTransaction.shared
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

@MainActor final class AppServiceLaunchCoordinator: ObservableObject {
    enum State: Equatable { case resolving, recoveryRequired, ready(AppServiceContext) }
    @Published private(set) var state: State = .resolving
    @Published private(set) var failure: AppServiceLaunchFailure?
    private let logger = Logger(subsystem: "com.lihao.BlindOracle", category: "AppServiceBootstrap")
    private let provider: any AppTransactionEvidenceProviding
    private let contextStore: AppServiceContextStore
    private let bundleID: String
    private var isResolving = false
    init(provider: any AppTransactionEvidenceProviding = StoreKitAppTransactionEvidence(),
         contextStore: AppServiceContextStore = .process, bundleID: String = Bundle.main.bundleIdentifier ?? "") {
        self.provider = provider; self.contextStore = contextStore; self.bundleID = bundleID
    }
    func resolve() async {
        await resolve(for: .current)
    }
    /// May display an App Store authentication prompt. Call only from a deliberate user action.
    func retryFromUser() async {
        await resolve(for: .userInitiatedRefresh)
    }
    private func resolve(for request: AppTransactionEvidenceRequest) async {
        guard !isResolving else { return }
        if let selected = contextStore.snapshot() { failure = nil; state = .ready(selected); return }
        isResolving = true; failure = nil; state = .resolving
        defer { isResolving = false }
        do {
            let evidence = try await provider.evidence(for: request)
            try Task.checkCancellation()
            let context = try AppServiceBootstrapPolicy.resolve(evidence, expectedBundleID: bundleID)
            state = .ready(try contextStore.freeze(context))
        } catch {
            let failure = AppServiceLaunchFailure(error: error)
            let diagnostic = AppServiceErrorDiagnostic(error)
            self.failure = failure
            logger.error("phase=\(request.rawValue, privacy: .public) kind=\(failure.kind.rawValue, privacy: .public) domain=\(diagnostic.domain.rawValue, privacy: .public) code=\(diagnostic.code, privacy: .public)")
            state = .recoveryRequired
        }
    }
}
