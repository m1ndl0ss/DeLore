package app.delore.android.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
sealed class CleanupScope {
    @Serializable
    data object Everything : CleanupScope()

    @Serializable
    data class Conversations(val ids: Set<ConversationID>) : CleanupScope()
}

@Serializable
data class CleanupFilter(
    val sentAfter: Long? = null,
    val sentBefore: Long? = null,
    val kinds: Set<MessageKind>? = null,
) {
    val isAdvanced: Boolean get() = sentAfter != null || sentBefore != null || kinds != null

    fun matches(message: DiscoveredMessage): Boolean {
        if (sentAfter != null && message.sentAtMillis < sentAfter) return false
        if (sentBefore != null && message.sentAtMillis > sentBefore) return false
        if (kinds != null && message.kind !in kinds) return false
        return true
    }

    companion object {
        val none = CleanupFilter()
    }
}

@Serializable
data class CleanupRequest(
    val scope: CleanupScope,
    val filter: CleanupFilter = CleanupFilter.none,
    val limit: Int? = null,
)

@Serializable
enum class CleanupItemState {
    @SerialName("discovered") DISCOVERED,
    @SerialName("queued") QUEUED,
    @SerialName("processing") PROCESSING,
    @SerialName("completed") COMPLETED,
    @SerialName("retryWait") RETRY_WAIT,
    @SerialName("failed") FAILED,
    @SerialName("skipped") SKIPPED,
    @SerialName("cancelled") CANCELLED,
    ;

    val isTerminal: Boolean
        get() = this == COMPLETED || this == FAILED || this == SKIPPED || this == CANCELLED
    val isPending: Boolean
        get() = this == QUEUED || this == RETRY_WAIT || this == DISCOVERED
}

@Serializable
data class CleanupItem(
    @SerialName("i") val index: Int,
    @SerialName("r") val ref: MessageRef,
    @SerialName("a") val authorID: ParticipantID,
    @SerialName("t") val sentAtMillis: Long,
    @SerialName("k") val kind: MessageKind,
    @SerialName("s") var state: CleanupItemState = CleanupItemState.QUEUED,
    @SerialName("n") var attempts: Int = 0,
    @SerialName("v") var needsReconcile: Boolean = false,
    @SerialName("w") var nextAttemptAt: Long? = null,
)

@Serializable
enum class PauseReason {
    @SerialName("user") USER,
    @SerialName("appInBackground") APP_IN_BACKGROUND,
    @SerialName("interrupted") INTERRUPTED,
    @SerialName("rateLimited") RATE_LIMITED,
    @SerialName("sessionExpired") SESSION_EXPIRED,
    @SerialName("verificationRequired") VERIFICATION_REQUIRED,
    @SerialName("repeatedFailures") REPEATED_FAILURES,
    @SerialName("offline") OFFLINE,
    @SerialName("unexpectedResponse") UNEXPECTED_RESPONSE,
    @SerialName("integrationUnavailable") INTEGRATION_UNAVAILABLE,
    @SerialName("storageFailure") STORAGE_FAILURE,
    ;

    val requiresUserAction: Boolean
        get() = this == SESSION_EXPIRED || this == VERIFICATION_REQUIRED || this == INTEGRATION_UNAVAILABLE
}

@Serializable
sealed class JobStatus {
    @Serializable
    data object Ready : JobStatus()

    @Serializable
    data object Running : JobStatus()

    @Serializable
    data class Paused(val reason: PauseReason) : JobStatus()

    @Serializable
    data object Completed : JobStatus()

    @Serializable
    data object Cancelled : JobStatus()

    val isFinished: Boolean get() = this == Completed || this == Cancelled
    val pauseReason: PauseReason? get() = (this as? Paused)?.reason
}

@Serializable
data class CleanupJob(
    val id: String = UUID.randomUUID().toString(),
    val createdAt: Long,
    val ownerID: ParticipantID,
    val request: CleanupRequest,
    var authorizedAt: Long? = null,
    var status: JobStatus = JobStatus.Ready,
    var resumeNotBefore: Long? = null,
    var itemCount: Int = 0,
)

data class CleanupProgress(
    val jobID: String,
    val status: JobStatus,
    val total: Int,
    val completed: Int,
    val skipped: Int,
    val failed: Int,
    val cancelled: Int,
    val estimatedSecondsRemaining: Double?,
    val resumeNotBefore: Long?,
) {
    val processed: Int get() = completed + skipped + failed + cancelled
    val remaining: Int get() = maxOf(0, total - processed)
    val fraction: Double
        get() {
            if (total <= 0) return if (status == JobStatus.Completed) 1.0 else 0.0
            return minOf(1.0, maxOf(0.0, processed.toDouble() / total.toDouble()))
        }
}
