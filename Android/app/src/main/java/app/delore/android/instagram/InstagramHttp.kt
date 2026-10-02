package app.delore.android.instagram

import app.delore.android.domain.CleanupTarget
import app.delore.android.domain.ConversationID
import app.delore.android.domain.ConversationSummary
import app.delore.android.domain.DiscoveredMessage
import app.delore.android.domain.HTTPMethod
import app.delore.android.domain.HTTPResponse
import app.delore.android.domain.InboxReadProgress
import app.delore.android.domain.IntegrationError
import app.delore.android.domain.LibraryOverview
import app.delore.android.domain.MessageKind
import app.delore.android.domain.MessagePresence
import app.delore.android.domain.MessageRef
import app.delore.android.domain.NetworkError
import app.delore.android.domain.ParticipantID
import app.delore.android.domain.UnsendOutcome
import app.delore.android.domain.UnsendService
import app.delore.android.engine.EngineClock
import app.delore.android.engine.SystemClock
import app.delore.android.persist.LocalLibraryStore
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

data class InstagramAPIRequest(
    val method: HTTPMethod,
    val path: String,
    val query: Map<String, String> = emptyMap(),
    val isIdempotent: Boolean = method == HTTPMethod.GET,
    val destructive: Boolean = false,
    val form: Map<String, String> = emptyMap(),
    val host: String = InstagramWebConstants.WWW_HOST,
    val emptyBody: Boolean = false,
)

object InstagramForm {
    private val FORM = "application/x-www-form-urlencoded; charset=UTF-8".toMediaType()

    fun mediaType() = FORM

    fun encode(fields: Map<String, String>): String =
        fields.entries.joinToString("&") { (key, value) ->
            "${URLEncoder.encode(key, Charsets.UTF_8)}=${URLEncoder.encode(value, Charsets.UTF_8)}"
        }
}

fun interface InstagramAPIClient {
    suspend fun send(request: InstagramAPIRequest): HTTPResponse
}

class InstagramHTTPClient(
    private val client: OkHttpClient,
    private val sessionProvider: () -> InstagramWebSession?,
    private val browser: InstagramWebViewGateway? = null,
) : InstagramAPIClient {
    private val apiClient = client.newBuilder()
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    @Volatile private var wwwClaim = "0"
    @Volatile private var asbdID: String? = null
    @Volatile private var fbDtsg: String? = null
    @Volatile private var lsdToken: String? = null
    @Volatile private var warmedForUser: String? = null

    override suspend fun send(request: InstagramAPIRequest): HTTPResponse {
        var last: Exception? = null
        repeat(2) { attempt ->
            try {
                val session = sessionProvider() ?: throw IntegrationError.SessionExpired
                if (!session.hasLiveSession) throw IntegrationError.SessionExpired
                val gateway = browser
                if (gateway != null) {
                    return gateway.send(request, session)
                }
                return withContext(Dispatchers.IO) { sendOnce(request) }
            } catch (error: IntegrationError.UnexpectedResponse) {
                if (attempt == 1 || (error.code != 403 && error.code != 400)) throw error
                last = error
                kotlinx.coroutines.delay(450)
            }
        }
        throw last ?: IntegrationError.Unavailable
    }

    private fun sendOnce(request: InstagramAPIRequest): HTTPResponse {
        val session = sessionProvider() ?: throw IntegrationError.SessionExpired
        if (!session.hasLiveSession) throw IntegrationError.SessionExpired
        val csrf = session.csrfToken?.takeIf { it.isNotEmpty() } ?: throw IntegrationError.SessionExpired
        warmupIfNeeded(session, csrf)
        val url = instagramUrl(request.path, request.query, request.host)
        val graphql = request.path.contains("graphql")
        if (graphql && fbDtsg.isNullOrBlank()) {
            throw IntegrationError.Unavailable
        }
        val sameSite = request.host == InstagramWebConstants.API_HOST
        val builder = Request.Builder()
            .url(url)
            .header("Cookie", session.cookieHeader())
            .header("X-CSRFToken", csrf)
            .header("X-IG-App-ID", InstagramWebConstants.WEB_APP_ID)
            .header("Referer", InstagramWebConstants.INBOX_REFERER)
            .header("Origin", InstagramWebConstants.BASE)
            .header("Accept-Language", "en-US,en;q=0.9")
            .header("User-Agent", InstagramWebConstants.CHROME_USER_AGENT)
            .header("Sec-Fetch-Dest", "empty")
            .header("Sec-Fetch-Mode", "cors")
            .header("Sec-Fetch-Site", if (sameSite) "same-site" else "same-origin")
        if (graphql) {
            builder
                .header("Accept", "*/*")
                .header("X-FB-Friendly-Name", "direct_unsend_message")
            lsdToken?.takeIf { it.isNotBlank() }?.let { builder.header("X-FB-LSD", it) }
        } else {
            builder
                .header("Accept", "application/json")
                .header("X-IG-WWW-Claim", wwwClaim)
                .header("X-Requested-With", "XMLHttpRequest")
                .header("ig-u-ds-user-id", session.userID)
                .header("ig-intended-user-id", session.userID)
            asbdID?.let { builder.header("X-ASBD-ID", it) }
        }
        when (request.method) {
            HTTPMethod.GET -> builder.get()
            HTTPMethod.POST -> {
                if (request.emptyBody) {
                    builder.post("".toRequestBody(null))
                } else {
                    val fields = signedForm(request.form, csrf, request.destructive).toMutableMap()
                    if (graphql) {
                        val token = fbDtsg?.takeIf { it.isNotBlank() } ?: throw IntegrationError.Unavailable
                        fields.putIfAbsent("fb_dtsg", token)
                        fields.putIfAbsent("jazoest", InstagramWebBootstrap.jazoest(token))
                        lsdToken?.takeIf { it.isNotBlank() }?.let { fields.putIfAbsent("lsd", it) }
                    }
                    builder.post(InstagramForm.encode(fields).toRequestBody(InstagramForm.mediaType()))
                        .header("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
                }
            }
            HTTPMethod.DELETE -> {
                val fields = signedForm(request.form, csrf, request.destructive)
                if (fields.isEmpty()) builder.delete()
                else builder.delete(InstagramForm.encode(fields).toRequestBody(InstagramForm.mediaType()))
            }
        }
        val response = try {
            apiClient.newCall(builder.build()).execute()
        } catch (_: java.net.UnknownHostException) {
            throw IntegrationError.Offline
        } catch (_: java.net.SocketTimeoutException) {
            throw IntegrationError.TransportFailure(request.destructive)
        } catch (error: CancellationException) {
            throw error
        } catch (error: IntegrationError) {
            throw error
        } catch (error: Exception) {
            Log.e("Retract", "IG transport ${request.path}: ${error.javaClass.simpleName}: ${error.message}")
            throw IntegrationError.TransportFailure(request.destructive)
        }
        response.use { http ->
            http.header("x-ig-set-www-claim")?.takeIf { it.isNotEmpty() }?.let { wwwClaim = it }
            val headers = http.headers.toMultimap().mapValues { it.value.last() }
            val body = http.body?.bytes() ?: ByteArray(0)
            val mapped = HTTPResponse(http.code, headers, body)
            Log.i(
                "Retract",
                "IG ${request.method} ${request.host}${request.path} -> ${http.code} bytes=${body.size} keys=${InstagramWebFormat.topKeys(body)}",
            )
            InstagramResponseClassifier.throwIfNeeded(mapped, request.destructive)
            return mapped
        }
    }

    private fun warmupIfNeeded(session: InstagramWebSession, csrf: String) {
        if (warmedForUser != session.userID) {
            InstagramRequestHost.reset()
        }
        if (warmedForUser == session.userID) return
        wwwClaim = session.wwwClaimCookie ?: "0"
        asbdID = null
        try {
            val warmup = Request.Builder()
                .url(InstagramWebConstants.INBOX_REFERER)
                .header("Cookie", session.cookieHeader())
                .header("X-CSRFToken", csrf)
                .header("X-IG-App-ID", InstagramWebConstants.WEB_APP_ID)
                .header("User-Agent", InstagramWebConstants.CHROME_USER_AGENT)
                .header("Accept", "text/html,application/xhtml+xml")
                .header("Accept-Language", "en-US,en;q=0.9")
                .get()
                .build()
            client.newBuilder()
                .connectTimeout(12, TimeUnit.SECONDS)
                .readTimeout(12, TimeUnit.SECONDS)
                .callTimeout(12, TimeUnit.SECONDS)
                .build()
                .newCall(warmup)
                .execute()
                .use { http ->
                http.header("x-ig-set-www-claim")?.takeIf { it.isNotEmpty() }?.let { wwwClaim = it }
                val html = http.body?.string().orEmpty()
                InstagramWebBootstrap.asbdID(html)?.let { asbdID = it }
                InstagramWebBootstrap.wwwClaim(html)?.let { wwwClaim = it }
                InstagramWebBootstrap.fbDtsg(html)?.let { fbDtsg = it }
                InstagramWebBootstrap.lsd(html)?.let { lsdToken = it }
                Log.i("Retract", "IG warmup -> ${http.code} htmlBytes=${html.length} hasClaim=${wwwClaim != "0"} hasAsbd=${asbdID != null} dtsg=${fbDtsg != null}")
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Log.w("Retract", "IG inbox warmup: ${error.javaClass.simpleName}: ${error.message}")
        }
        warmedForUser = session.userID
    }

    companion object {
        private val allowedHosts = setOf(
            InstagramWebConstants.WWW_HOST,
            "instagram.com",
            InstagramWebConstants.API_HOST,
        )

        fun instagramUrl(
            path: String,
            query: Map<String, String> = emptyMap(),
            host: String = InstagramWebConstants.WWW_HOST,
        ): String {
            val normalized = if (path.startsWith("/")) path else "/$path"
            if ("://" in normalized || normalized.startsWith("//")) throw NetworkError("invalidResponse")
            val requested = host.lowercase()
            if (requested !in allowedHosts) throw IntegrationError.Unavailable
            val httpUrl = "https://$requested$normalized".toHttpUrl().newBuilder()
            query.forEach { (k, v) -> httpUrl.addQueryParameter(k, v) }
            val url = httpUrl.build()
            val resolved = url.host.lowercase()
            if (url.scheme != "https" || resolved !in allowedHosts) {
                throw IntegrationError.Unavailable
            }
            return url.toString()
        }

        fun signedForm(form: Map<String, String>, csrf: String, destructive: Boolean): Map<String, String> {
            if (form.isEmpty() && !destructive) return emptyMap()
            val fields = form.toMutableMap()
            fields.putIfAbsent("_csrftoken", csrf)
            return fields
        }
    }
}

fun defaultOkHttp(): OkHttpClient = OkHttpClient.Builder()
    .followRedirects(true)
    .followSslRedirects(true)
    .cache(null)
    .connectTimeout(30, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .cookieJar(okhttp3.CookieJar.NO_COOKIES)
    .build()

/**
 * Unsend path that works against Instagram's website session:
 * GraphQL `direct_unsend_message` on www.instagram.com with Relay-only headers
 * (`fb_dtsg` from `require('DTSGInitialData')`). Extra Instagram API headers
 * (`X-Requested-With`, `ig-u-ds-user-id`, `X-IG-WWW-Claim`) make Meta's ajax
 * layer return "Log in to continue" even with a real token.
 *
 * Do not fall back to REST `…/items/{id}/delete/` — it returns 1404006 on the
 * web session and poisons the WebView onto i.instagram.com so GraphQL fails.
 * Desktop Chrome UA only — never a spoofed Instagram app identity.
 */
class InstagramWebUnsendService(
    private val client: InstagramAPIClient,
    private val ownerID: () -> String?,
    private val presencePageLimit: Int = 8,
    /** Hard cap so a pathological thread can't page forever. */
    private val resolvePageLimit: Int = 200,
    /** Larger pages = fewer round-trips while resolving mid.$ for long chats. */
    private val resolvePageSize: Int = 100,
) : UnsendService {
    /** thread|item_id → mid.$… resolved while paging a thread. */
    private val midCache = HashMap<String, String>()
    /** thread|mid.$… → numeric item_id (presence / cache). */
    private val itemCache = HashMap<String, String>()
    /**
     * Per-thread resume cursor. Queue is newest-owned first, but Instagram pages from the
     * absolute tip — which can be hundreds of *their* messages after your last send. Resume
     * so each later owned message doesn't re-walk the same tip.
     */
    private val scanCursor = HashMap<String, String?>()
    /** thread|cursor|pageSize → last resolve page (avoids re-fetching tip after a bad restart). */
    private val resolvePageCache = object : LinkedHashMap<String, ThreadPage>(24, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ThreadPage>?): Boolean = size > 24
    }
    /** thread|storedId marked gone when resolve paged past sentAt with no match. */
    private val goneHints = HashSet<String>()

    override suspend fun unsend(target: CleanupTarget): UnsendOutcome {
        if (!isOwned(target)) return UnsendOutcome.NOT_OWNED
        val owner = ownerID()?.takeIf { it.isNotEmpty() } ?: throw IntegrationError.SessionExpired
        val stored = target.ref.messageID
        val goneKey = "${target.ref.conversationID.rawValue}|$stored"

        val mid = when {
            stored.startsWith("mid.") -> stored
            else -> resolveIds(target)?.first
        }
        if (mid.isNullOrBlank()) {
            // No live mid. If resolve paged past sentAt / matched without mid, treat as gone.
            // Never hit REST (1404006 + i-origin poison).
            if (goneHints.remove(goneKey)) {
                Log.i("Retract", "IG unsend already gone (no mid)")
                return UnsendOutcome.ALREADY_GONE
            }
            throw IntegrationError.Unavailable
        }

        return try {
            val response = client.send(graphqlUnsend(target, owner, mid))
            val outcome = InstagramDeleteParse.outcome(response)
            Log.i("Retract", "IG unsend ok graphql mid")
            // Drop only this message — keep sibling mids learned while paging the thread.
            midCache.remove(goneKey)
            midCache.remove("${target.ref.conversationID.rawValue}|$mid")
            itemCache.remove("${target.ref.conversationID.rawValue}|$mid")
            // Tip pages change after an unsend; never reuse them from cache in FGS / next resolve.
            invalidateThreadPages(target.ref.conversationID.rawValue)
            outcome
        } catch (error: IntegrationError.UnexpectedResponse) {
            Log.w("Retract", "IG unsend skip graphql code=${error.code}")
            throw error
        } catch (error: IntegrationError.TransportFailure) {
            Log.w("Retract", "IG unsend skip graphql transport")
            throw error
        }
    }

    override suspend fun presence(of: CleanupTarget): MessagePresence {
        if (!isOwned(of)) return MessagePresence.NOT_OWNED
        val thread = of.ref.conversationID.rawValue
        var cursor: String? = null
        repeat(maxOf(1, presencePageLimit)) {
            val page = fetchThread(thread, cursor)
            val item = page.items.firstOrNull { matches(of.ref.messageID, it) }
            if (item != null) {
                rememberItem(thread, item)
                if (item.isSystem) return MessagePresence.GONE
                if (item.sentByViewer == false) return MessagePresence.NOT_OWNED
                val owner = ownerID()
                if (item.authorID != null && owner != null && item.authorID != owner) return MessagePresence.NOT_OWNED
                return MessagePresence.PRESENT
            }
            val oldest = page.items.minOfOrNull { it.sentAtMillis }
            if (oldest != null && oldest < of.sentAtMillis - 1_000) return MessagePresence.GONE
            if (!page.hasOlder || page.oldestCursor == null) return MessagePresence.GONE
            cursor = page.oldestCursor
        }
        // Oldest sends sit far past the newest pages. Unknown is "still there" so we retry unsend.
        return MessagePresence.PRESENT
    }

    private fun matches(stored: String, item: ThreadItem): Boolean =
        item.itemID == stored || item.webMessageID == stored

    private fun rememberItem(thread: String, item: ThreadItem) {
        val mid = item.webMessageID?.takeIf { it.startsWith("mid.") } ?: return
        midCache["$thread|${item.itemID}"] = mid
        itemCache["$thread|$mid"] = item.itemID
        midCache["$thread|$mid"] = mid
    }

    /** Returns (mid, numericItemId) when found in the live thread. */
    private suspend fun resolveIds(target: CleanupTarget): Pair<String, String>? {
        val thread = target.ref.conversationID.rawValue
        val stored = target.ref.messageID
        val goneKey = "$thread|$stored"
        if (goneKey in goneHints) return null
        midCache["$thread|$stored"]?.let { mid ->
            val item = itemCache["$thread|$mid"] ?: stored.takeUnless { it.startsWith("mid.") }
            if (item != null) {
                Log.i("Retract", "IG resolve cache hit")
                return mid to item
            }
        }

        // Resume deepest cursor. Only restart tip when that page sits *below* the target
        // (true overshoot). Do NOT use global oldest-of-all-speakers — their old messages
        // made every newer owned target look like an overshoot and re-walked the tip.
        var cursor = scanCursor[thread]
        var allowedTipRestart = cursor != null
        var pages = 0
        var networkPages = 0
        var midHits = 0
        val pageBudget = maxOf(1, resolvePageLimit)
        while (pages < pageBudget) {
            val pageStartCursor = cursor
            val (page, fromCache) = fetchResolvePage(thread, cursor)
            pages += 1
            if (!fromCache) networkPages += 1

            var pageOldest = Long.MAX_VALUE
            var pageNewest = Long.MIN_VALUE
            for (item in page.items) {
                if (item.sentAtMillis > 0) {
                    pageOldest = minOf(pageOldest, item.sentAtMillis)
                    pageNewest = maxOf(pageNewest, item.sentAtMillis)
                }
                rememberItem(thread, item)
                if (item.webMessageID?.startsWith("mid.") == true) midHits += 1
            }

            // Resumed too deep for this (newer) target — restart tip once.
            if (allowedTipRestart &&
                pageStartCursor != null &&
                pageNewest != Long.MIN_VALUE &&
                target.sentAtMillis > pageNewest + 5_000L
            ) {
                Log.i("Retract", "IG resolve restart tip (resume below target)")
                cursor = null
                scanCursor[thread] = null
                allowedTipRestart = false
                continue
            }
            allowedTipRestart = false

            for (item in page.items) {
                if (!matches(stored, item)) continue
                val mid = item.webMessageID?.takeIf { it.startsWith("mid.") }
                if (mid != null) {
                    // Stay on this page so older siblings in the newest-first queue re-scan it.
                    scanCursor[thread] = pageStartCursor
                    Log.i(
                        "Retract",
                        "IG resolve hit pages=$pages net=$networkPages midHits=$midHits cached=$fromCache",
                    )
                    return mid to item.itemID
                }
                // Live item without mid.$ — retry later; do not stamp as permanently gone.
                Log.w(
                    "Retract",
                    "IG resolve target without mid pages=$pages midHits=$midHits item=${item.itemID.take(24)}",
                )
                return null
            }

            if (!page.hasOlder || page.oldestCursor == null) {
                scanCursor[thread] = null
                goneHints.add(goneKey)
                break
            }
            // Past sentAt with no match → already gone. Keep resume at this page's start so
            // older siblings on the same page aren't skipped on the next resolve.
            if (pageOldest != Long.MAX_VALUE && pageOldest < target.sentAtMillis - 1_000) {
                Log.w(
                    "Retract",
                    "IG resolve past sentAt pages=$pages midHits=$midHits stored=${stored.take(24)}",
                )
                scanCursor[thread] = pageStartCursor
                goneHints.add(goneKey)
                break
            }
            cursor = page.oldestCursor
            scanCursor[thread] = cursor
            if (!fromCache && pages < pageBudget) {
                kotlinx.coroutines.delay(200)
            }
        }
        Log.w(
            "Retract",
            "IG resolve miss stored=${stored.take(24)} pages=$pages net=$networkPages midHits=$midHits " +
                "targetSent=${target.sentAtMillis}",
        )
        return null
    }

    private suspend fun fetchResolvePage(thread: String, cursor: String?): Pair<ThreadPage, Boolean> {
        val key = "$thread|${cursor.orEmpty()}|$resolvePageSize"
        resolvePageCache[key]?.let { return it to true }
        val page = client.fetchDirectThread(thread, cursor, resolvePageSize)
        resolvePageCache[key] = page
        return page to false
    }

    /** Drop cached pages for a thread (call after Unsend so tip isn't stale in background). */
    fun invalidateThreadPages(thread: String) {
        val prefix = "$thread|"
        val stale = resolvePageCache.keys.filter { it.startsWith(prefix) }
        stale.forEach { resolvePageCache.remove(it) }
    }

    /** Free page bodies when cleanup ends — mid map stays for a later resume. */
    fun releaseWorkingCaches() {
        resolvePageCache.clear()
    }

    private fun isOwned(target: CleanupTarget): Boolean {
        val owner = ownerID()?.takeIf { it.isNotEmpty() } ?: throw IntegrationError.SessionExpired
        return target.authorID == ParticipantID("ig:$owner")
    }

    private fun graphqlUnsend(target: CleanupTarget, owner: String, messageID: String): InstagramAPIRequest {
        val variables = JSONObject()
            .put("message_id", messageID)
            .put("send_data", JSONObject().put("thread_id", target.ref.conversationID.rawValue))
            .toString()
        return InstagramAPIRequest(
            method = HTTPMethod.POST,
            path = "/api/graphql",
            form = mapOf(
                "av" to owner,
                "__user" to owner,
                "fb_api_caller_class" to "RelayModern",
                "fb_api_req_friendly_name" to "direct_unsend_message",
                "variables" to variables,
                "server_timestamps" to "true",
                "doc_id" to InstagramWebConstants.UNSEND_DOC_ID,
            ),
            host = InstagramWebConstants.WWW_HOST,
            isIdempotent = false,
            destructive = true,
        )
    }

    private suspend fun fetchThread(id: String, cursor: String?): ThreadPage =
        client.fetchDirectThread(id, cursor)
}

internal suspend fun InstagramAPIClient.fetchDirectThread(
    id: String,
    cursor: String?,
    pageSize: Int = 20,
): ThreadPage {
    val query = mutableMapOf("limit" to pageSize.toString())
    if (cursor != null) {
        query["cursor"] = cursor
        query["direction"] = "older"
    }
    val encoded = URLEncoder.encode(id, Charsets.UTF_8)
    val path = "/api/v1/direct_v2/threads/$encoded/"
    // www only — dual-host preferred i.instagram.com and forced WebView origin thrash with GraphQL.
    val host = InstagramWebConstants.WWW_HOST
    val response = send(InstagramAPIRequest(HTTPMethod.GET, path, query, host = host))
    return runCatching { InstagramWebFormat.parseThread(response.body) }.getOrElse {
        Log.w("Retract", "IG thread parse $host keys=${InstagramWebFormat.topKeys(response.body)}")
        throw IntegrationError.UnexpectedResponse(response.statusCode)
    }
}

class InstagramInboxSync(
    private val client: InstagramAPIClient,
    private val library: LocalLibraryStore,
    private val pageSize: Int = 20,
    private val listingDelaySeconds: Double = 0.4,
    private val clock: EngineClock = SystemClock,
) {
    suspend fun run(session: InstagramWebSession, onProgress: ((InboxReadProgress) -> Unit)? = null): LibraryOverview {
        val listed = list(session, onProgress = onProgress)
        return load(session, listed.conversations.map { it.id }, onProgress = onProgress)
    }

    suspend fun list(
        session: InstagramWebSession,
        resumeCursor: String? = null,
        onProgress: ((InboxReadProgress) -> Unit)? = null,
        onCursor: ((String?) -> Unit)? = null,
    ): LibraryOverview {
        val ownerID = session.userID
        var displayName = session.displayName
        val summaries = LinkedHashMap<String, ConversationSummary>()
        val existing = try {
            library.conversations()
        } catch (_: Exception) {
            emptyList()
        }
        for (prior in existing) {
            summaries[prior.id.rawValue] = prior
        }
        var cursor = resumeCursor
        var inboxHasOlder = true
        emitListing(summaries, onProgress)
        while (inboxHasOlder) {
            val page = fetchInbox(cursor)
            if (displayName == null && !page.viewerUsername.isNullOrEmpty()) displayName = page.viewerUsername
            for (stub in page.threads) {
                val title = InstagramWebFormat.title(stub, ownerID)
                val prior = summaries[stub.threadID]
                summaries[stub.threadID] = if (prior?.messagesLoaded == true) {
                    prior.copy(title = title)
                } else {
                    ConversationSummary(
                        id = ConversationID(stub.threadID),
                        title = title,
                        sentByOwner = 0,
                        receivedFromOthers = 0,
                        messagesLoaded = false,
                    )
                }
            }
            inboxHasOlder = page.hasOlder
            cursor = page.oldestCursor
            if (cursor == null) inboxHasOlder = false
            val account = session.copy(displayName = displayName).account
            library.mergeListing(account, summaries.values.toList())
            onCursor?.invoke(if (inboxHasOlder) cursor else null)
            emitListing(summaries, onProgress)
            if (listingDelaySeconds > 0) clock.sleep(listingDelaySeconds)
        }
        return LibraryOverview(summaries.values.toList())
    }

    private fun emitListing(
        summaries: Map<String, ConversationSummary>,
        onProgress: ((InboxReadProgress) -> Unit)?,
    ) {
        onProgress?.invoke(
            InboxReadProgress(
                chatsFound = summaries.size,
                foundTitles = summaries.values.map { it.title },
            ),
        )
    }

    suspend fun load(
        session: InstagramWebSession,
        ids: Collection<ConversationID>,
        titles: Map<String, String> = emptyMap(),
        forceRefresh: Boolean = false,
        onProgress: ((InboxReadProgress) -> Unit)? = null,
    ): LibraryOverview {
        val ownerID = session.userID
        val wantedIDs = ids.map { it.rawValue }.distinct()
        val existing = try {
            library.conversations().associateBy { it.id.rawValue }
        } catch (_: Exception) {
            emptyMap()
        }
        val wanted = wantedIDs.map { raw ->
            existing[raw] ?: ConversationSummary(
                id = ConversationID(raw),
                title = titles[raw] ?: "Chat",
                sentByOwner = 0,
                receivedFromOthers = 0,
                messagesLoaded = false,
            )
        }
        val total = wanted.size
        var sends = 0
        var overview = LibraryOverview(existing.values.toList())
        if (wanted.isNotEmpty()) {
            onProgress?.invoke(
                InboxReadProgress(
                    chatsFound = total,
                    chatsRead = 0,
                    chatsTotal = total,
                    sendsFound = 0,
                    currentTitle = wanted.first().title,
                    foundTitles = wanted.map { it.title },
                ),
            )
        }
        wanted.forEachIndexed { index, listed ->
            if (listed.messagesLoaded && !forceRefresh) {
                sends += listed.sentByOwner
                onProgress?.invoke(
                    InboxReadProgress(
                        chatsFound = total,
                        chatsRead = index + 1,
                        chatsTotal = total,
                        sendsFound = sends,
                        currentTitle = listed.title,
                        foundTitles = wanted.map { it.title },
                    ),
                )
                return@forEachIndexed
            }
            val conversation = loadConversation(listed.id.rawValue, listed.title, ownerID) { partial ->
                onProgress?.invoke(
                    InboxReadProgress(
                        chatsFound = total,
                        chatsRead = index,
                        chatsTotal = total,
                        sendsFound = sends + partial,
                        currentTitle = listed.title,
                        foundTitles = wanted.map { it.title },
                    ),
                )
            }
            overview = library.upsertLoaded(conversation.first, conversation.second)
            sends += conversation.second.size
            onProgress?.invoke(
                InboxReadProgress(
                    chatsFound = total,
                    chatsRead = index + 1,
                    chatsTotal = total,
                    sendsFound = sends,
                    currentTitle = listed.title,
                    foundTitles = wanted.map { it.title },
                ),
            )
            if (listingDelaySeconds > 0) clock.sleep(listingDelaySeconds)
        }
        return overview
    }

    private suspend fun fetchInbox(cursor: String?): InboxPage {
        val query = mutableMapOf(
            "persistentBadging" to "true",
            "folder" to "inbox",
            "limit" to pageSize.toString(),
            "thread_message_limit" to "0",
            "visual_message_return_type" to "unseen",
        )
        if (cursor != null) query["cursor"] = cursor
        val host = InstagramWebConstants.WWW_HOST
        val response = client.send(InstagramAPIRequest(HTTPMethod.GET, "/api/v1/direct_v2/inbox/", query, host = host))
        return runCatching { InstagramWebFormat.parseInbox(response.body) }
            .getOrElse {
                Log.e(
                    "Retract",
                    "IG inbox parse $host: ${it.javaClass.simpleName}: ${it.message} keys=${InstagramWebFormat.topKeys(response.body)}",
                )
                throw IntegrationError.UnexpectedResponse(response.statusCode)
            }
    }

    private suspend fun loadConversation(
        threadID: String,
        title: String,
        ownerID: String,
        onPartial: ((Int) -> Unit)? = null,
    ): Pair<ConversationSummary, List<DiscoveredMessage>> {
        val conversationID = ConversationID(threadID)
        val ownerMessages = mutableListOf<DiscoveredMessage>()
        var received = 0
        var cursor: String? = null
        var hasOlder = true
        val seen = HashSet<String>()
        var lastCursor: String? = null
        var midStored = 0
        while (hasOlder) {
            val page = client.fetchDirectThread(threadID, cursor, pageSize)
            for (item in page.items) {
                if (item.isSystem || item.itemID.isEmpty()) continue
                if (!seen.add(item.itemID)) continue
                val authoredByOwner = when {
                    item.sentByViewer != null -> item.sentByViewer
                    item.authorID != null -> item.authorID == ownerID
                    else -> continue
                }
                if (authoredByOwner) {
                    // Prefer mid.$… so Unsend can GraphQL without a live-thread resolve.
                    val messageID = item.webMessageID?.takeIf { it.startsWith("mid.") }
                        ?: item.itemID
                    if (messageID.startsWith("mid.")) midStored += 1
                    ownerMessages.add(
                        DiscoveredMessage(
                            ref = MessageRef(conversationID, messageID),
                            authorID = ParticipantID("ig:$ownerID"),
                            sentAtMillis = item.sentAtMillis,
                            kind = item.kind,
                        ),
                    )
                } else {
                    received += 1
                }
            }
            hasOlder = page.hasOlder
            cursor = page.oldestCursor
            if (cursor == null || cursor == lastCursor) hasOlder = false
            lastCursor = cursor
            onPartial?.invoke(ownerMessages.size)
        }
        Log.i(
            "Retract",
            "IG load thread=$threadID owned=${ownerMessages.size} mid=$midStored numeric=${ownerMessages.size - midStored} received=$received",
        )
        ownerMessages.sortWith(compareBy({ it.sentAtMillis }, { it.ref.messageID }))
        val byKind = mutableMapOf<MessageKind, Int>()
        for (message in ownerMessages) byKind[message.kind] = (byKind[message.kind] ?: 0) + 1
        val summary = ConversationSummary(
            id = conversationID,
            title = title,
            sentByOwner = ownerMessages.size,
            receivedFromOthers = received,
            firstSentAt = ownerMessages.firstOrNull()?.sentAtMillis,
            lastSentAt = ownerMessages.lastOrNull()?.sentAtMillis,
            sentByKind = byKind,
            messagesLoaded = true,
        )
        return summary to ownerMessages
    }
}
