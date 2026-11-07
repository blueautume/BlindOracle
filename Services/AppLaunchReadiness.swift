import Foundation
import Network

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
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration)
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
