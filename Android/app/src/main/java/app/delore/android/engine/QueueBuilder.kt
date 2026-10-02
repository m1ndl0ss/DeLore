package app.delore.android.engine

import app.delore.android.domain.AccountIdentity
import app.delore.android.domain.CleanupItem
import app.delore.android.domain.CleanupJob
import app.delore.android.domain.CleanupRequest
import app.delore.android.domain.CleanupScope
import app.delore.android.domain.ConversationSummary
import app.delore.android.domain.DiscoveredMessage
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
        val candidates = ArrayList<DiscoveredMessage>()
        val seen = HashSet<String>()
        var notOwned = 0
        var duplicates = 0
        var alreadyCleaned = 0
        val limit = request.limit ?: Int.MAX_VALUE

        for (conversation in targets) {
            source.forEachPage(conversation.id, pageSize) { page ->
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
                    candidates.add(message)
                }
            }
        }

        // Most recent first — people usually want the latest slip-ups gone before old history.
        candidates.sortByDescending { it.sentAtMillis }
        val selected = if (candidates.size > limit) candidates.take(limit) else candidates

        val buffer = ArrayList<CleanupItem>(batchSize)
        var peak = 0
        suspend fun flush() {
            if (buffer.isEmpty()) return
            store.appendItems(buffer.toList())
            buffer.clear()
        }
        selected.forEachIndexed { index, message ->
            buffer.add(
                CleanupItem(
                    index = index,
                    ref = message.ref,
                    authorID = message.authorID,
                    sentAtMillis = message.sentAtMillis,
                    kind = message.kind,
                ),
            )
            peak = maxOf(peak, buffer.size)
            if (buffer.size >= batchSize) flush()
        }
        flush()
        job = job.copy(itemCount = selected.size)
        store.updateJob(job)
        return QueueBuildReport(job, peak, notOwned, duplicates, alreadyCleaned)
    }

    companion object {
        /** Scope membership only — used before chats are evaluated (messages may not be loaded yet). */
        fun conversationsInScope(scope: CleanupScope, conversations: List<ConversationSummary>): List<ConversationSummary> {
            val selected = when (scope) {
                CleanupScope.Everything -> conversations.filter { !it.ownershipAmbiguous }
                is CleanupScope.Conversations -> conversations.filter { it.id in scope.ids && !it.ownershipAmbiguous }
            }
            return selected.sortedBy { it.id }
        }

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
