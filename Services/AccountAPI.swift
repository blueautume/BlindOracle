import Foundation
import CryptoKit

struct AccountUser: Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var email: String?
    var createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name", createdAt = "created_at"
    }
}

struct AppleLoginChallenge: Decodable, Sendable {
    var challengeID: String
    var nonce: String
    var expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id", nonce, expiresIn = "expires_in"
    }
    var hashedNonce: String { SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct AccountTokenResponse: Decodable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int
    var user: AccountUser
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", user
    }
}

struct AccountSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var user: AccountUser
    var appleUserID: String?
    init(response: AccountTokenResponse, appleUserID: String?, now: Date = Date()) throws {
        guard !response.accessToken.isEmpty, !response.refreshToken.isEmpty, response.expiresIn > 0,
              !response.user.id.isEmpty else { throw AccountAPIError.invalidResponse }
        accessToken = response.accessToken; refreshToken = response.refreshToken
        expiresAt = now.addingTimeInterval(TimeInterval(response.expiresIn))
        user = response.user; self.appleUserID = appleUserID
    }
}

struct AccountQuota: Decodable, Equatable, Sendable {
    var remainingPercent: Int
    var isUnlimited: Bool
    var canStart: Bool
    var refundDebt = 0
    enum CodingKeys: String, CodingKey {
        case remainingPercent = "remaining_percent", isUnlimited = "is_unlimited", canStart = "can_start", refundDebt = "refund_debt"
    }
    init(remainingPercent: Int, isUnlimited: Bool, canStart: Bool, refundDebt: Int = 0) {
        self.remainingPercent = remainingPercent; self.isUnlimited = isUnlimited; self.canStart = canStart; self.refundDebt = refundDebt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remainingPercent = try c.decode(Int.self, forKey: .remainingPercent)
        isUnlimited = try c.decode(Bool.self, forKey: .isUnlimited)
        canStart = try c.decode(Bool.self, forKey: .canStart)
        refundDebt = try c.decodeIfPresent(Int.self, forKey: .refundDebt) ?? 0
    }
    var displayedPercent: Int { refundDebt > 0 ? 0 : (isUnlimited && canStart ? 100 : min(100, max(0, remainingPercent))) }
}

struct AccountWallet: Decodable, Equatable, Sendable {
    var paidCredits: Int
    var bonusCredits: Int
    var reservedCredits: Int
    var availableCredits: Int
    var quota: AccountQuota?
    enum CodingKeys: String, CodingKey {
        case paidCredits = "paid_credits", bonusCredits = "bonus_credits"
        case reservedCredits = "reserved_credits", availableCredits = "available_credits"
        case quota
    }
    init(paidCredits: Int = 0, bonusCredits: Int = 0, reservedCredits: Int = 0, availableCredits: Int = 0, quota: AccountQuota? = nil) {
        self.paidCredits = paidCredits; self.bonusCredits = bonusCredits
        self.reservedCredits = reservedCredits; self.availableCredits = availableCredits; self.quota = quota
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paidCredits = try c.decodeIfPresent(Int.self, forKey: .paidCredits) ?? 0
        bonusCredits = try c.decodeIfPresent(Int.self, forKey: .bonusCredits) ?? 0
        reservedCredits = try c.decodeIfPresent(Int.self, forKey: .reservedCredits) ?? 0
        availableCredits = try c.decodeIfPresent(Int.self, forKey: .availableCredits) ?? 0
        quota = try c.decodeIfPresent(AccountQuota.self, forKey: .quota)
    }
}

struct AccountUsageSummary: Decodable, Equatable, Sendable {
    var requestCount: Int
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var confirmedCostCNY: Decimal
    var unknownCount: Int
    enum CodingKeys: String, CodingKey {
        case requestCount = "request_count", inputTokens = "input_tokens", outputTokens = "output_tokens"
        case totalTokens = "total_tokens", confirmedCostCNY = "confirmed_cost_cny", unknownCount = "unknown_count"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestCount = try c.decode(Int.self, forKey: .requestCount)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        totalTokens = try c.decode(Int.self, forKey: .totalTokens)
        unknownCount = try c.decode(Int.self, forKey: .unknownCount)
        if let text = try? c.decode(String.self, forKey: .confirmedCostCNY),
           let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) {
            confirmedCostCNY = amount
        } else { confirmedCostCNY = try c.decode(Decimal.self, forKey: .confirmedCostCNY) }
    }
}

struct AccountProductCatalog: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var productID: String
        var name: String
        var currency: String
        var priceMilliunits: Decimal
        var credits: Int?
        enum CodingKeys: String, CodingKey { case productID = "product_id", name, currency, credits, priceMilliunits = "price_milliunits" }
    }
    var products: [Item]
}

struct ApplePurchaseConfirmation: Decodable, Sendable {
    var transactionID: String
    var status: String
    var wallet: AccountWallet
    enum CodingKeys: String, CodingKey { case transactionID = "transaction_id", status, wallet }
    var isResolved: Bool { status == "credited" || status == "refunded" }
}

struct AITaskAdmission: Decodable, Sendable {
    var taskID: UUID
    var state: String
    var admissionToken: String
    enum CodingKeys: String, CodingKey { case taskID = "task_id", state, admissionToken = "admission_token" }
}

enum AccountAPIError: Error, LocalizedError, Equatable {
    case unauthorized, unavailable, invalidResponse, storage, staleSession
    case server(status: Int, code: String)
    var status: Int? {
        if case .server(let status, _) = self { return status }
        return self == .unauthorized ? 401 : nil
    }
    var errorDescription: String? {
        switch self {
        case .unauthorized: L10n.text("登录已失效，请重新使用 Apple 登录。", "Your session expired. Sign in with Apple again.")
        case .storage: L10n.text("无法安全保存或清理登录信息，请解锁设备后重试。", "Your session could not be saved or cleared securely. Unlock your device and try again.")
        case .staleSession: L10n.text("账号状态已变化，请重试。", "Your account changed. Please try again.")
        case .invalidResponse: L10n.text("账号服务返回的信息不完整，请稍后重试。", "The account service returned an incomplete response. Try again later.")
        case .unavailable: L10n.text("账号服务暂时无法连接，请检查网络后重试。", "The account service is unavailable. Check your connection and try again.")
        case .server(let status, _):
            if status == 429 { L10n.text("操作较频繁，请稍后再试。", "Too many attempts. Please try again shortly.") }
            else { L10n.text("账号服务暂时不可用，请稍后重试。", "The account service is temporarily unavailable. Try again later.") }
        }
    }
}

/// Account metadata only. Questions, profiles, answers and provider keys never enter this API.
actor AccountAPI {
    static var baseURL: URL { ServiceEnvironment.current.baseURL }
    private let session: URLSession
    private let requestBaseURL: URL
    private let appTransactionJWS: String?
    init(configuration: URLSessionConfiguration = .ephemeral, context: AppServiceContext? = nil) {
        let selected = context ?? AppServiceContextStore.process.requireContext()
        requestBaseURL = selected.environment.baseURL; appTransactionJWS = selected.appleLoginProof
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }
    func challenge() async throws -> AppleLoginChallenge {
        try await decode("auth/apple/challenge/", method: "POST", body: [:])
    }
    func signIn(challengeID: String, identityToken: String, authorizationCode: String, fullName: String?) async throws -> AccountTokenResponse {
        var body = ["challenge_id": challengeID, "identity_token": identityToken, "authorization_code": authorizationCode]
        if let fullName, !fullName.isEmpty { body["full_name"] = String(fullName.prefix(256)) }
        if let appTransactionJWS { body["app_transaction_jws"] = appTransactionJWS }
        return try await decode("auth/apple/", method: "POST", body: body)
    }
    func refresh(_ token: String) async throws -> AccountTokenResponse {
        try await decode("auth/refresh/", method: "POST", body: ["refresh_token": token])
    }
    func user(token: String) async throws -> AccountUser { try await decode("me/", token: token) }
    func wallet(token: String) async throws -> AccountWallet { try await decode("wallet/", token: token) }
    func usage(token: String) async throws -> AccountUsageSummary { try await decode("usage/summary/", token: token) }
    func products(token: String) async throws -> AccountProductCatalog { try await decode("products/", token: token) }
    func verifyApplePurchase(transactionID: String, environment: String?, token: String) async throws -> ApplePurchaseConfirmation {
        var body = ["transaction_id": transactionID]
        if let environment { body["environment"] = environment }
        return try await decode("purchases/apple/verify/", method: "POST", token: token, body: body)
    }
    func startAITask(_ id: UUID, token: String) async throws -> AITaskAdmission {
        try await decode("ai/tasks/start/", method: "POST", token: token, body: ["task_id": id.uuidString.lowercased()])
    }
    func endAITask(_ id: UUID, status: String, admissionToken: String, token: String) async throws {
        _ = try await send("ai/tasks/\(id.uuidString.lowercased())/end/", method: "POST", token: token,
            body: ["status": status], headers: ["X-Task-Token": admissionToken])
    }
    func logout(accessToken: String, refreshToken: String) async throws {
        _ = try await send("auth/logout/", method: "POST", token: accessToken, body: ["refresh_token": refreshToken])
    }
    func deleteUser(token: String) async throws { _ = try await send("me/", method: "DELETE", token: token) }
    private func decode<T: Decodable>(_ path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil) async throws -> T {
        let data = try await send(path, method: method, token: token, body: body)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AccountAPIError.invalidResponse }
    }
    private func send(_ path: String, method: String, token: String? = nil, body: [String: String]? = nil, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: requestBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AccountAPIError.unavailable }
        guard let http = response as? HTTPURLResponse, data.count <= 1_000_000 else { throw AccountAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AccountAPIError.unauthorized }
            struct Failure: Decodable { struct Detail: Decodable { var code: String }; var error: Detail }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error.code ?? "unavailable"
            throw AccountAPIError.server(status: http.statusCode, code: code)
        }
        return data
    }
}
