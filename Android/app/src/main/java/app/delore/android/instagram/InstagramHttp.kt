package app.delore.android.instagram

import app.delore.android.domain.CleanupTarget
import app.delore.android.domain.ConversationID
import app.delore.android.domain.ConversationSummary
import app.delore.android.domain.DiscoveredMessage
import app.delore.android.domain.HTTPMethod
import app.delore.android.domain.HTTPResponse
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
import kotlinx.coroutines.CancellationException
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

data class InstagramAPIRequest(
    val method: HTTPMethod,
    val path: String,
    val query: Map<String, String> = emptyMap(),
    val isIdempotent: Boolean = method == HTTPMethod.GET,
    val destructive: Boolean = false,
)

fun interface InstagramAPIClient {
    suspend fun send(request: InstagramAPIRequest): HTTPResponse
}

class InstagramHTTPClient(
    private val client: OkHttpClient,
    private val sessionProvider: () -> InstagramWebSession?,
) : InstagramAPIClient {
    override suspend fun send(request: InstagramAPIRequest): HTTPResponse {
        val session = sessionProvider() ?: throw IntegrationError.SessionExpired
        if (!session.hasLiveSession) throw IntegrationError.SessionExpired
        val csrf = session.csrfToken?.takeIf { it.isNotEmpty() } ?: throw IntegrationError.SessionExpired
        val url = instagramUrl(request.path, request.query)
        val builder = Request.Builder()
            .url(url)
            .header("Cookie", session.cookieHeader())
            .header("X-CSRFToken", csrf)
            .header("X-IG-App-ID", InstagramWebConstants.WEB_APP_ID)
            .header("X-Requested-With", "XMLHttpRequest")
            .header("Referer", InstagramWebConstants.INBOX_REFERER)
            .header("Origin", InstagramWebConstants.BASE)
            .header("Accept", "application/json")
            .header("User-Agent", InstagramWebConstants.CHROME_USER_AGENT)
        when (request.method) {
            HTTPMethod.GET -> builder.get()
            HTTPMethod.POST -> builder.post("".toRequestBody(null)).header(
                "Content-Type",
                "application/x-www-form-urlencoded; charset=UTF-8",
            )
            HTTPMethod.DELETE -> builder.delete()
        }
        val response = try {
            client.newCall(builder.build()).execute()
        } catch (_: java.net.UnknownHostException) {
            throw IntegrationError.Offline
        } catch (_: java.net.SocketTimeoutException) {
            throw IntegrationError.TransportFailure(request.destructive)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw IntegrationError.TransportFailure(request.destructive)
        }
        response.use { http ->
            val headers = http.headers.toMultimap().mapValues { it.value.last() }
            val body = http.body?.bytes() ?: ByteArray(0)
            val mapped = HTTPResponse(http.code, headers, body)
            InstagramResponseClassifier.throwIfNeeded(mapped, request.destructive)
            return mapped
        }
    }

    companion object {
        fun instagramUrl(path: String, query: Map<String, String>): String {
            val normalized = if (path.startsWith("/")) path else "/$path"
            if ("://" in normalized || normalized.startsWith("//")) throw NetworkError("invalidResponse")
            val httpUrl = (InstagramWebConstants.BASE + normalized).toHttpUrl().newBuilder()
            query.forEach { (k, v) -> httpUrl.addQueryParameter(k, v) }
            val url = httpUrl.build()
            val host = url.host.lowercase()
            if (url.scheme != "https" || (host != "www.instagram.com" && host != "instagram.com")) {
                throw IntegrationError.Unavailable
            }
            return url.toString()
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

class InstagramWebUnsendService(
    private val client: InstagramAPIClient,
    private val ownerID: () -> String?,
    private val presencePageLimit: Int = 8,
) : UnsendService {
    override suspend fun unsend(target: CleanupTarget): UnsendOutcome {
        if (!isOwned(target)) return UnsendOutcome.NOT_OWNED
        val response = client.send(
            InstagramAPIRequest(
                method = HTTPMethod.POST,
                path = deletePath(target.ref),
                isIdempotent = false,
                destructive = true,
            ),
        )
        return InstagramDeleteParse.outcome(response)
    }

    override suspend fun presence(of: CleanupTarget): MessagePresence {
        if (!isOwned(of)) return MessagePresence.NOT_OWNED
        var cursor: String? = null
        repeat(maxOf(1, presencePageLimit)) {
            val page = fetchThread(of.ref.conversationID.rawValue, cursor)
            val item = page.items.firstOrNull { it.itemID == of.ref.messageID }
            if (item != null) {
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
        return MessagePresence.GONE
    }

    private fun isOwned(target: CleanupTarget): Boolean {
        val owner = ownerID()?.takeIf { it.isNotEmpty() } ?: throw IntegrationError.SessionExpired
        return target.authorID == ParticipantID("ig:$owner")
    }

    private fun deletePath(ref: MessageRef): String {
        val thread = URLEncoder.encode(ref.conversationID.rawValue, Charsets.UTF_8)
        val item = URLEncoder.encode(ref.messageID, Charsets.UTF_8)
        return "/api/v1/direct_v2/threads/$thread/items/$item/delete/"
    }

    private suspend fun fetchThread(id: String, cursor: String?): ThreadPage {
        val query = mutableMapOf("limit" to "20")
        if (cursor != null) {
            query["cursor"] = cursor
            query["direction"] = "older"
        }
        val encoded = URLEncoder.encode(id, Charsets.UTF_8)
        val response = client.send(
            InstagramAPIRequest(HTTPMethod.GET, "/api/v1/direct_v2/threads/$encoded/", query),
        )
        return InstagramWebFormat.parseThread(response.body)
    }
}

class InstagramInboxSync(
    private val client: InstagramAPIClient,
    private val library: LocalLibraryStore,
    private val pageSize: Int = 20,
    private val listingDelaySeconds: Double = 0.4,
    private val clock: EngineClock = SystemClock,
) {
    suspend fun run(session: InstagramWebSession, onProgress: ((Double) -> Unit)? = null): LibraryOverview {
        val ownerID = session.userID
        var displayName = session.displayName
        val stubs = mutableListOf<InboxThreadStub>()
        var cursor: String? = null
        var inboxHasOlder = true
        while (inboxHasOlder) {
            val page = fetchInbox(cursor)
            if (displayName == null && !page.viewerUsername.isNullOrEmpty()) displayName = page.viewerUsername
            stubs.addAll(page.threads)
            inboxHasOlder = page.hasOlder
            cursor = page.oldestCursor
            if (cursor == null) inboxHasOlder = false
            if (listingDelaySeconds > 0) clock.sleep(listingDelaySeconds)
        }
        val account = session.copy(displayName = displayName).account
        val writer = library.beginImport(account)
        val total = maxOf(stubs.size, 1)
        stubs.forEachIndexed { index, stub ->
            val conversation = loadConversation(stub, ownerID)
            writer.add(conversation.first, conversation.second)
            onProgress?.invoke((index + 1).toDouble() / total)
            if (listingDelaySeconds > 0) clock.sleep(listingDelaySeconds)
        }
        return writer.commit()
    }

    private suspend fun fetchInbox(cursor: String?): InboxPage {
        val query = mutableMapOf(
            "persistentBadging" to "true",
            "folder" to "inbox",
            "limit" to pageSize.toString(),
            "thread_message_limit" to "1",
        )
        if (cursor != null) query["cursor"] = cursor
        val response = client.send(InstagramAPIRequest(HTTPMethod.GET, "/api/v1/direct_v2/inbox/", query))
        return runCatching { InstagramWebFormat.parseInbox(response.body) }
            .getOrElse { throw IntegrationError.UnexpectedResponse(response.statusCode) }
    }

    private suspend fun loadConversation(
        stub: InboxThreadStub,
        ownerID: String,
    ): Pair<ConversationSummary, List<DiscoveredMessage>> {
        val conversationID = ConversationID(stub.threadID)
        val ownerMessages = mutableListOf<DiscoveredMessage>()
        var received = 0
        var cursor: String? = null
        var hasOlder = true
        val seen = HashSet<String>()
        while (hasOlder) {
            val page = fetchThread(stub.threadID, cursor)
            for (item in page.items) {
                if (item.isSystem || item.itemID.isEmpty()) continue
                if (!seen.add(item.itemID)) continue
                val authoredByOwner = when {
                    item.sentByViewer != null -> item.sentByViewer
                    item.authorID != null -> item.authorID == ownerID
                    else -> continue
                }
                if (authoredByOwner) {
                    ownerMessages.add(
                        DiscoveredMessage(
                            ref = MessageRef(conversationID, item.itemID),
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
            if (cursor == null) hasOlder = false
            if (hasOlder && listingDelaySeconds > 0) clock.sleep(listingDelaySeconds)
        }
        ownerMessages.sortWith(compareBy({ it.sentAtMillis }, { it.ref.messageID }))
        val byKind = mutableMapOf<MessageKind, Int>()
        for (message in ownerMessages) byKind[message.kind] = (byKind[message.kind] ?: 0) + 1
        val summary = ConversationSummary(
            id = conversationID,
            title = InstagramWebFormat.title(stub, ownerID),
            sentByOwner = ownerMessages.size,
            receivedFromOthers = received,
            firstSentAt = ownerMessages.firstOrNull()?.sentAtMillis,
            lastSentAt = ownerMessages.lastOrNull()?.sentAtMillis,
            sentByKind = byKind,
        )
        return summary to ownerMessages
    }

    private suspend fun fetchThread(id: String, cursor: String?): ThreadPage {
        val query = mutableMapOf("limit" to pageSize.toString())
        if (cursor != null) {
            query["cursor"] = cursor
            query["direction"] = "older"
        }
        val encoded = URLEncoder.encode(id, Charsets.UTF_8)
        val response = client.send(
            InstagramAPIRequest(HTTPMethod.GET, "/api/v1/direct_v2/threads/$encoded/", query),
        )
        return runCatching { InstagramWebFormat.parseThread(response.body) }
            .getOrElse { throw IntegrationError.UnexpectedResponse(response.statusCode) }
    }
}
