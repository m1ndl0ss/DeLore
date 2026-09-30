import DeLoreCore
import Foundation
import StoreKit

/// StoreKit 2 implementation. Every transaction is checked with `VerificationResult`
/// (Apple's on-device JWS verification) before anything is granted, and finished only after
/// the content has been delivered.
final class StoreKitPurchaseService: PurchaseService, @unchecked Sendable {
    private let catalog: ProductCatalog
    private let ledger: PassLedger
    private let logger: AppLogger
    private let updatesStream: AsyncStream<Void>
    private let updatesContinuation: AsyncStream<Void>.Continuation
    private var listener: Task<Void, Never>?

    init(catalog: ProductCatalog, ledger: PassLedger, logger: AppLogger) {
        self.catalog = catalog
        self.ledger = ledger
        self.logger = logger.scoped("store")
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updatesStream = stream
        updatesContinuation = continuation
        listener = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.unfinished {
                await self?.handle(result)
            }
        }
    }

    deinit {
        listener?.cancel()
        updatesContinuation.finish()
    }

    func products() async throws -> [StoreProduct] {
        let storeProducts: [Product]
        do {
            storeProducts = try await Product.products(for: catalog.all)
        } catch {
            throw PurchaseError.storeUnavailable
        }
        guard !storeProducts.isEmpty else { throw PurchaseError.storeUnavailable }
        return storeProducts.compactMap(map).filter { $0.kind != .oneTimeCleanup }.sorted { order($0.kind) < order($1.kind) }
    }

    func purchase(_ productID: String) async throws -> PurchaseOutcome {
        let products: [Product]
        do {
            products = try await Product.products(for: [productID])
        } catch {
            throw PurchaseError.storeUnavailable
        }
        guard let product = products.first else { throw PurchaseError.productNotFound }

        switch try await product.purchase() {
        case let .success(verification):
            guard await handle(verification) else { throw PurchaseError.verificationFailed }
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws {
        do {
            try await AppStore.sync()
        } catch {
            throw PurchaseError.storeUnavailable
        }
        updatesContinuation.yield()
    }

    func subscriptionStatus() async -> SubscriptionStatus {
        var status = SubscriptionStatus.inactive
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  catalog.subscriptions.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expiration = transaction.expirationDate, expiration < Date() { continue }
            status.isActive = true
            if let expiration = transaction.expirationDate {
                status.renewsOrExpiresAt = max(status.renewsOrExpiresAt ?? expiration, expiration)
            }
        }
        return status
    }

    func transactionUpdates() -> AsyncStream<Void> { updatesStream }

    /// Delivers a verified transaction. Unverified transactions grant nothing and are left
    /// unfinished, as Apple recommends.
    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>) async -> Bool {
        guard case let .verified(transaction) = result else {
            logger.warning("transaction failed verification")
            return false
        }
        if transaction.productID == catalog.oneTimeCleanup, transaction.revocationDate == nil {
            do {
                _ = try ledger.credit(transactionID: String(transaction.id))
            } catch {
                logger.error("could not record pass: \(error.safeDescription)")
                return false
            }
        }
        await transaction.finish()
        updatesContinuation.yield()
        return true
    }

    private func map(_ product: Product) -> StoreProduct? {
        let kind: StoreProduct.Kind
        switch product.id {
        case catalog.oneTimeCleanup: kind = .oneTimeCleanup
        case catalog.proMonthly: kind = .proMonthly
        case catalog.proYearly: kind = .proYearly
        default: return nil
        }
        var monthly: String?
        if kind == .proYearly {
            let perMonth = product.price / 12
            monthly = perMonth.formatted(product.priceFormatStyle)
        }
        return StoreProduct(
            id: product.id,
            kind: kind,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            monthlyEquivalent: monthly
        )
    }

    private func order(_ kind: StoreProduct.Kind) -> Int {
        switch kind {
        case .proYearly: return 0
        case .proMonthly: return 1
        case .oneTimeCleanup: return 2
        }
    }
}
