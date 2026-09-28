package app.delore.android.instagram

import app.delore.android.domain.AccountIdentity
import app.delore.android.domain.HTTPResponse
import app.delore.android.domain.IntegrationError
import app.delore.android.domain.MessageKind
import app.delore.android.domain.ParticipantID
import app.delore.android.domain.UnsendOutcome
import kotlinx.serialization.Serializable
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

object InstagramWebConstants {
    const val BASE = "https://www.instagram.com"
    const val WEB_APP_ID = "936619743392459"
    const val LOGIN_URL = "https://www.instagram.com/accounts/login/"
    const val INBOX_REFERER = "https://www.instagram.com/direct/inbox/"
    const val CHROME_USER_AGENT =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
}

object InstagramLoginPolicy {
    val allowedHostSuffixes = listOf(
        "instagram.com",
        "cdninstagram.com",
        "facebook.com",
        "fbcdn.net",
        "facebook.net",
        "meta.com",
        "accountkit.com",
    )

    fun allowsNavigation(url: String): Boolean {
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        val scheme = uri.scheme?.lowercase() ?: return false
        if (scheme == "about") return true
        if (scheme != "https") return false
        val host = uri.host?.lowercase()?.trim('.') ?: return false
        return allowedHostSuffixes.any { host == it || host.endsWith(".$it") }
    }

    fun isInstagramCookieDomain(domain: String): Boolean {
        val trimmed = domain.lowercase().trim('.')
        return trimmed == "instagram.com" || trimmed.endsWith(".instagram.com")
    }
}

@Serializable
data class InstagramWebSession(
    val cookies: List<Cookie>,
    val userID: String,
    val displayName: String? = null,
) {
    @Serializable
    data class Cookie(
        val name: String,
        val value: String,
        val domain: String,
        val path: String,
        val isSecure: Boolean,
        val expiresAt: Long? = null,
    )

    val ownerID: ParticipantID get() = ParticipantID("ig:$userID")
    val csrfToken: String?
        get() = cookies.firstOrNull { it.name.equals("csrftoken", ignoreCase = true) }?.value
    val hasLiveSession: Boolean
        get() = userID.isNotEmpty() && cookies.any { it.name.equals("sessionid", ignoreCase = true) && it.value.isNotEmpty() }
    val account: AccountIdentity
        get() = AccountIdentity(ownerID, displayName ?: "you")

    fun cookieHeader(): String = cookies.joinToString("; ") { "${it.name}=${it.value}" }

    companion object {
        fun from(cookies: List<Cookie>): InstagramWebSession? {
            val instagramCookies = cookies.filter {
                it.value.isNotEmpty() && InstagramLoginPolicy.isInstagramCookieDomain(it.domain)
            }
            val sessionCookie = instagramCookies.firstOrNull { it.name.equals("sessionid", ignoreCase = true) }
            val userCookie = instagramCookies.firstOrNull { it.name.equals("ds_user_id", ignoreCase = true) }
            val csrfCookie = instagramCookies.firstOrNull { it.name.equals("csrftoken", ignoreCase = true) }
            if (sessionCookie == null || csrfCookie == null || userCookie == null) return null
            return InstagramWebSession(instagramCookies, userCookie.value)
        }
    }
}

object InstagramResponseClassifier {
    fun classify(response: HTTPResponse, destructive: Boolean): IntegrationError? {
        statusError(response.statusCode, retryAfter(response), destructive)?.let { fromStatus ->
            if (response.statusCode == 403 || response.statusCode == 400) {
                bodyError(response.body, destructive)?.let { return it }
            }
            return fromStatus
        }
        return bodyError(response.body, destructive)
    }

    fun throwIfNeeded(response: HTTPResponse, destructive: Boolean) {
        classify(response, destructive)?.let { throw it }
    }

    private fun retryAfter(response: HTTPResponse): Double? =
        response.header("Retry-After")?.toDoubleOrNull()

    private fun statusError(code: Int, retryAfter: Double?, destructive: Boolean): IntegrationError? = when (code) {
        in 200..299 -> null
        401 -> IntegrationError.SessionExpired
        429 -> IntegrationError.RateLimited(retryAfter)
        in 500..599 -> IntegrationError.ServerUnavailable
        403, 400 -> IntegrationError.UnexpectedResponse(code)
        else -> IntegrationError.UnexpectedResponse(code)
    }

    private fun bodyError(body: ByteArray, destructive: Boolean): IntegrationError? {
        if (body.isEmpty()) return null
        val text = body.decodeToString()
        val objectJson = runCatching { JSONObject(text) }.getOrNull()
        if (objectJson == null) {
            if (looksLikeHtml(body)) {
                val html = text.take(4_000).lowercase()
                if ("checkpoint" in html || "/challenge" in html) return IntegrationError.VerificationRequired
                if ("login" in html) return IntegrationError.SessionExpired
            }
            return null
        }
        val blob = flatten(objectJson).lowercase()
        if ("checkpoint_required" in blob || "challenge_required" in blob || "\"challenge\"" in blob || "/challenge/" in blob) {
            return IntegrationError.VerificationRequired
        }
        if ("login_required" in blob || "not_logged_in" in blob) return IntegrationError.SessionExpired
        if ("feedback_required" in blob || "spam" in blob || "please wait a few minutes" in blob) {
            return IntegrationError.RateLimited(null)
        }
        if ("rate limit" in blob || "too many" in blob) return IntegrationError.RateLimited(null)
        val status = objectJson.optString("status").lowercase()
        if (status == "fail" || status == "error") {
            if ("not found" in blob || "does not exist" in blob || "no longer" in blob) return null
            return IntegrationError.UnexpectedResponse(null)
        }
        return null
    }

    private fun looksLikeHtml(data: ByteArray): Boolean {
        val prefix = data.decodeToString(0, minOf(32, data.size)).lowercase()
        return prefix.contains("<!doctype") || prefix.contains("<html")
    }

    private fun flatten(value: Any?): String = when (value) {
        is JSONObject -> {
            val keys = value.keys().asSequence().toList()
            keys.joinToString(" ") + " " + keys.joinToString(" ") { flatten(value.opt(it)) }
        }
        is JSONArray -> (0 until minOf(20, value.length())).joinToString(" ") { flatten(value.opt(it)) }
        is String -> if (value.length > 120) value.take(120) else value
        else -> ""
    }
}

object InstagramDeleteParse {
    fun outcome(from: HTTPResponse): UnsendOutcome {
        val obj = runCatching { JSONObject(from.body.decodeToString()) }.getOrNull() ?: return UnsendOutcome.UNSENT
        val blob = (obj.optString("message") + obj.optString("error_title")).lowercase()
        return if ("not found" in blob || "already" in blob || "no longer" in blob) {
            UnsendOutcome.ALREADY_GONE
        } else {
            UnsendOutcome.UNSENT
        }
    }
}

data class InboxThreadStub(
    val threadID: String,
    val threadTitle: String?,
    val users: List<InboxUser>,
)

data class InboxUser(
    val pk: String?,
    val username: String?,
    val fullName: String?,
)

data class InboxPage(
    val threads: List<InboxThreadStub>,
    val hasOlder: Boolean,
    val oldestCursor: String?,
    val viewerUsername: String?,
)

data class ThreadItem(
    val itemID: String,
    val authorID: String?,
    val sentAtMillis: Long,
    val kind: MessageKind,
    val isSystem: Boolean,
    val sentByViewer: Boolean?,
)

data class ThreadPage(
    val items: List<ThreadItem>,
    val hasOlder: Boolean,
    val oldestCursor: String?,
)

object InstagramWebFormat {
    fun parseInbox(body: ByteArray): InboxPage {
        val root = JSONObject(body.decodeToString())
        val inbox = root.optJSONObject("inbox")
        val viewer = root.optJSONObject("viewer")
        val threadsJson = inbox?.optJSONArray("threads") ?: JSONArray()
        val threads = buildList {
            for (i in 0 until threadsJson.length()) {
                val t = threadsJson.getJSONObject(i)
                add(
                    InboxThreadStub(
                        threadID = flexibleId(t, "thread_id"),
                        threadTitle = t.optString("thread_title").ifBlank { null },
                        users = parseUsers(t.optJSONArray("users")),
                    ),
                )
            }
        }
        return InboxPage(
            threads = threads,
            hasOlder = inbox?.optBoolean("has_older") ?: false,
            oldestCursor = inbox?.optString("oldest_cursor")?.ifBlank { null },
            viewerUsername = viewer?.optString("username")?.ifBlank { null },
        )
    }

    fun parseThread(body: ByteArray): ThreadPage {
        val root = JSONObject(body.decodeToString())
        val thread = root.optJSONObject("thread")
        val itemsJson = thread?.optJSONArray("items") ?: JSONArray()
        val items = buildList {
            for (i in 0 until itemsJson.length()) {
                add(parseItem(itemsJson.getJSONObject(i)))
            }
        }
        return ThreadPage(
            items = items,
            hasOlder = thread?.optBoolean("has_older") ?: false,
            oldestCursor = thread?.optString("oldest_cursor")?.ifBlank { null },
        )
    }

    fun title(stub: InboxThreadStub, ownerID: String): String {
        val titled = stub.threadTitle?.trim().orEmpty()
        if (titled.isNotEmpty() && titled != "Instagram User") return titled
        val others = stub.users.mapNotNull { user ->
            if (user.pk == ownerID) null else user.fullName?.takeIf { it.isNotEmpty() } ?: user.username
        }
        return if (others.isEmpty()) "Chat" else others.joinToString(", ")
    }

    private fun parseUsers(array: JSONArray?): List<InboxUser> {
        array ?: return emptyList()
        return buildList {
            for (i in 0 until array.length()) {
                val u = array.getJSONObject(i)
                add(
                    InboxUser(
                        pk = flexibleIdOrNull(u, "pk"),
                        username = u.optString("username").ifBlank { null },
                        fullName = u.optString("full_name").ifBlank { null },
                    ),
                )
            }
        }
    }

    private fun parseItem(obj: JSONObject): ThreadItem {
        val type = obj.optString("item_type", "text").lowercase()
        return ThreadItem(
            itemID = flexibleId(obj, "item_id"),
            authorID = flexibleIdOrNull(obj, "user_id"),
            sentAtMillis = dateFrom(obj.optLong("timestamp")),
            kind = kindFor(type),
            isSystem = type in setOf("action_log", "video_call_event", "profile", "live_viewer_invite", "info"),
            sentByViewer = if (obj.has("is_sent_by_viewer")) obj.optBoolean("is_sent_by_viewer") else null,
        )
    }

    private fun dateFrom(raw: Long): Long = when {
        raw > 10_000_000_000_000L -> raw / 1_000
        raw > 10_000_000_000L -> raw
        else -> raw * 1_000
    }

    private fun kindFor(type: String): MessageKind = when (type) {
        "voice_media", "audio" -> MessageKind.VOICE
        "media", "raven_media", "animated_media", "clip", "media_share", "reel_share",
        "story_share", "felix_share", "xma_media_share", "generic_xma",
        -> MessageKind.MEDIA
        "link", "xma_link" -> MessageKind.LINK
        "text", "placeholder" -> MessageKind.TEXT
        else -> MessageKind.OTHER
    }

    private fun flexibleId(obj: JSONObject, key: String): String {
        if (!obj.has(key) || obj.isNull(key)) return ""
        return obj.optString(key).ifBlank { obj.optLong(key).toString() }
    }

    private fun flexibleIdOrNull(obj: JSONObject, key: String): String? {
        val value = flexibleId(obj, key)
        return value.takeIf { it.isNotEmpty() && it != "0" }
    }
}
