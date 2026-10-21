package app.delore.android.notify

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/** Syncs free-unsends usage with the Retract worker (per-message increment + pull on login). */
class FreeUsageSync(private val auth: WorkerAuth) {
    suspend fun pull(userId: String): Int? = post(
        JSONObject()
            .put("op", "pull")
            .put("instagramUserId", userId)
            .put("platform", "android"),
    )

    suspend fun sync(userId: String, localUsed: Int): Int? = post(
        JSONObject()
            .put("op", "sync")
            .put("instagramUserId", userId)
            .put("freeUsed", maxOf(0, localUsed))
            .put("platform", "android"),
    )

    suspend fun increment(userId: String, idempotencyKey: String): Int? = post(
        JSONObject()
            .put("op", "increment")
            .put("instagramUserId", userId)
            .put("delta", 1)
            .put("idempotencyKey", idempotencyKey)
            .put("platform", "android"),
    )

    private suspend fun post(body: JSONObject): Int? = withContext(Dispatchers.IO) {
        if (body.optString("instagramUserId").isBlank()) return@withContext null
        val endpoint = auth.url("v1/free-usage") ?: return@withContext null
        val token = auth.bearerToken() ?: return@withContext null
        runCatching {
            val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 4_000
                readTimeout = 4_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("Authorization", "Bearer $token")
            }
            try {
                OutputStreamWriter(connection.outputStream, Charsets.UTF_8).use { it.write(body.toString()) }
                if (connection.responseCode !in 200..299) return@runCatching null
                val text = connection.inputStream.bufferedReader().use { it.readText() }
                val used = JSONObject(text).optInt("freeUsed", -1)
                if (used < 0) null else used
            } finally {
                connection.disconnect()
            }
        }.getOrNull()
    }
}
