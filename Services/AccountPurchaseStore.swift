import Foundation
import StoreKit
import Combine

extension Notification.Name {
    static let accountBalanceChanged = Notification.Name("BlindOracle.accountBalanceChanged")
}

struct VerifiedAccountPurchase: Sendable {
    var transactionID: String
    var appAccountToken: UUID?
    var environment: String?
}

/// StoreKit owns the payment and price. The server owns delivery and the account balance.
@MainActor final class AccountPurchaseStore: ObservableObject {
    @Published private(set) var products: [AccountPurchaseProduct] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isCheckingPurchases = false
    @Published private(set) var hasUnresolvedPurchase = false
    @Published private(set) var message: String?
    private let api: AccountAPI
    private let sessions: AccountSessionManager
    private let environment: ServiceEnvironment
    private let provider: AccountPurchaseProviding
    private var allowedProductIDs: Set<String> = []
    private var inFlightTransactions: Set<String> = []
    private var unresolvedByAccount: [UUID: Set<String>] = [:]
    private var pendingApprovalAccounts: Set<UUID> = []
    private var uncertainPurchaseAccounts: Set<UUID> = []
    private var needsReconciliation = false
    private var reconcileUserInitiated = false
    private var reconciliationTask: Task<Void, Never>?
    private var updates: Task<Void, Never>?
    init(api: AccountAPI = AccountAPI(), sessions: AccountSessionManager = .shared, environment: ServiceEnvironment = .current,
         provider: AccountPurchaseProviding? = nil) {
        self.api = api; self.sessions = sessions; self.environment = environment; self.provider = provider ?? StoreKitPurchaseProvider()
    }
    deinit { updates?.cancel(); reconciliationTask?.cancel() }
    func startObserving() {
        guard updates == nil else { return }
        let events = provider.updates()
        updates = Task { [weak self] in
            for await result in events {
                guard !Task.isCancelled, let self else { return }
                await self.handle(result)
            }
        }
    }
    func resumeUnfinished(userInitiated: Bool = false) async {
        guard !isCheckingPurchases, !isPurchasing else {
            needsReconciliation = true
            reconcileUserInitiated = reconcileUserInitiated || userInitiated
            return
        }
        isCheckingPurchases = true
        defer { isCheckingPurchases = false; scheduleReconciliationIfNeeded() }
        let context = await sessions.context()
        guard let accountID = context.session.flatMap({ UUID(uuidString: $0.user.id) }) else {
            hasUnresolvedPurchase = false; return
        }
        hasUnresolvedPurchase = hasUnresolved(for: accountID)
        if userInitiated { message = nil }
        var eligibleCount = 0
        for await result in provider.unfinished() {
            guard !Task.isCancelled else { return }
            guard await sessions.sessionGeneration() == context.generation else { needsReconciliation = true; return }
            if case .verified(let record, _) = result,
               record.appAccountToken == accountID, record.environment == environment.storeKitEnvironment {
                eligibleCount += 1
            }
            await handle(result)
        }
        guard await sessions.sessionGeneration() == context.generation else { needsReconciliation = true; return }
        hasUnresolvedPurchase = hasUnresolved(for: accountID)
        if userInitiated, pendingApprovalAccounts.contains(accountID), eligibleCount == 0 {
            message = L10n.text("Apple正在确认这笔购买，完成后会自动更新，请勿重复付款。", "Apple is still confirming this purchase. It will update automatically; please do not buy again.")
        }
        if userInitiated, uncertainPurchaseAccounts.contains(accountID), eligibleCount == 0 {
            message = L10n.text("这笔购买仍待核实，请保留订单并联系我们，暂时不要重复付款。", "This purchase still needs verification. Keep the order and contact us; please do not buy again.")
        }
        if userInitiated, eligibleCount == 0, !hasUnresolvedPurchase {
            message = L10n.text("未发现当前账号待核对的购买。", "There are no pending purchases for this account.")
        }
    }
    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true; message = nil
        defer { isLoading = false }
        let context = await sessions.context()
        do {
            let catalog: AccountProductCatalog = try await authorized(expectedGeneration: context.generation) { [api] token in
                try await api.products(token: token)
            }
            let ids = Set(catalog.products.map(\.productID).filter { !$0.isEmpty })
            let loaded = ids.isEmpty ? [] : try await provider.products(for: ids)
            guard await sessions.sessionGeneration() == context.generation else { return }
            allowedProductIDs = ids
            let regionMismatch = loaded.contains { product in
                guard let approved = catalog.products.first(where: { $0.productID == product.id }) else { return false }
                return product.currency != approved.currency || product.price * 1000 != approved.priceMilliunits
            }
            products = loaded.filter { product in
                guard product.isConsumable, let approved = catalog.products.first(where: { $0.productID == product.id }) else { return false }
                return approved.currency == "CNY" && product.currency == approved.currency && product.price * 1000 == approved.priceMilliunits
            }.sorted { $0.price < $1.price }
            if products.isEmpty {
                message = regionMismatch && environment.isSandbox
                    ? L10n.text("请在设置→开发者→沙盒 Apple 账户登录中国大陆测试账号，再刷新购买选项。", "In Settings → Developer → Sandbox Apple Account, sign in with a China mainland tester, then refresh purchase options.")
                    : L10n.text("补充额度功能正在准备中，请稍后再来。", "Top-ups are being prepared. Please check back later.")
            }
        } catch {
            guard await sessions.sessionGeneration() == context.generation else { return }
            products = []; allowedProductIDs = []
            message = L10n.text("暂时无法获取购买选项，请稍后重试。", "Purchase options are unavailable. Please try again later.")
        }
    }
    func purchase(_ product: AccountPurchaseProduct) async {
        guard !isPurchasing, !isCheckingPurchases, allowedProductIDs.contains(product.id),
              products.contains(where: { $0.id == product.id }), product.isConsumable else { return }
        // Reserve before the first suspension, including the session lookup.
        isPurchasing = true
        defer { isPurchasing = false; scheduleReconciliationIfNeeded() }
        let context = await sessions.context()
        guard let accountID = context.session.flatMap({ UUID(uuidString: $0.user.id) }) else {
            message = AccountAPIError.unauthorized.localizedDescription; return
        }
        hasUnresolvedPurchase = hasUnresolved(for: accountID)
        guard !hasUnresolvedPurchase else {
            message = L10n.text("有购买正在核对，请先点“核对购买”，无需再次付款。", "A purchase is awaiting verification. Use Check purchases before buying again.")
            return
        }
        message = nil
        do {
            let result = try await provider.purchase(productID: product.id, accountToken: accountID)
            if case .pending = result { pendingApprovalAccounts.insert(accountID) }
            if case .success(.unverified) = result { uncertainPurchaseAccounts.insert(accountID) }
            if case .success(.verified(let record, _)) = result,
               record.environment != environment.storeKitEnvironment { uncertainPurchaseAccounts.insert(accountID) }
            guard await sessions.sessionGeneration() == context.generation else { return }
            switch result {
            case .success(let verification):
                if case .verified(let record, _) = verification, record.environment != environment.storeKitEnvironment {
                    hasUnresolvedPurchase = true
                    message = L10n.text("购买所属环境与当前服务不一致，暂未交付。请保留订单并联系我们，无需再次付款。", "This purchase belongs to a different service environment and has not been delivered. Keep the order and contact us; please do not buy again.")
                    return
                }
                if case .unverified = verification { hasUnresolvedPurchase = true }
                await handle(verification)
            case .pending:
                if await sessions.sessionGeneration() == context.generation {
                    hasUnresolvedPurchase = true
                    message = L10n.text("购买正在等待确认，完成后会自动更新。", "Your purchase is awaiting confirmation and will update automatically.")
                }
            case .cancelled: break
            }
        } catch {
            if await sessions.sessionGeneration() == context.generation {
                message = L10n.text("购买未完成，请稍后重试。", "The purchase did not complete. Please try again later.")
            }
        }
    }
    private func handle(_ result: AccountPurchaseEvent) async {
        guard case .verified(let record, let finish) = result else {
            message = L10n.text("购买信息暂未通过核实，请稍后重试或联系我们。", "The purchase could not be verified. Try again later or contact us.")
            return
        }
        await deliver(record, finish: finish)
    }
    /// Called only after StoreKit verification. The server independently checks the official transaction.
    func deliver(_ record: VerifiedAccountPurchase, finish: @escaping @Sendable () async -> Void) async {
        // StoreKit's unfinished sequence may include purchases from the other build; never deliver or finish those here.
        guard record.environment == environment.storeKitEnvironment else { return }
        guard !inFlightTransactions.contains(record.transactionID) else { return }
        let context = await sessions.context()
        guard let userID = context.session.flatMap({ UUID(uuidString: $0.user.id) }), record.appAccountToken == userID else {
            // Keep unfinished purchases for their original account, including after signing out or switching users.
            return
        }
        unresolvedByAccount[userID, default: []].insert(record.transactionID)
        pendingApprovalAccounts.remove(userID)
        uncertainPurchaseAccounts.remove(userID)
        hasUnresolvedPurchase = true
        guard !inFlightTransactions.contains(record.transactionID) else { return }
        inFlightTransactions.insert(record.transactionID)
        defer { inFlightTransactions.remove(record.transactionID) }
        do {
            let confirmation: ApplePurchaseConfirmation = try await authorized(expectedGeneration: context.generation) { [api] token in
                try await api.verifyApplePurchase(transactionID: record.transactionID, environment: record.environment, token: token)
            }
            guard confirmation.transactionID == record.transactionID, confirmation.isResolved else { throw AccountAPIError.invalidResponse }
            guard await sessions.sessionGeneration() == context.generation else { return }
            await finish()
            // The original owner's finished record must be cleared even if
            // sign-out or account switching happened during StoreKit.finish().
            unresolvedByAccount[userID]?.remove(record.transactionID)
            guard await sessions.sessionGeneration() == context.generation else { return }
            hasUnresolvedPurchase = hasUnresolved(for: userID)
            message = confirmation.status == "credited"
                ? L10n.text("额度已补充。", "Your allowance has been replenished.")
                : L10n.text("此购买已退款，未补充额度。", "This purchase was refunded; no allowance was added.")
            NotificationCenter.default.post(name: .accountBalanceChanged, object: nil)
        } catch {
            guard await sessions.sessionGeneration() == context.generation else { return }
            // Never finish an unconfirmed purchase. StoreKit keeps it in unfinished for a later retry.
            message = L10n.text("购买暂未完成核实，请稍后点“核对购买”，或联系我们。请勿重复购买。", "Your purchase is awaiting verification. Use Check purchases later or contact us. Please do not buy again.")
        }
    }
    private func hasUnresolved(for accountID: UUID) -> Bool {
        pendingApprovalAccounts.contains(accountID) || uncertainPurchaseAccounts.contains(accountID)
            || !(unresolvedByAccount[accountID] ?? []).isEmpty
    }
    private func scheduleReconciliationIfNeeded() {
        guard needsReconciliation, !isCheckingPurchases, !isPurchasing, reconciliationTask == nil else { return }
        let userInitiated = reconcileUserInitiated
        needsReconciliation = false; reconcileUserInitiated = false
        reconciliationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.reconciliationTask = nil
            await self.resumeUnfinished(userInitiated: userInitiated)
        }
    }
    private func authorized<T: Sendable>(expectedGeneration: UUID, operation: @Sendable (String) async throws -> T) async throws -> T {
        var token = try await sessions.accessToken(expectedGeneration: expectedGeneration)
        do { return try await operation(token) }
        catch AccountAPIError.unauthorized {
            token = try await sessions.refreshAfterRejection(of: token, expectedGeneration: expectedGeneration)
            do { return try await operation(token) }
            catch AccountAPIError.unauthorized {
                try? await sessions.invalidate(expectedGeneration: expectedGeneration)
                throw AccountAPIError.unauthorized
            }
        }
    }
}
