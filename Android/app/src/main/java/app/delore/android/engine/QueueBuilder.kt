package app.delore.android.engine

import app.delore.android.domain.AccountIdentity
import app.delore.android.domain.CleanupItem
import app.delore.android.domain.CleanupJob
import app.delore.android.domain.CleanupRequest
import app.delore.android.domain.CleanupScope
import app.delore.android.domain.ConversationSummary
import app.delore.android.domain.MessageSource
import app.delore.android.persist.JobStore

data class QueueBuildReport(
    val job: CleanupJob,
    val peakBufferedItems: Int,
    val excludedNotOwned: Int,
    val excludedDuplicates: Int,
    val excludedAlreadyCleaned: Int,
)

class QueueBuilder(
    private val source: MessageSource,
    private val store: JobStore,
    private val pageSize: Int = 200,
    private val batchSize: Int = 500,
) {
    suspend fun build(
        request: CleanupRequest,
        account: AccountIdentity,
        conversations: List<ConversationSummary>,
        nowMillis: Long,
    ): QueueBuildReport {
        val ledger = store.loadLedger()
        val targets = targetConversations(request.scope, conversations)
        var job = CleanupJob(createdAt = nowMillis, ownerID = account.ownerID, request = request)
        store.createJob(job)
        val buffer = ArrayList<CleanupItem>(batchSize)
        val seen = HashSet<String>()
        var count = 0
        var peak = 0
        var notOwned = 0
        var duplicates = 0
        var alreadyCleaned = 0
        val limit = request.limit ?: Int.MAX_VALUE
        var stop = false

        suspend fun flush() {
            if (buffer.isEmpty()) return
            store.appendItems(buffer.toList())
            buffer.clear()
        }

        conversationLoop@ for (conversation in targets) {
            if (stop) break
            source.forEachPage(conversation.id, pageSize) { page ->
                if (stop) return@forEachPage
                for (message in page) {
                    if (message.authorID != account.ownerID) {
                        notOwned += 1
                        continue
                    }
                    if (message.ref.conversationID != conversation.id) continue
                    if (!request.filter.matches(message)) continue
                    val key = message.ref.key
                    if (key in ledger) {
                        alreadyCleaned += 1
                        continue
                    }
                    if (!seen.add(key)) {
                        duplicates += 1
                        continue
                    }
                    buffer.add(
                        CleanupItem(
                            index = count,
                            ref = message.ref,
                            authorID = message.authorID,
                            sentAtMillis = message.sentAtMillis,
                            kind = message.kind,
                        ),
                    )
                    count += 1
                    peak = maxOf(peak, buffer.size)
                    if (buffer.size >= batchSize) flush()
                    if (count >= limit) {
                        stop = true
                        return@forEachPage
                    }
                }
            }
        }
        flush()
        job = job.copy(itemCount = count)
        store.updateJob(job)
        return QueueBuildReport(job, peak, notOwned, duplicates, alreadyCleaned)
    }

    companion object {
        fun targetConversations(scope: CleanupScope, conversations: List<ConversationSummary>): List<ConversationSummary> {
            val cleanable = conversations.filter { it.isCleanable }
            val selected = when (scope) {
                CleanupScope.Everything -> cleanable
                is CleanupScope.Conversations -> cleanable.filter { it.id in scope.ids }
            }
            return selected.sortedBy { it.id }
        }

        fun estimatedCount(request: CleanupRequest, conversations: List<ConversationSummary>): Int {
            val targets = targetConversations(request.scope, conversations)
            val total = if (request.filter.kinds != null) {
                targets.sumOf { conversation ->
                    request.filter.kinds.sumOf { conversation.sentByKind[it] ?: 0 }
                }
            } else {
                targets.sumOf { it.sentByOwner }
            }
            return minOf(total, request.limit ?: Int.MAX_VALUE)
        }
    }
}
