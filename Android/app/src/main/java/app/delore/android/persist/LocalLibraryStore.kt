package app.delore.android.persist

import app.delore.android.domain.AccountIdentity
import app.delore.android.domain.ConversationID
import app.delore.android.domain.ConversationSummary
import app.delore.android.domain.DiscoveredMessage
import app.delore.android.domain.LibraryOverview
import app.delore.android.domain.MessageKind
import app.delore.android.domain.MessageRef
import app.delore.android.domain.MessageSource
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class LocalLibraryStore(private val root: File) : MessageSource {
    @Serializable
    private data class Manifest(
        val account: AccountIdentity,
        val conversations: List<ConversationSummary>,
        val files: Map<String, String>,
        val importedAt: Long,
    )

    @Serializable
    private data class IndexLine(val m: String, val t: Double, val k: MessageKind)

    private val lock = ReentrantLock()
    private var cached: Manifest? = null
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val manifestFile get() = File(root, "library.json")

    init {
        root.mkdirs()
    }

    val hasLibrary: Boolean get() = runCatching { loadManifest() }.isSuccess

    private fun indexDirectory(base: File) = File(base, "index")

    private fun loadManifest(): Manifest = lock.withLock {
        cached?.let { return@withLock it }
        if (!manifestFile.exists()) throw JobStoreError.noActiveJob
        json.decodeFromString<Manifest>(manifestFile.readText()).also { cached = it }
    }

    suspend fun overviewExcluding(cleaned: Set<String>): LibraryOverview {
        val manifest = loadManifest()
        if (cleaned.isEmpty()) return LibraryOverview(manifest.conversations)
        val adjusted = mutableListOf<ConversationSummary>()
        for (summary in manifest.conversations) {
            if (!summary.isCleanable) {
                adjusted.add(summary)
                continue
            }
            var sent = 0
            val byKind = mutableMapOf<MessageKind, Int>()
            var first: Long? = null
            var last: Long? = null
            forEachPage(summary.id, 500) { page ->
                for (message in page) {
                    if (message.ref.key in cleaned) continue
                    sent += 1
                    byKind[message.kind] = (byKind[message.kind] ?: 0) + 1
                    if (first == null) first = message.sentAtMillis
                    last = message.sentAtMillis
                }
            }
            adjusted.add(
                summary.copy(
                    sentByOwner = sent,
                    firstSentAt = first,
                    lastSentAt = last,
                    sentByKind = byKind,
                ),
            )
        }
        return LibraryOverview(adjusted)
    }

    override suspend fun account(): AccountIdentity = loadManifest().account

    override suspend fun conversations(): List<ConversationSummary> = loadManifest().conversations

    override suspend fun forEachPage(
        conversation: ConversationID,
        pageSize: Int,
        block: suspend (List<DiscoveredMessage>) -> Unit,
    ) {
        val manifest = loadManifest()
        val fileName = manifest.files[conversation.rawValue] ?: return
        val file = File(indexDirectory(root), fileName)
        if (!file.exists()) return
        val page = ArrayList<DiscoveredMessage>(pageSize)
        file.forEachLine { line ->
            if (line.isEmpty()) return@forEachLine
            val entry = json.decodeFromString<IndexLine>(line)
            page.add(
                DiscoveredMessage(
                    ref = MessageRef(conversation, entry.m),
                    authorID = manifest.account.ownerID,
                    sentAtMillis = (entry.t * 1000).toLong(),
                    kind = entry.k,
                ),
            )
        }
        page.chunked(pageSize).forEach { chunk -> block(chunk) }
    }

    class ImportWriter internal constructor(
        private val store: LocalLibraryStore,
        private val staging: File,
        account: AccountIdentity,
    ) {
        private var manifest = Manifest(account, emptyList(), emptyMap(), System.currentTimeMillis())
        private val json get() = store.json

        fun add(summary: ConversationSummary, messages: List<DiscoveredMessage>) {
            val fileName = "c${manifest.conversations.size}.jsonl"
            val file = File(store.indexDirectory(staging), fileName)
            val builder = StringBuilder()
            for (message in messages) {
                builder.append(
                    json.encodeToString(
                        IndexLine(message.ref.messageID, message.sentAtMillis / 1000.0, message.kind),
                    ),
                ).append('\n')
            }
            file.writeText(builder.toString())
            manifest = manifest.copy(
                conversations = manifest.conversations + summary,
                files = manifest.files + (summary.id.rawValue to fileName),
            )
        }

        fun commit(): LibraryOverview {
            File(staging, "library.json").writeText(json.encodeToString(manifest))
            store.replace(staging, manifest)
            return LibraryOverview(manifest.conversations)
        }
    }

    fun beginImport(account: AccountIdentity): ImportWriter {
        val staging = File(root.parentFile, root.name + ".staging")
        if (staging.exists()) staging.deleteRecursively()
        staging.mkdirs()
        indexDirectory(staging).mkdirs()
        return ImportWriter(this, staging, account)
    }

    fun wipe() {
        lock.withLock {
            if (root.exists()) root.deleteRecursively()
            root.mkdirs()
            cached = null
        }
    }

    private fun replace(staging: File, manifest: Manifest) = lock.withLock {
        val backup = File(root.parentFile, root.name + ".old")
        if (backup.exists()) backup.deleteRecursively()
        if (root.exists()) root.renameTo(backup)
        if (!staging.renameTo(root)) {
            staging.copyRecursively(root, overwrite = true)
            staging.deleteRecursively()
        }
        if (backup.exists()) backup.deleteRecursively()
        cached = manifest
    }
}
