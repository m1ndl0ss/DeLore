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
import app.delore.android.domain.MessageKind
import app.delore.android.engine.CleanupEngine
import app.delore.android.engine.CleanupEngineError
import app.delore.android.engine.InstagramWorkController
import app.delore.android.engine.QueueBuilder
import app.delore.android.instagram.InstagramWebSession
import app.delore.android.persist.CleanupHistoryEntry
import app.delore.android.secrets.BillingLedger
import app.delore.android.secrets.CleanupBilling as SecretBilling
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.Calendar

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
    val isDemoMode: Boolean = false,
    /** Observed in Compose — do not read env.hasLiveSession from UI directly. */
    val hasLiveSession: Boolean = false,
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

class AppViewModel(
    private val env: AppEnvironment,
    private val work: InstagramWorkController,
) : ViewModel() {
    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state
    val environment: AppEnvironment get() = env
    val entitlements get() = env.entitlements
    val ratePolicy get() = env.ratePolicy
    val hasLiveSession get() = env.hasLiveSession
    val isDemoMode get() = env.isDemoMode
    val isCleanupAvailable get() = env.isCleanupAvailable

    private val engine get() = work.engine
    private var didPromptDeletionLogin = false
    private var termsNoticeDismissedThisLaunch = false
    private var pendingSampleInbox = false
    private var inboxLoadIds: Collection<ConversationID>? = null
    private var lastInboxCompletedTick = work.inbox.value.completedTick

    val hasUnfinishedSession: Boolean
        get() = _state.value.progress?.status?.isFinished == false

    init {
        viewModelScope.launch {
            work.inbox.collect { ui ->
                _state.update {
                    it.copy(
                        syncing = ui.active,
                        inboxRead = ui.progress,
                        syncErrorTitle = ui.errorTitle,
                        syncErrorMessage = ui.errorMessage,
                        syncPauseKind = ui.pauseKind,
                        syncRetryAfterSeconds = ui.retryAfterSeconds,
                    )
                }
                if (ui.completedTick > lastInboxCompletedTick) {
                    lastInboxCompletedTick = ui.completedTick
                    onInboxFinished()
                }
            }
        }
        viewModelScope.launch {
            work.cleanup.collect { progress ->
                _state.update { current ->
                    val present = when {
                        progress == null -> current.sessionPresented
                        !progress.status.isFinished -> true
                        else -> current.sessionPresented
                    }
                    current.copy(progress = progress, sessionPresented = present)
                }
                if (progress != null) reloadHistory()
            }
        }
    }

    fun bootstrap() = viewModelScope.launch {
        val splash = launch { delay(700) }
        env.entitlements.refresh()
        env.dropStaleFullInbox()
        syncSessionFlags()
        if (env.hasLibrary) {
            reloadOverview()
        } else {
            val history = runCatching { env.history.load() }.getOrDefault(emptyList()).asReversed()
            _state.update { it.copy(history = history) }
        }
        work.resumePersistedWork().join()
        if (env.loadRetractQueue().isNotEmpty() && !work.inbox.value.active) {
            onInboxFinished()
        }
        splash.join()
        env.inboxHoldOffUntilMillis = 0L
        _state.update { it.copy(route = Route.HOME) }
        maybeShowTermsNotice()
    }

    private fun syncSessionFlags() {
        _state.update {
            it.copy(
                isDemoMode = env.isDemoMode,
                hasLiveSession = env.hasLiveSession,
            )
        }
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
            if (pendingSampleInbox) {
                pendingSampleInbox = false
                _state.update { it.copy(termsPrompt = null) }
                openSampleInbox()
            } else {
                _state.update { it.copy(termsPrompt = null, loginPurpose = LoginPurpose.CONNECT) }
            }
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
        _state.update { it.copy(loginPurpose = null, isDemoMode = env.isDemoMode, hasLiveSession = true) }
        viewModelScope.launch { env.entitlements.refresh() }
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
        inboxLoadIds = loadIds
        val conversations = _state.value.overview?.conversations.orEmpty()
        val seedTitles = conversations.map { it.title }
            .ifEmpty { _state.value.inboxRead.foundTitles }
        val focused = loadIds?.map { it.rawValue }?.distinct().orEmpty()
        val titles = focused.associateWith { raw ->
            conversations.firstOrNull { it.id.rawValue == raw }?.title ?: "Chat"
        }
        _state.update { it.copy(sheet = null) }
        work.startInbox(loadIds, titles, seedTitles, env.loadRetractQueue())
    }

    fun retractWith(ids: Set<ConversationID>) {
        if (ids.isEmpty()) return
        env.saveRetractQueue(emptySet())
        // List was names-only. Evaluate chat sizes in cleanup setup, then unsend.
        openSetup(CleanupScope.Conversations(ids))
    }

    fun dismissSync() {
        work.cancelInbox()
        viewModelScope.launch { reloadOverview() }
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
            env.saveRetractQueue(emptySet())
            env.inboxListCursor = null
            beginInboxSync(force = true, loadIds = null)
        } else {
            beginLogin(LoginPurpose.REFRESH)
        }
    }

    fun showConnect() {
        _state.update { it.copy(tab = MainTab.UNSENDING) }
        if (env.hasLiveSession) {
            env.saveRetractQueue(emptySet())
            beginInboxSync(force = true, loadIds = null)
        } else {
            beginLogin(LoginPurpose.CONNECT)
        }
    }

    fun returnHome() {
        _state.update { it.copy(route = Route.HOME) }
    }

    fun selectTab(tab: MainTab) {
        syncSessionFlags()
        _state.update { it.copy(tab = tab) }
        if (tab == MainTab.ACTIVITY) reloadHistory()
    }

    fun openSampleInbox() {
        if (env.hasLiveSession) return
        _state.update { it.copy(loginPurpose = null) }
        if (!env.hasAcceptedTerms) {
            pendingSampleInbox = true
            _state.update { it.copy(termsPrompt = TermsPrompt.SIGNUP, loginPurpose = null) }
            return
        }
        env.enterReviewDemo()
        viewModelScope.launch {
            reloadOverview()
            _state.update { it.copy(isDemoMode = true, hasLiveSession = false) }
        }
    }

    fun deletionAppeared() {
        if (env.hasLiveSession) {
            if (!env.hasLibrary && !_state.value.syncing) beginInboxSync()
            return
        }
        if (env.isDemoMode) return
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

    private fun reloadHistory() {
        val history = runCatching { env.history.load() }.getOrDefault(emptyList()).asReversed()
        _state.update { it.copy(history = history) }
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
        var decision = prepared.decision as? CleanupAllowanceDecision.Allowed ?: return
        // Pull server free-usage before starting so reinstall / multi-device can't refill the free tier.
        if (decision.usesFreeAllowance) {
            env.entitlements.syncFreeUsage()
            val refreshed = env.entitlements.allowance(
                prepared.count,
                prepared.job.request.filter.isAdvanced,
            )
            decision = refreshed as? CleanupAllowanceDecision.Allowed ?: return
        }
        val billing = when {
            decision.consumesPass -> {
                if (!env.entitlements.consumePass()) return
                SecretBilling.PASS
            }
            decision.usesFreeAllowance -> SecretBilling.FREE
            else -> SecretBilling.PRO
        }
        BillingLedger.record(env.prefs, billing, prepared.job.id)
        env.entitlements.setTracksFreeUnsent(billing == SecretBilling.FREE)
        val loaded = CleanupEngine.loadActive(env.engineDependencies()) ?: return
        work.holdEngine(loaded)
        _state.update { it.copy(sheet = null, sessionPresented = true, progress = loaded.progress()) }
        loaded.authorizeAndStartSafe()
    }

    fun closeSession(thenChooseChats: Boolean = false) = viewModelScope.launch {
        val progress = _state.value.progress ?: return@launch
        if (!progress.status.isFinished) return@launch
        work.releaseEngine()
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
        work.cancelInbox()
        engine?.cancel()
        work.releaseEngine()
        env.eraseAllData()
        env.entitlements.refresh()
        didPromptDeletionLogin = false
        _state.update {
            UiState(route = Route.HOME, tab = MainTab.SETTINGS, isDemoMode = false, hasLiveSession = false)
        }
    }

    fun logOutInstagram() = viewModelScope.launch {
        work.cancelInbox()
        engine?.cancel()
        work.releaseEngine()
        env.disconnectInstagram()
        env.entitlements.refresh()
        reloadOverview()
        reloadHistory()
        _state.update {
            it.copy(
                sessionPresented = false,
                progress = null,
                sheet = null,
                isDemoMode = false,
                hasLiveSession = false,
                overview = null,
            )
        }
    }

    fun pauseCleanup() = viewModelScope.launch { engine?.pause() }
    fun cancelCleanup() = viewModelScope.launch {
        val cleaned = engine?.cancel().orEmpty()
        if (cleaned.isNotEmpty()) {
            runCatching { env.library.excludeCleaned(cleaned) }
        }
        reloadHistory()
        reloadOverview()
    }

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

    fun onAppBackground() {
        if (work.isInboxActive || work.isCleanupBusy) work.attachBrowser()
    }

    fun onAppForeground() = viewModelScope.launch {
        if (work.isInboxActive || work.isCleanupBusy) work.attachBrowser()
        engine?.resumeAfterBackground()
        engine?.let { _state.update { s -> s.copy(progress = it.progress()) } }
    }

    private suspend fun onInboxFinished() {
        reloadOverview()
        _state.update { it.copy(syncing = false, route = Route.HOME) }
        val pending = work.consumeRetractQueue()
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
    }

    private suspend fun CleanupEngine.authorizeAndStartSafe() {
        runCatching {
            authorize()
            start()
        }
    }

    class Factory(
        private val env: AppEnvironment,
        private val work: InstagramWorkController,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = AppViewModel(env, work) as T
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
    overview: LibraryOverview,
    initial: CleanupScope,
    private val env: AppEnvironment,
) {
    enum class ScopeKind { EVERYTHING, CHOSEN }
    enum class DateBound { ANY, BEFORE, AFTER }

    var overview: LibraryOverview by mutableStateOf(overview)
        private set
    var scopeKind: ScopeKind by mutableStateOf(
        if (initial is CleanupScope.Conversations) ScopeKind.CHOSEN else ScopeKind.EVERYTHING,
    )
    var chosen: Set<ConversationID> by mutableStateOf(
        (initial as? CleanupScope.Conversations)?.ids ?: emptySet(),
    )
    var dateBound: DateBound by mutableStateOf(DateBound.ANY)
    var cutoff: Long by mutableStateOf(Calendar.getInstance().apply { add(Calendar.YEAR, -1) }.timeInMillis)
    var kinds: Set<MessageKind> by mutableStateOf(filterableKinds.toSet())
    var isPreparing: Boolean by mutableStateOf(false)
    var isEvaluating: Boolean by mutableStateOf(false)
    var evaluateProgress: InboxReadProgress by mutableStateOf(InboxReadProgress())
    var prepared: PreparedCleanup? by mutableStateOf(null)
    var failed: Boolean by mutableStateOf(false)

    companion object {
        val filterableKinds = listOf(MessageKind.TEXT, MessageKind.MEDIA, MessageKind.LINK, MessageKind.VOICE)
    }

    val filter: CleanupFilter
        get() {
            val cal = Calendar.getInstance().apply { timeInMillis = cutoff; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
            val dayStart = cal.timeInMillis
            cal.add(Calendar.DAY_OF_YEAR, 1)
            val nextDay = cal.timeInMillis
            // Kind filters omitted — Instagram item_type is often wrong, so type toggles would skip real messages.
            return when (dateBound) {
                DateBound.ANY -> CleanupFilter()
                DateBound.BEFORE -> CleanupFilter(sentBefore = nextDay)
                DateBound.AFTER -> CleanupFilter(sentAfter = dayStart)
            }
        }

    val scope: CleanupScope
        get() = if (scopeKind == ScopeKind.EVERYTHING) CleanupScope.Everything else CleanupScope.Conversations(chosen)

    val usesAdvancedFilters: Boolean get() = filter.isAdvanced
    val estimatedCount: Int
        get() = QueueBuilder.estimatedCount(CleanupRequest(scope, filter), overview.conversations)
    val canContinue: Boolean
        get() = when (scopeKind) {
            ScopeKind.EVERYTHING -> overview.conversations.isNotEmpty()
            ScopeKind.CHOSEN -> chosen.isNotEmpty()
        }

    suspend fun prepare(limit: Int? = null) {
        if (isPreparing) return
        isPreparing = true
        failed = false
        try {
            refreshChatSizes()
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
        } catch (e: Exception) {
            android.util.Log.e("Retract", "prepare failed", e)
            failed = true
        } finally {
            isEvaluating = false
            isPreparing = false
        }
    }

    /**
     * Rechecks in-scope chats against Instagram before every prepare.
     * Skipping already-loaded chats left a stale zero count after the first clean
     * (ledger exclusion + cached `messagesLoaded`), so later cleans looked empty.
     */
    private suspend fun refreshChatSizes() {
        val targets = QueueBuilder.conversationsInScope(scope, overview.conversations)
        if (targets.isEmpty()) {
            overview = env.loadOverview()
            return
        }
        isEvaluating = true
        evaluateProgress = InboxReadProgress(
            chatsFound = targets.size,
            chatsRead = 0,
            chatsTotal = targets.size,
            currentTitle = targets.firstOrNull()?.title,
            foundTitles = targets.firstOrNull()?.title?.let { listOf(it) }.orEmpty(),
        )
        if (env.hasLiveSession) {
            val titleMap = targets.associate { it.id.rawValue to it.title }
            env.loadInbox(targets.map { it.id }, titleMap, forceRefresh = true) { progress ->
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    evaluateProgress = progress
                }
            }
        } else {
            val revealed = mutableListOf<String>()
            targets.forEachIndexed { index, chat ->
                revealed += chat.title
                evaluateProgress = InboxReadProgress(
                    chatsFound = targets.size,
                    chatsRead = index,
                    chatsTotal = targets.size,
                    sendsFound = chat.sentByOwner,
                    currentTitle = chat.title,
                    foundTitles = revealed.toList(),
                )
                delay(90)
                evaluateProgress = InboxReadProgress(
                    chatsFound = targets.size,
                    chatsRead = index + 1,
                    chatsTotal = targets.size,
                    sendsFound = chat.sentByOwner,
                    currentTitle = chat.title,
                    foundTitles = revealed.toList(),
                )
            }
        }
        isEvaluating = false
        overview = env.loadOverview()
    }

    fun discardPrepared() {
        if (prepared == null) return
        env.jobStore.discardActiveJob()
        prepared = null
    }
}

object StatusCopyFactory {
    const val FIRST_UNSEND_HINT =
        "The first unsend can take a minute — we're lining your messages up with Instagram's chat history. After that, it usually picks up."

    fun make(
        status: JobStatus,
        coolingDownUntil: Long?,
        now: Long = System.currentTimeMillis(),
        processed: Int = -1,
    ): StatusCopy {
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
                val hint = if (processed == 0) FIRST_UNSEND_HINT else null
                return StatusCopy("Cleaning your digital past…", hint, false, StatusCopy.Action.PAUSE)
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
            StatusCopy("Paused while you were away", "We'll keep going in the background. Tap Resume if we're waiting — we won't unsend twice.", false, StatusCopy.Action.RESUME)
        app.delore.android.domain.PauseReason.INTERRUPTED ->
            StatusCopy("Pick up where you left off", "We'll continue automatically. Tap Resume if we're waiting — we won't unsend the same message twice.", false, StatusCopy.Action.RESUME)
        app.delore.android.domain.PauseReason.RATE_LIMITED ->
            StatusCopy("Instagram asked us to wait", "We've paused because Instagram asked us to wait. We'll try again automatically.", true, StatusCopy.Action.TRY_AGAIN)
        app.delore.android.domain.PauseReason.SESSION_EXPIRED ->
            StatusCopy("Instagram signed you out", "Reconnect your account, then come back to continue. Nothing else was touched.", true, StatusCopy.Action.RECONNECT)
        app.delore.android.domain.PauseReason.VERIFICATION_REQUIRED ->
            StatusCopy("Instagram is asking you to verify your account.", "Open Instagram and follow its steps, then come back here. Retract isn't responsible for what Instagram does.", true, StatusCopy.Action.RESUME_AFTER_VERIFYING)
        app.delore.android.domain.PauseReason.REPEATED_FAILURES ->
            StatusCopy("Instagram isn't cooperating", "Instagram stopped responding. We'll try again in about 3 minutes — you can leave Retract open in the background.", true, StatusCopy.Action.TRY_AGAIN)
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
