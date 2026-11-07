import XCTest
import SwiftUI
import UIKit
import Vision
import CryptoKit
@testable import BlindOracle

/// Review-only evidence: actual view rendering with isolated catalog fixture;
/// no financial event; not marketing/native-payment validation.
@MainActor final class AppStoreIapReviewScreenshotTests: XCTestCase {
    private let productID = "com.lihao.BlindOracle.quota.1m"
    private let exampleID = "00000000-0000-4000-8000-000000000048"

    func testCaptureActualTopUpViewForIapReviewInChineseAndEnglish() async throws {
        let defaults = UserDefaults.standard
        let originalLanguage = defaults.object(forKey: AppLanguage.preferenceKey)
        defer {
            if let originalLanguage { defaults.set(originalLanguage, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
            IapReviewScreenshotURLProtocol.reset()
        }
        for (language, locale) in [(AppLanguage.simplifiedChinese, "zh-Hans"), (.english, "en-US")] {
            defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey)
            try await AppLanguage.$override.withValue(language) {
                try await capture(language: language, locale: locale)
            }
        }
    }

    private func capture(language: AppLanguage, locale: String) async throws {
        IapReviewScreenshotURLProtocol.install(routes: [
            "/products/": "{\"products\":[{\"product_id\":\"\(productID)\",\"name\":\"补充额度\",\"credits\":1000000,\"currency\":\"CNY\",\"price_milliunits\":6000}]}",
            "/me/": "{\"id\":\"\(exampleID)\",\"display_name\":\"示例账号 / Example account\",\"email\":null,\"created_at\":\"2026-11-07T00:00:00Z\"}",
            "/wallet/": #"{"quota":{"remaining_percent":100,"is_unlimited":false,"can_start":true}}"#,
            "/usage/summary/": #"{"request_count":0,"input_tokens":0,"output_tokens":0,"total_tokens":0,"confirmed_cost_cny":"0","unknown_count":0}"#,
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IapReviewScreenshotURLProtocol.self]
        let api = AccountAPI(configuration: configuration)
        let sampleSession = try AccountSession(response: AccountTokenResponse(accessToken: "review-fixture-access",
            refreshToken: "review-fixture-refresh", expiresIn: 3600,
            user: AccountUser(id: exampleID, displayName: "示例账号 / Example account", email: nil, createdAt: "2026-11-07T00:00:00Z")),
            appleUserID: nil)
        let sessions = AccountSessionManager(api: api, vault: IapReviewScreenshotVault(sampleSession))
        let account = AccountStore(api: api, sessions: sessions)
        let provider = IapReviewScreenshotPurchaseProvider(productID: productID, language: language)
        let purchases = AccountPurchaseStore(api: api, sessions: sessions, provider: provider)
        // No restoration/Apple credential checks: all account metadata comes
        // from this test's memory vault and isolated URLProtocol responses.
        await account.sessionChanged()
        await account.refreshOverview()
        await purchases.loadProducts()
        XCTAssertTrue(IapReviewScreenshotURLProtocol.unexpectedRequests.isEmpty,
                      "Unmatched isolated fixture endpoint: \(IapReviewScreenshotURLProtocol.unexpectedRequests)")
        let product = try XCTUnwrap(purchases.products.first, purchases.message ?? "Expected the isolated approved product")
        XCTAssertEqual(product.id, productID)
        XCTAssertEqual(product.currency, "CNY")
        XCTAssertEqual(product.price, Decimal(6))
        XCTAssertTrue(product.isConsumable)
        XCTAssertEqual(product.allowanceTokens, 1_000_000)
        XCTAssertEqual(account.wallet?.quota?.displayedPercent, 100)
        XCTAssertNil(account.message)
        XCTAssertNil(purchases.message)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        let host = UIHostingController(rootView:
            NavigationStack { AccountTopUpView() }
                .environmentObject(account)
                .environmentObject(purchases)
                .environment(\.locale, Locale(identifier: locale))
                .preferredColorScheme(.light))
        window.rootViewController = host
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        window.layoutIfNeeded()
        // The real view's .task loads the same isolated catalog and examines
        // an empty unfinished-transaction sequence. It never purchases.
        for _ in 0..<100 {
            if provider.scanCount > 0, !purchases.isLoading, !purchases.isCheckingPurchases { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(provider.scanCount, 0)
        XCTAssertFalse(purchases.isLoading)
        XCTAssertFalse(purchases.isCheckingPurchases)
        await Task.yield()
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scene.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var hierarchyWasDrawn = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            hierarchyWasDrawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(hierarchyWasDrawn, "Capture must draw the real hosted view hierarchy")
        let cgImage = try XCTUnwrap(image.cgImage)
        let text = try recognizedText(in: cgImage, locale: locale)
        let compactText = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "％", with: "%")
        let titleVisible = compactText.contains(language.isEnglish ? "Replenishallowance" : "补充额度")
        let allowanceVisible = compactText.contains("1,000,000Token")
        let priceVisible = compactText.contains("6.00")
        XCTAssertTrue(titleVisible, "The actual view title must be visible")
        XCTAssertTrue(allowanceVisible, "The package Token amount must be rendered before payment")
        XCTAssertFalse(compactText.contains("100%"), "The purchase page does not show remaining allowance")
        XCTAssertTrue(priceVisible, "The offered fixture price must be visible")
        XCTAssertEqual(provider.purchaseCount, 0)
        XCTAssertTrue(IapReviewScreenshotURLProtocol.unexpectedRequests.isEmpty)
        XCTAssertTrue(IapReviewScreenshotURLProtocol.requestMethods.allSatisfy { $0 == "GET" })
        guard hierarchyWasDrawn, titleVisible, allowanceVisible, priceVisible, provider.purchaseCount == 0,
              IapReviewScreenshotURLProtocol.unexpectedRequests.isEmpty,
              IapReviewScreenshotURLProtocol.requestMethods.allSatisfy({ $0 == "GET" }) else {
            throw IapReviewScreenshotError.captureNotValidated
        }

        let png = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(png.count, 25)
        guard png.count > 25, png[24] == 8, png[25] == 2 else {
            XCTFail("The native capture must be an 8-bit RGB PNG without alpha")
            throw IapReviewScreenshotError.captureNotValidated
        }
        let screenshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        screenshot.name = "iap-review-\(locale)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let metadata: [String: Any] = [
            "locale": locale,
            "capture_kind": "actual view rendering with isolated catalog fixture; no financial event; not marketing/native-payment validation",
            "rendered_view": "AccountTopUpView",
            "product_id": productID,
            "product_type": "CONSUMABLE",
            "currency": "CNY",
            "fixture_price": "6.00",
            "display_price": product.displayPrice,
            "price_source": "isolated AccountPurchaseProviding fixture; not a live StoreKit price lookup",
            "account_data": "explicit synthetic example account; no private identity or remaining allowance shown",
            "pixel_width": cgImage.width,
            "pixel_height": cgImage.height,
            "png_bit_depth": Int(png[24]),
            "png_color_type": Int(png[25]),
            "has_alpha": false,
            "png_sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "service_environment": ServiceEnvironment.current.rawValue,
            "external_network_used": false,
            "native_storekit_used": false,
            "purchase_invocations": provider.purchaseCount,
            "financial_event": false,
            "marketing_screenshot": false,
            "native_payment_validation": false,
            "rendered_title_allowance_and_price_confirmed_by_on_device_ocr": true,
        ]
        let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]),
                                     uniformTypeIdentifier: "public.json")
        evidence.name = "iap-review-\(locale)-metadata"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func recognizedText(in image: CGImage, locale: String) throws -> String {
        // Vision performs this check locally on the rendered synthetic view.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [locale]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

private enum IapReviewScreenshotError: Error { case captureNotValidated }

@MainActor private final class IapReviewScreenshotPurchaseProvider: AccountPurchaseProviding {
    private let productID: String
    private let language: AppLanguage
    private(set) var purchaseCount = 0
    private(set) var scanCount = 0
    init(productID: String, language: AppLanguage) { self.productID = productID; self.language = language }
    func products(for ids: Set<String>) async throws -> [AccountPurchaseProduct] {
        guard ids == [productID] else { throw AccountAPIError.invalidResponse }
        return [AccountPurchaseProduct(id: productID, displayPrice: language.isEnglish ? "CN¥6.00" : "¥6.00",
                                       price: Decimal(6), currency: "CNY", isConsumable: true)]
    }
    func purchase(productID: String, accountToken: UUID) async throws -> AccountPurchaseResult {
        purchaseCount += 1
        XCTFail("The review screenshot must never initiate a purchase")
        throw AccountAPIError.invalidResponse
    }
    func unfinished() -> AsyncStream<AccountPurchaseEvent> {
        scanCount += 1
        return AsyncStream { $0.finish() }
    }
    func updates() -> AsyncStream<AccountPurchaseEvent> { AsyncStream { $0.finish() } }
}

private final class IapReviewScreenshotVault: AccountSessionStorage {
    private var value: AccountSession?
    init(_ value: AccountSession?) { self.value = value }
    func load() throws -> AccountSession? { value }
    func save(_ session: AccountSession) throws { value = session }
    func delete() throws { value = nil }
}

private final class IapReviewScreenshotURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: String] = [:]
    nonisolated(unsafe) private static var unexpected: [String] = []
    nonisolated(unsafe) private static var methods: [String] = []
    static var unexpectedRequests: [String] { lock.lock(); defer { lock.unlock() }; return unexpected }
    static var requestMethods: [String] { lock.lock(); defer { lock.unlock() }; return methods }
    static func install(routes: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        self.routes = routes; unexpected = []; methods = []
    }
    static func reset() { install(routes: [:]) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? "missing-path"
        // Foundation's URL.path can omit the trailing slash even though the
        // request URL preserves it. Normalize this fixture lookup only.
        let routePath = path.hasSuffix("/") ? path : path + "/"
        Self.lock.lock()
        Self.methods.append(request.httpMethod ?? "missing-method")
        let body = request.httpMethod == "GET" ? Self.routes.first(where: { routePath.hasSuffix($0.key) })?.value : nil
        if body == nil { Self.unexpected.append(path) }
        Self.lock.unlock()
        guard let body, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
