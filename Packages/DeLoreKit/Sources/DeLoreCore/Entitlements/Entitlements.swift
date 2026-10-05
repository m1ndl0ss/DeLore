import Foundation

/// What the user has paid for, as derived from verified StoreKit transactions.
public struct EntitlementState: Equatable, Sendable {
    public var isPro: Bool
    public var proRenewsOrExpiresAt: Date?
    /// Unused one-time cleanup passes.
    public var cleanupPasses: Int
    /// Messages already cleaned under the free allowance.
    public var freeMessagesUsed: Int

    public init(isPro: Bool = false, proRenewsOrExpiresAt: Date? = nil, cleanupPasses: Int = 0, freeMessagesUsed: Int = 0) {
        self.isPro = isPro
        self.proRenewsOrExpiresAt = proRenewsOrExpiresAt
        self.cleanupPasses = cleanupPasses
        self.freeMessagesUsed = freeMessagesUsed
    }

    public static let free = EntitlementState()
}

public enum CleanupAllowanceDecision: Hashable, Sendable {
    /// Go ahead. `limit` caps the job size; `consumesPass` means a one-time pass is used.
    case allowed(limit: Int?, consumesPass: Bool, usesFreeAllowance: Bool)
    /// Free users can clean `remainingFree` now, or upgrade for everything.
    case limited(remainingFree: Int)
    /// Date and type filters are a Pro feature.
    case filtersRequirePro
}

public enum CleanupAllowance {
    public static func evaluate(
        requestedCount: Int,
        usesAdvancedFilters: Bool,
        entitlement: EntitlementState,
        freeLimit: Int
    ) -> CleanupAllowanceDecision {
        if entitlement.isPro {
            return .allowed(limit: nil, consumesPass: false, usesFreeAllowance: false)
        }
        if usesAdvancedFilters {
            return .filtersRequirePro
        }
        if entitlement.cleanupPasses > 0 {
            return .allowed(limit: nil, consumesPass: true, usesFreeAllowance: false)
        }
        let remaining = max(0, freeLimit - entitlement.freeMessagesUsed)
        if requestedCount <= remaining {
            return .allowed(limit: requestedCount, consumesPass: false, usesFreeAllowance: true)
        }
        return .limited(remainingFree: remaining)
    }
}

/// Product identifiers live in configuration; this is the shape the UI consumes.
public struct ProductCatalog: Equatable, Sendable {
    public var oneTimeCleanup: String
    public var proMonthly: String
    public var proYearly: String
    public var proMonthlyPromo: String
    public var proYearlyPromo: String
    public var subscriptionGroupID: String?

    public init(
        oneTimeCleanup: String,
        proMonthly: String,
        proYearly: String,
        proMonthlyPromo: String = "app.retract.pro.monthly.promo",
        proYearlyPromo: String = "app.retract.pro.yearly.promo",
        subscriptionGroupID: String? = nil
    ) {
        self.oneTimeCleanup = oneTimeCleanup
        self.proMonthly = proMonthly
        self.proYearly = proYearly
        self.proMonthlyPromo = proMonthlyPromo
        self.proYearlyPromo = proYearlyPromo
        self.subscriptionGroupID = subscriptionGroupID
    }

    public var all: [String] { [oneTimeCleanup, proMonthly, proYearly, proMonthlyPromo, proYearlyPromo] }
    public var subscriptions: Set<String> { [proMonthly, proYearly, proMonthlyPromo, proYearlyPromo] }
    public var displaySubscriptions: Set<String> { [proMonthly, proYearly] }

    public func isDisplaySubscription(_ id: String) -> Bool {
        id == proMonthly || id == proYearly
    }

    public func checkoutID(forDisplay id: String, discounted: Bool) -> String {
        guard discounted else { return id }
        switch id {
        case proMonthly: return proMonthlyPromo
        case proYearly: return proYearlyPromo
        default: return id
        }
    }
}
