package app.delore.android.domain

import app.delore.android.persist.LocalLibraryStore
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

object ReviewDemo {
    val account = AccountIdentity(ParticipantID("demo:you"), "you")

    val chats = listOf(
        Triple("demo-bestie", "bestie", 125),
        Triple("demo-group", "the group chat", 96),
        Triple("demo-ex", "the ex", 72),
        Triple("demo-roommates", "roommates", 48),
        Triple("demo-gym", "gym crew", 36),
        Triple("demo-mom", "mom", 24),
    )

    fun seed(library: LocalLibraryStore) {
        val writer = library.beginImport(account)
        val kinds = listOf(
            MessageKind.TEXT,
            MessageKind.TEXT,
            MessageKind.TEXT,
            MessageKind.MEDIA,
            MessageKind.LINK,
            MessageKind.VOICE,
        )
        val base = 1_560_000_000_000L
        for ((rawId, title, count) in chats) {
            val id = ConversationID(rawId)
            val messages = ArrayList<DiscoveredMessage>(count)
            val byKind = mutableMapOf<MessageKind, Int>()
            for (index in 0 until count) {
                val kind = kinds[index % kinds.size]
                byKind[kind] = (byKind[kind] ?: 0) + 1
                messages.add(
                    DiscoveredMessage(
                        ref = MessageRef(id, "demo-$rawId-$index"),
                        authorID = account.ownerID,
                        sentAtMillis = base + index * 90_000L,
                        kind = kind,
                    ),
                )
            }
            writer.add(
                ConversationSummary(
                    id = id,
                    title = title,
                    sentByOwner = count,
                    receivedFromOthers = count / 3,
                    firstSentAt = messages.first().sentAtMillis,
                    lastSentAt = messages.last().sentAtMillis,
                    sentByKind = byKind,
                    messagesLoaded = true,
                ),
                messages,
            )
        }
        writer.commit()
    }
}

class ReviewDemoUnsendService : UnsendService {
    private val lock = ReentrantLock()
    private val gone = mutableSetOf<String>()

    override suspend fun unsend(target: CleanupTarget): UnsendOutcome = lock.withLock {
        if (target.ref.key in gone) UnsendOutcome.ALREADY_GONE
        else {
            gone.add(target.ref.key)
            UnsendOutcome.UNSENT
        }
    }

    override suspend fun presence(of: CleanupTarget): MessagePresence = lock.withLock {
        if (of.ref.key in gone) MessagePresence.GONE else MessagePresence.PRESENT
    }
}
