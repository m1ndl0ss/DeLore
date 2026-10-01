package app.delore.android.engine

import android.app.Application
import android.os.Handler
import android.os.Looper
import app.delore.android.AppEnvironment
import app.delore.android.SyncPause
import app.delore.android.SyncPauseKind
import app.delore.android.domain.ConversationID
import app.delore.android.domain.InboxReadProgress
import app.delore.android.domain.JobStatus
import app.delore.android.domain.PauseReason
import app.delore.android.persist.InboxWorkSnapshot
import app.delore.android.secrets.BillingLedger
import app.delore.android.secrets.CleanupBilling as SecretBilling
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class InboxWorkUi(
    val active: Boolean = false,
    val progress: InboxReadProgress = InboxReadProgress(),
    val errorTitle: String? = null,
    val errorMessage: String? = null,
    val pauseKind: SyncPauseKind? = null,
    val retryAfterSeconds: Double? = null,
    val completedTick: Long = 0,
)

class InstagramWorkController(private val app: Application, private val env: AppEnvironment) {
    private val main = Handler(Looper.getMainLooper())
    private val mutex = Mutex()
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _inbox = MutableStateFlow(InboxWorkUi())
    val inbox: StateFlow<InboxWorkUi> = _inbox

    private val _cleanup = MutableStateFlow<app.delore.android.domain.CleanupProgress?>(null)
    val cleanup: StateFlow<app.delore.android.domain.CleanupProgress?> = _cleanup

    var engine: CleanupEngine? = null
        private set

    private var inboxJob: Job? = null
    private var observeJob: Job? = null
    private var finishHandled = false
    private var currentJobId: String? = null
    private var completedTick = 0L

    val isInboxActive: Boolean get() = inboxJob?.isActive == true || _inbox.value.active
    val isCleanupBusy: Boolean
        get() {
            val status = _cleanup.value?.status
            return status == JobStatus.Running || (status != null && !status.isFinished)
        }

    fun attachBrowser() {
        if (env.isDemoMode) return
        val run = {
            env.webBrowser.attach(app)
            env.webBrowser.wake()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run() else main.post(run)
    }

    fun startInbox(
        loadIds: Collection<ConversationID>?,
        titles: Map<String, String>,
        seedTitles: List<String>,
        retractIds: Collection<ConversationID>,
    ) {
        env.inboxHoldOffUntilMillis = 0L
        val snapshot = if (loadIds == null) {
            InboxWorkSnapshot(
                kind = InboxWorkSnapshot.Kind.LIST,
                titles = titles,
                retractIds = retractIds.map { it.rawValue },
            )
        } else {
            InboxWorkSnapshot(
                kind = InboxWorkSnapshot.Kind.LOAD,
                ids = loadIds.map { it.rawValue }.distinct(),
                titles = titles,
                retractIds = retractIds.map { it.rawValue },
            )
        }
        env.inboxWork.save(snapshot)
        val focused = snapshot.ids
        val names = if (loadIds != null) {
            focused.map { titles[it] ?: "Chat" }
        } else {
            seedTitles
        }
        _inbox.value = InboxWorkUi(
            active = true,
            progress = if (loadIds != null) {
                InboxReadProgress(
                    chatsFound = focused.size,
                    chatsRead = 0,
                    chatsTotal = focused.size,
                    sendsFound = 0,
                    currentTitle = names.firstOrNull(),
                    foundTitles = names,
                )
            } else {
                InboxReadProgress(chatsFound = names.size, foundTitles = names)
            },
        )
        keepAlive(notificationText(_inbox.value.progress, null))
        inboxJob?.cancel()
        inboxJob = scope.launch {
            try {
                attachBrowser()
                if (loadIds == null) {
                    env.listInbox { progress ->
                        persistListing()
                        publishInbox(progress)
                    }
                } else {
                    env.loadInbox(loadIds, titles) { progress ->
                        persistLoad(snapshot, progress)
                        publishInbox(progress)
                    }
                }
                env.hasCompletedOnboarding = true
                env.saveRetractQueue(snapshot.retract)
                env.inboxWork.clear()
                completedTick += 1
                _inbox.update {
                    it.copy(active = false, errorTitle = null, errorMessage = null, completedTick = completedTick)
                }
            } catch (_: kotlinx.coroutines.CancellationException) {
                _inbox.update { it.copy(active = false) }
            } catch (error: Exception) {
                android.util.Log.e("Retract", "Inbox sync failed: ${error.javaClass.simpleName}: ${error.message}")
                val pause = SyncPause.from(error)
                if (pause.kind == SyncPauseKind.HOLD_OFF) {
                    val wait = pause.retryAfterSeconds ?: SyncPause.WAIT_SECONDS
                    env.inboxHoldOffUntilMillis = System.currentTimeMillis() + (wait * 1000).toLong()
                }
                _inbox.update {
                    it.copy(
                        active = false,
                        errorTitle = pause.title,
                        errorMessage = pause.message,
                        pauseKind = pause.kind,
                        retryAfterSeconds = pause.retryAfterSeconds,
                    )
                }
            } finally {
                stopIfIdle()
            }
        }
    }

    fun cancelInbox() {
        inboxJob?.cancel()
        inboxJob = null
        env.inboxWork.clear()
        env.saveRetractQueue(emptySet())
        _inbox.update {
            it.copy(
                active = false,
                errorTitle = null,
                errorMessage = null,
                pauseKind = null,
                retryAfterSeconds = null,
            )
        }
        stopIfIdle()
    }

    fun consumeRetractQueue(): Set<ConversationID> {
        val ids = env.loadRetractQueue()
        env.saveRetractQueue(emptySet())
        return ids
    }

    fun holdEngine(loaded: CleanupEngine) {
        engine = loaded
        finishHandled = false
        currentJobId = loaded.jobID
        observe(loaded)
        scope.launch {
            _cleanup.value = loaded.progress()
            keepAlive(notificationText(null, _cleanup.value))
        }
    }

    fun releaseEngine() {
        observeJob?.cancel()
        observeJob = null
        engine = null
        currentJobId = null
        _cleanup.value = null
        stopIfIdle()
    }

    fun resumePersistedWork(): Job = scope.launch {
        mutex.withLock {
            attachBrowser()
            if (!resumeCleanupLocked()) resumeInboxLocked()
        }
    }

    suspend fun cancelCleanup() {
        engine?.cancel()
    }

    private suspend fun resumeCleanupLocked(): Boolean {
        val existing = engine
        if (existing != null) {
            val job = existing.currentJob()
            if (job.status.isFinished) return false
            keepAlive(notificationText(null, existing.progress()))
            maybeStart(existing, job.status, job.authorizedAt != null, job.resumeNotBefore)
            return true
        }
        val loaded = runCatching { CleanupEngine.loadActive(env.engineDependencies()) }.getOrNull() ?: return false
        val progress = loaded.progress()
        val job = loaded.currentJob()
        if (progress.status.isFinished || job.authorizedAt == null) {
            env.jobStore.discardActiveJob()
            return false
        }
        holdEngine(loaded)
        maybeStart(loaded, job.status, true, job.resumeNotBefore)
        return true
    }

    private fun resumeInboxLocked() {
        if (inboxJob?.isActive == true) {
            keepAlive(notificationText(_inbox.value.progress, null))
            return
        }
        if (_inbox.value.errorTitle != null) return
        if (env.inboxHoldOffUntilMillis > System.currentTimeMillis()) return
        val snapshot = env.inboxWork.load() ?: return
        if (!env.hasLiveSession) return
        val loadIds = if (snapshot.kind == InboxWorkSnapshot.Kind.LOAD) snapshot.conversationIds else null
        startInbox(loadIds, snapshot.titles, snapshot.titles.values.toList(), snapshot.retract)
    }

    private suspend fun maybeStart(
        loaded: CleanupEngine,
        status: JobStatus,
        authorized: Boolean,
        resumeNotBefore: Long?,
    ) {
        if (!authorized) return
        val should = when (status) {
            JobStatus.Running -> false
            JobStatus.Ready -> true
            is JobStatus.Paused -> when (status.reason) {
                PauseReason.INTERRUPTED, PauseReason.APP_IN_BACKGROUND -> true
                else -> false
            }
            else -> false
        }
        if (!should) return
        if (resumeNotBefore != null && resumeNotBefore > System.currentTimeMillis()) return
        runCatching { loaded.start() }
    }

    private fun observe(loaded: CleanupEngine) {
        observeJob?.cancel()
        observeJob = scope.launch {
            loaded.updates.collect { update ->
                _cleanup.value = update
                keepAlive(notificationText(null, update))
                if (update.status.isFinished) handleFinish(update)
                if (update.status != JobStatus.Running) stopIfIdle()
            }
        }
    }

    private fun handleFinish(update: app.delore.android.domain.CleanupProgress) {
        if (finishHandled) return
        finishHandled = true
        val id = currentJobId ?: update.jobID
        if (BillingLedger.billing(env.prefs, id) == SecretBilling.FREE) {
            env.entitlements.recordFreeUsage(update.completed)
        }
        BillingLedger.clear(env.prefs, id)
        stopIfIdle()
    }

    private fun publishInbox(progress: InboxReadProgress) {
        _inbox.update { it.copy(active = true, progress = progress, errorTitle = null) }
        keepAlive(notificationText(progress, null))
    }

    private fun persistListing() {
        val retract = env.loadRetractQueue()
        env.inboxWork.save(
            InboxWorkSnapshot(
                kind = InboxWorkSnapshot.Kind.LIST,
                retractIds = retract.map { it.rawValue },
            ),
        )
    }

    private fun persistLoad(original: InboxWorkSnapshot, progress: InboxReadProgress) {
        val remaining = original.ids.drop(progress.chatsRead.coerceAtLeast(0))
        env.inboxWork.save(original.copy(ids = remaining))
    }

    private fun keepAlive(text: String) {
        attachBrowser()
        CleanupForegroundService.start(app, text)
    }

    private fun stopIfIdle() {
        val cleanupRunning = _cleanup.value?.status == JobStatus.Running
        if (!cleanupRunning && inboxJob?.isActive != true && !_inbox.value.active) {
            CleanupForegroundService.stop(app)
        }
    }

    companion object {
        fun notificationText(
            inbox: InboxReadProgress?,
            cleanup: app.delore.android.domain.CleanupProgress?,
        ): String {
            if (cleanup?.status == JobStatus.Running) {
                return "Unsending ${cleanup.processed} of ${cleanup.total}"
            }
            if (inbox != null) {
                return if (inbox.isListing) {
                    "Finding your chats"
                } else {
                    "Reading chats"
                }
            }
            return "Retract is working"
        }
    }
}
