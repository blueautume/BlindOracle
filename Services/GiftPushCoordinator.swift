import Security
import Combine
import UIKit
import UserNotifications

struct GiftPushRegistration: Encodable {
    let installationID: UUID
    let deviceToken: String?
    let apnsEnvironment: String
    let language: AppLanguage

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case deviceToken = "device_token"
        case apnsEnvironment = "apns_environment"
        case language
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(installationID.uuidString.lowercased(), forKey: .installationID)
        try values.encode(deviceToken, forKey: .deviceToken)
        try values.encode(apnsEnvironment, forKey: .apnsEnvironment)
        try values.encode(language, forKey: .language)
    }
}

@MainActor
final class GiftPushCoordinator: NSObject, ObservableObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @Published private(set) var showsExplanation = false
    @Published private(set) var openedAccountID: UUID?

    private let explanationShownKey = "oracle.giftPush.explanationShown"
    private let center = UNUserNotificationCenter.current()
    private weak var activeAccount: AccountStore?
    private var activeAccountID: UUID?
    private var language: AppLanguage = .simplifiedChinese
    private var acceptsNotifications = false
    private var lastDisabledAccountID: UUID?
    private var pendingRegistration: (value: GiftPushRegistration, accountID: UUID)?
    private var sendingRegistration = false
    private var isRequestingAuthorization = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        center.delegate = self
        return true
    }

    func refresh(account: AccountStore, language: AppLanguage) async {
        guard account.canAccessMain, let accountID = account.user.flatMap({ UUID(uuidString: $0.id) }) else { return }
        let settings = await center.notificationSettings()
        guard !Task.isCancelled, account.canAccessMain,
              account.user.flatMap({ UUID(uuidString: $0.id) }) == accountID else { return }

        activeAccount = account
        activeAccountID = accountID
        self.language = language

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            acceptsNotifications = true
            lastDisabledAccountID = nil
            dismissExplanation()
            UIApplication.shared.registerForRemoteNotifications()
        case .notDetermined:
            acceptsNotifications = false
            if lastDisabledAccountID != accountID { setRegistration(token: nil) }
            if !UserDefaults.standard.bool(forKey: explanationShownKey), !isRequestingAuthorization {
                showsExplanation = true
            }
        default:
            dismissExplanation()
            acceptsNotifications = false
            disableDeliveryOnDevice()
            if lastDisabledAccountID != accountID { setRegistration(token: nil) }
        }
    }

    func explanationAppeared() {
        UserDefaults.standard.set(true, forKey: explanationShownKey)
    }

    func dismissExplanation() {
        showsExplanation = false
    }

    func requestAuthorization(account: AccountStore, language: AppLanguage) async {
        guard !isRequestingAuthorization, account.canAccessMain else { return }
        isRequestingAuthorization = true
        dismissExplanation()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        isRequestingAuthorization = false
        await refresh(account: account, language: language)
    }

    func signedOut() {
        dismissExplanation()
        acceptsNotifications = false
        activeAccount = nil
        activeAccountID = nil
        lastDisabledAccountID = nil
        pendingRegistration = nil
        disableDeliveryOnDevice()
    }

    private func disableDeliveryOnDevice() {
        if UIApplication.shared.isRegisteredForRemoteNotifications {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
        center.removeAllDeliveredNotifications()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard acceptsNotifications, !deviceToken.isEmpty else { return }
        setRegistration(token: deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    private func setRegistration(token: String?) {
        guard let accountID = activeAccountID,
              let environment = Bundle.main.object(forInfoDictionaryKey: "OracleAPNsEnvironment") as? String,
              environment == "development" || environment == "production",
              let installationID = Self.installationID(createIfMissing: token != nil) else { return }
        let value = GiftPushRegistration(installationID: installationID, deviceToken: token,
                                         apnsEnvironment: environment, language: language)
        pendingRegistration = (value, accountID)
        guard !sendingRegistration else { return }
        sendingRegistration = true
        Task { await sendPendingRegistration() }
    }

    private func sendPendingRegistration() async {
        defer { sendingRegistration = false }
        while let (registration, accountID) = pendingRegistration {
            pendingRegistration = nil
            guard activeAccountID == accountID, let account = activeAccount else { continue }
            do {
                try await account.syncGiftPushInstallation(registration, accountID: accountID)
                if registration.deviceToken == nil, activeAccountID == accountID, !acceptsNotifications {
                    lastDisabledAccountID = accountID
                }
            } catch {
                // Recheck authorization and request a fresh device token on the next foreground event.
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard acceptsNotifications, let accountID = Self.giftAccountID(from: notification), accountID == activeAccountID,
              activeAccount?.canAccessMain == true else { return [] }
        NotificationCenter.default.post(name: .accountBalanceChanged, object: nil)
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        openedAccountID = Self.giftAccountID(from: response.notification)
    }

    func consumeOpen(for accountID: String?) -> Bool {
        guard let targetID = openedAccountID, let accountID else { return false }
        openedAccountID = nil
        return UUID(uuidString: accountID) == targetID
    }

    private static func giftAccountID(from notification: UNNotification) -> UUID? {
        let payload = notification.request.content.userInfo
        guard payload["kind"] as? String == "gift_arrival", let accountID = payload["account_id"] as? String else { return nil }
        return UUID(uuidString: accountID)
    }

    /// A UUID local to this device avoids sharing an installation across restored backups.
    private static func installationID(createIfMissing: Bool) -> UUID? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lihao.BlindOracle.giftPush",
            kSecAttrAccount as String: "installation"
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let string = String(data: data, encoding: .utf8) {
            return UUID(uuidString: string)
        }
        guard status == errSecItemNotFound, createIfMissing else { return nil }
        let id = UUID()
        var item = query
        item[kSecValueData as String] = Data(id.uuidString.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? id : nil
    }
}
