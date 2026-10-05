package app.delore.android.domain

data class EntitlementState(
    val isPro: Boolean = false,
    val proRenewsOrExpiresAt: Long? = null,
    val cleanupPasses: Int = 0,
    val freeMessagesUsed: Int = 0,
) {
    companion object {
        val Free = EntitlementState()
    }
}

sealed class CleanupAllowanceDecision {
    data class Allowed(val limit: Int?, val consumesPass: Boolean, val usesFreeAllowance: Boolean) : CleanupAllowanceDecision()
    data class Limited(val remainingFree: Int) : CleanupAllowanceDecision()
    data object FiltersRequirePro : CleanupAllowanceDecision()
}

object CleanupAllowance {
    fun evaluate(
        requestedCount: Int,
        usesAdvancedFilters: Boolean,
        entitlement: EntitlementState,
        freeLimit: Int,
    ): CleanupAllowanceDecision {
        if (entitlement.isPro) {
            return CleanupAllowanceDecision.Allowed(limit = null, consumesPass = false, usesFreeAllowance = false)
        }
        if (usesAdvancedFilters) return CleanupAllowanceDecision.FiltersRequirePro
        if (entitlement.cleanupPasses > 0) {
            return CleanupAllowanceDecision.Allowed(limit = null, consumesPass = true, usesFreeAllowance = false)
        }
        val remaining = maxOf(0, freeLimit - entitlement.freeMessagesUsed)
        if (requestedCount <= remaining) {
            return CleanupAllowanceDecision.Allowed(limit = requestedCount, consumesPass = false, usesFreeAllowance = true)
        }
        return CleanupAllowanceDecision.Limited(remainingFree = remaining)
    }
}

data class ProductCatalog(
    val oneTimeCleanup: String,
    val proMonthly: String,
    val proYearly: String,
    val proMonthlyPromo: String = "app.retract.pro.monthly.promo",
    val proYearlyPromo: String = "app.retract.pro.yearly.promo",
) {
    val all: List<String> get() = listOf(oneTimeCleanup, proMonthly, proYearly, proMonthlyPromo, proYearlyPromo)
    val subscriptions: List<String> get() = listOf(proMonthly, proYearly, proMonthlyPromo, proYearlyPromo)
    val displaySubscriptions: List<String> get() = listOf(proMonthly, proYearly)

    fun checkoutId(displayId: String, discounted: Boolean): String {
        if (!discounted) return displayId
        return when (displayId) {
            proMonthly -> proMonthlyPromo
            proYearly -> proYearlyPromo
            else -> displayId
        }
    }
}
