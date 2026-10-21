package app.delore.android.billing

import android.app.Activity
import android.content.Context
import app.delore.android.BuildConfig
import app.delore.android.domain.EntitlementState
import app.delore.android.notify.FreeUsageSync
import app.delore.android.secrets.PassLedger
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class StoreProduct(
    val id: String,
    val kind: Kind,
    val displayName: String,
    val displayPrice: String,
    val monthlyEquivalent: String? = null,
    val isPromo: Boolean = false,
) {
    enum class Kind { ONE_TIME, MONTHLY, YEARLY }
}

enum class PurchaseOutcome { PURCHASED, PENDING, CANCELLED }

class EntitlementManager(
    private val context: Context,
    private val ledger: PassLedger,
    private val promo: PromoVault,
    val freeLimit: Int = BuildConfig.FREE_LIMIT,
    private val accountUserId: () -> String? = { null },
    private val accountUsername: () -> String? = { null },
    private val freeUsage: FreeUsageSync? = null,
    private val onSubscriptionPurchased: ((productId: String, promoCode: String?, purchaseToken: String) -> Unit)? = null,
    private val onComplimentaryUnlocked: ((promoCode: String) -> Unit)? = null,
) {
    var state: EntitlementState = EntitlementState(
        isPro = promo.isComplimentaryUsername(accountUsername()),
        cleanupPasses = ledger.passes,
        freeMessagesUsed = ledger.freeMessagesUsed(accountUserId()),
    )
        private set
    var products: List<StoreProduct> = fallbackProducts()
        private set
    private var catalogProducts: List<StoreProduct> = fallbackCatalog()
    var isLoadingProducts: Boolean = false
        private set
    var storeUnavailable: Boolean = false
        private set
    var isPurchasing: Boolean = false
        private set

    val isPro: Boolean get() = state.isPro
    val remainingFree: Int get() = maxOf(0, freeLimit - state.freeMessagesUsed)
    val percentOff: Int get() = promo.percentOff
    val appliedPromoCode: String? get() = promo.appliedCode
    val promoGuessesRemaining: Int get() = promo.remainingGuesses()
    val isPromoLocked: Boolean get() = promo.isLocked()
    val hasStoreSubscription: Boolean get() = paidFromStore
    /** Live Play Billing result only — never sticky across logout or billing outages. */
    private var paidFromStore: Boolean = false

    private var billing: BillingClient? = null
    private var details: Map<String, ProductDetails> = emptyMap()
    private val purchaseWaiter = AtomicReference<CompletableDeferred<PurchaseOutcome>?>(null)
    private val setupMutex = Mutex()
    private val syncScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var tracksFreeUnsent: Boolean = false

    fun redeemPromo(raw: String): PromoRedeemResult {
        val result = promo.redeem(raw, accountUserId = accountUserId())
        // Complimentary Pro is hosted username allowlist only — redeem never grants it.
        return result
    }

    /** Drops complimentary / promo unlocks. Per-account free usage stays so logout cannot refill it. */
    fun clearLocalUnlocks() {
        promo.clearLocalUnlocks()
        paidFromStore = false
        state = EntitlementState(
            isPro = false,
            cleanupPasses = ledger.passes,
            freeMessagesUsed = 0,
        )
    }

    fun allowance(requestedCount: Int, usesAdvancedFilters: Boolean) =
        app.delore.android.domain.CleanupAllowance.evaluate(requestedCount, usesAdvancedFilters, state, freeLimit)

    fun consumePass(): Boolean {
        val consumed = ledger.consumePass()
        state = state.copy(cleanupPasses = ledger.passes)
        return consumed
    }

    fun setTracksFreeUnsent(enabled: Boolean) {
        tracksFreeUnsent = enabled
    }

    /** Called once per completed free-tier unsend (idempotent on the worker via message key). */
    fun noteFreeUnsent(idempotencyKey: String) {
        if (!tracksFreeUnsent) return
        val uid = accountUserId()
        ledger.addFreeUsage(1, uid)
        state = state.copy(freeMessagesUsed = ledger.freeMessagesUsed(uid))
        val userId = uid?.takeIf { it.isNotBlank() } ?: return
        val sync = freeUsage ?: return
        syncScope.launch {
            val merged = sync.increment(userId, idempotencyKey) ?: return@launch
            ledger.mergeRemoteFreeUsage(merged, userId)
            state = state.copy(freeMessagesUsed = ledger.freeMessagesUsed(userId))
        }
    }

    /** Pull + max-merge with the worker so reinstall / new device picks up prior free usage. */
    suspend fun syncFreeUsage() {
        val uid = accountUserId()?.takeIf { it.isNotBlank() } ?: return
        val sync = freeUsage ?: return
        // Prefer a pull first so reinstalls adopt the server total before any local push.
        sync.pull(uid)?.let {
            ledger.mergeRemoteFreeUsage(it, uid)
            state = state.copy(freeMessagesUsed = ledger.freeMessagesUsed(uid))
        }
        // Worker caps each sync raise; loop until local is fully pushed or the server stops moving.
        repeat(5) {
            val local = ledger.freeMessagesUsed(uid)
            val merged = sync.sync(uid, local) ?: return
            ledger.mergeRemoteFreeUsage(merged, uid)
            state = state.copy(freeMessagesUsed = ledger.freeMessagesUsed(uid))
            if (merged >= local) return
        }
    }

    suspend fun refresh() {
        // Drop any leftover vault complimentary flags from the retired binary gift code.
        promo.clearLegacyComplimentaryFlags()
        refreshCampaignCodes()
        runCatching { ensureClient() }
        val uid = accountUserId()
        val signedIn = !uid.isNullOrBlank()
        val ready = billing?.isReady == true
        val subscription = if (ready) querySubscription() else false to null
        // Fail closed when Billing is unavailable — never keep a sticky local Pro flag.
        paidFromStore = subscription.first
        if (signedIn) syncFreeUsage()
        val complimentary = promo.isComplimentaryUsername(accountUsername())
        state = EntitlementState(
            isPro = signedIn && (paidFromStore || complimentary),
            proRenewsOrExpiresAt = subscription.second,
            cleanupPasses = ledger.passes,
            freeMessagesUsed = if (signedIn) ledger.freeMessagesUsed(uid) else 0,
        )
    }

    /** Pulls hosted percent-off codes + complimentary username allowlist. Soft-fails to cache / baked codes. */
    suspend fun refreshCampaignCodes() {
        withContext(Dispatchers.IO) {
            RemotePromoCatalog.refresh(promo.campaignBook, BuildConfig.PROMO_CATALOG_URL)
        }
    }

    suspend fun loadProducts() {
        if (isLoadingProducts) return
        isLoadingProducts = true
        try {
            refreshCampaignCodes()
            ensureClient()
            val loaded = queryProductDetails()
            if (loaded.isNotEmpty()) {
                products = loaded
                storeUnavailable = false
            } else {
                products = fallbackProducts()
            }
        } catch (_: Exception) {
            storeUnavailable = true
            products = fallbackProducts()
        } finally {
            isLoadingProducts = false
        }
    }

    fun checkoutProduct(forDisplay: StoreProduct): StoreProduct? {
        if (percentOff <= 0) return forDisplay
        return catalogProducts.firstOrNull { it.kind == forDisplay.kind && it.isPromo }
    }

    suspend fun purchase(activity: Activity, product: StoreProduct): PurchaseOutcome? {
        if (isPurchasing) return null
        // Promo SKUs require an active percent-off code — never sell them bare.
        if (product.isPromo && percentOff <= 0) return null
        val target = checkoutProduct(forDisplay = product) ?: return null
        if (target.isPromo && percentOff <= 0) return null
        isPurchasing = true
        val waiter = CompletableDeferred<PurchaseOutcome>()
        purchaseWaiter.set(waiter)
        return try {
            ensureClient()
            val detail = details[target.id] ?: return null.also { storeUnavailable = true }
            val offerToken = detail.subscriptionOfferDetails?.firstOrNull()?.offerToken
            val params = BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(
                    listOf(
                        BillingFlowParams.ProductDetailsParams.newBuilder()
                            .setProductDetails(detail)
                            .apply { if (offerToken != null) setOfferToken(offerToken) }
                            .build(),
                    ),
                )
                .build()
            val result = billing?.launchBillingFlow(activity, params)
            if (result?.responseCode != BillingClient.BillingResponseCode.OK) {
                purchaseWaiter.compareAndSet(waiter, null)
                return null
            }
            withTimeoutOrNull(120_000) { waiter.await() } ?: run {
                // Flow launched but no callback yet — poll once for a completed purchase.
                refresh()
                if (isPro) PurchaseOutcome.PURCHASED else PurchaseOutcome.PENDING
            }
        } catch (_: Exception) {
            storeUnavailable = true
            null
        } finally {
            purchaseWaiter.compareAndSet(waiter, null)
            isPurchasing = false
        }
    }

    suspend fun restore(): Boolean = runCatching {
        queryPurchasesAndApply()
        refresh()
        true
    }.getOrDefault(false)

    private fun fallbackProducts() = listOf(
        StoreProduct(BuildConfig.PRODUCT_PRO_YEARLY, StoreProduct.Kind.YEARLY, "Pro Yearly", "$59.99", "$5.00"),
        StoreProduct(BuildConfig.PRODUCT_PRO_MONTHLY, StoreProduct.Kind.MONTHLY, "Pro Monthly", "$19.99"),
    )

    private fun fallbackPromoProducts() = listOf(
        StoreProduct(BuildConfig.PRODUCT_PRO_YEARLY_PROMO, StoreProduct.Kind.YEARLY, "Pro Yearly", "$53.99", "$4.50", isPromo = true),
        StoreProduct(BuildConfig.PRODUCT_PRO_MONTHLY_PROMO, StoreProduct.Kind.MONTHLY, "Pro Monthly", "$17.99", isPromo = true),
    )

    private fun fallbackCatalog() = fallbackProducts() + fallbackPromoProducts()

    private suspend fun ensureClient() {
        if (billing?.isReady == true) return
        setupMutex.withLock {
            if (billing?.isReady == true) return
            withContext(Dispatchers.IO) {
                suspendCancellableCoroutine { cont ->
                    val client = BillingClient.newBuilder(context)
                        .setListener { result, purchases ->
                            when (result.responseCode) {
                                BillingClient.BillingResponseCode.OK -> {
                                    var bought = false
                                    purchases?.forEach {
                                        handlePurchase(it)
                                        if (it.purchaseState == Purchase.PurchaseState.PURCHASED &&
                                            it.products.any { id -> id in subscriptionIds }
                                        ) {
                                            bought = true
                                        }
                                    }
                                    purchaseWaiter.getAndSet(null)?.complete(
                                        if (bought || paidFromStore) PurchaseOutcome.PURCHASED else PurchaseOutcome.PENDING,
                                    )
                                }
                                BillingClient.BillingResponseCode.USER_CANCELED -> {
                                    purchaseWaiter.getAndSet(null)?.complete(PurchaseOutcome.CANCELLED)
                                }
                                BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> {
                                    purchases?.forEach { handlePurchase(it) }
                                    purchaseWaiter.getAndSet(null)?.complete(PurchaseOutcome.PURCHASED)
                                }
                                else -> {
                                    purchaseWaiter.getAndSet(null)?.complete(PurchaseOutcome.CANCELLED)
                                }
                            }
                        }
                        .enablePendingPurchases(
                            PendingPurchasesParams.newBuilder().enableOneTimeProducts().build(),
                        )
                        .build()
                    billing = client
                    client.startConnection(object : BillingClientStateListener {
                        override fun onBillingSetupFinished(result: BillingResult) {
                            if (!cont.isActive) return
                            if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                                storeUnavailable = false
                                cont.resume(Unit)
                            } else {
                                storeUnavailable = true
                                cont.resumeWithException(IllegalStateException("billing setup ${result.responseCode}"))
                            }
                        }
                        override fun onBillingServiceDisconnected() = Unit
                    })
                }
            }
        }
    }

    private suspend fun queryProductDetails(): List<StoreProduct> {
        val client = billing ?: return emptyList()
        val subs = queryDetails(
            client,
            BillingClient.ProductType.SUBS,
            listOf(
                BuildConfig.PRODUCT_PRO_MONTHLY,
                BuildConfig.PRODUCT_PRO_YEARLY,
                BuildConfig.PRODUCT_PRO_MONTHLY_PROMO,
                BuildConfig.PRODUCT_PRO_YEARLY_PROMO,
            ),
        )
        details = subs.associateBy { it.productId }
        if (details.isEmpty()) {
            catalogProducts = fallbackCatalog()
            return fallbackProducts()
        }
        catalogProducts = fallbackCatalog().mapNotNull { fallback ->
            val detail = details[fallback.id] ?: return@mapNotNull null
            val price = detail.subscriptionOfferDetails?.firstOrNull()?.pricingPhases?.pricingPhaseList?.firstOrNull()?.formattedPrice
                ?: fallback.displayPrice
            fallback.copy(displayPrice = price)
        }
        return catalogProducts.filter { !it.isPromo }.sortedBy {
            when (it.kind) {
                StoreProduct.Kind.YEARLY -> 0
                StoreProduct.Kind.MONTHLY -> 1
                StoreProduct.Kind.ONE_TIME -> 2
            }
        }
    }

    private suspend fun queryDetails(
        client: BillingClient,
        type: String,
        ids: List<String>,
    ): List<ProductDetails> = suspendCancellableCoroutine { cont ->
        val products = ids.map {
            QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(type).build()
        }
        client.queryProductDetailsAsync(
            QueryProductDetailsParams.newBuilder().setProductList(products).build(),
        ) { _: BillingResult, productDetailsList: List<ProductDetails> ->
            if (cont.isActive) cont.resume(productDetailsList)
        }
    }

    private suspend fun querySubscription(): Pair<Boolean, Long?> {
        val client = billing ?: return false to null
        return suspendCancellableCoroutine { cont ->
            client.queryPurchasesAsync(
                QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build(),
            ) { _, purchases ->
                val active = purchases.firstOrNull {
                    it.purchaseState == Purchase.PurchaseState.PURCHASED &&
                        it.products.any { id -> id in subscriptionIds }
                }
                if (cont.isActive) cont.resume((active != null) to active?.let { System.currentTimeMillis() + 30L * 24 * 60 * 60 * 1000 })
            }
        }
    }

    private suspend fun queryPurchasesAndApply() {
        val client = billing ?: return
        listOf(BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS).forEach { type ->
            suspendCancellableCoroutine { cont ->
                client.queryPurchasesAsync(
                    QueryPurchasesParams.newBuilder().setProductType(type).build(),
                ) { _, purchases ->
                    purchases.forEach { handlePurchase(it) }
                    if (cont.isActive) cont.resume(Unit)
                }
            }
        }
    }

    private fun handlePurchase(purchase: Purchase) {
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) return
        if (purchase.products.contains(BuildConfig.PRODUCT_ONE_TIME)) {
            ledger.credit(purchase.orderId ?: purchase.purchaseToken)
        }
        if (!purchase.isAcknowledged) {
            billing?.acknowledgePurchase(
                AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build(),
            ) { }
        }
        val subProduct = purchase.products.firstOrNull { it in subscriptionIds }
        val uid = accountUserId()
        val fromStore = purchase.products.any { it in subscriptionIds }
        if (fromStore) paidFromStore = true
        state = state.copy(
            isPro = !uid.isNullOrBlank() && (paidFromStore || promo.isComplimentaryUsername(accountUsername())),
            cleanupPasses = ledger.passes,
        )
        if (subProduct != null) {
            onSubscriptionPurchased?.invoke(subProduct, promo.appliedCode, purchase.purchaseToken)
        }
    }

    private val subscriptionIds = setOf(
        BuildConfig.PRODUCT_PRO_MONTHLY,
        BuildConfig.PRODUCT_PRO_YEARLY,
        BuildConfig.PRODUCT_PRO_MONTHLY_PROMO,
        BuildConfig.PRODUCT_PRO_YEARLY_PROMO,
    )
}
