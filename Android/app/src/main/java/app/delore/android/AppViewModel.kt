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
import app.delore.android.domain.JobStatus
import app.delore.android.domain.LibraryOverview
import app.delore.android.domain.MessageKind
import app.delore.android.engine.CleanupEngine
import app.delore.android.engine.CleanupEngineError
import app.delore.android.engine.QueueBuilder
import app.delore.android.instagram.InstagramWebSession
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

enum class Route { LAUNCHING, WELCOME, CONNECT, HOME }

enum class LoginPurpose { CONNECT, RECONNECT, REFRESH }

sealed class Sheet {
    data object Settings : Sheet()
    data object Privacy : Sheet()
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
    val sheet: Sheet? = null,
    val overview: LibraryOverview? = null,
    val loadingOverview: Boolean = false,
    val loginPurpose: LoginPurpose? = null,
    val syncing: Boolean = false,
    val syncProgress: Double = 0.0,
    val syncErrorTitle: String? = null,
    val syncErrorMessage: String? = null,
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
    private var finishHandled = false
    private var currentJobId: String? = null

    val hasUnfinishedSession: Boolean
        get() = _state.value.progress?.status?.isFinished == false

    fun bootstrap() = viewModelScope.launch {
        val splash = launch { delay(700) }
        env.entitlements.refresh()
        if (!env.hasCompletedOnboarding) {
            splash.join()
            _state.update { it.copy(route = Route.WELCOME) }
            return@launch
        }
        if (env.hasLibrary) {
            reloadOverview()
            restoreSession()
            splash.join()
            _state.update { it.copy(route = Route.HOME) }
        } else if (env.hasLiveSession) {
            splash.join()
            _state.update { it.copy(route = Route.CONNECT) }
            beginInboxSync()
        } else {
            splash.join()
            _state.update { it.copy(route = Route.CONNECT) }
        }
    }

    fun getStarted() {
        _state.update { it.copy(route = Route.CONNECT) }
    }

    fun beginLogin(purpose: LoginPurpose = LoginPurpose.CONNECT) {
        _state.update { it.copy(loginPurpose = purpose) }
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
            delay(350)
            beginInboxSync()
        }
    }

    fun beginInboxSync() {
        _state.update { it.copy(syncing = true, syncProgress = 0.0, syncErrorTitle = null, syncErrorMessage = null) }
        viewModelScope.launch {
            try {
                env.syncInbox { progress -> _state.update { it.copy(syncProgress = progress) } }
                env.hasCompletedOnboarding = true
                reloadOverview()
                _state.update { it.copy(syncing = false, route = Route.HOME) }
            } catch (_: kotlinx.coroutines.CancellationException) {
                _state.update { it.copy(syncing = false) }
            } catch (error: Exception) {
                val (title, message) = syncCopy(error)
                _state.update { it.copy(syncing = false, syncErrorTitle = title, syncErrorMessage = message) }
            }
        }
    }

    fun dismissSync() {
        _state.update { it.copy(syncing = false, syncErrorTitle = null, syncErrorMessage = null) }
    }

    fun refreshChats() {
        if (env.hasLiveSession) beginInboxSync() else beginLogin(LoginPurpose.REFRESH)
    }

    fun showConnect() {
        _state.update { it.copy(route = Route.CONNECT) }
    }

    fun returnHome() {
        if (env.hasLibrary) _state.update { it.copy(route = Route.HOME) }
    }

    fun showSheet(sheet: Sheet?) {
        _state.update { it.copy(sheet = sheet) }
    }

    fun presentSession(present: Boolean) {
        _state.update { it.copy(sessionPresented = present) }
    }

    suspend fun reloadOverview() {
        _state.update { it.copy(loadingOverview = true) }
        val overview = runCatching { env.loadOverview() }.getOrNull()
        _state.update { it.copy(overview = overview, loadingOverview = false) }
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
    }

    fun eraseEverything() = viewModelScope.launch {
        engine?.cancel()
        engine = null
        env.eraseAllData()
        _state.update { UiState(route = Route.WELCOME) }
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
            _state.update { it.copy(progress = progress, sessionPresented = true) }
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

    private fun syncCopy(error: Exception): Pair<String, String> = when (error) {
        IntegrationError.SessionExpired -> "Instagram signed you out" to "Sign in again, then we'll pick up where we left off."
        IntegrationError.VerificationRequired -> "Instagram is asking you to verify your account." to "Open Instagram, follow its steps, then come back. We won't skip that check."
        is IntegrationError.RateLimited -> "We've paused to keep your account safe." to "Instagram asked us to slow down. Try again later."
        IntegrationError.Offline -> "You're offline" to "Connect to the internet and try again."
        else -> "We couldn't read your DMs" to "Try connecting again in a bit."
    }

    class Factory(private val env: AppEnvironment) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = AppViewModel(env) as T
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
                        "We're slowing down on purpose to keep your account safe. Back at it around ${formatTime(coolingDownUntil)}.",
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
            StatusCopy("Instagram asked us to wait", "We've paused the cleanup to keep your account safe. Try again later.", true, StatusCopy.Action.TRY_AGAIN)
        app.delore.android.domain.PauseReason.SESSION_EXPIRED ->
            StatusCopy("Instagram signed you out", "Reconnect your account, then come back to continue. Nothing else was touched.", true, StatusCopy.Action.RECONNECT)
        app.delore.android.domain.PauseReason.VERIFICATION_REQUIRED ->
            StatusCopy("Instagram is asking you to verify your account.", "We've paused the cleanup to keep your account safe. Open Instagram and follow its steps, then come back here.", true, StatusCopy.Action.RESUME_AFTER_VERIFYING)
        app.delore.android.domain.PauseReason.REPEATED_FAILURES ->
            StatusCopy("We've paused the cleanup to keep your account safe.", "Instagram isn't responding the way it should right now. Try again later.", true, StatusCopy.Action.TRY_AGAIN)
        app.delore.android.domain.PauseReason.OFFLINE ->
            StatusCopy("You're offline", "We'll carry on as soon as you're back online.", true, StatusCopy.Action.TRY_AGAIN)
        app.delore.android.domain.PauseReason.UNEXPECTED_RESPONSE ->
            StatusCopy("We stopped to be safe", "Instagram replied in a way we didn't expect. Try again later; we'll double-check before touching anything.", true, StatusCopy.Action.TRY_AGAIN)
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
