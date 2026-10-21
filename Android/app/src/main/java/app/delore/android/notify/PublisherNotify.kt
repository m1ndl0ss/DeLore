package app.delore.android.notify

import android.content.SharedPreferences
import android.util.Log
import app.delore.android.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant

/**
 * Fire-and-forget ops ping to the publisher notify worker.
 * Auth is a short-lived worker token — no shared secret in the app.
 */
class PublisherNotify(
    private val prefs: SharedPreferences,
    private val isEnabled: () -> Boolean,
    private val resolveUsername: () -> String?,
    val auth: WorkerAuth = WorkerAuth(),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val freeUsage = FreeUsageSync(auth)

    fun instagramConnected(userId: String, username: String) {
        val handle = clean(username) ?: return
        postOnce(
            prefKey = "notify.connect.$userId",
            event = "instagram_connected",
            username = handle,
            idempotencyKey = "connect:$userId:${dayStamp()}",
        )
    }

    fun subscriptionPurchased(
        username: String?,
        productId: String,
        promoCode: String?,
        purchaseToken: String,
    ) {
        val handle = clean(username ?: resolveUsername()) ?: return
        postOnce(
            prefKey = "notify.purchase.$purchaseToken",
            event = "subscription_purchased",
            username = handle,
            productId = productId,
            promoCode = promoCode,
            idempotencyKey = "purchase:$purchaseToken",
        )
    }

    fun complimentaryUnlocked(userId: String?, username: String?, promoCode: String) {
        val handle = clean(username ?: resolveUsername()) ?: return
        val id = userId ?: handle
        postOnce(
            prefKey = "notify.comp.$id.$promoCode",
            event = "complimentary_unlocked",
            username = handle,
            promoCode = promoCode,
            idempotencyKey = "comp:$id:$promoCode",
        )
    }

    private fun postOnce(
        prefKey: String,
        event: String,
        username: String,
        productId: String? = null,
        promoCode: String? = null,
        idempotencyKey: String,
    ) {
        if (!isEnabled()) return
        if (prefs.getBoolean(prefKey, false)) return
        if (!auth.isConfigured) {
            if (BuildConfig.DEBUG) {
                Log.w("Retract", "notify skipped: set NOTIFY_URL in android/local.properties")
            }
            return
        }

        prefs.edit().putBoolean(prefKey, true).apply()

        scope.launch {
            val ok = runCatching {
                val token = auth.bearerToken() ?: return@runCatching false
                val endpoint = auth.url("v1/notify") ?: return@runCatching false
                val body = JSONObject()
                    .put("event", event)
                    .put("instagramUsername", username)
                    .put("platform", "android")
                    .put("occurredAt", Instant.now().toString())
                    .put("idempotencyKey", idempotencyKey)
                if (!productId.isNullOrBlank()) body.put("productId", productId)
                if (!promoCode.isNullOrBlank()) body.put("promoCode", promoCode)

                val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 2_500
                    readTimeout = 2_500
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    setRequestProperty("Authorization", "Bearer $token")
                }
                try {
                    OutputStreamWriter(connection.outputStream, Charsets.UTF_8).use { it.write(body.toString()) }
                    connection.responseCode in 200..299
                } finally {
                    connection.disconnect()
                }
            }.getOrElse {
                Log.d("Retract", "notify skipped: ${it.javaClass.simpleName}")
                false
            }
            if (!ok) {
                prefs.edit().putBoolean(prefKey, false).apply()
            }
        }
    }

    companion object {
        fun clean(raw: String?): String? {
            if (raw.isNullOrBlank()) return null
            val trimmed = raw.trim().removePrefix("@")
            if (trimmed.isEmpty() || trimmed.equals("you", ignoreCase = true)) return null
            if (trimmed.length > 64 || !trimmed.matches(Regex("^[A-Za-z0-9._]+$"))) return null
            return trimmed
        }

        private fun dayStamp(): String =
            java.time.LocalDate.now(java.time.ZoneOffset.UTC).toString()
    }
}
