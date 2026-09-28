package app.delore.android

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import app.delore.android.billing.EntitlementManager
import app.delore.android.domain.LibraryOverview
import app.delore.android.engine.CleanupEngineDependencies
import app.delore.android.engine.RatePolicy
import app.delore.android.instagram.InstagramHTTPClient
import app.delore.android.instagram.InstagramInboxSync
import app.delore.android.instagram.InstagramWebSession
import app.delore.android.instagram.InstagramWebUnsendService
import app.delore.android.instagram.defaultOkHttp
import app.delore.android.persist.FileJobStore
import app.delore.android.persist.InMemoryJobStore
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
    val ratePolicy: RatePolicy = RatePolicy.conservative
    val secrets: SecretStore = EncryptedSecretStore(context)
    val sessionVault = SessionVault(secrets)
    val ledger = PassLedger(secrets)
    val entitlements = EntitlementManager(context, ledger)
    val library = LocalLibraryStore(File(context.filesDir, "library"))
    val jobStore: JobStore = runCatching {
        FileJobStore(File(context.filesDir, "jobs"))
    }.getOrElse { InMemoryJobStore() }
    val prefs: SharedPreferences = context.getSharedPreferences("delore", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val http = InstagramHTTPClient(defaultOkHttp()) { loadSession() }
    val unsender = InstagramWebUnsendService(http, ownerID = { loadSession()?.userID })

    val hasLibrary: Boolean get() = library.hasLibrary
    val hasLiveSession: Boolean get() = loadSession()?.hasLiveSession == true
    val isCleanupAvailable: Boolean get() = hasLiveSession
    var hasCompletedOnboarding: Boolean
        get() = prefs.getBoolean("onboarding.completed", false)
        set(value) { prefs.edit().putBoolean("onboarding.completed", value).apply() }

    fun isOnline(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    fun saveSession(session: InstagramWebSession) {
        sessionVault.save(json.encodeToString(session))
    }

    fun loadSession(): InstagramWebSession? {
        val raw = sessionVault.load() ?: return null
        return runCatching { json.decodeFromString<InstagramWebSession>(raw) }.getOrNull()
    }

    suspend fun syncInbox(onProgress: ((Double) -> Unit)?): LibraryOverview {
        val session = loadSession()?.takeIf { it.hasLiveSession } ?: throw app.delore.android.domain.IntegrationError.SessionExpired
        return InstagramInboxSync(http, library).run(session, onProgress)
    }

    suspend fun loadOverview(): LibraryOverview {
        val cleaned = jobStore.loadLedger()
        return library.overviewExcluding(cleaned)
    }

    fun engineDependencies() = CleanupEngineDependencies(
        store = jobStore,
        unsender = unsender,
        policy = ratePolicy,
    )

    fun eraseAllData() {
        val eraserKeys = PassLedger.preservedKeys
        secrets.wipePreserving(eraserKeys)
        jobStore.wipe()
        library.wipe()
        BillingLedger.clearAll(prefs)
        prefs.edit().remove("onboarding.completed").apply()
    }
}
