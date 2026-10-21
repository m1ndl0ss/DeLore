package app.delore.android.notify

import app.delore.android.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** Mints short-lived bearer tokens. The signing key never ships in the app. */
class WorkerAuth(notifyUrl: String = BuildConfig.NOTIFY_URL) {
    private val notifyURL = notifyUrl.trim()
    private val mutex = Mutex()
    private var token: String? = null
    private var expiresAtEpochSec: Long = 0

    val isConfigured: Boolean get() = notifyURL.isNotEmpty()

    fun url(path: String): String? {
        if (notifyURL.isEmpty()) return null
        val base = when {
            notifyURL.contains("/v1/") -> notifyURL.substringBefore("/v1/")
            notifyURL.endsWith("/notify") -> notifyURL.removeSuffix("/notify")
            else -> notifyURL.trimEnd('/')
        }.trimEnd('/')
        val clean = path.trim().trimStart('/')
        return "$base/$clean"
    }

    suspend fun bearerToken(): String? = mutex.withLock {
        val now = System.currentTimeMillis() / 1000
        token?.takeIf { expiresAtEpochSec - now > 60 }?.let { return it }

        val endpoint = url("v1/token") ?: return null
        val minted = withContext(Dispatchers.IO) {
            runCatching {
                val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 4_000
                    readTimeout = 4_000
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
                }
                try {
                    connection.outputStream.use { it.write("{}".toByteArray()) }
                    if (connection.responseCode !in 200..299) return@runCatching null
                    val text = connection.inputStream.bufferedReader().use { it.readText() }
                    val json = JSONObject(text)
                    val value = json.optString("token").takeIf { it.isNotBlank() } ?: return@runCatching null
                    val exp = json.optLong("expiresAt", 0L)
                    value to exp
                } finally {
                    connection.disconnect()
                }
            }.getOrNull()
        } ?: return null

        token = minted.first
        expiresAtEpochSec = minted.second
        minted.first
    }
}
