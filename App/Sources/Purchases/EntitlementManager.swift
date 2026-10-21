import DeLoreCore
import Foundation

/// Single source of truth for what the user can do.
/// Paid Pro comes only from StoreKit (Apple ID). Complimentary Pro is a hosted Instagram
/// username allowlist (live on refresh) — never a sticky device-wide flag.
@MainActor
@Observable
final class EntitlementManager {
    private(set) var state = EntitlementState.free
    private(set) var products: [StoreProduct] = []
    private var catalogProducts: [StoreProduct] = []
    private(set) var isLoadingProducts = false
    private(set) var storeUnavailable = false
    private(set) var isPurchasing = false
    private(set) var percentOff = 0
    private(set) var appliedPromoCode: String?
    private(set) var hasStoreSubscription = false

    let freeLimit: Int
    private let service: PurchaseService
    private let ledger: PassLedger
    private let promo: PromoVault
    private let analytics: Analytics
    private let promoCatalogURL: URL
    private let accountUserID: () -> String?
    private let accountUsername: () -> String?
    private let workerAuth: WorkerAuth?
    private let onSubscriptionPurchased: ((String, String?) -> Void)?
    private let onComplimentaryUnlocked: ((String) -> Void)?
    /// When true, each completed unsend increments local + worker free usage.
    private(set) var tracksFreeUnsent = false
    /// Only touched on the main actor, plus `deinit` once no other reference exists.
    @ObservationIgnored private nonisolated(unsafe) var updatesTask: Task<Void, Never>?

    init(
        service: PurchaseService,
        ledger: PassLedger,
        freeLimit: Int,
        analytics: Analytics,
        promo: PromoVault? = nil,
        promoCatalogURL: URL = RemotePromoCatalog.defaultURL,
        accountUserID: @escaping () -> String? = { nil },
        accountUsername: @escaping () -> String? = { nil },
        workerAuth: WorkerAuth? = nil,
        onSubscriptionPurchased: ((String, String?) -> Void)? = nil,
        onComplimentaryUnlocked: ((String) -> Void)? = nil
    ) {
        self.service = service
        self.ledger = ledger
        self.freeLimit = freeLimit
        self.analytics = analytics
        self.promo = promo ?? PromoVault(store: ledger.store)
        self.promoCatalogURL = promoCatalogURL
        self.accountUserID = accountUserID
        self.accountUsername = accountUsername
        self.workerAuth = workerAuth
        self.onSubscriptionPurchased = onSubscriptionPurchased
        self.onComplimentaryUnlocked = onComplimentaryUnlocked
        percentOff = self.promo.percentOff
        appliedPromoCode = self.promo.appliedCode
        let uid = accountUserID()
        state = EntitlementState(
            isPro: self.promo.isComplimentaryUsername(accountUsername()),
            cleanupPasses: ledger.passes,
            freeMessagesUsed: ledger.freeMessagesUsed(for: uid)
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
        let result = promo.redeem(raw, accountUserID: accountUserID())
        if case .applied(let offer) = result {
            appliedPromoCode = promo.appliedCode
            percentOff = promo.percentOff
            if offer == .complimentary {
                state.isPro = true
                onComplimentaryUnlocked?(promo.appliedCode ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            }
        }
        return result
    }

    /// Drops complimentary / promo unlocks. Per-account free usage stays in the ledger
    /// so the same Instagram account cannot refill by logging out. Call on logout.
    func clearLocalUnlocks() {
        promo.clearLocalUnlocks()
        percentOff = 0
        appliedPromoCode = nil
        hasStoreSubscription = false
        state = EntitlementState(
            isPro: false,
            cleanupPasses: ledger.passes,
            freeMessagesUsed: 0
        )
    }

    func refresh() async {
        // Drop any leftover vault complimentary flags from the retired binary gift code.
        promo.clearLegacyComplimentaryFlags()
        await refreshCampaignCodes()
        let uid = accountUserID()
        let signedIn = !(uid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let subscription = await service.subscriptionStatus()
        // Store status is queried live — never sticky. Pro only applies while an Instagram
        // account is signed in so logout cannot leave another account unlocked.
        hasStoreSubscription = subscription.isActive
        if signedIn {
            await syncFreeUsage()
        }
        let complimentary = promo.isComplimentaryUsername(accountUsername())
        state = EntitlementState(
            isPro: signedIn && (subscription.isActive || complimentary),
            proRenewsOrExpiresAt: subscription.renewsOrExpiresAt,
            cleanupPasses: ledger.passes,
            freeMessagesUsed: signedIn ? ledger.freeMessagesUsed(for: uid) : 0
        )
        percentOff = promo.percentOff
        appliedPromoCode = promo.appliedCode
    }

    func setTracksFreeUnsent(_ enabled: Bool) {
        tracksFreeUnsent = enabled
    }

    /// Called once per completed free-tier unsend (idempotent on the worker via message key).
    func noteFreeUnsent(idempotencyKey: String) {
        guard tracksFreeUnsent else { return }
        let uid = accountUserID()
        try? ledger.addFreeUsage(1, accountUserID: uid)
        state.freeMessagesUsed = ledger.freeMessagesUsed(for: uid)
        guard let auth = workerAuth, let uid, !uid.isEmpty else { return }
        let key = idempotencyKey
        Task {
            if let merged = await FreeUsageSync.increment(auth: auth, userID: uid, idempotencyKey: key) {
                _ = try? ledger.mergeRemoteFreeUsage(merged, accountUserID: uid)
                state.freeMessagesUsed = ledger.freeMessagesUsed(for: uid)
            }
        }
    }

    /// Pull + max-merge with the worker so reinstall / new device picks up prior free usage.
    /// Worker caps each sync raise; loop until local is fully pushed or the server stops moving.
    func syncFreeUsage() async {
        guard let uid = accountUserID(), !uid.isEmpty, let auth = workerAuth else { return }
        // Prefer a pull first so reinstalls adopt the server total before any local push.
        if let pulled = await FreeUsageSync.pull(auth: auth, userID: uid) {
            _ = try? ledger.mergeRemoteFreeUsage(pulled, accountUserID: uid)
            state.freeMessagesUsed = ledger.freeMessagesUsed(for: uid)
        }
        for _ in 0..<5 {
            let local = ledger.freeMessagesUsed(for: uid)
            guard let merged = await FreeUsageSync.sync(auth: auth, userID: uid, localUsed: local) else { break }
            _ = try? ledger.mergeRemoteFreeUsage(merged, accountUserID: uid)
            state.freeMessagesUsed = ledger.freeMessagesUsed(for: uid)
            if merged >= local { break }
        }
    }

    /// Pulls the hosted percent-off list. Soft-fails to cache / baked codes. Complimentary never comes from the network.
    func refreshCampaignCodes() async {
        _ = await RemotePromoCatalog.refresh(into: promo.campaignBook, from: promoCatalogURL)
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        await refreshCampaignCodes()
        do {
            catalogProducts = try await service.products().filter { $0.kind != .oneTimeCleanup }
            products = catalogProducts.filter { !$0.isPromo }
            storeUnavailable = false
        } catch {
            storeUnavailable = true
        }
    }

    /// Store SKU to buy for a paywall card. Promo codes switch to the discounted IAP.
    func checkoutProduct(for product: StoreProduct) -> StoreProduct? {
        guard percentOff > 0 else { return product }
        return catalogProducts.first { $0.kind == product.kind && $0.isPromo }
    }

    /// Returns true when the purchase completed and the entitlement is in place.
    func purchase(_ product: StoreProduct) async -> PurchaseOutcome? {
        guard !isPurchasing else { return nil }
        // Promo SKUs require an active percent-off code — never sell them bare.
        if product.isPromo, percentOff <= 0 { return nil }
        guard let target = checkoutProduct(for: product) else { return nil }
        if target.isPromo, percentOff <= 0 { return nil }
        isPurchasing = true
        defer { isPurchasing = false }
        let kind = analyticsKind(product.kind)
        analytics.track(.purchaseStarted(product: kind))
        do {
            let outcome = try await service.purchase(target.id)
            await refresh()
            if outcome == .purchased {
                analytics.track(.purchaseCompleted(product: kind))
                if product.kind != .oneTimeCleanup {
                    analytics.track(.subscriptionStarted)
                    onSubscriptionPurchased?(target.id, appliedPromoCode)
                }
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
        let uid = accountUserID()
        try? ledger.addFreeUsage(count, accountUserID: uid)
        state.freeMessagesUsed = ledger.freeMessagesUsed(for: uid)
        Task { await syncFreeUsage() }
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
