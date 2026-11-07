import Foundation
import StoreKit

struct AccountPurchaseProduct: Identifiable, Sendable {
    let id: String
    let displayPrice: String
    let price: Decimal
    let currency: String
    let isConsumable: Bool
    var allowanceTokens: Int? = nil
}

enum AccountPurchaseEvent: Sendable {
    case verified(VerifiedAccountPurchase, @Sendable () async -> Void)
    case unverified
}

enum AccountPurchaseResult: Sendable {
    case success(AccountPurchaseEvent)
    case pending
    case cancelled
}

/// StoreKit retains unfinished transactions across launches. Delivery remains a server decision.
@MainActor protocol AccountPurchaseProviding {
    func products(for ids: Set<String>) async throws -> [AccountPurchaseProduct]
    func purchase(productID: String, accountToken: UUID) async throws -> AccountPurchaseResult
    func unfinished() -> AsyncStream<AccountPurchaseEvent>
    func updates() -> AsyncStream<AccountPurchaseEvent>
}

@MainActor final class StoreKitPurchaseProvider: AccountPurchaseProviding {
    private var available: [String: Product] = [:]

    func products(for ids: Set<String>) async throws -> [AccountPurchaseProduct] {
        let products = try await Product.products(for: ids)
        available = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        return products.map {
            AccountPurchaseProduct(id: $0.id, displayPrice: $0.displayPrice, price: $0.price,
                                   currency: $0.priceFormatStyle.currencyCode, isConsumable: $0.type == .consumable)
        }
    }

    func purchase(productID: String, accountToken: UUID) async throws -> AccountPurchaseResult {
        guard let product = available[productID], product.type == .consumable else {
            throw AccountAPIError.invalidResponse
        }
        let result: Product.PurchaseResult
        do { result = try await product.purchase(options: [.appAccountToken(accountToken)]) }
        catch StoreKitError.userCancelled { return .cancelled }
        switch result {
        case .success(let result): return .success(Self.event(result))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw AccountAPIError.invalidResponse
        }
    }

    func unfinished() -> AsyncStream<AccountPurchaseEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.unfinished {
                    guard !Task.isCancelled else { break }
                    continuation.yield(Self.event(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func updates() -> AsyncStream<AccountPurchaseEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(Self.event(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func event(_ result: VerificationResult<Transaction>) -> AccountPurchaseEvent {
        guard case .verified(let transaction) = result, transaction.productType == .consumable else { return .unverified }
        let environment: String
        if transaction.environment == .production { environment = "Production" }
        else if transaction.environment == .sandbox { environment = "Sandbox" }
        else { environment = "LocalTesting" }
        let record = VerifiedAccountPurchase(transactionID: String(transaction.id),
                                             appAccountToken: transaction.appAccountToken, environment: environment)
        return .verified(record, { await transaction.finish() })
    }
}
