import DeLoreCore
import Foundation

/// Single source of truth for what the user can do. The app stays fully usable on the free
/// tier if the App Store can't be reached.
@MainActor
@Observable
final class EntitlementManager {
    private(set) var state = EntitlementState.free
    private(set) var products: [StoreProduct] = []
    private(set) var isLoadingProducts = false
    private(set) var storeUnavailable = false
    private(set) var isPurchasing = false
    private(set) var percentOff = 0
    private(set) var appliedPromoCode: String?

    let freeLimit: Int
    private let service: PurchaseService
    private let ledger: PassLedger
    private let promo: PromoVault
    private let analytics: Analytics
    /// Only touched on the main actor, plus `deinit` once no other reference exists.
    @ObservationIgnored private nonisolated(unsafe) var updatesTask: Task<Void, Never>?

    init(service: PurchaseService, ledger: PassLedger, freeLimit: Int, analytics: Analytics, promo: PromoVault? = nil) {
        self.service = service
        self.ledger = ledger
        self.freeLimit = freeLimit
        self.analytics = analytics
        self.promo = promo ?? PromoVault(store: ledger.store)
        percentOff = self.promo.percentOff
        appliedPromoCode = self.promo.appliedCode
        state = EntitlementState(
            isPro: self.promo.isComplimentary,
            cleanupPasses: ledger.passes,
            freeMessagesUsed: ledger.freeMessagesUsed
        )
        updatesTask = Task { [weak self, service] in
            for await _ in service.transactionUpdates() {
                await self?.refresh()
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    var isPro: Bool { state.isPro }
    var promoGuessesRemaining: Int { promo.remainingGuesses() }
    var isPromoLocked: Bool { promo.isLocked() }

    func redeemPromo(_ raw: String) -> PromoRedeemResult {
        let result = promo.redeem(raw)
        if case .applied(let offer) = result {
            appliedPromoCode = promo.appliedCode
            percentOff = promo.percentOff
            if offer == .complimentary {
                state.isPro = true
            }
        }
        return result
    }

    func refresh() async {
        let subscription = await service.subscriptionStatus()
        state = EntitlementState(
            isPro: subscription.isActive || promo.isComplimentary,
            proRenewsOrExpiresAt: subscription.renewsOrExpiresAt,
            cleanupPasses: ledger.passes,
            freeMessagesUsed: ledger.freeMessagesUsed
        )
        percentOff = promo.percentOff
        appliedPromoCode = promo.appliedCode
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await service.products().filter { $0.kind != .oneTimeCleanup }
            storeUnavailable = false
        } catch {
            storeUnavailable = true
        }
    }

    /// Returns true when the purchase completed and the entitlement is in place.
    func purchase(_ product: StoreProduct) async -> PurchaseOutcome? {
        guard !isPurchasing else { return nil }
        isPurchasing = true
        defer { isPurchasing = false }
        let kind = analyticsKind(product.kind)
        analytics.track(.purchaseStarted(product: kind))
        do {
            let outcome = try await service.purchase(product.id)
            await refresh()
            if outcome == .purchased {
                analytics.track(.purchaseCompleted(product: kind))
                if product.kind != .oneTimeCleanup { analytics.track(.subscriptionStarted) }
            }
            return outcome
        } catch {
            storeUnavailable = (error as? PurchaseError) == .storeUnavailable
            return nil
        }
    }

    func restore() async -> Bool {
        do {
            try await service.restore()
            await refresh()
            analytics.track(.restoreCompleted)
            return true
        } catch {
            return false
        }
    }

    func allowance(requestedCount: Int, usesAdvancedFilters: Bool) -> CleanupAllowanceDecision {
        CleanupAllowance.evaluate(
            requestedCount: requestedCount,
            usesAdvancedFilters: usesAdvancedFilters,
            entitlement: state,
            freeLimit: freeLimit
        )
    }

    func consumePass() -> Bool {
        let consumed = (try? ledger.consumePass()) ?? false
        state.cleanupPasses = ledger.passes
        return consumed
    }

    func recordFreeUsage(_ count: Int) {
        try? ledger.addFreeUsage(count)
        state.freeMessagesUsed = ledger.freeMessagesUsed
    }

    var remainingFree: Int { max(0, freeLimit - state.freeMessagesUsed) }

    private func analyticsKind(_ kind: StoreProduct.Kind) -> AnalyticsEvent.ProductKind {
        switch kind {
        case .oneTimeCleanup: return .oneTime
        case .proMonthly: return .proMonthly
        case .proYearly: return .proYearly
        }
    }
}
