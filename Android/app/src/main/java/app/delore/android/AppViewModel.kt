package app.delore.android

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import app.delore.android.domain.CleanupAllowanceDecision
import app.delore.android.domain.CleanupFilter
import app.delore.android.domain.CleanupJob
import app.delore.android.domain.CleanupProgress
import app.delore.android.domain.CleanupRequest
import app.delore.android.domain.CleanupScope
import app.delore.android.domain.ConversationID
import app.delore.android.domain.IntegrationError
import app.delore.android.domain.InboxReadProgress
import app.delore.android.domain.JobStatus
import app.delore.android.domain.LibraryOverview
import app.delore.android.domain.PauseReason
import app.delore.android.domain.MessageKind
import app.delore.android.engine.CleanupEngine
import app.delore.android.engine.CleanupEngineError
import app.delore.android.engine.QueueBuilder
import app.delore.android.instagram.InstagramWebSession
import app.delore.android.persist.CleanupHistoryEntry
import app.delore.android.secrets.BillingLedger
import app.delore.android.secrets.CleanupBilling as SecretBilling
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.Calendar
import java.util.UUID

enum class Route { LAUNCHING, HOME }

enum class MainTab { UNSENDING, ACTIVITY, SETTINGS }

enum class LoginPurpose { CONNECT, RECONNECT, REFRESH }

enum class TermsPrompt { SIGNUP, REMINDER }

sealed class Sheet {
    data object Settings : Sheet()
    data object Privacy : Sheet()
    data object Support : Sheet()
    data object Terms : Sheet()
    data object ChooseChats : Sheet()
    data object Included : Sheet()
    data class Setup(val scope: CleanupScope) : Sheet()
    data class Paywall(val context: String) : Sheet()
    data object Unavailable : Sheet()
}

data class StatusCopy(
    val headline: String,
    val message: String?,
    val caution: Boolean,
    val action: Action,
) {
    enum class Action { PAUSE, RESUME, TRY_AGAIN, RESUME_AFTER_VERIFYING, RECONNECT, NONE }
}

data class UiState(
    val route: Route = Route.LAUNCHING,
    val tab: MainTab = MainTab.UNSENDING,
    val sheet: Sheet? = null,
    val overview: LibraryOverview? = null,
    val history: List<CleanupHistoryEntry> = emptyList(),
    val loadingOverview: Boolean = false,
    val loginPurpose: LoginPurpose? = null,
    val termsPrompt: TermsPrompt? = null,
    val syncing: Boolean = false,
    val inboxRead: InboxReadProgress = InboxReadProgress(),
    val syncErrorTitle: String? = null,
    val syncErrorMessage: String? = null,
    val syncPauseKind: SyncPauseKind? = null,
    val syncRetryAfterSeconds: Double? = null,
    val sessionPresented: Boolean = false,
    val progress: CleanupProgress? = null,
    val tryAgainAt: Long? = null,
    val sessionBusy: Boolean = false,
)

class AppViewModel(private val env: AppEnvironment) : ViewModel() {
    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state
    val environment: AppEnvironment get() = env
    val entitlements get() = env.entitlements
    val ratePolicy get() = env.ratePolicy
    val hasLiveSession get() = env.hasLiveSession

    private var engine: CleanupEngine? = null
    private var observeJob: Job? = null
    private var inboxJob: Job? = null
    private var finishHandled = false
    private var currentJobId: String? = null
    private var didPromptDeletionLogin = false
    private var termsNoticeDismissedThisLaunch = false
    private var pendingRetractIds: Set<ConversationID> = emptySet()
    private var inboxLoadIds: Collection<ConversationID>? = null

    val hasUnfinishedSession: Boolean
        get() = _state.value.progress?.status?.isFinished == false

    fun bootstrap() = viewModelScope.launch {
        val splash = launch { delay(700) }
        env.entitlements.refresh()
        env.dropStaleFullInbox()
        if (env.hasLibrary) {
            reloadOverview()
            restoreSession()
        } else {
            val history = runCatching { env.history.load() }.getOrDefault(emptyList()).asReversed()
            _state.update { it.copy(history = history) }
        }
        splash.join()
        env.inboxHoldOffUntilMillis = 0L
        _state.update { it.copy(route = Route.HOME) }
        maybeShowTermsNotice()
    }

    fun beginLogin(purpose: LoginPurpose = LoginPurpose.CONNECT) {
        if (purpose == LoginPurpose.CONNECT && !env.hasAcceptedTerms) {
            _state.update { it.copy(termsPrompt = TermsPrompt.SIGNUP, loginPurpose = null) }
            return
        }
        _state.update { it.copy(loginPurpose = purpose, termsPrompt = null) }
    }

    fun cancelTermsPrompt() {
        if (_state.value.termsPrompt == TermsPrompt.REMINDER) termsNoticeDismissedThisLaunch = true
        _state.update { it.copy(termsPrompt = null) }
    }

    fun acceptTermsPrompt(dontShowAgain: Boolean = true) {
        val prompt = _state.value.termsPrompt
        if (prompt == TermsPrompt.SIGNUP || dontShowAgain) {
            env.acceptedTermsVersion = app.delore.android.ui.LegalCopy.TERMS_VERSION
        } else {
            termsNoticeDismissedThisLaunch = true
        }
        if (prompt == TermsPrompt.SIGNUP) {
            _state.update { it.copy(termsPrompt = null, loginPurpose = LoginPurpose.CONNECT) }
        } else {
            _state.update { it.copy(termsPrompt = null) }
        }
    }

    fun maybeShowTermsNotice() {
        if (env.hasAcceptedTerms || !env.hasLiveSession || termsNoticeDismissedThisLaunch) return
        val state = _state.value
        if (state.sessionPresented && state.progress?.status?.isFinished == false) return
        if (state.termsPrompt != null || state.loginPurpose != null) return
        _state.update { it.copy(termsPrompt = TermsPrompt.REMINDER) }
    }

    fun cancelLogin() {
        _state.update { it.copy(loginPurpose = null) }
    }

    fun handleLogin(session: InstagramWebSession, purpose: LoginPurpose) {
        env.saveSession(session)
        _state.update { it.copy(loginPurpose = null) }
        val shouldSync = when (purpose) {
            LoginPurpose.CONNECT, LoginPurpose.REFRESH -> true
            LoginPurpose.RECONNECT -> !env.hasLibrary
        }
        if (shouldSync) viewModelScope.launch {
            delay(900)
            beginInboxSync(force = true)
        } else {
            maybeShowTermsNotice()
        }
    }

    fun beginInboxSync(force: Boolean = false, loadIds: Collection<ConversationID>? = null) {
        if (!force && env.inboxHoldOffUntilMillis > System.currentTimeMillis()) {
            return
        }
        env.inboxHoldOffUntilMillis = 0L
        inboxLoadIds = loadIds
        val conversations = _state.value.overview?.conversations.orEmpty()
        val seedTitles = conversations.map { it.title }
            .ifEmpty { _state.value.inboxRead.foundTitles }
        val focused = loadIds?.map { it.rawValue }?.distinct().orEmpty()
        val titles = focused.associateWith { raw ->
            conversations.firstOrNull { it.id.rawValue == raw }?.title ?: "Chat"
        }
        _state.update {
            it.copy(
                sheet = null,
                syncing = true,
                inboxRead = if (loadIds != null) {
                    val names = focused.map { raw -> titles[raw] ?: "Chat" }
                    InboxReadProgress(
                        chatsFound = focused.size,
                        chatsRead = 0,
                        chatsTotal = focused.size,
                        sendsFound = 0,
                        currentTitle = names.firstOrNull(),
                        foundTitles = names,
                    )
                } else {
                    InboxReadProgress(
                        chatsFound = seedTitles.size,
                        foundTitles = seedTitles,
                    )
                },
                syncErrorTitle = null,
                syncErrorMessage = null,
                syncPauseKind = null,
                syncRetryAfterSeconds = null,
            )
        }
        inboxJob?.cancel()
        inboxJob = viewModelScope.launch {
            try {
                if (loadIds == null) {
                    env.listInbox { progress -> _state.update { it.copy(inboxRead = progress) } }
                } else {
                    env.loadInbox(loadIds, titles) { progress -> _state.update { it.copy(inboxRead = progress) } }
                }
                env.hasCompletedOnboarding = true
                reloadOverview()
                _state.update { it.copy(syncing = false, route = Route.HOME) }
                val pending = pendingRetractIds
                pendingRetractIds = emptySet()
                if (pending.isNotEmpty()) {
                    val pendingRaw = pending.map { it.rawValue }.toSet()
                    val cleanable = _state.value.overview?.cleanableConversations
                        .orEmpty()
                        .filter { it.id.rawValue in pendingRaw }
                        .map { it.id }
                        .toSet()
                    if (cleanable.isNotEmpty()) openSetup(CleanupScope.Conversations(cleanable))
                }
                maybeShowTermsNotice()
            } catch (_: kotlinx.coroutines.CancellationException) {
                reloadOverview()
                _state.update { it.copy(syncing = false) }
            } catch (error: Exception) {
                android.util.Log.e("Retract", "Inbox sync failed: ${error.javaClass.simpleName}: ${error.message}")
                reloadOverview()
                val saved = _state.value.overview?.conversations?.map { it.title }.orEmpty()
                val pause = SyncPause.from(error)
                _state.update {
                    val keptTitles = it.inboxRead.foundTitles.ifEmpty { saved }
                    it.copy(
                        syncing = false,
                        syncErrorTitle = pause.title,
                        syncErrorMessage = pause.message,
                        syncPauseKind = pause.kind,
                        syncRetryAfterSeconds = pause.retryAfterSeconds,
                        inboxRead = it.inboxRead.copy(
                            chatsFound = maxOf(it.inboxRead.chatsFound, keptTitles.size),
                            foundTitles = keptTitles,
                        ),
                    )
                }
            }
        }
    }

    fun retractWith(ids: Set<ConversationID>) {
        if (ids.isEmpty()) return
        pendingRetractIds = ids
        val unread = _state.value.overview?.conversations.orEmpty().filter { chat ->
            chat.id.rawValue in ids.map { it.rawValue }.toSet() && !chat.messagesLoaded
        }
        if (unread.isEmpty()) {
            pendingRetractIds = emptySet()
            openSetup(CleanupScope.Conversations(ids))
            return
        }
        beginInboxSync(force = true, loadIds = unread.map { it.id })
    }

    fun dismissSync() {
        inboxJob?.cancel()
        pendingRetractIds = emptySet()
        viewModelScope.launch { reloadOverview() }
        _state.update {
            it.copy(
                syncing = false,
                syncErrorTitle = null,
                syncErrorMessage = null,
                syncPauseKind = null,
                syncRetryAfterSeconds = null,
            )
        }
        maybeShowTermsNotice()
    }

    fun acceptInboxHoldOff(later: Boolean) {
        val suggested = _state.value.syncRetryAfterSeconds ?: 0.0
        val base = if (later) SyncPause.LATER_SECONDS else SyncPause.WAIT_SECONDS
        env.inboxHoldOffUntilMillis = System.currentTimeMillis() + (maxOf(base, suggested) * 1000).toLong()
        dismissSync()
    }

    fun retryInboxNow() {
        env.inboxHoldOffUntilMillis = 0L
        beginInboxSync(force = true, loadIds = inboxLoadIds)
    }

    fun retryInboxWhenAllowed() {
        retryInboxNow()
    }

    fun signInAgainFromSync() {
        dismissSync()
        beginLogin(LoginPurpose.REFRESH)
    }

    fun refreshChats() {
        if (env.hasLiveSession) {
            pendingRetractIds = emptySet()
            env.inboxListCursor = null
            beginInboxSync(force = true, loadIds = null)
        } else {
            beginLogin(LoginPurpose.REFRESH)
        }
    }

    fun showConnect() {
        _state.update { it.copy(tab = MainTab.UNSENDING) }
        if (env.hasLiveSession) {
            pendingRetractIds = emptySet()
            beginInboxSync(force = true, loadIds = null)
        } else {
            beginLogin(LoginPurpose.CONNECT)
        }
    }

    fun returnHome() {
        _state.update { it.copy(route = Route.HOME) }
    }

    fun selectTab(tab: MainTab) {
        _state.update { it.copy(tab = tab) }
    }

    fun deletionAppeared() {
        if (env.hasLiveSession) {
            if (!env.hasLibrary && !_state.value.syncing) beginInboxSync()
            return
        }
        if (didPromptDeletionLogin) return
        didPromptDeletionLogin = true
        beginLogin(LoginPurpose.CONNECT)
    }

    fun showSheet(sheet: Sheet?) {
        _state.update { it.copy(sheet = sheet) }
    }

    fun presentSession(present: Boolean) {
        _state.update { it.copy(sessionPresented = present) }
        if (!present) maybeShowTermsNotice()
    }

    suspend fun reloadOverview() {
        _state.update { it.copy(loadingOverview = true) }
        val overview = runCatching { env.loadOverview() }.getOrNull()
        val history = runCatching { env.history.load() }.getOrDefault(emptyList()).asReversed()
        _state.update { it.copy(overview = overview, history = history, loadingOverview = false) }
    }

    fun openSetup(scope: CleanupScope) {
        if (hasUnfinishedSession) {
            _state.update { it.copy(sheet = null, sessionPresented = true) }
            return
        }
        if (!env.isCleanupAvailable) {
            beginLogin(LoginPurpose.RECONNECT)
            return
        }
        _state.update { it.copy(sheet = Sheet.Setup(scope)) }
    }

    suspend fun startCleanup(prepared: PreparedCleanup) {
        val decision = prepared.decision as? CleanupAllowanceDecision.Allowed ?: return
        val billing = when {
            decision.consumesPass -> {
                if (!env.entitlements.consumePass()) return
                SecretBilling.PASS
            }
            decision.usesFreeAllowance -> SecretBilling.FREE
            else -> SecretBilling.PRO
        }
        BillingLedger.record(env.prefs, billing, prepared.job.id)
        val loaded = CleanupEngine.loadActive(env.engineDependencies()) ?: return
        engine = loaded
        currentJobId = prepared.job.id
        finishHandled = false
        observe(loaded)
        _state.update { it.copy(sheet = null, sessionPresented = true, progress = loaded.progress()) }
        loaded.authorizeAndStartSafe()
    }

    fun closeSession(thenChooseChats: Boolean = false) = viewModelScope.launch {
        val progress = _state.value.progress ?: return@launch
        if (!progress.status.isFinished) return@launch
        engine = null
        env.jobStore.discardActiveJob()
        reloadOverview()
        _state.update {
            it.copy(
                sessionPresented = false,
                progress = null,
                sheet = if (thenChooseChats) Sheet.ChooseChats else it.sheet,
            )
        }
        maybeShowTermsNotice()
    }

    fun eraseEverything() = viewModelScope.launch {
        engine?.cancel()
        engine = null
        env.eraseAllData()
        didPromptDeletionLogin = false
        _state.update { UiState(route = Route.HOME, tab = MainTab.SETTINGS) }
    }

    fun pauseCleanup() = viewModelScope.launch { engine?.pause() }
    fun cancelCleanup() = viewModelScope.launch { engine?.cancel() }

    fun resumeCleanup(userResolvedIssue: Boolean = false) = viewModelScope.launch {
        val current = engine ?: return@launch
        _state.update { it.copy(sessionBusy = true) }
        try {
            current.start(userResolvedIssue)
            _state.update { it.copy(tryAgainAt = null) }
        } catch (error: CleanupEngineError.CoolingDown) {
            _state.update { it.copy(tryAgainAt = error.untilMillis) }
        } catch (_: Exception) {
        } finally {
            _state.update { it.copy(sessionBusy = false, progress = current.progress()) }
        }
    }

    fun onAppBackground() = viewModelScope.launch {
        if (_state.value.progress?.status == JobStatus.Running) {
            engine?.suspendForBackground()
            engine?.waitUntilStopped()
        }
    }

    fun onAppForeground() = viewModelScope.launch {
        engine?.resumeAfterBackground()
        engine?.let { _state.update { s -> s.copy(progress = it.progress()) } }
    }

    private fun restoreSession() {
        val loaded = runCatching { CleanupEngine.loadActive(env.engineDependencies()) }.getOrNull() ?: return
        viewModelScope.launch {
            val progress = loaded.progress()
            val job = loaded.currentJob()
            if (progress.status.isFinished || job.authorizedAt == null) {
                env.jobStore.discardActiveJob()
                return@launch
            }
            engine = loaded
            currentJobId = progress.jobID
            observe(loaded)
            if (loaded.currentJob().status.pauseReason == PauseReason.INTERRUPTED) {
                runCatching { loaded.start() }
            }
            _state.update { it.copy(progress = loaded.progress(), sessionPresented = true) }
        }
    }

    private fun observe(loaded: CleanupEngine) {
        observeJob?.cancel()
        observeJob = viewModelScope.launch {
            loaded.updates.collect { update ->
                _state.update { it.copy(progress = update) }
                if (update.status.isFinished) handleFinish(update)
            }
        }
    }

    private fun handleFinish(update: CleanupProgress) {
        if (finishHandled) return
        finishHandled = true
        val id = currentJobId ?: update.jobID
        if (BillingLedger.billing(env.prefs, id) == SecretBilling.FREE) {
            env.entitlements.recordFreeUsage(update.completed)
        }
        BillingLedger.clear(env.prefs, id)
    }

    private suspend fun CleanupEngine.authorizeAndStartSafe() {
        runCatching {
            authorize()
            start()
        }
    }

    class Factory(private val env: AppEnvironment) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = AppViewModel(env) as T
    }
}

enum class SyncPauseKind { HOLD_OFF, RECONNECT, VERIFY, OFFLINE }

data class SyncPause(
    val title: String,
    val message: String,
    val kind: SyncPauseKind,
    val retryAfterSeconds: Double? = null,
) {
    companion object {
        const val WAIT_SECONDS = 10 * 60.0
        const val LATER_SECONDS = 60 * 60.0

        fun from(error: Exception): SyncPause = when (error) {
            IntegrationError.SessionExpired -> SyncPause(
                "Instagram signed you out",
                "Sign in again when you're ready. Nothing left this phone.",
                SyncPauseKind.RECONNECT,
            )
            IntegrationError.VerificationRequired -> SyncPause(
                "Instagram is asking you to verify.",
                "Do that in Instagram, then come back. We won't skip that check, and we won't keep reading while it's pending.",
                SyncPauseKind.VERIFY,
            )
            is IntegrationError.RateLimited -> SyncPause(
                "We'll hold off for a bit.",
                "Instagram asked us to slow down. That's a cue to stop reading, not a prompt to retry. Your login stays on this phone.",
                SyncPauseKind.HOLD_OFF,
                error.retryAfterSeconds,
            )
            IntegrationError.Offline -> SyncPause(
                "You're offline",
                "Reconnect to the internet, then we can keep reading from this phone.",
                SyncPauseKind.OFFLINE,
            )
            is IntegrationError.UnexpectedResponse -> SyncPause(
                "We'll hold off for a bit.",
                "Instagram didn't hand over your inbox cleanly. Waiting is safer than poking it again. Your login stays on this phone.",
                SyncPauseKind.HOLD_OFF,
            )
            is IntegrationError.TransportFailure, IntegrationError.ServerUnavailable -> SyncPause(
                "We'll hold off for a bit.",
                "Instagram went quiet, so we stopped instead of keeping at it. Give it a breather — your login stays on this phone.",
                SyncPauseKind.HOLD_OFF,
            )
            else -> SyncPause(
                "We'll hold off for a bit.",
                "We couldn't finish reading without making noise. Sitting this out is the move. Your login stays on this phone.",
                SyncPauseKind.HOLD_OFF,
            )
        }
    }
}

data class PreparedCleanup(val job: CleanupJob, val decision: CleanupAllowanceDecision) {
    val count: Int get() = job.itemCount
}

class CleanupSetupState(
    val overview: LibraryOverview,
    initial: CleanupScope,
    private val env: AppEnvironment,
) {
    enum class ScopeKind { EVERYTHING, CHOSEN }
    enum class DateBound { ANY, BEFORE, AFTER }

    var scopeKind: ScopeKind = if (initial is CleanupScope.Conversations) ScopeKind.CHOSEN else ScopeKind.EVERYTHING
    var chosen: Set<ConversationID> = (initial as? CleanupScope.Conversations)?.ids ?: emptySet()
    var dateBound: DateBound = DateBound.ANY
    var cutoff: Long = Calendar.getInstance().apply { add(Calendar.YEAR, -1) }.timeInMillis
    var kinds: Set<MessageKind> = filterableKinds.toSet()
    var isPreparing: Boolean = false
    var prepared: PreparedCleanup? = null
    var failed: Boolean = false

    companion object {
        val filterableKinds = listOf(MessageKind.TEXT, MessageKind.MEDIA, MessageKind.LINK, MessageKind.VOICE)
    }

    val filter: CleanupFilter
        get() {
            val cal = Calendar.getInstance().apply { timeInMillis = cutoff; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
            val dayStart = cal.timeInMillis
            cal.add(Calendar.DAY_OF_YEAR, 1)
            val nextDay = cal.timeInMillis
            val kindFilter = if (kinds.size == filterableKinds.size) null else kinds
            return when (dateBound) {
                DateBound.ANY -> CleanupFilter(kinds = kindFilter)
                DateBound.BEFORE -> CleanupFilter(sentBefore = nextDay, kinds = kindFilter)
                DateBound.AFTER -> CleanupFilter(sentAfter = dayStart, kinds = kindFilter)
            }
        }

    val scope: CleanupScope
        get() = if (scopeKind == ScopeKind.EVERYTHING) CleanupScope.Everything else CleanupScope.Conversations(chosen)

    val usesAdvancedFilters: Boolean get() = filter.isAdvanced
    val estimatedCount: Int
        get() = QueueBuilder.estimatedCount(CleanupRequest(scope, filter), overview.conversations)
    val canContinue: Boolean
        get() = !(scopeKind == ScopeKind.CHOSEN && chosen.isEmpty()) && kinds.isNotEmpty() && estimatedCount > 0

    suspend fun prepare(limit: Int? = null) {
        if (isPreparing) return
        isPreparing = true
        failed = false
        try {
            val request = CleanupRequest(scope, filter, limit)
            val account = env.library.account()
            val report = QueueBuilder(env.library, env.jobStore).build(
                request,
                account,
                overview.conversations,
                System.currentTimeMillis(),
            )
            val decision = env.entitlements.allowance(report.job.itemCount, usesAdvancedFilters)
            prepared = PreparedCleanup(report.job, decision)
        } catch (_: Exception) {
            failed = true
        } finally {
            isPreparing = false
        }
    }

    fun discardPrepared() {
        if (prepared == null) return
        env.jobStore.discardActiveJob()
        prepared = null
    }
}

object StatusCopyFactory {
    fun make(status: JobStatus, coolingDownUntil: Long?, now: Long = System.currentTimeMillis()): StatusCopy {
        when (status) {
            JobStatus.Ready, JobStatus.Running -> {
                if (coolingDownUntil != null && coolingDownUntil > now) {
                    return StatusCopy(
                        "Instagram asked us to wait",
                        "We're slowing down because Instagram asked us to wait. Back at it around ${formatTime(coolingDownUntil)}.",
                        true,
                        StatusCopy.Action.PAUSE,
                    )
                }
                return StatusCopy("Cleaning your digital past…", null, false, StatusCopy.Action.PAUSE)
            }
            JobStatus.Completed -> return StatusCopy("Fresh start ✨", null, false, StatusCopy.Action.NONE)
            JobStatus.Cancelled -> return StatusCopy("Cleanup stopped", "Anything already unsent stays unsent.", false, StatusCopy.Action.NONE)
            is JobStatus.Paused -> return copy(status.reason)
        }
    }

    fun copy(reason: app.delore.android.domain.PauseReason): StatusCopy = when (reason) {
        app.delore.android.domain.PauseReason.USER ->
            StatusCopy("Paused", "Tap Resume. We won't unsend the same message twice.", false, StatusCopy.Action.RESUME)
        app.delore.android.domain.PauseReason.APP_IN_BACKGROUND ->
            StatusCopy("Paused while you were away", "Cleaning only runs while the app is open. Tap Resume — we won't unsend twice.", false, StatusCopy.Action.RESUME)
        app.delore.android.domain.PauseReason.INTERRUPTED ->
            StatusCopy("Pick up where you left off", "The app closed mid-clean. Your progress is saved. Tap Resume — we won't unsend the same message twice.", false, StatusCopy.Action.RESUME)
        app.delore.android.domain.PauseReason.RATE_LIMITED ->
            StatusCopy("Instagram asked us to wait", "We've paused because Instagram asked us to wait. Try again later.", true, StatusCopy.Action.TRY_AGAIN)
        app.delore.android.domain.PauseReason.SESSION_EXPIRED ->
            StatusCopy("Instagram signed you out", "Reconnect your account, then come back to continue. Nothing else was touched.", true, StatusCopy.Action.RECONNECT)
        app.delore.android.domain.PauseReason.VERIFICATION_REQUIRED ->
            StatusCopy("Instagram is asking you to verify your account.", "Open Instagram and follow its steps, then come back here. Retract isn't responsible for what Instagram does.", true, StatusCopy.Action.RESUME_AFTER_VERIFYING)
        app.delore.android.domain.PauseReason.REPEATED_FAILURES ->
            StatusCopy("Instagram isn't cooperating", "Instagram isn't responding the way it should right now. Try again later. Retract isn't responsible for what happens to your account.", true, StatusCopy.Action.TRY_AGAIN)
        app.delore.android.domain.PauseReason.OFFLINE ->
            StatusCopy("You're offline", "We'll carry on as soon as you're back online.", true, StatusCopy.Action.TRY_AGAIN)
        app.delore.android.domain.PauseReason.UNEXPECTED_RESPONSE ->
            StatusCopy("We stopped", "Instagram replied in a way we didn't expect. Try again later; we'll double-check before touching anything.", true, StatusCopy.Action.TRY_AGAIN)
        app.delore.android.domain.PauseReason.INTEGRATION_UNAVAILABLE ->
            StatusCopy("We couldn't unsend just now", "Instagram didn't let this cleanup continue. Nothing else was changed.", true, StatusCopy.Action.NONE)
        app.delore.android.domain.PauseReason.STORAGE_FAILURE ->
            StatusCopy("We couldn't save your progress", "Free up some space on your phone, then try again. Nothing was sent that we couldn't track.", true, StatusCopy.Action.TRY_AGAIN)
    }

    fun timeRemaining(seconds: Double?): String {
        if (seconds == null) return "Working out how long this takes…"
        if (seconds < 60) return "Less than a minute left"
        val total = seconds.toInt()
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        return when {
            hours >= 1 && minutes == 0 -> "About $hours hour${if (hours == 1) "" else "s"} remaining"
            hours >= 1 -> "About $hours hour${if (hours == 1) "" else "s"} remaining"
            else -> "About $minutes minute${if (minutes == 1) "" else "s"} remaining"
        }
    }

    private fun formatTime(millis: Long): String {
        val cal = Calendar.getInstance().apply { timeInMillis = millis }
        val hour = cal.get(Calendar.HOUR)
        val minute = cal.get(Calendar.MINUTE).toString().padStart(2, '0')
        val ampm = if (cal.get(Calendar.AM_PM) == Calendar.AM) "AM" else "PM"
        val h = if (hour == 0) 12 else hour
        return "$h:$minute $ampm"
    }
}
