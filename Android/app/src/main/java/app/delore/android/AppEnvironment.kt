package app.delore.android

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import app.delore.android.billing.EntitlementManager
import app.delore.android.billing.PromoVault
import app.delore.android.domain.ConversationID
import app.delore.android.domain.InboxReadProgress
import app.delore.android.domain.LibraryOverview
import app.delore.android.engine.CleanupEngineDependencies
import app.delore.android.engine.RatePolicy
import app.delore.android.instagram.InstagramHTTPClient
import app.delore.android.instagram.InstagramInboxSync
import app.delore.android.instagram.InstagramWebSession
import app.delore.android.instagram.InstagramWebUnsendService
import app.delore.android.instagram.InstagramWebViewGateway
import app.delore.android.instagram.defaultOkHttp
import app.delore.android.notify.PublisherNotify
import app.delore.android.persist.CleanupHistoryStore
import app.delore.android.persist.FileCleanupHistoryStore
import app.delore.android.persist.FileJobStore
import app.delore.android.persist.InMemoryCleanupHistoryStore
import app.delore.android.persist.InMemoryJobStore
import app.delore.android.persist.InboxWorkStore
import app.delore.android.persist.JobStore
import app.delore.android.persist.LocalLibraryStore
import app.delore.android.secrets.BillingLedger
import app.delore.android.secrets.EncryptedSecretStore
import app.delore.android.secrets.PassLedger
import app.delore.android.secrets.SecretStore
import app.delore.android.secrets.SessionVault
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

class AppEnvironment(private val context: Context) {
    val ratePolicy: RatePolicy
        get() = if (isDemoMode) RatePolicy.review else RatePolicy.conservative
    val secrets: SecretStore = EncryptedSecretStore(context)
    val sessionVault = SessionVault(secrets)
    val ledger = PassLedger(secrets)
    val promo = PromoVault(secrets)
    val library = LocalLibraryStore(File(context.filesDir, "library"))
    val jobStore: JobStore = runCatching {
        FileJobStore(File(context.filesDir, "jobs"))
    }.getOrElse { InMemoryJobStore() }
    val history: CleanupHistoryStore = runCatching {
        FileCleanupHistoryStore(File(context.filesDir, "history"))
    }.getOrElse { InMemoryCleanupHistoryStore() }
    val prefs: SharedPreferences = context.getSharedPreferences("retract", Context.MODE_PRIVATE)
    val publisherNotify = PublisherNotify(
        prefs = prefs,
        isEnabled = { !isDemoMode },
        resolveUsername = { loadSession()?.displayName },
    )
    val entitlements = EntitlementManager(
        context,
        ledger,
        promo,
        onSubscriptionPurchased = { productId, promoCode, token ->
            publisherNotify.subscriptionPurchased(
                username = loadSession()?.displayName,
                productId = productId,
                promoCode = promoCode,
                purchaseToken = token,
            )
        },
        onComplimentaryUnlocked = { code ->
            publisherNotify.complimentaryUnlocked(
                userId = loadSession()?.userID,
                username = loadSession()?.displayName,
                promoCode = code,
            )
        },
    )
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    val inboxWork = InboxWorkStore(prefs, json)
    val webBrowser = InstagramWebViewGateway()
    private val http = InstagramHTTPClient(defaultOkHttp(), { loadSession() }, webBrowser)
    private val liveUnsender = InstagramWebUnsendService(http, ownerID = { loadSession()?.userID })
    private val demoUnsender = app.delore.android.domain.ReviewDemoUnsendService()
    val unsender: app.delore.android.domain.UnsendService
        get() = if (isDemoMode) demoUnsender else liveUnsender

    val hasLibrary: Boolean get() = library.hasLibrary
    val hasLiveSession: Boolean get() = loadSession()?.hasLiveSession == true
    val isCleanupAvailable: Boolean get() = hasLiveSession || isDemoMode
    var isDemoMode: Boolean
        get() = prefs.getBoolean(DEMO_KEY, false)
        set(value) { prefs.edit().putBoolean(DEMO_KEY, value).apply() }
    var hasCompletedOnboarding: Boolean
        get() = prefs.getBoolean("onboarding.completed", false)
        set(value) { prefs.edit().putBoolean("onboarding.completed", value).apply() }

    var acceptedTermsVersion: Int
        get() = prefs.getInt("terms.acceptedVersion", 0)
        set(value) { prefs.edit().putInt("terms.acceptedVersion", value).apply() }

    val hasAcceptedTerms: Boolean
        get() = acceptedTermsVersion >= app.delore.android.ui.LegalCopy.TERMS_VERSION

    var inboxHoldOffUntilMillis: Long
        get() = prefs.getLong("inbox.holdOffUntil", 0L)
        set(value) { prefs.edit().putLong("inbox.holdOffUntil", value).apply() }

    var inboxListCursor: String?
        get() = prefs.getString("inbox.listCursor", null)?.ifBlank { null }
        set(value) {
            val editor = prefs.edit()
            if (value.isNullOrBlank()) editor.remove("inbox.listCursor") else editor.putString("inbox.listCursor", value)
            editor.apply()
        }

    fun dropStaleFullInbox() {
        if (isDemoMode) return
        if (prefs.getBoolean("inbox.listFirst", false)) return
        library.wipe()
        jobStore.wipe()
        prefs.edit().putBoolean("inbox.listFirst", true).remove("inbox.listCursor").apply()
    }

    fun isOnline(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    fun enterReviewDemo() {
        jobStore.wipe()
        app.delore.android.domain.ReviewDemo.seed(library)
        saveRetractQueue(emptySet())
        inboxWork.clear()
        inboxListCursor = null
        isDemoMode = true
    }

    fun saveSession(session: InstagramWebSession) {
        isDemoMode = false
        sessionVault.save(json.encodeToString(session))
    }

    fun loadSession(): InstagramWebSession? {
        val raw = sessionVault.load() ?: return null
        return runCatching { json.decodeFromString<InstagramWebSession>(raw) }.getOrNull()
    }

    suspend fun listInbox(onProgress: ((InboxReadProgress) -> Unit)?): LibraryOverview {
        val session = loadSession()?.takeIf { it.hasLiveSession } ?: throw app.delore.android.domain.IntegrationError.SessionExpired
        val resume = inboxListCursor
        return kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val overview = InstagramInboxSync(http, library).list(session, resume, onProgress) { cursor ->
                inboxListCursor = cursor
            }
            maybeNotifyConnected()
            overview
        }
    }

    suspend fun loadInbox(
        ids: Collection<ConversationID>,
        titles: Map<String, String> = emptyMap(),
        forceRefresh: Boolean = false,
        onProgress: ((InboxReadProgress) -> Unit)?,
    ): LibraryOverview {
        val session = loadSession()?.takeIf { it.hasLiveSession } ?: throw app.delore.android.domain.IntegrationError.SessionExpired
        return kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val overview = InstagramInboxSync(http, library).load(session, ids, titles, forceRefresh, onProgress)
            maybeNotifyConnected()
            overview
        }
    }

    private suspend fun maybeNotifyConnected() {
        if (isDemoMode) return
        val session = loadSession()?.takeIf { it.hasLiveSession } ?: return
        val fromLibrary = runCatching { library.account().displayName }.getOrNull()
        val username = PublisherNotify.clean(session.displayName)
            ?: PublisherNotify.clean(fromLibrary)
            ?: return
        if (session.displayName.isNullOrBlank() || session.displayName == "you") {
            saveSession(session.copy(displayName = username))
        }
        publisherNotify.instagramConnected(session.userID, username)
    }

    suspend fun loadOverview(): LibraryOverview {
        val cleaned = jobStore.loadLedger()
        return library.overviewExcluding(cleaned)
    }

    fun engineDependencies() = CleanupEngineDependencies(
        store = jobStore,
        unsender = unsender,
        policy = ratePolicy,
        history = history,
    )

    /** Signs out of Instagram on this phone. Keeps Pro, passes, terms acceptance, and onboarding. */
    fun disconnectInstagram() {
        sessionVault.clear()
        jobStore.wipe()
        library.wipe()
        history.wipe()
        inboxWork.clear()
        inboxListCursor = null
        saveRetractQueue(emptySet())
        prefs.edit().remove("inbox.holdOffUntil").apply()
        isDemoMode = false
        webBrowser.destroy()
    }

    fun eraseAllData() {
        val eraserKeys = PassLedger.preservedKeys + PromoVault.COMPLIMENTARY_KEY
        secrets.wipePreserving(eraserKeys)
        jobStore.wipe()
        library.wipe()
        history.wipe()
        BillingLedger.clearAll(prefs)
        prefs.edit()
            .remove("onboarding.completed")
            .remove("terms.acceptedVersion")
            .remove("inbox.holdOffUntil")
            .remove("inbox.listFirst")
            .remove("inbox.listCursor")
            .remove(InboxWorkStore.KEY)
            .remove(RETRACT_QUEUE_KEY)
            .remove(DEMO_KEY)
            .apply()
        val clearNotify = prefs.edit()
        prefs.all.keys.filter { it.startsWith("notify.") }.forEach { clearNotify.remove(it) }
        clearNotify.apply()
        webBrowser.destroy()
    }

    fun saveRetractQueue(ids: Collection<ConversationID>) {
        val raw = ids.map { it.rawValue }
        if (raw.isEmpty()) {
            prefs.edit().remove(RETRACT_QUEUE_KEY).apply()
        } else {
            prefs.edit().putString(RETRACT_QUEUE_KEY, json.encodeToString(raw)).apply()
        }
    }

    fun loadRetractQueue(): Set<ConversationID> {
        val raw = prefs.getString(RETRACT_QUEUE_KEY, null) ?: return emptySet()
        return runCatching { json.decodeFromString<List<String>>(raw) }
            .getOrDefault(emptyList())
            .map(::ConversationID)
            .toSet()
    }

    companion object {
        private const val RETRACT_QUEUE_KEY = "inbox.retractQueue"
        private const val DEMO_KEY = "review.demo"
    }
}
