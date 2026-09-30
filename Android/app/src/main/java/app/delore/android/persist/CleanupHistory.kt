package app.delore.android.persist

import app.delore.android.domain.MessageKind
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** One unsent message, with no text. Chat title is resolved at display time. */
@Serializable
data class CleanupHistoryEntry(
    val key: String,
    val conversationID: String,
    val kind: MessageKind,
    val sentAtMillis: Long,
    val cleanedAtMillis: Long,
)

interface CleanupHistoryStore {
    fun append(entry: CleanupHistoryEntry)
    fun load(): List<CleanupHistoryEntry>
    fun wipe()
}

class FileCleanupHistoryStore(root: File) : CleanupHistoryStore {
    private val lock = ReentrantLock()
    private val file: File
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    init {
        root.mkdirs()
        file = File(root, "history.jsonl")
    }

    override fun append(entry: CleanupHistoryEntry) = lock.withLock {
        file.appendText(json.encodeToString(entry) + "\n")
    }

    override fun load(): List<CleanupHistoryEntry> = lock.withLock {
        if (!file.exists()) return@withLock emptyList()
        file.readLines().mapNotNull { line ->
            if (line.isEmpty()) null
            else runCatching { json.decodeFromString<CleanupHistoryEntry>(line) }.getOrNull()
        }
    }

    override fun wipe() = lock.withLock {
        if (file.exists()) file.delete()
    }
}

class InMemoryCleanupHistoryStore : CleanupHistoryStore {
    private val lock = ReentrantLock()
    private val entries = mutableListOf<CleanupHistoryEntry>()

    override fun append(entry: CleanupHistoryEntry) = lock.withLock { entries.add(entry); Unit }

    override fun load(): List<CleanupHistoryEntry> = lock.withLock { entries.toList() }

    override fun wipe() = lock.withLock { entries.clear() }
}
