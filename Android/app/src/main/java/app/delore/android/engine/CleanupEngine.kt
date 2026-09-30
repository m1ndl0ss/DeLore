package app.delore.android.engine

import app.delore.android.domain.CleanupItem
import app.delore.android.domain.CleanupItemState
import app.delore.android.domain.CleanupJob
import app.delore.android.domain.CleanupProgress
import app.delore.android.domain.CleanupScope
import app.delore.android.domain.CleanupTarget
import app.delore.android.domain.IntegrationError
import app.delore.android.domain.JobStatus
import app.delore.android.domain.MessagePresence
import app.delore.android.domain.PauseReason
import app.delore.android.domain.UnsendOutcome
import app.delore.android.domain.UnsendService
import app.delore.android.persist.CleanupHistoryEntry
import app.delore.android.persist.CleanupHistoryStore
import app.delore.android.persist.JobStore
import app.delore.android.persist.JobStoreError
import app.delore.android.persist.PersistedJob
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

sealed class CleanupEngineError : Exception() {
    data object NotAuthorized : CleanupEngineError()
    data object AlreadyRunning : CleanupEngineError()
    data object Finished : CleanupEngineError()
    data class NeedsUserAction(val reason: PauseReason) : CleanupEngineError()
    data class CoolingDown(val untilMillis: Long) : CleanupEngineError()
}

data class CleanupEngineDependencies(
    val store: JobStore,
    val unsender: UnsendService,
    val policy: RatePolicy = RatePolicy.conservative,
    val clock: EngineClock = SystemClock,
    val random: RandomSource = SystemRandom,
    val history: CleanupHistoryStore? = null,
)

class CleanupEngine private constructor(
    persisted: PersistedJob,
    private val deps: CleanupEngineDependencies,
) {
    private val mutex = Mutex()
    private var job: CleanupJob
    private val items: MutableList<CleanupItem>
    private val throttler = Throttler(deps.policy)
    private val estimator = ThroughputEstimator()
    private var queueCursor = 0
    private val retryIndices = mutableSetOf<Int>()
    private var consecutiveFailures = 0
    private val counts = mutableMapOf<CleanupItemState, Int>()
    private var runJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _updates = MutableSharedFlow<CleanupProgress>(replay = 1, extraBufferCapacity = 1)

    val updates: SharedFlow<CleanupProgress> get() = _updates
    val jobID: String get() = job.id

    suspend fun currentJob(): CleanupJob = mutex.withLock { job }

    init {
        var restored = persisted.job
        val restoredItems = persisted.items.toMutableList()
        require(restoredItems.size == restored.itemCount) { throw JobStoreError.corrupted }
        for (index in restoredItems.indices) {
            when (restoredItems[index].state) {
                CleanupItemState.PROCESSING -> {
                    restoredItems[index] = restoredItems[index].copy(
                        state = CleanupItemState.RETRY_WAIT,
                        needsReconcile = true,
                        nextAttemptAt = null,
                    )
                    deps.store.record(restoredItems[index])
                }
                CleanupItemState.DISCOVERED -> {
                    restoredItems[index] = restoredItems[index].copy(state = CleanupItemState.QUEUED)
                    deps.store.record(restoredItems[index])
                }
                else -> Unit
            }
            if (restoredItems[index].state == CleanupItemState.RETRY_WAIT) retryIndices.add(index)
            counts[restoredItems[index].state] = (counts[restoredItems[index].state] ?: 0) + 1
        }
        if (restored.status == JobStatus.Running || restored.status == JobStatus.Paused(PauseReason.APP_IN_BACKGROUND)) {
            restored = restored.copy(status = JobStatus.Paused(PauseReason.INTERRUPTED))
            deps.store.updateJob(restored)
        }
        job = restored
        items = restoredItems
        _updates.tryEmit(snapshotProgress())
    }

    companion object {
        fun loadActive(dependencies: CleanupEngineDependencies): CleanupEngine? {
            val persisted = dependencies.store.loadActiveJob() ?: return null
            return CleanupEngine(persisted, dependencies)
        }
    }

    suspend fun authorize() = mutex.withLock {
        job = job.copy(authorizedAt = deps.clock.nowMillis())
        deps.store.updateJob(job)
    }

    suspend fun start(userResolvedIssue: Boolean = false) {
        mutex.withLock {
            if (job.authorizedAt == null) throw CleanupEngineError.NotAuthorized
            when (val status = job.status) {
                JobStatus.Running -> throw CleanupEngineError.AlreadyRunning
                JobStatus.Completed, JobStatus.Cancelled -> throw CleanupEngineError.Finished
                is JobStatus.Paused -> {
                    if (status.reason.requiresUserAction && !userResolvedIssue) {
                        throw CleanupEngineError.NeedsUserAction(status.reason)
                    }
                    val until = job.resumeNotBefore
                    if (until != null && until > deps.clock.nowMillis()) {
                        throw CleanupEngineError.CoolingDown(until)
                    }
                }
                JobStatus.Ready -> Unit
            }
            job = job.copy(status = JobStatus.Running, resumeNotBefore = null)
            deps.store.updateJob(job)
            throttler.beginNewRun()
            consecutiveFailures = 0
            estimator.beginSegment(deps.clock.nowMillis())
            emitLocked()
        }
        runJob?.cancel()
        runJob = scope.launch { runLoop() }
    }

    suspend fun pause() = pause(PauseReason.USER)

    suspend fun suspendForBackground() = pause(PauseReason.APP_IN_BACKGROUND)

    suspend fun resumeAfterBackground() {
        val should = mutex.withLock { job.status == JobStatus.Paused(PauseReason.APP_IN_BACKGROUND) }
        if (should) start()
    }

    suspend fun cancel() = mutex.withLock {
        if (job.status.isFinished) return@withLock
        val wasRunning = job.status == JobStatus.Running
        job = job.copy(status = JobStatus.Cancelled, resumeNotBefore = null)
        runCatching {
            deps.store.recordCancelPending()
            deps.store.updateJob(job)
        }
        for (index in items.indices) {
            if (items[index].state.isPending) {
                setState(index, CleanupItemState.CANCELLED)
                items[index] = items[index].copy(nextAttemptAt = null)
            }
        }
        retryIndices.clear()
        if (wasRunning) runJob?.cancel()
        estimator.endSegment()
        emitLocked()
    }

    suspend fun waitUntilStopped() {
        runJob?.join()
    }

    suspend fun progress(): CleanupProgress = mutex.withLock { snapshotProgress() }

    private suspend fun pause(reason: PauseReason) = mutex.withLock {
        if (job.status != JobStatus.Running) return@withLock
        stopLocked(reason)
        runJob?.cancel()
    }

    private suspend fun runLoop() {
        while (true) {
            val index = mutex.withLock {
                if (job.status != JobStatus.Running) return
                nextIndex()
            }
            if (index == null) {
                mutex.withLock { finishLocked() }
                return
            }
            val wait = mutex.withLock {
                val now = deps.clock.nowMillis()
                var delay = throttler.delayBeforeNextRequest(now, deps.random)
                items[index].nextAttemptAt?.let { next ->
                    delay = maxOf(delay, (next - now) / 1000.0)
                }
                delay
            }
            if (wait > 0) {
                mutex.withLock { emitLocked() }
                try {
                    deps.clock.sleep(wait)
                } catch (_: CancellationException) {
                    return
                }
                val stillRunning = mutex.withLock { job.status == JobStatus.Running }
                if (!stillRunning) return
            }
            process(index)
            mutex.withLock { emitLocked() }
        }
    }

    private fun nextIndex(): Int? {
        val now = deps.clock.nowMillis()
        val due = retryIndices.filter { (items[it].nextAttemptAt ?: Long.MIN_VALUE) <= now }
        due.minOrNull()?.let { return it }
        while (queueCursor < items.size && items[queueCursor].state != CleanupItemState.QUEUED) {
            queueCursor += 1
        }
        if (queueCursor < items.size) return queueCursor
        return retryIndices.minWithOrNull(compareBy({ items[it].nextAttemptAt ?: Long.MIN_VALUE }, { it }))
    }

    private suspend fun process(index: Int) {
        val target = mutex.withLock { CleanupTarget(items[index]) }
        val skip = mutex.withLock {
            if (items[index].authorID != job.ownerID) {
                transition(index, CleanupItemState.SKIPPED)
                true
            } else false
        }
        if (skip) return
        val reconcile = mutex.withLock { items[index].needsReconcile }
        if (reconcile) {
            reconcile(index, target)
            return
        }
        val shouldSend = mutex.withLock {
            if (items[index].attempts >= deps.policy.maxAttemptsPerItem) {
                transition(index, CleanupItemState.FAILED)
                false
            } else {
                items[index] = items[index].copy(attempts = items[index].attempts + 1, nextAttemptAt = null)
                transition(index, CleanupItemState.PROCESSING)
            }
        }
        if (!shouldSend) return
        mutex.withLock { throttler.recordRequest(deps.clock.nowMillis()) }
        val result = runCatching { withContext(Dispatchers.IO) { deps.unsender.unsend(target) } }
        mutex.withLock {
            if (items[index].state != CleanupItemState.PROCESSING) return@withLock
            result.fold(
                onSuccess = { outcome ->
                    when (outcome) {
                        UnsendOutcome.UNSENT, UnsendOutcome.ALREADY_GONE -> markCompleted(index)
                        UnsendOutcome.NOT_OWNED -> {
                            consecutiveFailures = 0
                            transition(index, CleanupItemState.SKIPPED)
                        }
                    }
                },
                onFailure = { error -> handleFailure(index, error, destructive = true) },
            )
        }
    }

    private suspend fun reconcile(index: Int, target: CleanupTarget) {
        mutex.withLock { throttler.recordRequest(deps.clock.nowMillis()) }
        val result = runCatching { withContext(Dispatchers.IO) { deps.unsender.presence(target) } }
        mutex.withLock {
            if (items[index].state.isTerminal) return@withLock
            result.fold(
                onSuccess = { presence ->
                    when (presence) {
                        MessagePresence.GONE -> {
                            items[index] = items[index].copy(needsReconcile = false)
                            markCompleted(index)
                        }
                        MessagePresence.NOT_OWNED -> {
                            items[index] = items[index].copy(needsReconcile = false)
                            transition(index, CleanupItemState.SKIPPED)
                        }
                        MessagePresence.PRESENT -> {
                            throttler.recordSuccess()
                            items[index] = items[index].copy(needsReconcile = false, nextAttemptAt = null)
                            val next = if (job.status == JobStatus.Cancelled) CleanupItemState.CANCELLED else CleanupItemState.RETRY_WAIT
                            transition(index, next)
                        }
                    }
                },
                onFailure = { error -> handleFailure(index, error, destructive = false) },
            )
        }
    }

    private fun markCompleted(index: Int) {
        consecutiveFailures = 0
        throttler.recordSuccess()
        items[index] = items[index].copy(nextAttemptAt = null)
        if (!transition(index, CleanupItemState.COMPLETED)) return
        val item = items[index]
        runCatching { deps.store.addToLedger(listOf(item.ref.key)) }
        runCatching {
            deps.history?.append(
                CleanupHistoryEntry(
                    key = item.ref.key,
                    conversationID = item.ref.conversationID.rawValue,
                    kind = item.kind,
                    sentAtMillis = item.sentAtMillis,
                    cleanedAtMillis = deps.clock.nowMillis(),
                ),
            )
        }
    }

    private fun handleFailure(index: Int, error: Throwable, destructive: Boolean) {
        val failure = error as? IntegrationError ?: IntegrationError.TransportFailure(true)
        val now = deps.clock.nowMillis()
        if (job.status == JobStatus.Cancelled) {
            items[index] = items[index].copy(nextAttemptAt = null)
            transition(index, CleanupItemState.CANCELLED)
            return
        }
        fun refundAttempt() {
            if (destructive) items[index] = items[index].copy(attempts = maxOf(0, items[index].attempts - 1))
        }
        when (failure) {
            is IntegrationError.RateLimited -> {
                refundAttempt()
                val cooldown = throttler.recordRateLimit(now, failure.retryAfterSeconds, deps.random)
                items[index] = items[index].copy(nextAttemptAt = now + (cooldown * 1000).toLong())
                transition(index, CleanupItemState.RETRY_WAIT)
                if (throttler.shouldStopForRateLimits) stopLocked(PauseReason.RATE_LIMITED, throttler.blockedUntil)
                return
            }
            IntegrationError.SessionExpired -> {
                refundAttempt()
                items[index] = items[index].copy(nextAttemptAt = null)
                transition(index, CleanupItemState.RETRY_WAIT)
                stopLocked(PauseReason.SESSION_EXPIRED)
                return
            }
            IntegrationError.VerificationRequired -> {
                refundAttempt()
                items[index] = items[index].copy(nextAttemptAt = null)
                transition(index, CleanupItemState.RETRY_WAIT)
                stopLocked(PauseReason.VERIFICATION_REQUIRED)
                return
            }
            IntegrationError.Unavailable -> {
                refundAttempt()
                items[index] = items[index].copy(nextAttemptAt = null)
                transition(index, CleanupItemState.RETRY_WAIT)
                stopLocked(PauseReason.INTEGRATION_UNAVAILABLE)
                return
            }
            IntegrationError.Offline -> {
                refundAttempt()
                items[index] = items[index].copy(nextAttemptAt = null)
                transition(index, CleanupItemState.RETRY_WAIT)
                stopLocked(PauseReason.OFFLINE)
                return
            }
            is IntegrationError.UnexpectedResponse -> {
                if (destructive) items[index] = items[index].copy(needsReconcile = true, nextAttemptAt = null)
                else items[index] = items[index].copy(nextAttemptAt = null)
                transition(index, CleanupItemState.RETRY_WAIT)
                stopLocked(PauseReason.UNEXPECTED_RESPONSE)
                return
            }
            is IntegrationError.TransportFailure -> {
                if (destructive && failure.requestMayHaveBeenApplied) {
                    items[index] = items[index].copy(needsReconcile = true)
                }
                if (!destructive) items[index] = items[index].copy(attempts = items[index].attempts + 1)
            }
            IntegrationError.ServerUnavailable -> {
                if (destructive) items[index] = items[index].copy(needsReconcile = true)
                if (!destructive) items[index] = items[index].copy(attempts = items[index].attempts + 1)
            }
        }
        consecutiveFailures += 1
        if (items[index].attempts >= deps.policy.maxAttemptsPerItem) {
            items[index] = items[index].copy(nextAttemptAt = null)
            transition(index, CleanupItemState.FAILED)
        } else {
            val delay = Backoff.delay(maxOf(1, items[index].attempts), deps.policy, deps.random)
            items[index] = items[index].copy(nextAttemptAt = now + (delay * 1000).toLong())
            transition(index, CleanupItemState.RETRY_WAIT)
        }
        if (consecutiveFailures >= deps.policy.maxConsecutiveFailures) {
            stopLocked(PauseReason.REPEATED_FAILURES)
        }
    }

    private val terminalCount: Int
        get() = (counts[CleanupItemState.COMPLETED] ?: 0) +
            (counts[CleanupItemState.SKIPPED] ?: 0) +
            (counts[CleanupItemState.FAILED] ?: 0) +
            (counts[CleanupItemState.CANCELLED] ?: 0)

    private fun transition(index: Int, state: CleanupItemState): Boolean {
        setState(index, state)
        if (state.isTerminal) estimator.recordItem(deps.clock.nowMillis())
        return try {
            deps.store.record(items[index])
            true
        } catch (_: Exception) {
            if (state == CleanupItemState.PROCESSING) {
                items[index] = items[index].copy(attempts = maxOf(0, items[index].attempts - 1))
                setState(index, CleanupItemState.QUEUED)
                if (index < queueCursor) queueCursor = index
            }
            stopLocked(PauseReason.STORAGE_FAILURE)
            false
        }
    }

    private fun setState(index: Int, state: CleanupItemState) {
        val old = items[index].state
        if (old == state) return
        counts[old] = (counts[old] ?: 0) - 1
        counts[state] = (counts[state] ?: 0) + 1
        items[index] = items[index].copy(state = state)
        if (state == CleanupItemState.RETRY_WAIT) retryIndices.add(index) else retryIndices.remove(index)
    }

    private fun stopLocked(reason: PauseReason, resumeNotBefore: Long? = null) {
        if (job.status != JobStatus.Running) return
        job = job.copy(status = JobStatus.Paused(reason), resumeNotBefore = resumeNotBefore)
        runCatching { deps.store.updateJob(job) }
        estimator.endSegment()
        emitLocked()
    }

    private fun finishLocked() {
        job = job.copy(status = JobStatus.Completed, resumeNotBefore = null)
        runCatching { deps.store.updateJob(job) }
        estimator.endSegment()
        emitLocked()
    }

    private fun snapshotProgress(): CleanupProgress {
        val now = deps.clock.nowMillis()
        var resumeAt = job.resumeNotBefore
        if (job.status == JobStatus.Running) {
            throttler.blockedUntil?.let { blocked -> if (blocked > now) resumeAt = blocked }
        }
        val remaining = items.size - terminalCount
        return CleanupProgress(
            jobID = job.id,
            status = job.status,
            total = items.size,
            completed = counts[CleanupItemState.COMPLETED] ?: 0,
            skipped = counts[CleanupItemState.SKIPPED] ?: 0,
            failed = counts[CleanupItemState.FAILED] ?: 0,
            cancelled = counts[CleanupItemState.CANCELLED] ?: 0,
            estimatedSecondsRemaining = estimator.estimatedSeconds(remaining),
            resumeNotBefore = resumeAt,
        )
    }

    private fun emitLocked() {
        _updates.tryEmit(snapshotProgress())
    }
}
