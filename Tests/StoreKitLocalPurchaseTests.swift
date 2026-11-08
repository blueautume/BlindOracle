import XCTest
import StoreKit
import StoreKitTest
@testable import BlindOracle

/// These tests exercise Apple's local StoreKit service, not an API stub for
/// Product.purchase. They never contact the account server or charge money.
/// SKTestSession has one global environment: run this class without parallel
/// test execution, and keep its .storekit resource in the test bundle only.
final class StoreKitLocalPurchaseTests: XCTestCase {
    private let productID = "com.lihao.BlindOracle.quota.1m"
    private let configurationGuardID = "com.lihao.BlindOracle.localtest.configuration.guard"
    @MainActor private var updatesObserver: Task<Void, Never>?

    @MainActor private func makeSession(_ market: LocalStoreKitMarket = .china) async throws -> SKTestSession {
        print("[Local StoreKit] Initializing the local test session.")
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: market.configurationName, withExtension: "storekit", subdirectory: "Fixtures")
                ?? bundle.url(forResource: market.configurationName, withExtension: "storekit"),
            "\(market.configurationName).storekit must be copied into the test bundle, not the shipping app."
        )
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = market.storefront
        session.locale = Locale(identifier: market.locale)
        LocalStoreKitRejectingURLProtocol.reset()
        // SKTestSession can log a configuration error without throwing, and
        // StoreKit may then use the real App Store. An actual SKU and price do
        // not prove isolation, so require a local-only product before ANY buy.
        // This marker is never bought or included in the app's server catalog.
        print("[Local StoreKit] Looking up the local-only configuration marker.")
        let markers = try await Product.products(for: [configurationGuardID])
        guard markers.contains(where: {
            $0.id == configurationGuardID && $0.displayName == "Local configuration guard"
                && $0.price == Decimal(1) / Decimal(100) && $0.priceFormatStyle.currencyCode == market.currency
        }) else {
            XCTFail("The local StoreKit configuration is not active. Use the dedicated StoreKit scheme and a supported simulator; never continue with a real App Store purchase.")
            throw LocalStoreKitFailure.configurationNotActive
        }
        print("[Local StoreKit] Local-only configuration marker verified.")
        updatesObserver?.cancel()
        updatesObserver = Task {
            for await _ in Transaction.updates {
                guard !Task.isCancelled else { return }
                // Observe only. Each test or AccountPurchaseStore owns finish.
            }
        }
        await Task.yield()
        return session
    }

    @MainActor private func clean(_ session: SKTestSession) {
        updatesObserver?.cancel()
        updatesObserver = nil
        session.clearTransactions()
        session.resetToDefaultState()
    }

    @MainActor private func provider() async throws -> StoreKitPurchaseProvider {
        let provider = StoreKitPurchaseProvider()
        let products = try await provider.products(for: [productID])
        XCTAssertEqual(products.map(\.id), [productID])
        return provider
    }

    private func savedSession(_ accountID: UUID) throws -> AccountSession {
        try AccountSession(response: AccountTokenResponse(
            accessToken: "local-storekit-test-access", refreshToken: "local-storekit-test-refresh", expiresIn: 3600,
            user: AccountUser(id: accountID.uuidString, displayName: "本地测试", email: nil,
                              createdAt: "2026-11-06T00:00:00Z")
        ), appleUserID: nil)
    }

    @MainActor private func nativeUnfinishedTransactions() async -> [Transaction] {
        var transactions: [Transaction] = []
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result { transactions.append(transaction) }
        }
        return transactions
    }

    @MainActor private func waitForUnfinishedTransaction(productID: String) async throws -> Transaction {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let transaction = await nativeUnfinishedTransactions().first(where: { $0.productID == productID }) {
                return transaction
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        throw LocalStoreKitFailure.missingTransaction
    }

    @MainActor func testNativeProductsUseConfiguredConsumableAndLocalizedSixCNYPrice() async throws {
        let session = try await makeSession()
        defer { clean(session) }
        let provider = try await provider()
        let products = try await provider.products(for: [productID])
        let product = try XCTUnwrap(products.first)
        XCTAssertEqual(product.id, productID)
        XCTAssertEqual(product.price, Decimal(6))
        XCTAssertEqual(product.currency, "CNY")
        XCTAssertTrue(product.isConsumable)
        XCTAssertFalse(product.displayPrice.isEmpty)
        let storefront = await provider.currentStorefront()
        XCTAssertEqual(storefront, "CHN")
    }

    @MainActor func testNativeProductsUseUSAStorefrontAndLocalizedNinetyNineCentUSDPrice() async throws {
        let session = try await makeSession(.unitedStates)
        defer { clean(session) }
        let provider = try await provider()
        let storefront = await provider.currentStorefront()
        XCTAssertEqual(storefront, "USA", "Use StoreKit's current storefront, independently of the interface language.")
        let products = try await provider.products(for: [productID])
        let product = try XCTUnwrap(products.first)
        XCTAssertEqual(product.id, productID)
        XCTAssertEqual(product.price, Decimal(99) / Decimal(100))
        XCTAssertEqual(product.currency, "USD")
        XCTAssertTrue(product.isConsumable)
        XCTAssertFalse(product.displayPrice.isEmpty)
    }

    @MainActor func testNativeXcodePurchaseCannotEnterEitherRealServiceAndRemainsUnfinished() async throws {
        let session = try await makeSession()
        defer { clean(session) }
        try await assertNativePurchaseRemainsLocal()
    }

    @MainActor func testNativeUSDXcodePurchaseCannotEnterEitherRealServiceAndRemainsUnfinished() async throws {
        let session = try await makeSession(.unitedStates)
        defer { clean(session) }
        try await assertNativePurchaseRemainsLocal()
    }

    @MainActor private func assertNativePurchaseRemainsLocal() async throws {
        let provider = try await provider()
        let accountID = UUID()
        let result = try await provider.purchase(productID: productID, accountToken: accountID)
        guard case .success(.verified(let purchase, let finish)) = result else {
            XCTFail("A local native purchase must yield a verified StoreKit event.")
            return
        }
        XCTAssertEqual(purchase.environment, "LocalTesting")
        XCTAssertEqual(purchase.appAccountToken, accountID)
        let counter = LocalStoreKitFinishCounter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalStoreKitRejectingURLProtocol.self]
        for environment in [ServiceEnvironment.production, .sandbox] {
            let api = AccountAPI(configuration: configuration)
            let sessions = AccountSessionManager(api: api, vault: LocalStoreKitSessionVault(try savedSession(accountID)))
            let store = AccountPurchaseStore(api: api, sessions: sessions, environment: environment)
            await store.deliver(purchase) {
                await counter.increment()
                await finish()
            }
            XCTAssertFalse(store.message?.contains("已补充") == true)
        }
        let finishCalls = await counter.count
        XCTAssertEqual(finishCalls, 0, "Rejecting a local transaction must not silently finish it.")
        XCTAssertEqual(LocalStoreKitRejectingURLProtocol.requestCount, 0,
                       "Xcode-signed transactions must never reach either account backend.")
        let unfinished = await nativeUnfinishedTransactions()
        XCTAssertTrue(unfinished.contains { String($0.id) == purchase.transactionID })
        XCTAssertTrue(unfinished.filter { $0.productID == productID }.allSatisfy { $0.environment == .xcode })
    }

    @MainActor func testNativeCancellationCreatesNoUnfinishedPurchase() async throws {
        let session = try await makeSession()
        defer { clean(session) }
        let provider = try await provider()
        try await session.setSimulatedError(SKTestFailures.Purchase.generic(.userCancelled), forAPI: .purchase)
        let result = try await provider.purchase(productID: productID, accountToken: UUID())
        guard case .cancelled = result else {
            XCTFail("A simulated user cancellation must return cancellation, including when StoreKit throws it.")
            return
        }
        try await session.setSimulatedError(nil, forAPI: .purchase)
        let unfinished = await nativeUnfinishedTransactions()
        XCTAssertFalse(unfinished.contains { $0.productID == productID })
        XCTAssertEqual(LocalStoreKitRejectingURLProtocol.requestCount, 0)
    }

    @MainActor func testNativeAskToBuyWaitsForApprovalBeforeBecomingUnfinished() async throws {
        let session = try await makeSession()
        defer { clean(session) }
        session.askToBuyEnabled = true
        let provider = try await provider()
        let accountID = UUID()
        print("[Local StoreKit] Requesting the native Ask to Buy purchase.")
        let result = try await provider.purchase(productID: productID, accountToken: accountID)
        guard case .pending = result else {
            XCTFail("Ask to Buy must remain pending until explicitly approved.")
            return
        }
        print("[Local StoreKit] Native purchase returned pending.")
        let pending = try XCTUnwrap(session.allTransactions().first {
            $0.productIdentifier == productID && $0.pendingAskToBuyConfirmation
        })
        let beforeApproval = await nativeUnfinishedTransactions()
        XCTAssertFalse(beforeApproval.contains { $0.productID == productID })
        print("[Local StoreKit] Approving the pending test request.")
        try session.approveAskToBuyTransaction(identifier: UInt(pending.identifier))
        let approved = try await waitForUnfinishedTransaction(productID: productID)
        print("[Local StoreKit] Approved request is present in unfinished.")
        XCTAssertEqual(approved.environment, .xcode)
        XCTAssertEqual(approved.appAccountToken, accountID)
        XCTAssertEqual(LocalStoreKitRejectingURLProtocol.requestCount, 0)
    }

    @MainActor func testNativeInterruptedPurchaseCanBeResolvedWithoutLosingTheUnfinishedTransaction() async throws {
        let session = try await makeSession()
        defer { clean(session) }
        session.interruptedPurchasesEnabled = true
        let provider = try await provider()
        let accountID = UUID()
        do {
            let result = try await provider.purchase(productID: productID, accountToken: accountID)
            if case .success = result { XCTFail("An unresolved purchase issue must not be delivered as successful.") }
        } catch {
            // The issue flag below independently verifies that this is a real
            // interrupted StoreKit transaction, rather than an arbitrary error.
        }
        let interrupted = try XCTUnwrap(session.allTransactions().first {
            $0.productIdentifier == productID && $0.hasPurchaseIssue
        })
        let beforeResolution = await nativeUnfinishedTransactions()
        XCTAssertFalse(beforeResolution.contains { $0.productID == productID })
        try session.resolveIssueForTransaction(identifier: UInt(interrupted.identifier))
        let resolved = try await waitForUnfinishedTransaction(productID: productID)
        XCTAssertEqual(resolved.environment, .xcode)
        XCTAssertEqual(resolved.appAccountToken, accountID)
        XCTAssertEqual(LocalStoreKitRejectingURLProtocol.requestCount, 0)
    }
}

private enum LocalStoreKitMarket {
    case china, unitedStates
    var configurationName: String { self == .china ? "QuotaProducts" : "QuotaProductsUSD" }
    var storefront: String { self == .china ? "CHN" : "USA" }
    var locale: String { self == .china ? "zh_CN" : "en_US" }
    var currency: String { self == .china ? "CNY" : "USD" }
}

private enum LocalStoreKitFailure: Error { case configurationNotActive, missingTransaction }

private actor LocalStoreKitFinishCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private final class LocalStoreKitSessionVault: AccountSessionStorage {
    private var session: AccountSession?
    init(_ session: AccountSession) { self.session = session }
    func load() throws -> AccountSession? { session }
    func save(_ session: AccountSession) throws { self.session = session }
    func delete() throws { session = nil }
}

private final class LocalStoreKitRejectingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}
