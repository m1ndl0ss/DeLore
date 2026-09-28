package app.delore.android.persist

import app.delore.android.domain.CleanupItem
import app.delore.android.domain.CleanupItemState
import app.delore.android.domain.CleanupJob
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

data class PersistedJob(val job: CleanupJob, val items: List<CleanupItem>)

class JobStoreError(message: String) : Exception(message) {
    companion object {
        val noActiveJob = JobStoreError("noActiveJob")
        val corrupted = JobStoreError("corrupted")
        val ioFailure = JobStoreError("ioFailure")
    }
}

interface JobStore {
    fun createJob(job: CleanupJob)
    fun appendItems(items: List<CleanupItem>)
    fun updateJob(job: CleanupJob)
    fun record(item: CleanupItem)
    fun recordCancelPending()
    fun loadActiveJob(): PersistedJob?
    fun discardActiveJob()
    fun loadLedger(): Set<String>
    fun addToLedger(keys: List<String>)
    fun wipe()
}

fun applyCancelPending(items: MutableList<CleanupItem>) {
    for (index in items.indices) {
        if (items[index].state.isPending) {
            items[index] = items[index].copy(state = CleanupItemState.CANCELLED, nextAttemptAt = null)
        }
    }
}

class InMemoryJobStore : JobStore {
    private val lock = ReentrantLock()
    private var job: CleanupJob? = null
    private val items = mutableListOf<CleanupItem>()
    private val ledger = mutableSetOf<String>()

    override fun createJob(job: CleanupJob) = lock.withLock {
        this.job = job
        items.clear()
    }

    override fun appendItems(newItems: List<CleanupItem>) = lock.withLock {
        items.addAll(newItems)
    }

    override fun updateJob(job: CleanupJob) = lock.withLock { this.job = job }

    override fun record(item: CleanupItem) = lock.withLock {
        if (item.index !in items.indices) throw JobStoreError.corrupted
        items[item.index] = item
    }

    override fun recordCancelPending() = lock.withLock { applyCancelPending(items) }

    override fun loadActiveJob(): PersistedJob? = lock.withLock {
        job?.let { PersistedJob(it, items.toList()) }
    }

    override fun discardActiveJob() = lock.withLock {
        job = null
        items.clear()
    }

    override fun loadLedger(): Set<String> = lock.withLock { ledger.toSet() }

    override fun addToLedger(keys: List<String>) = lock.withLock { ledger.addAll(keys) }

    override fun wipe() = lock.withLock {
        job = null
        items.clear()
        ledger.clear()
    }
}

private val json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

@kotlinx.serialization.Serializable
private data class JournalLine(val type: String, val item: CleanupItem? = null)

class FileJobStore(private val root: File, private val compactionThreshold: Int = 2_000) : JobStore {
    private val lock = ReentrantLock()
    private var journalLines = 0
    private val activeDirectory get() = File(root, "active")
    private val jobFile get() = File(activeDirectory, "job.json")
    private val itemsFile get() = File(activeDirectory, "items.jsonl")
    private val journalFile get() = File(activeDirectory, "journal.jsonl")
    private val ledgerFile get() = File(root, "ledger.jsonl")

    init {
        root.mkdirs()
    }

    override fun createJob(job: CleanupJob) = lock.withLock {
        if (activeDirectory.exists()) activeDirectory.deleteRecursively()
        activeDirectory.mkdirs()
        itemsFile.writeText("")
        jobFile.writeText(json.encodeToString(job))
        journalLines = 0
    }

    override fun appendItems(items: List<CleanupItem>) {
        if (items.isEmpty()) return
        lock.withLock {
            itemsFile.appendBytes(encodeLines(items))
        }
    }

    override fun updateJob(job: CleanupJob) = lock.withLock {
        if (!activeDirectory.exists()) throw JobStoreError.noActiveJob
        atomicWrite(jobFile, json.encodeToString(job).toByteArray())
    }

    override fun record(item: CleanupItem) = appendJournal(JournalLine("i", item))

    override fun recordCancelPending() = appendJournal(JournalLine("x"))

    private fun appendJournal(line: JournalLine) = lock.withLock {
        journalFile.appendBytes(json.encodeToString(line).toByteArray() + 0x0A)
        journalLines += 1
        if (journalLines >= compactionThreshold) compactLocked()
    }

    override fun loadActiveJob(): PersistedJob? = lock.withLock {
        if (!jobFile.exists()) return@withLock null
        val job = json.decodeFromString<CleanupJob>(jobFile.readText())
        val items = loadItemsLocked()
        journalLines = replayJournalLocked(items)
        PersistedJob(job, items.toList())
    }

    override fun discardActiveJob() = lock.withLock {
        if (activeDirectory.exists()) activeDirectory.deleteRecursively()
        journalLines = 0
    }

    override fun loadLedger(): Set<String> = lock.withLock {
        if (!ledgerFile.exists()) return@withLock emptySet()
        ledgerFile.readLines().filter { it.isNotEmpty() }.toSet()
    }

    override fun addToLedger(keys: List<String>) {
        if (keys.isEmpty()) return
        lock.withLock {
            val data = keys.filter { '\n' !in it }.joinToString("\n", postfix = "\n")
            ledgerFile.appendText(data)
        }
    }

    override fun wipe() = lock.withLock {
        if (root.exists()) root.deleteRecursively()
        root.mkdirs()
        journalLines = 0
    }

    private fun encodeLines(items: List<CleanupItem>): ByteArray {
        val builder = StringBuilder()
        for (item in items) {
            builder.append(json.encodeToString(item)).append('\n')
        }
        return builder.toString().toByteArray()
    }

    private fun loadItemsLocked(): MutableList<CleanupItem> {
        if (!itemsFile.exists()) return mutableListOf()
        val items = mutableListOf<CleanupItem>()
        itemsFile.forEachLine { line ->
            if (line.isEmpty()) return@forEachLine
            val item = runCatching { json.decodeFromString<CleanupItem>(line) }.getOrNull() ?: return@forEachLine
            when {
                item.index == items.size -> items.add(item)
                item.index in items.indices -> items[item.index] = item
                else -> throw JobStoreError.corrupted
            }
        }
        return items
    }

    private fun replayJournalLocked(items: MutableList<CleanupItem>): Int {
        if (!journalFile.exists()) return 0
        var count = 0
        journalFile.forEachLine { line ->
            if (line.isEmpty()) return@forEachLine
            val record = runCatching { json.decodeFromString<JournalLine>(line) }.getOrNull() ?: return@forEachLine
            count += 1
            when (record.type) {
                "i" -> {
                    val item = record.item
                    if (item != null && item.index in items.indices) items[item.index] = item
                }
                "x" -> applyCancelPending(items)
            }
        }
        return count
    }

    private fun compactLocked() {
        val items = loadItemsLocked()
        replayJournalLocked(items)
        atomicWrite(itemsFile, encodeLines(items))
        if (journalFile.exists()) journalFile.delete()
        journalLines = 0
    }

    private fun atomicWrite(file: File, bytes: ByteArray) {
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file)) {
            file.delete()
            tmp.renameTo(file)
        }
    }
}
