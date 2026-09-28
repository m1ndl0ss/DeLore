package app.delore.android.domain

data class CleanupTarget(
    val ref: MessageRef,
    val authorID: ParticipantID,
    val sentAtMillis: Long,
    val kind: MessageKind,
) {
    constructor(item: CleanupItem) : this(item.ref, item.authorID, item.sentAtMillis, item.kind)
}

enum class UnsendOutcome { UNSENT, ALREADY_GONE, NOT_OWNED }

enum class MessagePresence { PRESENT, GONE, NOT_OWNED }

interface UnsendService {
    suspend fun unsend(target: CleanupTarget): UnsendOutcome
    suspend fun presence(of: CleanupTarget): MessagePresence
}

class UnavailableUnsendService : UnsendService {
    override suspend fun unsend(target: CleanupTarget) = throw IntegrationError.Unavailable
    override suspend fun presence(of: CleanupTarget) = throw IntegrationError.Unavailable
}

interface MessageSource {
    suspend fun account(): AccountIdentity
    suspend fun conversations(): List<ConversationSummary>
    suspend fun forEachPage(
        conversation: ConversationID,
        pageSize: Int,
        block: suspend (List<DiscoveredMessage>) -> Unit,
    )
}

sealed class IntegrationError : Exception() {
    data class RateLimited(val retryAfterSeconds: Double?) : IntegrationError()
    data object SessionExpired : IntegrationError()
    data object VerificationRequired : IntegrationError()
    data object Offline : IntegrationError()
    data class TransportFailure(val requestMayHaveBeenApplied: Boolean) : IntegrationError()
    data object ServerUnavailable : IntegrationError()
    data class UnexpectedResponse(val code: Int?) : IntegrationError()
    data object Unavailable : IntegrationError()

    val caseName: String
        get() = when (this) {
            is RateLimited -> "rateLimited"
            SessionExpired -> "sessionExpired"
            VerificationRequired -> "verificationRequired"
            Offline -> "offline"
            is TransportFailure -> "transportFailure"
            ServerUnavailable -> "serverUnavailable"
            is UnexpectedResponse -> "unexpectedResponse"
            Unavailable -> "unavailable"
        }
}

enum class HTTPMethod { GET, POST, DELETE }

data class HTTPResponse(
    val statusCode: Int,
    val headers: Map<String, String>,
    val body: ByteArray,
) {
    fun header(name: String): String? =
        headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
}

class NetworkError(message: String) : Exception(message)
