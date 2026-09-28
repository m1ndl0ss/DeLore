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

    let freeLimit: Int
    private let service: PurchaseService
    private let ledger: PassLedger
    private let analytics: Analytics
    /// Only touched on the main actor, plus `deinit` once no other reference exists.
    @ObservationIgnored private nonisolated(unsafe) var updatesTask: Task<Void, Never>?

    init(service: PurchaseService, ledger: PassLedger, freeLimit: Int, analytics: Analytics) {
        self.service = service
        self.ledger = ledger
        self.freeLimit = freeLimit
        self.analytics = analytics
        state = EntitlementState(cleanupPasses: ledger.passes, freeMessagesUsed: ledger.freeMessagesUsed)
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

    func refresh() async {
        let subscription = await service.subscriptionStatus()
        state = EntitlementState(
            isPro: subscription.isActive,
            proRenewsOrExpiresAt: subscription.renewsOrExpiresAt,
            cleanupPasses: ledger.passes,
            freeMessagesUsed: ledger.freeMessagesUsed
        )
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await service.products()
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
