import XCTest
@testable import BlindOracle

@MainActor final class PurchaseRecoveryTests: XCTestCase {
    private let productID = "com.lihao.BlindOracle.quota.1m"
    private let buyer = UUID()
    private let metrics = RecoveryMetrics()
    private var provider: RecoveryPurchaseProvider!
    private var api: AccountAPI!
    private var manager: AccountSessionManager!

    override func setUp() async throws {
        provider = RecoveryPurchaseProvider()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryURLProtocol.self]
        api = AccountAPI(configuration: configuration)
        let session = try makeSession(buyer)
        manager = AccountSessionManager(api: api, vault: RecoveryVault(session))
        let productID = productID
        RecoveryURLProtocol.handler = { request in
            if request.url!.absoluteString.hasSuffix("/products/") {
                return "{\"products\":[{\"product_id\":\"\(productID)\",\"name\":\"补充额度\",\"currency\":\"CNY\",\"price_milliunits\":6000}]}"
            }
            throw URLError(.badServerResponse)
        }
        provider.offers = [offer()]
    }

    override func tearDown() async throws { RecoveryURLProtocol.handler = nil }

    private func makeSession(_ id: UUID) throws -> AccountSession {
        try AccountSession(response: AccountTokenResponse(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresIn: 3600,
            user: AccountUser(id: id.uuidString, displayName: "购买恢复测试", email: nil, createdAt: "2026-11-06")), appleUserID: nil)
    }

    private func offer(currency: String = "CNY", price: Decimal = 6, consumable: Bool = true) -> AccountPurchaseProduct {
        let amount = String(format: "%.2f", NSDecimalNumber(decimal: price).doubleValue)
        return .init(id: productID, displayPrice: (currency == "USD" ? "$" : "¥") + amount,
                     price: price, currency: currency, isConsumable: consumable)
    }

    private func useRegionalCatalog(prices: String? = nil) {
        let productID = productID
        let regionalPrices = prices ?? #"[{"storefront":"CHN","currency":"CNY","price_milliunits":6000},{"storefront":"USA","currency":"USD","price_milliunits":990}]"#
        RecoveryURLProtocol.handler = { _ in
            "{\"products\":[{\"product_id\":\"\(productID)\",\"name\":\"补充额度\",\"credits\":1000000,\"currency\":\"CNY\",\"price_milliunits\":6000,\"prices\":\(regionalPrices)}]}"
        }
    }

    private func event(id: String = "recovery-transaction", owner: UUID? = nil, environment: String? = nil) -> AccountPurchaseEvent {
        let metrics = metrics
        return .verified(.init(transactionID: id, appAccountToken: owner ?? buyer,
            environment: environment ?? ServiceEnvironment.current.storeKitEnvironment), { metrics.finished() })
    }

    private func store() -> AccountPurchaseStore { AccountPurchaseStore(api: api, sessions: manager, provider: provider) }
    private func confirmation(_ id: String = "recovery-transaction", status: String = "credited") -> String {
        "{\"transaction_id\":\"\(id)\",\"status\":\"\(status)\",\"wallet\":{\"quota\":{\"remaining_percent\":100,\"is_unlimited\":false,\"can_start\":true}}}"
    }

    func testDisplayedTokenAmountComesFromApprovedCatalogAndDoesNotInventLegacyAmounts() async throws {
        let productID = productID
        for amount in ["1000000", "0", "-1", "null"] {
            RecoveryURLProtocol.handler = { _ in
                "{\"products\":[{\"product_id\":\"\(productID)\",\"name\":\"补充额度\",\"credits\":\(amount),\"currency\":\"CNY\",\"price_milliunits\":6000}]}"
            }
            let purchases = store()
            await purchases.loadProducts()
            let product = try XCTUnwrap(purchases.products.first)
            XCTAssertEqual(product.allowanceTokens, amount == "1000000" ? 1_000_000 : nil)
            XCTAssertEqual(product.displayPrice, "¥6.00", "The price still comes from StoreKit.")
        }
        RecoveryURLProtocol.handler = { _ in
            "{\"products\":[{\"product_id\":\"\(productID)\",\"name\":\"补充额度\",\"currency\":\"CNY\",\"price_milliunits\":6000}]}"
        }
        let legacy = store()
        await legacy.loadProducts()
        XCTAssertNil(try XCTUnwrap(legacy.products.first).allowanceTokens)
        XCTAssertEqual(provider.purchaseCount, 0, "Reviewing a package must not open payment.")
    }

    func testCancelDoesNotVerifyOrFinishAndAllowsAnotherAttempt() async throws {
        let store = store(); await store.loadProducts()
        provider.result = .cancelled
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(provider.purchaseCount, 1)
        XCTAssertEqual(metrics.finishCount, 0)
        XCTAssertFalse(store.isPurchasing); XCTAssertFalse(store.hasUnresolvedPurchase)
        XCTAssertNil(store.message)
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(provider.purchaseCount, 2)
    }

    func testPendingDoesNotCreditUntilVerifiedStoreKitUpdate() async throws {
        let store = store(); await store.loadProducts()
        provider.result = .pending
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(metrics.finishCount, 0)
        XCTAssertTrue(store.message?.contains("等待") == true)
        XCTAssertTrue(store.hasUnresolvedPurchase)
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(provider.purchaseCount, 1, "A pending approval must not create a second payment request")
        let reply = confirmation(); let metrics = metrics
        RecoveryURLProtocol.handler = { _ in metrics.verified(); return reply }
        store.startObserving()
        await Task.yield()
        provider.emit(event())
        await waitFor { metrics.finishCount == 1 }
        XCTAssertEqual(metrics.verifyCount, 1)
        XCTAssertFalse(store.hasUnresolvedPurchase)
    }

    func testLostResponseAfterServerCommitBlocksRepurchaseAndRelaunchResumesUnfinished() async throws {
        var store: AccountPurchaseStore? = store(); await store!.loadProducts()
        let selected = try XCTUnwrap(store!.products.first)
        provider.result = .success(event())
        let metrics = metrics; let reply = confirmation()
        RecoveryURLProtocol.handler = { _ in
            metrics.verified()
            // The server has already processed the transaction; the response is lost in transit.
            if metrics.verifyCount == 1 { throw URLError(.networkConnectionLost) }
            return reply
        }
        await store!.purchase(selected)
        XCTAssertEqual(metrics.finishCount, 0)
        XCTAssertTrue(store!.hasUnresolvedPurchase)
        await store!.purchase(selected)
        XCTAssertEqual(provider.purchaseCount, 1, "An unresolved payment must not invite a second payment")
        store = nil
        provider.pending = [event()]
        let relaunched = self.store()
        await relaunched.resumeUnfinished(userInitiated: true)
        XCTAssertEqual(metrics.verifyCount, 2)
        XCTAssertEqual(metrics.finishCount, 1)
        XCTAssertFalse(relaunched.hasUnresolvedPurchase)
        XCTAssertTrue(relaunched.message?.contains("已补充") == true)
    }

    func testVerificationFailsThenManualCheckRetriesSamePurchaseWithoutNewPayment() async throws {
        let store = store(); await store.loadProducts()
        provider.result = .success(event())
        RecoveryURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertTrue(store.hasUnresolvedPurchase); XCTAssertEqual(metrics.finishCount, 0)
        provider.pending = [event()]
        let reply = confirmation()
        RecoveryURLProtocol.handler = { _ in reply }
        await store.resumeUnfinished(userInitiated: true)
        XCTAssertEqual(metrics.finishCount, 1)
        XCTAssertFalse(store.hasUnresolvedPurchase)
        XCTAssertEqual(provider.purchaseCount, 1)
    }

    func testConcurrentPurchaseTapsEnterStoreKitOnlyOnce() async throws {
        let store = store(); await store.loadProducts()
        let selected = try XCTUnwrap(store.products.first)
        let gate = RecoveryPurchaseGate()
        provider.beforePurchaseReturns = { await gate.wait() }
        let first = Task { await store.purchase(selected) }
        let second = Task { await store.purchase(selected) }
        await waitFor { self.provider.purchaseCount >= 1 }
        for _ in 0..<5 { await Task.yield() }
        let calls = provider.purchaseCount
        await gate.open()
        await first.value; await second.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(provider.purchaseCount, 1)
    }

    func testAccountSwitchDuringFinishDoesNotLeaveOriginalAccountBlocked() async throws {
        let store = store(); await store.loadProducts()
        let original = try makeSession(buyer)
        let other = try makeSession(UUID())
        let manager = manager!; let metrics = metrics
        let record = VerifiedAccountPurchase(transactionID: "recovery-transaction", appAccountToken: buyer,
                                             environment: ServiceEnvironment.current.storeKitEnvironment)
        let reply = confirmation()
        RecoveryURLProtocol.handler = { _ in reply }
        await store.deliver(record) {
            metrics.finished()
            try? await manager.install(other)
        }
        XCTAssertEqual(metrics.finishCount, 1)
        try await manager.install(original)
        provider.pending = []
        await store.resumeUnfinished(userInitiated: true)
        XCTAssertFalse(store.hasUnresolvedPurchase)
        provider.result = .cancelled
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(provider.purchaseCount, 1)
    }

    func testUnfinishedPurchasesForOtherAccountsOrEnvironmentsRemainUnfinished() async throws {
        provider.pending = [event(owner: UUID()), event(environment: "LocalTesting"),
                            event(environment: ServiceEnvironment.current.isSandbox ? "Production" : "Sandbox")]
        let store = store()
        await store.resumeUnfinished(userInitiated: true)
        XCTAssertEqual(metrics.finishCount, 0)
        XCTAssertFalse(store.hasUnresolvedPurchase)
        XCTAssertTrue(store.message?.contains("未发现") == true)
    }

    func testUnverifiedStoreKitPurchaseNeverReachesVerificationOrFinishes() async throws {
        let store = store(); await store.loadProducts()
        provider.result = .success(.unverified)
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(metrics.finishCount, 0)
        XCTAssertTrue(store.message?.contains("未通过") == true)
        XCTAssertTrue(store.hasUnresolvedPurchase)
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(provider.purchaseCount, 1)
    }

    func testUnexpectedPurchaseEnvironmentDoesNotEncourageASecondPayment() async throws {
        let store = store(); await store.loadProducts()
        provider.result = .success(event(environment: "LocalTesting"))
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(metrics.finishCount, 0)
        XCTAssertTrue(store.hasUnresolvedPurchase)
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(provider.purchaseCount, 1)
        await store.resumeUnfinished(userInitiated: true)
        XCTAssertTrue(store.hasUnresolvedPurchase)
        XCTAssertTrue(store.message?.contains("待核实") == true)
    }

    func testAccountSwitchDuringScanQueuesReconciliationForTheLatestAccount() async throws {
        let store = store()
        let held = AsyncStream<AccountPurchaseEvent>.makeStream()
        let otherID = UUID()
        let oldEvent = event()
        let otherEvent = event(id: "other-account-transaction", owner: otherID)
        provider.unfinishedOverride = { [provider] in
            if provider!.scanCount == 1 { return held.stream }
            return AsyncStream { continuation in continuation.yield(otherEvent); continuation.finish() }
        }
        let first = Task { await store.resumeUnfinished() }
        await waitFor { self.provider.scanCount == 1 }
        try await manager.install(makeSession(otherID))
        let metrics = metrics; let reply = confirmation("other-account-transaction")
        RecoveryURLProtocol.handler = { _ in metrics.verified(); return reply }
        await store.resumeUnfinished()
        held.continuation.yield(oldEvent); held.continuation.finish()
        await first.value
        await waitFor { metrics.finishCount == 1 }
        XCTAssertEqual(provider.scanCount, 2)
        XCTAssertEqual(metrics.verifyCount, 1, "Only the latest account's transaction may be submitted")
        XCTAssertFalse(store.hasUnresolvedPurchase)
    }

    func testWrongTransactionOrPendingServerResponseCannotFinish() async throws {
        for response in [confirmation("a-different-transaction"), confirmation(status: "pending")] {
            let productID = productID
            RecoveryURLProtocol.handler = { request in
                if request.url!.absoluteString.hasSuffix("/products/") {
                    return "{\"products\":[{\"product_id\":\"\(productID)\",\"name\":\"补充额度\",\"currency\":\"CNY\",\"price_milliunits\":6000}]}"
                }
                return response
            }
            let store = store(); await store.loadProducts()
            provider.result = .success(event())
            await store.purchase(try XCTUnwrap(store.products.first))
            XCTAssertTrue(store.hasUnresolvedPurchase)
            XCTAssertEqual(metrics.finishCount, 0)
        }
    }

    func testRefundedConfirmationFinishesWithoutClaimingNewAllowance() async throws {
        let store = store(); await store.loadProducts()
        provider.result = .success(event())
        let reply = confirmation(status: "refunded")
        RecoveryURLProtocol.handler = { _ in reply }
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(metrics.finishCount, 1)
        XCTAssertFalse(store.hasUnresolvedPurchase)
        XCTAssertTrue(store.message?.contains("已退款") == true)
        XCTAssertFalse(store.message?.contains("已补充") == true)
    }

    func testWrongCurrencyPriceAndNonConsumableAreNotOfferedOrPurchasable() async throws {
        for product in [offer(currency: "USD"), offer(price: 7), offer(consumable: false)] {
            provider.offers = [product]
            let store = store(); await store.loadProducts()
            XCTAssertTrue(store.products.isEmpty)
            await store.purchase(product)
            XCTAssertEqual(provider.purchaseCount, 0)
        }
    }

    func testChineseAndUSStorefrontsSelectTheirApprovedLocalPrices() async throws {
        useRegionalCatalog()
        for (region, currency, price) in [("CHN", "CNY", Decimal(6)), ("USA", "USD", Decimal(99) / 100)] {
            provider.storefront = region
            provider.offers = [offer(currency: currency, price: price)]
            let purchases = store()
            await purchases.loadProducts()
            let selected = try XCTUnwrap(purchases.products.first, purchases.message ?? "Missing regional offer")
            XCTAssertEqual(selected.currency, currency)
            XCTAssertEqual(selected.price, price)
            XCTAssertEqual(selected.allowanceTokens, 1_000_000)
            XCTAssertEqual(selected.displayPrice, currency == "USD" ? "$0.99" : "¥6.00")
            await purchases.purchase(selected)
        }
        XCTAssertEqual(provider.purchaseCount, 2)
    }

    func testUSQuoteDoesNotDependOnCatalogPriceOrderingOrInterfaceLanguage() async throws {
        provider.storefront = "USA"
        provider.offers = [offer(currency: "USD", price: Decimal(99) / 100)]
        useRegionalCatalog(prices: #"[{"storefront":"USA","currency":"USD","price_milliunits":990},{"storefront":"CHN","currency":"CNY","price_milliunits":6000}]"#)
        for language in [AppLanguage.simplifiedChinese, .english] {
            await AppLanguage.$override.withValue(language) {
                let purchases = store()
                await purchases.loadProducts()
                XCTAssertEqual(purchases.products.first?.currency, "USD")
                XCTAssertEqual(purchases.products.first?.displayPrice, "$0.99")
            }
        }
    }

    func testRegionCurrencyAndAmountMustAllMatchApprovedPrice() async throws {
        useRegionalCatalog()
        for (region, currency, price) in [("CHN", "USD", Decimal(99) / 100), ("USA", "CNY", Decimal(6)),
                                          ("USA", "USD", Decimal(199) / 100)] {
            provider.storefront = region
            let candidate = offer(currency: currency, price: price)
            provider.offers = [candidate]
            let purchases = store()
            await purchases.loadProducts()
            XCTAssertTrue(purchases.products.isEmpty)
            await purchases.purchase(candidate)
            XCTAssertFalse(purchases.message?.contains("中国大陆测试账号") == true)
        }
        XCTAssertEqual(provider.purchaseCount, 0)
    }

    func testApprovedPriceChangeUsesServerQuoteRatherThanHardcodedAmount() async throws {
        provider.storefront = "USA"
        provider.offers = [offer(currency: "USD", price: Decimal(199) / 100)]
        useRegionalCatalog(prices: #"[{"storefront":"USA","currency":"USD","price_milliunits":1990}]"#)
        let purchases = store()
        await purchases.loadProducts()
        XCTAssertEqual(purchases.products.first?.price, Decimal(199) / 100)
    }

    func testAmbiguousOrInvalidRegionalQuotesCannotAuthorizePayment() async throws {
        provider.storefront = "USA"
        let candidate = offer(currency: "USD", price: Decimal(99) / 100)
        provider.offers = [candidate]
        for prices in [#"[{"storefront":"USA","currency":"USD","price_milliunits":990},{"storefront":"USA","currency":"USD","price_milliunits":990}]"#,
                       #"[{"storefront":"USA","currency":"USD","price_milliunits":0}]"#,
                       #"[{"storefront":"USA","currency":"USD","price_milliunits":-990}]"#,
                       #"[{"storefront":"USA","currency":"CNY","price_milliunits":990}]"#,
                       "null"] {
            useRegionalCatalog(prices: prices)
            let purchases = store()
            await purchases.loadProducts()
            XCTAssertTrue(purchases.products.isEmpty)
            await purchases.purchase(candidate)
        }
        XCTAssertEqual(provider.purchaseCount, 0)
    }

    func testUnsupportedAndUnknownStorefrontsCannotUseDollarCurrencyAsFallback() async throws {
        useRegionalCatalog()
        provider.offers = [offer(currency: "USD", price: Decimal(99) / 100)]
        for region: String? in ["CAN", "GBR", "HKG", "", nil] {
            provider.storefront = region
            let purchases = store()
            await purchases.loadProducts()
            XCTAssertTrue(purchases.products.isEmpty)
            await purchases.purchase(provider.offers[0])
        }
        XCTAssertEqual(provider.purchaseCount, 0)
    }

    func testLegacyCatalogCannotAuthorizeDollarPurchases() async throws {
        provider.storefront = "USA"
        provider.offers = [offer(currency: "USD", price: Decimal(99) / 100)]
        let purchases = store()
        await purchases.loadProducts()
        XCTAssertTrue(purchases.products.isEmpty)
        await purchases.purchase(provider.offers[0])
        XCTAssertEqual(provider.purchaseCount, 0)
    }

    func testSignedOutCatalogLoadDoesNotQueryAppleOrOpenAuthentication() async throws {
        try await manager.clear()
        let purchases = store()
        await purchases.loadProducts()
        XCTAssertTrue(purchases.products.isEmpty)
        XCTAssertEqual(provider.storefrontReadCount, 0)
        XCTAssertEqual(provider.storefrontObservationCount, 0)
        XCTAssertEqual(provider.productLookupCount, 0)
        XCTAssertEqual(provider.purchaseCount, 0)
    }

    func testExplicitEmptyRegionalPricesDoNotFallBackToLegacyChinesePrice() async throws {
        useRegionalCatalog(prices: "[]")
        let purchases = store()
        await purchases.loadProducts()
        XCTAssertTrue(purchases.products.isEmpty, "An explicitly empty policy must not regain legacy permission")
    }

    func testStorefrontChangedBeforePurchaseReloadsWithoutOpeningOldPayment() async throws {
        useRegionalCatalog()
        let purchases = store()
        await purchases.loadProducts()
        let chinese = try XCTUnwrap(purchases.products.first)
        provider.storefront = "USA"
        provider.offers = [offer(currency: "USD", price: Decimal(99) / 100)]
        await purchases.purchase(chinese)
        XCTAssertEqual(provider.purchaseCount, 0)
        await waitFor { !purchases.isLoading && purchases.products.first?.currency == "USD" }
        XCTAssertEqual(purchases.products.first?.currency, "USD")
    }

    func testSameSKUWithOldDisplayedPriceCannotStartANewPricedPurchase() async throws {
        useRegionalCatalog()
        provider.storefront = "USA"
        provider.offers = [offer(currency: "USD", price: Decimal(99) / 100)]
        let purchases = store()
        await purchases.loadProducts()
        let oldOffer = try XCTUnwrap(purchases.products.first)
        useRegionalCatalog(prices: #"[{"storefront":"USA","currency":"USD","price_milliunits":1990}]"#)
        provider.offers = [offer(currency: "USD", price: Decimal(199) / 100)]
        await purchases.loadProducts()
        XCTAssertEqual(purchases.products.first?.price, Decimal(199) / 100)
        await purchases.purchase(oldOffer)
        XCTAssertEqual(provider.purchaseCount, 0)
    }

    func testProductReloadWaitsUntilNativePurchaseFinishes() async throws {
        useRegionalCatalog()
        let purchases = store()
        await purchases.loadProducts()
        let selected = try XCTUnwrap(purchases.products.first)
        let gate = RecoveryPurchaseGate()
        provider.beforePurchaseReturns = { await gate.wait() }
        let payment = Task { await purchases.purchase(selected) }
        await waitFor { self.provider.purchaseCount == 1 }
        await purchases.loadProducts()
        XCTAssertEqual(provider.productLookupCount, 1, "Do not replace StoreKit's cached product during an open payment")
        await gate.open()
        await payment.value
        await waitFor { !purchases.isLoading && self.provider.productLookupCount == 2 }
        XCTAssertEqual(provider.productLookupCount, 2)
        XCTAssertEqual(provider.purchaseCount, 1)
    }

    func testStorefrontChangedDuringProductLookupCannotPublishStaleOffer() async throws {
        useRegionalCatalog()
        provider.beforeProductsReturn = { [provider] in
            provider?.beforeProductsReturn = nil
            provider?.storefront = "USA"
            provider?.offers = [self.offer(currency: "USD", price: Decimal(99) / 100)]
        }
        let purchases = store()
        await purchases.loadProducts()
        await waitFor { !purchases.isLoading && purchases.products.first?.currency == "USD" }
        XCTAssertEqual(purchases.products.first?.currency, "USD")
        XCTAssertEqual(provider.purchaseCount, 0)
    }

    func testStorefrontUpdatesClearAndReloadOffers() async throws {
        useRegionalCatalog()
        let purchases = store()
        purchases.startObserving()
        await purchases.loadProducts()
        provider.offers = [offer(currency: "USD", price: Decimal(99) / 100)]
        provider.emitStorefront("USA")
        await waitFor { !purchases.isLoading && purchases.products.first?.currency == "USD" }
        XCTAssertEqual(purchases.products.first?.currency, "USD")
        provider.emitStorefront("GBR")
        await waitFor { !purchases.isLoading && purchases.products.isEmpty }
        XCTAssertTrue(purchases.products.isEmpty)
        XCTAssertEqual(provider.purchaseCount, 0)
    }

    func testSwitchingStorefrontDoesNotPreventDeliveryOfOriginalPurchase() async throws {
        provider.storefront = "USA"
        provider.pending = [event()]
        let reply = confirmation()
        RecoveryURLProtocol.handler = { _ in reply }
        let purchases = store()
        await purchases.resumeUnfinished(userInitiated: true)
        XCTAssertEqual(metrics.finishCount, 1)
        XCTAssertFalse(purchases.hasUnresolvedPurchase)
    }

    func testAccountSwitchWhileNativePurchaseIsPendingLeavesOriginalTransactionForOriginalAccount() async throws {
        let store = store(); await store.loadProducts()
        provider.result = .success(event())
        let manager = manager!; let other = try makeSession(UUID())
        provider.beforePurchaseReturns = { try await manager.install(other) }
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(metrics.finishCount, 0)
        XCTAssertFalse(store.hasUnresolvedPurchase)
        XCTAssertNil(store.message)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected purchase recovery did not complete")
    }
}

@MainActor private final class RecoveryPurchaseProvider: AccountPurchaseProviding {
    var storefront: String? = "CHN"
    var offers: [AccountPurchaseProduct] = []
    var result: AccountPurchaseResult = .cancelled
    var pending: [AccountPurchaseEvent] = []
    var purchaseCount = 0
    var productLookupCount = 0
    var storefrontReadCount = 0
    var storefrontObservationCount = 0
    var scanCount = 0
    var unfinishedOverride: (() -> AsyncStream<AccountPurchaseEvent>)?
    var beforePurchaseReturns: (() async throws -> Void)?
    var beforeProductsReturn: (() async -> Void)?
    private var continuation: AsyncStream<AccountPurchaseEvent>.Continuation?
    private var storefrontContinuation: AsyncStream<String?>.Continuation?
    func currentStorefront() async -> String? { storefrontReadCount += 1; return storefront }
    func storefrontUpdates() -> AsyncStream<String?> {
        storefrontObservationCount += 1
        return AsyncStream { storefrontContinuation = $0 }
    }
    func emitStorefront(_ region: String?) { storefront = region; storefrontContinuation?.yield(region) }
    func products(for ids: Set<String>) async throws -> [AccountPurchaseProduct] {
        productLookupCount += 1
        let snapshot = offers.filter { ids.contains($0.id) }
        await beforeProductsReturn?()
        return snapshot
    }
    func purchase(productID: String, accountToken: UUID) async throws -> AccountPurchaseResult {
        purchaseCount += 1
        try await beforePurchaseReturns?()
        return result
    }
    func unfinished() -> AsyncStream<AccountPurchaseEvent> {
        scanCount += 1
        if let unfinishedOverride { return unfinishedOverride() }
        let events = pending
        return AsyncStream { continuation in events.forEach { continuation.yield($0) }; continuation.finish() }
    }
    func updates() -> AsyncStream<AccountPurchaseEvent> { AsyncStream { continuation = $0 } }
    func emit(_ event: AccountPurchaseEvent) { continuation?.yield(event) }
}

private final class RecoveryVault: AccountSessionStorage {
    private var value: AccountSession?
    init(_ value: AccountSession?) { self.value = value }
    func load() throws -> AccountSession? { value }
    func save(_ value: AccountSession) throws { self.value = value }
    func delete() throws { value = nil }
}

private final class RecoveryMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var finishes = 0
    private var verifications = 0
    var finishCount: Int { lock.lock(); defer { lock.unlock() }; return finishes }
    var verifyCount: Int { lock.lock(); defer { lock.unlock() }; return verifications }
    func finished() { lock.lock(); defer { lock.unlock() }; finishes += 1 }
    func verified() { lock.lock(); defer { lock.unlock() }; verifications += 1 }
}

private actor RecoveryPurchaseGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiting; waiting.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class RecoveryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
