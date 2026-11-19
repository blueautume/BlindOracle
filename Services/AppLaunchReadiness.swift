import Foundation
import Network
import Combine

/// A successful exchange is only evidence that this app can use HTTPS now.
/// It grants no account, StoreKit verification, environment, or purchase rights.
protocol AppLaunchNetworkReadinessProviding: Sendable {
    func check() async throws
}

struct ImmediateAppLaunchNetworkReadiness: AppLaunchNetworkReadinessProviding {
    func check() async throws { }
}

#if DEBUG
struct DelayedAppLaunchNetworkReadinessUIFixture: AppLaunchNetworkReadinessProviding {
    func check() async throws { try await Task.sleep(nanoseconds: 8_000_000_000) }
}
#endif

struct HTTPSAppLaunchNetworkReadiness: AppLaunchNetworkReadinessProviding {
    static let endpoint = URL(string: "https://wellecho.cn/xiazi-api/v1/health/")!
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral, resourceTimeout: TimeInterval = 90) {
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = min(10, resourceTimeout)
        configuration.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: configuration, delegate: ReadinessRedirectPolicy(), delegateQueue: nil)
    }
    func check() async throws {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme == "https", response.url?.host == Self.endpoint.host,
              (100...599).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        // Even 4xx/5xx proves a real HTTPS exchange. Backend health/business
        // status and its environment must never select or block a StoreKit route.
    }
}

private final class ReadinessRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // A response from the original first-party endpoint is sufficient.
        completionHandler(nil)
    }
}

/// Starts an anonymous request without making account or StoreKit work wait at launch.
@MainActor final class FirstLaunchNetworkWarmup: ObservableObject {
    private static let completedKey = "oracle.firstLaunchNetworkReachable"

    private let readiness: any AppLaunchNetworkReadinessProviding
    private let recoveryReadiness: any AppLaunchNetworkReadinessProviding
    private let defaults: UserDefaults
    private let recoveryWindow: Duration
    private let retryInterval: Duration
    private var didStartProbe = false
    private var startupFlight: Task<Void, Never>?
    private var recoveryFlight: Task<Bool, Never>?
    private var lastSuccessfulProbe: ContinuousClock.Instant?

    init(readiness: any AppLaunchNetworkReadinessProviding = HTTPSAppLaunchNetworkReadiness(resourceTimeout: 30),
         recoveryReadiness: any AppLaunchNetworkReadinessProviding = HTTPSAppLaunchNetworkReadiness(resourceTimeout: 2),
         defaults: UserDefaults = .standard,
         recoveryWindow: Duration = .seconds(30),
         retryInterval: Duration = .seconds(1)) {
        self.readiness = readiness
        self.recoveryReadiness = recoveryReadiness
        self.defaults = defaults
        self.recoveryWindow = recoveryWindow
        self.retryInterval = retryInterval
    }

    deinit {
        startupFlight?.cancel()
        recoveryFlight?.cancel()
    }

    func startIfNeeded() {
        guard !didStartProbe, recoveryFlight == nil, !defaults.bool(forKey: Self.completedKey) else { return }
        didStartProbe = true
        startupFlight = Task { [weak self, readiness] in
            defer { self?.startupFlight = nil }
            do {
                try await readiness.check()
                guard !Task.isCancelled else { return }
                self?.recordSuccess()
            } catch {
                // A failed optional warmup leaves the preference unset for the next launch.
            }
        }
    }

    /// System permission can leave Wi-Fi itself reachable while rejecting this app's first request.
    /// After an explicit sign-in fails, look for a new successful exchange within a short window.
    func waitForSignInNetwork() async -> Bool {
        guard !Task.isCancelled else { return false }
        if let recoveryFlight {
            let connected = await recoveryFlight.value
            return connected && !Task.isCancelled
        }
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: recoveryWindow)
        let flight = Task { [weak self, recoveryReadiness, retryInterval] in
            defer { self?.recoveryFlight = nil }
            while !Task.isCancelled {
                if let success = self?.lastSuccessfulProbe, success >= started { return true }
                guard clock.now < deadline else { return false }
                do {
                    try await recoveryReadiness.check()
                    guard !Task.isCancelled else { return false }
                    self?.recordSuccess()
                    return true
                } catch {
                    do { try await clock.sleep(until: min(deadline, clock.now.advanced(by: retryInterval))) }
                    catch { return false }
                }
            }
            return false
        }
        recoveryFlight = flight
        let connected = await flight.value
        return connected && !Task.isCancelled
    }

    private func recordSuccess() {
        lastSuccessfulProbe = ContinuousClock().now
        defaults.set(true, forKey: Self.completedKey)
    }
}

/// Path changes are hints to try the HTTPS check, never proof of permission.
final class AppLaunchNetworkPathObserver {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.lihao.BlindOracle.launch-network-path")
    init(onRecovery: @escaping @Sendable () -> Void) {
        var previous: NWPath.Status?
        monitor.pathUpdateHandler = { path in
            let recovered = previous != nil && previous != .satisfied && path.status == .satisfied
            previous = path.status
            if recovered { onRecovery() }
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
}
