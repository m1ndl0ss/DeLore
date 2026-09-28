package app.delore.android.billing

import android.app.Activity
import android.content.Context
import app.delore.android.BuildConfig
import app.delore.android.domain.EntitlementState
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

data class StoreProduct(
    val id: String,
    val kind: Kind,
    val displayName: String,
    val displayPrice: String,
    val monthlyEquivalent: String? = null,
) {
    enum class Kind { ONE_TIME, MONTHLY, YEARLY }
}

enum class PurchaseOutcome { PURCHASED, PENDING, CANCELLED }

class EntitlementManager(
    private val context: Context,
    private val ledger: PassLedger,
    val freeLimit: Int = BuildConfig.FREE_LIMIT,
) {
    var state: EntitlementState = EntitlementState(cleanupPasses = ledger.passes, freeMessagesUsed = ledger.freeMessagesUsed)
        private set
    var products: List<StoreProduct> = fallbackProducts()
        private set
    var isLoadingProducts: Boolean = false
        private set
    var storeUnavailable: Boolean = false
        private set
    var isPurchasing: Boolean = false
        private set

    val isPro: Boolean get() = state.isPro
    val remainingFree: Int get() = maxOf(0, freeLimit - state.freeMessagesUsed)

    private var billing: BillingClient? = null
    private var details: Map<String, ProductDetails> = emptyMap()

    fun allowance(requestedCount: Int, usesAdvancedFilters: Boolean) =
        app.delore.android.domain.CleanupAllowance.evaluate(requestedCount, usesAdvancedFilters, state, freeLimit)

    fun consumePass(): Boolean {
        val consumed = ledger.consumePass()
        state = state.copy(cleanupPasses = ledger.passes)
        return consumed
    }

    fun recordFreeUsage(count: Int) {
        ledger.addFreeUsage(count)
        state = state.copy(freeMessagesUsed = ledger.freeMessagesUsed)
    }

    suspend fun refresh() {
        val subscription = querySubscription()
        state = EntitlementState(
            isPro = subscription.first,
            proRenewsOrExpiresAt = subscription.second,
            cleanupPasses = ledger.passes,
            freeMessagesUsed = ledger.freeMessagesUsed,
        )
    }

    suspend fun loadProducts() {
        if (isLoadingProducts) return
        isLoadingProducts = true
        try {
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

    suspend fun purchase(activity: Activity, product: StoreProduct): PurchaseOutcome? {
        if (isPurchasing) return null
        isPurchasing = true
        return try {
            ensureClient()
            val detail = details[product.id] ?: return null.also { storeUnavailable = true }
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
            if (result?.responseCode == BillingClient.BillingResponseCode.OK) PurchaseOutcome.PENDING else null
        } catch (_: Exception) {
            storeUnavailable = true
            null
        } finally {
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
        StoreProduct(BuildConfig.PRODUCT_ONE_TIME, StoreProduct.Kind.ONE_TIME, "One-time cleanup", "$9.99"),
    )

    private suspend fun ensureClient() {
        if (billing?.isReady == true) return
        withContext(Dispatchers.IO) {
            suspendCancellableCoroutine { cont ->
                val client = BillingClient.newBuilder(context)
                    .setListener { _, purchases ->
                        purchases?.forEach { handlePurchase(it) }
                    }
                    .enablePendingPurchases(
                        PendingPurchasesParams.newBuilder().enableOneTimeProducts().build(),
                    )
                    .build()
                billing = client
                client.startConnection(object : BillingClientStateListener {
                    override fun onBillingSetupFinished(result: BillingResult) {
                        if (cont.isActive) cont.resume(Unit)
                    }
                    override fun onBillingServiceDisconnected() = Unit
                })
            }
        }
    }

    private suspend fun queryProductDetails(): List<StoreProduct> {
        val client = billing ?: return emptyList()
        val inApp = queryDetails(client, BillingClient.ProductType.INAPP, listOf(BuildConfig.PRODUCT_ONE_TIME))
        val subs = queryDetails(
            client,
            BillingClient.ProductType.SUBS,
            listOf(BuildConfig.PRODUCT_PRO_MONTHLY, BuildConfig.PRODUCT_PRO_YEARLY),
        )
        details = (inApp + subs).associateBy { it.productId }
        return fallbackProducts().map { fallback ->
            val detail = details[fallback.id] ?: return@map fallback
            val price = when (fallback.kind) {
                StoreProduct.Kind.ONE_TIME -> detail.oneTimePurchaseOfferDetails?.formattedPrice
                else -> detail.subscriptionOfferDetails?.firstOrNull()?.pricingPhases?.pricingPhaseList?.firstOrNull()?.formattedPrice
            } ?: fallback.displayPrice
            fallback.copy(displayPrice = price)
        }.sortedBy {
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
        ) { _, result ->
            val list = result.productDetailsList.orEmpty()
            if (cont.isActive) cont.resume(list)
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
                        it.products.any { id -> id == BuildConfig.PRODUCT_PRO_MONTHLY || id == BuildConfig.PRODUCT_PRO_YEARLY }
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
        state = state.copy(isPro = purchase.products.any {
            it == BuildConfig.PRODUCT_PRO_MONTHLY || it == BuildConfig.PRODUCT_PRO_YEARLY
        } || state.isPro, cleanupPasses = ledger.passes)
    }
}
