import Foundation

/// Only a known rejection before upstream admission is safe to wait and resend.
/// Network failures, provider failures and other limits retain explicit retries.
struct GatewayGenerationWaitPolicy: Sendable {
    let timeout: Duration
    let initialDelay: Duration
    let maximumDelay: Duration

    init(timeout: Duration = .seconds(900), initialDelay: Duration = .seconds(1),
         maximumDelay: Duration = .seconds(3)) {
        self.timeout = max(.zero, timeout)
        self.maximumDelay = max(.milliseconds(1), maximumDelay)
        self.initialDelay = min(self.maximumDelay, max(.milliseconds(1), initialDelay))
    }

    static func rejection(status: Int, body: Data) -> DeepSeekError? {
        let error = AIGatewayFailure.error(status: status, body: body)
        guard case .gateway(let status, let code) = error else { return nil }
        switch (status, code) {
        case (429, "generation_in_progress"), (429, "sandbox_installation_busy"), (409, "stage_running"):
            return error
        default:
            return nil
        }
    }
}
