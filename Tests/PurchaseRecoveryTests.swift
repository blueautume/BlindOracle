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
        .init(id: productID, displayPrice: "¥6.00", price: price, currency: currency, isConsumable: consumable)
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
    var offers: [AccountPurchaseProduct] = []
    var result: AccountPurchaseResult = .cancelled
    var pending: [AccountPurchaseEvent] = []
    var purchaseCount = 0
    var scanCount = 0
    var unfinishedOverride: (() -> AsyncStream<AccountPurchaseEvent>)?
    var beforePurchaseReturns: (() async throws -> Void)?
    private var continuation: AsyncStream<AccountPurchaseEvent>.Continuation?
    func products(for ids: Set<String>) async throws -> [AccountPurchaseProduct] { offers.filter { ids.contains($0.id) } }
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
