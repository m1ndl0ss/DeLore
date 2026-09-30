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
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.6778.139 Safari/537.36"
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

    fun isPostLogin(url: String): Boolean {
        if (!allowsNavigation(url)) return false
        val path = runCatching { URI(url).path?.lowercase().orEmpty() }.getOrDefault("")
        if (path.contains("/accounts/login")) return false
        if (path.contains("/accounts/emailsignup")) return false
        if (path.contains("/challenge")) return false
        if (path.contains("/two_factor")) return false
        if (path.contains("/accounts/password")) return false
        return true
    }

    fun isDirectSurface(url: String): Boolean {
        if (!allowsNavigation(url)) return false
        val path = runCatching { URI(url).path?.lowercase().orEmpty() }.getOrDefault("")
        return path.startsWith("/direct/")
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
    val wwwClaimCookie: String?
        get() = cookies.firstOrNull { it.name.equals("ig_www_claim", ignoreCase = true) }?.value
            ?.takeIf { it.isNotEmpty() && it != "0" }
    val hasLiveSession: Boolean
        get() = userID.isNotEmpty() && cookies.any { it.name.equals("sessionid", ignoreCase = true) && it.value.isNotEmpty() }
    val account: AccountIdentity
        get() = AccountIdentity(ownerID, displayName ?: "you")

    fun cookieHeader(): String = cookies.joinToString("; ") { "${it.name}=${it.value}" }

    fun installIntoCookieManager() {
        val manager = android.webkit.CookieManager.getInstance()
        manager.setAcceptCookie(true)
        for (cookie in cookies) {
            val domain = cookie.domain.ifBlank { ".instagram.com" }
            val path = cookie.path.ifBlank { "/" }
            val header = buildString {
                append(cookie.name).append('=').append(cookie.value)
                append("; Domain=").append(domain)
                append("; Path=").append(path)
                if (cookie.isSecure) append("; Secure")
            }
            manager.setCookie("https://www.instagram.com", header)
            manager.setCookie("https://instagram.com", header)
        }
        manager.flush()
    }

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
                if ("/accounts/login" in html || "login_required" in html) return IntegrationError.SessionExpired
                return IntegrationError.UnexpectedResponse(null)
            }
            return null
        }
        val status = objectJson.optString("status").lowercase()
        val envelope = envelopeText(objectJson)
        if ("checkpoint_required" in envelope || "challenge_required" in envelope) {
            return IntegrationError.VerificationRequired
        }
        if ("login_required" in envelope || "not_logged_in" in envelope) return IntegrationError.SessionExpired
        val spamFlag = objectJson.optBoolean("spam") || objectJson.optString("spam").equals("true", true)
        val feedbackFlag = objectJson.optBoolean("feedback_required") ||
            objectJson.optString("feedback_required").equals("true", true) ||
            objectJson.optString("message").equals("feedback_required", true) ||
            objectJson.optString("error_type").equals("feedback_required", true)
        if (feedbackFlag || (spamFlag && status != "ok")) {
            return IntegrationError.RateLimited(null)
        }
        if ("please wait a few minutes" in envelope || "rate limit" in envelope) {
            return IntegrationError.RateLimited(null)
        }
        if (status == "ok" || status == "success") return null
        if (objectJson.has("inbox") || objectJson.has("thread") || objectJson.has("items")) return null
        if (status == "fail" || status == "error") {
            if ("not found" in envelope || "does not exist" in envelope || "no longer" in envelope) return null
            return IntegrationError.UnexpectedResponse(null)
        }
        return null
    }

    /** Instagram's own error envelope — never nested DM text. */
    private fun envelopeText(objectJson: JSONObject): String = listOf(
        objectJson.optString("status"),
        objectJson.optString("message"),
        objectJson.optString("error_type"),
        objectJson.optString("error_title"),
        objectJson.optString("error_message"),
        objectJson.opt("feedback_required")?.toString().orEmpty(),
        objectJson.opt("spam")?.toString().orEmpty(),
        objectJson.opt("checkpoint_required")?.toString().orEmpty(),
        objectJson.opt("challenge_required")?.toString().orEmpty(),
    ).joinToString(" ").lowercase()

    fun looksLikeHtml(data: ByteArray): Boolean {
        val prefix = data.decodeToString(0, minOf(32, data.size)).lowercase()
        return prefix.contains("<!doctype") || prefix.contains("<html")
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

object InstagramWebBootstrap {
    private val asbd = Regex("\"ASBD_ID\"\\s*:\\s*\"(\\d+)\"")
    private val claim = Regex("\"www_claim\"\\s*:\\s*\"([^\"]+)\"")

    fun asbdID(html: String): String? = asbd.find(html)?.groupValues?.getOrNull(1)?.takeIf { it.isNotEmpty() }

    fun wwwClaim(html: String): String? = claim.find(html)?.groupValues?.getOrNull(1)
        ?.takeIf { it.isNotEmpty() && it != "0" }
}

object InstagramWebFormat {
    fun topKeys(body: ByteArray): String {
        if (body.isEmpty()) return "empty"
        if (InstagramResponseClassifier.looksLikeHtml(body)) return "html"
        val root = runCatching { JSONObject(body.decodeToString()) }.getOrNull() ?: return "not-json"
        return root.keys().asSequence().take(12).joinToString(",")
    }

    fun parseInbox(body: ByteArray): InboxPage {
        val root = JSONObject(body.decodeToString())
        val inbox = root.optJSONObject("inbox")
            ?: root.optJSONObject("data")?.optJSONObject("inbox")
            ?: throw IllegalArgumentException("missing inbox (${topKeys(body)})")
        val viewer = root.optJSONObject("viewer") ?: root.optJSONObject("data")?.optJSONObject("viewer")
        val threadsJson = inbox.optJSONArray("threads") ?: JSONArray()
        val threads = buildList {
            for (i in 0 until threadsJson.length()) {
                val t = threadsJson.optJSONObject(i) ?: continue
                val threadID = threadId(t) ?: continue
                add(
                    InboxThreadStub(
                        threadID = threadID,
                        threadTitle = t.optString("thread_title").ifBlank { null },
                        users = parseUsers(t.optJSONArray("users")),
                    ),
                )
            }
        }
        return InboxPage(
            threads = threads,
            hasOlder = inbox.optBoolean("has_older"),
            oldestCursor = inbox.optString("oldest_cursor").ifBlank { null },
            viewerUsername = viewer?.optString("username")?.ifBlank { null },
        )
    }

    fun parseThread(body: ByteArray): ThreadPage {
        val root = JSONObject(body.decodeToString())
        val thread = root.optJSONObject("thread")
            ?: root.optJSONObject("data")?.optJSONObject("thread")
            ?: throw IllegalArgumentException("missing thread (${topKeys(body)})")
        val itemsJson = thread.optJSONArray("items") ?: JSONArray()
        val items = buildList {
            for (i in 0 until itemsJson.length()) {
                val obj = itemsJson.optJSONObject(i) ?: continue
                val item = parseItem(obj)
                if (item.itemID.isNotEmpty()) add(item)
            }
        }
        return ThreadPage(
            items = items,
            hasOlder = thread.optBoolean("has_older"),
            oldestCursor = thread.optString("oldest_cursor").ifBlank { null },
        )
    }

    fun title(stub: InboxThreadStub, ownerID: String): String {
        val others = stub.users.mapNotNull { user ->
            if (user.pk == ownerID) null
            else user.username?.takeIf { it.isNotEmpty() }?.let { "@$it" }
                ?: user.fullName?.takeIf { it.isNotEmpty() }
        }
        if (others.isNotEmpty()) return others.joinToString(", ")
        val titled = stub.threadTitle?.trim().orEmpty()
        if (titled.isNotEmpty() && titled != "Instagram User") return titled
        return "Chat"
    }

    private fun threadId(obj: JSONObject): String? =
        flexibleIdOrNull(obj, "thread_id")
            ?: flexibleIdOrNull(obj, "thread_v2_id")
            ?: flexibleIdOrNull(obj, "id")

    private fun parseUsers(array: JSONArray?): List<InboxUser> {
        array ?: return emptyList()
        return buildList {
            for (i in 0 until array.length()) {
                val u = array.optJSONObject(i) ?: continue
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
