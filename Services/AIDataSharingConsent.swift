import Foundation

/// Permission to send reading context to the developer's gateway and DeepSeek.
/// It is separate from account authentication and never uploads local records by itself.
actor AIDataSharingConsentStore {
    static let currentPolicyVersion = 1
    static let didChange = Notification.Name("oracle.aiDataSharingConsentChanged")
    static let shared: AIDataSharingConsentStore = makeShared()

    enum ConsentError: Error { case required }

    private let defaults: UserDefaults
    private let policyVersion: Int
    private let storageKey: String

    init(defaults: UserDefaults = .standard, policyVersion: Int = AIDataSharingConsentStore.currentPolicyVersion,
         storageKey: String = "oracle.aiDataSharingConsent.policyVersion") {
        self.defaults = defaults
        self.policyVersion = policyVersion
        self.storageKey = storageKey
    }

    func isAuthorized() -> Bool {
        defaults.integer(forKey: storageKey) == policyVersion
    }

    func grant() {
        defaults.set(policyVersion, forKey: storageKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func revoke() {
        defaults.removeObject(forKey: storageKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func requireAuthorization() throws {
        guard isAuthorized() else { throw ConsentError.required }
    }

    private static func makeShared() -> AIDataSharingConsentStore {
        #if DEBUG
        // Local UI fixtures use an isolated preference domain, never the user's
        // real permission. Consent-specific tests opt into the actual prompt.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-local") {
            let flag = "--ui-testing-ai-consent-suite"
            let suffix = arguments.firstIndex(of: flag).flatMap { index in
                arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            } ?? "default"
            let suite = "BlindOracle.UIDataSharingConsent." + suffix
            let defaults = UserDefaults(suiteName: suite)!
            if arguments.contains("--ui-testing-ai-consent-reset") { defaults.removePersistentDomain(forName: suite) }
            if !arguments.contains("--ui-testing-ai-consent-required") {
                defaults.set(currentPolicyVersion, forKey: "oracle.aiDataSharingConsent.policyVersion")
            }
            return AIDataSharingConsentStore(defaults: defaults)
        }
        #endif
        return AIDataSharingConsentStore()
    }
}
