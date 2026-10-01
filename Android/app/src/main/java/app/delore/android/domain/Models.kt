package app.delore.android.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@JvmInline
@Serializable
value class ConversationID(val rawValue: String) : Comparable<ConversationID> {
    override fun compareTo(other: ConversationID): Int = rawValue.compareTo(other.rawValue)
}

@JvmInline
@Serializable
value class ParticipantID(val rawValue: String)

@Serializable
data class MessageRef(
    @SerialName("c") val conversationID: ConversationID,
    @SerialName("m") val messageID: String,
) {
    val key: String get() = "${conversationID.rawValue}|$messageID"
}

@Serializable
enum class MessageKind {
    @SerialName("text") TEXT,
    @SerialName("media") MEDIA,
    @SerialName("link") LINK,
    @SerialName("voice") VOICE,
    @SerialName("other") OTHER,
}

data class DiscoveredMessage(
    val ref: MessageRef,
    val authorID: ParticipantID,
    val sentAtMillis: Long,
    val kind: MessageKind,
)

@Serializable
data class AccountIdentity(
    val ownerID: ParticipantID,
    val displayName: String,
)

@Serializable
data class ConversationSummary(
    val id: ConversationID,
    val title: String,
    val sentByOwner: Int,
    val receivedFromOthers: Int,
    val firstSentAt: Long? = null,
    val lastSentAt: Long? = null,
    val sentByKind: Map<MessageKind, Int> = emptyMap(),
    val ownershipAmbiguous: Boolean = false,
    val messagesLoaded: Boolean = true,
) {
    val isCleanable: Boolean get() = messagesLoaded && !ownershipAmbiguous && sentByOwner > 0
}

data class LibraryOverview(val conversations: List<ConversationSummary>) {
    val sentByOwner: Int get() = conversations.filter { it.isCleanable }.sumOf { it.sentByOwner }
    val receivedFromOthers: Int get() = conversations.sumOf { it.receivedFromOthers }
    val cleanableConversations: List<ConversationSummary> get() = conversations.filter { it.isCleanable }
    val unreadConversations: List<ConversationSummary> get() = conversations.filter { !it.messagesLoaded }
    val sentByKind: Map<MessageKind, Int>
        get() {
            val totals = mutableMapOf<MessageKind, Int>()
            for (conversation in cleanableConversations) {
                for ((kind, count) in conversation.sentByKind) {
                    totals[kind] = (totals[kind] ?: 0) + count
                }
            }
            return totals
        }
}

fun MessageKind.title(): String = when (this) {
    MessageKind.TEXT -> "Texts"
        MessageKind.MEDIA -> "Media"
    MessageKind.LINK -> "Links & shared posts"
    MessageKind.VOICE -> "Voice messages"
    MessageKind.OTHER -> "Everything else"
}

fun inflect(count: Int, singular: String, plural: String = singular + "s"): String =
    if (count == 1) "1 $singular" else "$count $plural"

data class InboxReadProgress(
    val chatsFound: Int = 0,
    val chatsRead: Int = 0,
    val chatsTotal: Int? = null,
    val sendsFound: Int = 0,
    val currentTitle: String? = null,
    val foundTitles: List<String> = emptyList(),
) {
    val isListing: Boolean get() = chatsTotal == null
    val isComplete: Boolean get() = chatsTotal != null && chatsRead >= chatsTotal

    val displayChat: String?
        get() {
            val title = currentTitle?.trim().orEmpty()
            if (title.isEmpty() || title.equals("Instagram User", ignoreCase = true)) return null
            return if (title.length > 28) title.take(27) + "…" else title
        }

    val headline: String
        get() = when {
            isComplete -> "All set"
            isListing -> "Finding who you talked to…"
            else -> displayChat?.let { "Reading $it" } ?: "Reading this chat"
        }

    val detail: String
        get() = if (isListing) {
            "${inflect(chatsFound, "person", "people")} so far"
        } else {
            "${inflect(sendsFound, "message")} found so far"
        }

    val fraction: Double
        get() {
            val total = chatsTotal
            if (total == null) {
                return (0.05 + chatsFound.coerceAtMost(80) * 0.0014).coerceAtMost(0.16)
            }
            if (total <= 0) return 1.0
            if (total == 1 && chatsRead < 1) {
                return (0.2 + 0.55 * (1.0 - 1.0 / (1.0 + sendsFound / 12.0))).coerceIn(0.2, 0.82)
            }
            val working = if (chatsRead < total) 0.35 else 0.0
            return (0.18 + 0.82 * ((chatsRead + working) / total)).coerceIn(0.18, 1.0)
        }
}
