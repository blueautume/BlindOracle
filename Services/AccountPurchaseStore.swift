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
    private var storefrontObserver: Task<Void, Never>?
    private var productReloadTask: Task<Void, Never>?
    private var needsProductReload = false
    private var storefrontRevision: UInt64 = 0
    private var observedStorefront: String?
    private var hasObservedStorefront = false
    private var loadedStorefront: String?
    private var localDataGeneration = UUID()
    init(api: AccountAPI = AccountAPI(), sessions: AccountSessionManager = .shared, environment: ServiceEnvironment = .current,
         provider: AccountPurchaseProviding? = nil) {
        self.api = api; self.sessions = sessions; self.environment = environment; self.provider = provider ?? StoreKitPurchaseProvider()
    }
    deinit { updates?.cancel(); storefrontObserver?.cancel(); productReloadTask?.cancel(); reconciliationTask?.cancel() }
    func clearDeletedAccountData() {
        localDataGeneration = UUID()
        reconciliationTask?.cancel(); reconciliationTask = nil
        productReloadTask?.cancel(); productReloadTask = nil; needsProductReload = false
        storefrontRevision &+= 1; loadedStorefront = nil
        products = []; allowedProductIDs = []; inFlightTransactions = []
        unresolvedByAccount = [:]; pendingApprovalAccounts = []; uncertainPurchaseAccounts = []
        needsReconciliation = false; reconcileUserInitiated = false
        hasUnresolvedPurchase = false; message = nil
        // Apple owns its unfinished transactions and purchase history. Never
        // finish an undelivered purchase merely because an account was deleted.
    }
    func startObserving() {
        startObservingStorefront()
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
        let expectedLocalDataGeneration = localDataGeneration
        guard !isCheckingPurchases, !isPurchasing else {
            needsReconciliation = true
            reconcileUserInitiated = reconcileUserInitiated || userInitiated
            return
        }
        isCheckingPurchases = true
        defer { isCheckingPurchases = false; scheduleReconciliationIfNeeded() }
        let context = await sessions.context()
        guard expectedLocalDataGeneration == localDataGeneration else { return }
        guard let accountID = context.session.flatMap({ UUID(uuidString: $0.user.id) }) else {
            hasUnresolvedPurchase = false; return
        }
        hasUnresolvedPurchase = hasUnresolved(for: accountID)
        if userInitiated { message = nil }
        var eligibleCount = 0
        for await result in provider.unfinished() {
            guard !Task.isCancelled, expectedLocalDataGeneration == localDataGeneration else { return }
            guard await sessions.sessionGeneration() == context.generation else { needsReconciliation = true; return }
            if case .verified(let record, _) = result,
               record.appAccountToken == accountID, record.environment == environment.storeKitEnvironment {
                eligibleCount += 1
            }
            await handle(result)
        }
        guard expectedLocalDataGeneration == localDataGeneration else { return }
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
        let expectedLocalDataGeneration = localDataGeneration
        // Do not replace StoreKit's cached Product while a payment is being
        // prepared or presented. Its owner will drain this reload on completion.
        guard !isPurchasing else { needsProductReload = true; return }
        guard !isLoading else { needsProductReload = true; return }
        isLoading = true; needsProductReload = false; message = nil
        clearProductOffers()
        defer { isLoading = false; scheduleProductReloadIfNeeded() }
        let context = await sessions.context()
        guard expectedLocalDataGeneration == localDataGeneration,
              await sessions.sessionGeneration() == context.generation else { return }
        guard context.session != nil else {
            message = AccountAPIError.unauthorized.localizedDescription
            return
        }
        startObservingStorefront()
        // A storefront change during either request gets one immediate fresh
        // load. Further update events remain queued for the serial reload slot.
        for attempt in 0..<2 {
            let revision = storefrontRevision
            let storefront = await provider.currentStorefront()
            guard expectedLocalDataGeneration == localDataGeneration, await sessions.sessionGeneration() == context.generation else { return }
            guard revision == storefrontRevision else {
                if attempt == 0 { needsProductReload = false; continue }
                return
            }
            observedStorefront = storefront; hasObservedStorefront = true
            guard let storefront, storefront == "CHN" || storefront == "USA" else {
                message = storefront == nil
                    ? L10n.text("暂时无法确认 App Store 地区，请重新加载购买选项。", "Your App Store region is unavailable. Please reload purchase options.")
                    : L10n.text("当前 App Store 地区暂不支持补充额度。", "Top-ups are not available in your App Store region.")
                return
            }
            do {
                let catalog: AccountProductCatalog = try await authorized(expectedGeneration: context.generation) { [api] token in
                    try await api.products(token: token)
                }
                let ids = Set(catalog.products.filter { $0.approvedPrice(for: storefront) != nil }.map(\.productID).filter { !$0.isEmpty })
                let loaded = ids.isEmpty ? [] : try await provider.products(for: ids)
                let finalStorefront = await provider.currentStorefront()
                guard expectedLocalDataGeneration == localDataGeneration, await sessions.sessionGeneration() == context.generation else { return }
                guard revision == storefrontRevision, finalStorefront == storefront else {
                    clearProductOffers()
                    if attempt == 0 { needsProductReload = false; continue }
                    message = storefrontChangedMessage
                    return
                }
                products = loaded.compactMap { product -> AccountPurchaseProduct? in
                    guard product.isConsumable,
                          let approved = catalog.products.first(where: { $0.productID == product.id }),
                          let price = approved.approvedPrice(for: storefront),
                          product.currency == price.currency, product.price * 1000 == price.priceMilliunits else { return nil }
                    var offer = product
                    offer.allowanceTokens = approved.credits.flatMap { $0 > 0 ? $0 : nil }
                    return offer
                }.sorted { $0.price < $1.price }
                allowedProductIDs = Set(products.map(\.id)); loadedStorefront = storefront
                needsProductReload = false
                if products.isEmpty {
                    message = L10n.text("当前 App Store 暂无可用的购买选项，请稍后重新加载。", "No purchase options are available for your App Store right now. Please reload later.")
                }
                return
            } catch {
                guard expectedLocalDataGeneration == localDataGeneration, await sessions.sessionGeneration() == context.generation else { return }
                clearProductOffers()
                if attempt == 0, revision != storefrontRevision || error is AccountPurchaseStorefrontError {
                    needsProductReload = false
                    continue
                }
                message = L10n.text("暂时无法获取购买选项，请稍后重试。", "Purchase options are unavailable. Please try again later.")
                return
            }
        }
    }
    func purchase(_ product: AccountPurchaseProduct) async {
        let expectedLocalDataGeneration = localDataGeneration
        let expectedStorefrontRevision = storefrontRevision
        let expectedStorefront = loadedStorefront
        guard !isPurchasing, !isCheckingPurchases, !isLoading, allowedProductIDs.contains(product.id),
              products.contains(product), product.isConsumable else { return }
        // Reserve before the first suspension, including the session lookup.
        isPurchasing = true
        defer { isPurchasing = false; scheduleReconciliationIfNeeded(); scheduleProductReloadIfNeeded() }
        let context = await sessions.context()
        guard expectedLocalDataGeneration == localDataGeneration else { return }
        guard let accountID = context.session.flatMap({ UUID(uuidString: $0.user.id) }) else {
            message = AccountAPIError.unauthorized.localizedDescription; return
        }
        hasUnresolvedPurchase = hasUnresolved(for: accountID)
        guard !hasUnresolvedPurchase else {
            message = L10n.text("有购买正在核对，请先点“核对购买”，无需再次付款。", "A purchase is awaiting verification. Use Check purchases before buying again.")
            return
        }
        let storefront = await provider.currentStorefront()
        guard expectedLocalDataGeneration == localDataGeneration, await sessions.sessionGeneration() == context.generation else { return }
        guard let expectedStorefront, storefront == expectedStorefront,
              expectedStorefrontRevision == storefrontRevision, loadedStorefront == expectedStorefront,
              allowedProductIDs.contains(product.id), products.contains(product) else {
            clearProductOffers(); message = storefrontChangedMessage
            needsProductReload = true
            return
        }
        message = nil
        do {
            let result = try await provider.purchase(productID: product.id, accountToken: accountID)
            guard expectedLocalDataGeneration == localDataGeneration else { return }
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
            if expectedLocalDataGeneration == localDataGeneration, await sessions.sessionGeneration() == context.generation {
                if error is AccountPurchaseStorefrontError {
                    clearProductOffers(); message = storefrontChangedMessage
                    needsProductReload = true
                    return
                }
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
        let expectedLocalDataGeneration = localDataGeneration
        // StoreKit's unfinished sequence may include purchases from the other build; never deliver or finish those here.
        guard record.environment == environment.storeKitEnvironment else { return }
        guard !inFlightTransactions.contains(record.transactionID) else { return }
        let context = await sessions.context()
        guard expectedLocalDataGeneration == localDataGeneration else { return }
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
            guard expectedLocalDataGeneration == localDataGeneration, await sessions.sessionGeneration() == context.generation else { return }
            await finish()
            // The original owner's finished record must be cleared even if
            // sign-out or account switching happened during StoreKit.finish().
            unresolvedByAccount[userID]?.remove(record.transactionID)
            guard expectedLocalDataGeneration == localDataGeneration, await sessions.sessionGeneration() == context.generation else { return }
            hasUnresolvedPurchase = hasUnresolved(for: userID)
            message = confirmation.status == "credited"
                ? L10n.text("额度已补充。", "Your allowance has been replenished.")
                : L10n.text("此购买已退款，未补充额度。", "This purchase was refunded; no allowance was added.")
            NotificationCenter.default.post(name: .accountBalanceChanged, object: nil)
        } catch {
            guard expectedLocalDataGeneration == localDataGeneration, await sessions.sessionGeneration() == context.generation else { return }
            // Never finish an unconfirmed purchase. StoreKit keeps it in unfinished for a later retry.
            message = L10n.text("购买暂未完成核实，请稍后点“核对购买”，或联系我们。请勿重复购买。", "Your purchase is awaiting verification. Use Check purchases later or contact us. Please do not buy again.")
        }
    }
    private func hasUnresolved(for accountID: UUID) -> Bool {
        pendingApprovalAccounts.contains(accountID) || uncertainPurchaseAccounts.contains(accountID)
            || !(unresolvedByAccount[accountID] ?? []).isEmpty
    }
    private var storefrontChangedMessage: String {
        L10n.text("App Store 地区已变化，请核对重新加载后的购买选项。", "Your App Store region changed. Review the reloaded purchase options.")
    }
    private func clearProductOffers() {
        products = []; allowedProductIDs = []; loadedStorefront = nil
    }
    private func startObservingStorefront() {
        guard storefrontObserver == nil else { return }
        let events = provider.storefrontUpdates()
        storefrontObserver = Task { [weak self] in
            for await storefront in events {
                guard !Task.isCancelled, let self else { return }
                guard !self.hasObservedStorefront || self.observedStorefront != storefront else { continue }
                self.hasObservedStorefront = true; self.observedStorefront = storefront
                self.storefrontRevision &+= 1
                self.clearProductOffers()
                self.message = self.storefrontChangedMessage
                self.needsProductReload = true
                self.scheduleProductReloadIfNeeded()
            }
        }
    }
    private func scheduleProductReloadIfNeeded() {
        guard needsProductReload, !isLoading, !isPurchasing, productReloadTask == nil else { return }
        needsProductReload = false
        productReloadTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.productReloadTask = nil
            await self.loadProducts()
        }
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
