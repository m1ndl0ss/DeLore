package app.delore.android.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.AutoDelete
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import app.delore.android.AppViewModel
import app.delore.android.BuildConfig
import app.delore.android.CleanupSetupState
import app.delore.android.LoginPurpose
import app.delore.android.MainTab
import app.delore.android.PreparedCleanup
import app.delore.android.Route
import app.delore.android.Sheet
import app.delore.android.StatusCopy
import app.delore.android.StatusCopyFactory
import app.delore.android.SyncPauseKind
import app.delore.android.TermsPrompt
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextDecoration
import app.delore.android.billing.PromoCatalog
import app.delore.android.billing.PromoOffer
import app.delore.android.billing.PromoRedeemResult
import app.delore.android.billing.PurchaseOutcome
import app.delore.android.billing.StoreProduct
import app.delore.android.domain.CleanupAllowanceDecision
import app.delore.android.domain.CleanupScope
import app.delore.android.domain.ConversationID
import app.delore.android.domain.ConversationSummary
import app.delore.android.domain.LibraryOverview
import app.delore.android.domain.MessageKind
import app.delore.android.domain.JobStatus
import app.delore.android.domain.inflect
import app.delore.android.domain.title
import app.delore.android.instagram.InstagramWebViewGateway
import app.delore.android.persist.CleanupHistoryEntry
import kotlinx.coroutines.launch
import java.text.NumberFormat
import java.util.Locale

@Composable
fun DeLoreRoot(model: AppViewModel) {
    val state by model.state.collectAsState()
    LaunchedEffect(Unit) { model.bootstrap() }
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Palette.accent,
            onPrimary = Palette.onAccent,
            background = Palette.backgroundDark,
            surface = Palette.surfaceDark,
            onBackground = Palette.inkDark,
            onSurface = Palette.inkDark,
            secondary = Palette.lilac,
        ),
    ) {
        Box(Modifier.fillMaxSize()) {
            val covering = state.loginPurpose != null ||
                state.termsPrompt != null ||
                state.syncing ||
                state.syncErrorTitle != null ||
                (state.sessionPresented && state.progress != null)
            if (state.route != Route.HOME || covering) {
                MeshBackground(Modifier.matchParentSize())
            }
            InstagramBrowserHost(model.environment.webBrowser)
            when (state.route) {
                Route.LAUNCHING -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Wordmark() }
                Route.HOME -> if (!covering) MainTabs(model)
            }
            if (state.termsPrompt != null) {
                TermsAcceptScreen(
                    reminder = state.termsPrompt == TermsPrompt.REMINDER,
                    onPrimary = { dontShow -> model.acceptTermsPrompt(dontShow) },
                    onCancel = { model.cancelTermsPrompt() },
                    onReviewDemo = { model.openSampleInbox() },
                )
            }
            if (state.loginPurpose != null) {
                InstagramLoginScreen(
                    onComplete = { session -> model.handleLogin(session, state.loginPurpose!!) },
                    onCancel = { model.cancelLogin() },
                    onReviewDemo = { model.openSampleInbox() },
                )
            }
            if (state.sessionPresented && state.progress != null) {
                CleanupRunScreen(model)
            }
            if (!state.syncing && state.syncErrorTitle == null) {
                state.sheet?.let { SheetHost(model, it) }
            }
            if (state.syncing || state.syncErrorTitle != null) {
                InboxSyncScreen(model)
            }
        }
    }
}

@Composable
private fun InstagramBrowserHost(gateway: InstagramWebViewGateway) {
    AndroidView(
        modifier = Modifier
            .size(360.dp, 640.dp)
            .offset(x = (-4800).dp),
        factory = { context ->
            val view = gateway.attach(context)
            (view.parent as? android.view.ViewGroup)?.removeView(view)
            view
        },
    )
}

@Composable
private fun MainTabs(model: AppViewModel) {
    val state by model.state.collectAsState()
    Scaffold(
        containerColor = Color.Transparent,
        contentColor = Palette.ink(),
        bottomBar = {
            Column {
                Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.hairlineDark))
                NavigationBar(
                containerColor = Palette.backgroundDark.copy(alpha = 0.62f),
                tonalElevation = 0.dp,
            ) {
                listOf(
                    Triple(MainTab.UNSENDING, "Unsending", Icons.Outlined.AutoDelete),
                    Triple(MainTab.ACTIVITY, "Activity", Icons.Outlined.History),
                    Triple(MainTab.SETTINGS, "Settings", Icons.Outlined.Settings),
                ).forEach { (tab, label, icon) ->
                    NavigationBarItem(
                        selected = state.tab == tab,
                        onClick = { model.selectTab(tab) },
                        icon = { Icon(icon, contentDescription = label, modifier = Modifier.size(22.dp)) },
                        label = {
                            Text(label, fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 11.sp)
                        },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = Palette.accent,
                            selectedTextColor = Palette.accent,
                            indicatorColor = Color.Transparent,
                            unselectedIconColor = Palette.tertiaryDark,
                            unselectedTextColor = Palette.tertiaryDark,
                        ),
                    )
                }
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize()) {
            MeshBackground(Modifier.matchParentSize())
            Box(Modifier.fillMaxSize().padding(padding)) {
                when (state.tab) {
                    MainTab.UNSENDING -> HomeScreen(model)
                    MainTab.ACTIVITY -> ActivityScreen(model)
                    MainTab.SETTINGS -> AccountScreen(model)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AccountScreen(model: AppViewModel) {
    var confirmErase by remember { mutableStateOf(false) }
    var restoreNotice by remember { mutableStateOf<String?>(null) }
    val restoreScope = rememberCoroutineScope()
    val context = LocalContext.current
    val state by model.state.collectAsState()
    LaunchedEffect(Unit) { model.reloadOverview() }
    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Spacing.screen)
            .padding(bottom = Spacing.xl),
        verticalArrangement = Arrangement.spacedBy(Spacing.l),
    ) {
        Spacer(Modifier.height(Spacing.s))
        Text(
            "Settings",
            color = Palette.ink(),
            fontFamily = Type.sans,
            fontWeight = FontWeight.SemiBold,
            fontSize = 26.sp,
            lineHeight = 32.sp,
        )
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(Radius.m))
                .background(Palette.surface())
                .clickable(enabled = !model.hasLiveSession) { model.beginLogin(LoginPurpose.CONNECT) }
                .padding(Metrics.cardInset),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Instagram", color = Palette.ink(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                Text(
                    when {
                        model.hasLiveSession -> "Connected · stays on this phone"
                        state.isDemoMode -> "Sample inbox · not a real account"
                        else -> "Not connected"
                    },
                    color = if (model.hasLiveSession || state.isDemoMode) Palette.accent else Palette.secondaryInk(),
                    fontFamily = Type.sans,
                    fontSize = 14.sp,
                )
            }
            if (!model.hasLiveSession) {
                Box(
                    Modifier
                        .clip(RoundedCornerShape(50))
                        .background(Palette.accent)
                        .clickable { model.beginLogin(LoginPurpose.CONNECT) }
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                ) {
                    Text("Connect", color = Palette.onAccent, fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                }
            }
        }
        Column(Modifier.clip(RoundedCornerShape(Radius.m)).background(Palette.surface())) {
            YouRow("Plan", if (model.entitlements.isPro) "Pro" else "Free · Upgrade") {
                if (!model.entitlements.isPro) model.showSheet(Sheet.Paywall("settings"))
            }
            if (model.entitlements.hasStoreSubscription) {
                YouDivider()
                YouRow("Cancel or manage subscription") {
                    openPlaySubscriptions(context)
                }
            }
            YouDivider()
            YouRow("Restore purchases") {
                restoreScope.launch {
                    val ok = model.entitlements.restore()
                    restoreNotice = if (!ok) "Play Store isn’t reachable."
                    else if (!model.entitlements.isPro) "No Pro plan found."
                    else "Purchases restored."
                }
            }
            restoreNotice?.let {
                Text(
                    it,
                    color = Palette.secondaryInk(),
                    fontFamily = Type.sans,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(horizontal = Metrics.cardInset, vertical = Spacing.s),
                )
            }
        }
        Column(Modifier.clip(RoundedCornerShape(Radius.m)).background(Palette.surface())) {
            YouRow("Privacy") { model.showSheet(Sheet.Privacy) }
            YouDivider()
            YouRow("Support") { model.showSheet(Sheet.Support) }
            YouDivider()
            YouRow("Terms") { model.showSheet(Sheet.Terms) }
        }
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(Radius.m))
                .background(Palette.surface())
                .clickable { confirmErase = true }
                .padding(horizontal = Metrics.cardInset)
                .height(Metrics.button),
            contentAlignment = Alignment.CenterStart,
        ) {
            Text("Delete my data", color = Palette.danger(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        }
    }
    if (confirmErase) {
        AlertDialog(
            onDismissRequest = { confirmErase = false },
            title = { Text("Delete everything on this phone?") },
            text = { Text("Login, chats, history and progress leave this phone. Already unsent messages stay unsent. Purchases stay with your Google account.") },
            confirmButton = {
                QuietButton("Delete my data", tint = Palette.danger()) {
                    confirmErase = false
                    model.eraseEverything()
                }
            },
            dismissButton = { QuietButton("Keep it") { confirmErase = false } },
        )
    }
}

@Composable
private fun YouRow(title: String, value: String? = null, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = Metrics.cardInset, vertical = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            color = Palette.ink(),
            fontFamily = Type.sans,
            fontSize = 17.sp,
            lineHeight = 22.sp,
            modifier = Modifier.weight(1f),
        )
        if (value != null) {
            Text(
                value,
                color = Palette.secondaryInk(),
                fontFamily = Type.sans,
                fontSize = 15.sp,
                lineHeight = 20.sp,
            )
            Spacer(Modifier.size(8.dp))
        }
        Text("›", color = Palette.tertiaryDark, fontSize = 18.sp, lineHeight = 20.sp)
    }
}

@Composable
private fun YouDivider() {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.cardInset)
            .height(0.5.dp)
            .background(Palette.hairline()),
    )
}

@Composable
private fun ActivityScreen(model: AppViewModel) {
    val state by model.state.collectAsState()
    LaunchedEffect(Unit) { model.reloadOverview() }
    val groups = groupedHistory(state.history, state.overview)
    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Spacing.screen)
            .padding(bottom = Spacing.xl),
        verticalArrangement = Arrangement.spacedBy(Spacing.l),
    ) {
        Spacer(Modifier.height(Spacing.s))
        Text("Activity", color = Palette.ink(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 26.sp, lineHeight = 32.sp)
        if (groups.isEmpty()) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(Radius.m))
                    .background(Palette.surface())
                    .padding(Metrics.cardInset),
                verticalArrangement = Arrangement.spacedBy(Spacing.s),
            ) {
                Text("Nothing unsent yet.", color = Palette.ink(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                Text("When you clean, chats show up here. Message text never leaves this phone.", color = Palette.secondaryInk(), fontFamily = Type.sans, fontSize = 15.sp)
            }
        } else {
            Column(Modifier.clip(RoundedCornerShape(Radius.m)).background(Palette.surface())) {
                groups.forEachIndexed { index, group ->
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = Metrics.cardInset, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(group.title, color = Palette.ink(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                            Text(group.detail, color = Palette.secondaryInk(), fontFamily = Type.sans, fontSize = 13.sp)
                        }
                        Text("${group.count}", color = Palette.accent, fontFamily = Type.sans, fontWeight = FontWeight.SemiBold)
                    }
                    if (index < groups.lastIndex) YouDivider()
                }
            }
        }
    }
}

private data class HistoryGroup(val id: String, val title: String, val count: Int, val detail: String)

private fun groupedHistory(
    history: List<CleanupHistoryEntry>,
    overview: LibraryOverview?,
): List<HistoryGroup> {
    val titles = overview?.conversations?.associate { it.id.rawValue to it.title }.orEmpty()
    return history.groupBy { it.conversationID }.map { (id, entries) ->
        val kinds = entries.groupBy { it.kind }.map { (kind, items) ->
            "${kindHistoryLabel(kind)} ×${items.size}"
        }.sorted()
        HistoryGroup(
            id = id,
            title = titles[id] ?: "A chat",
            count = entries.size,
            detail = kinds.joinToString(" · "),
        )
    }.sortedByDescending { it.count }
}

private fun kindHistoryLabel(kind: MessageKind): String = when (kind) {
    MessageKind.TEXT -> "Texts"
    MessageKind.MEDIA -> "Photos"
    MessageKind.LINK -> "Links"
    MessageKind.VOICE -> "Voice"
    MessageKind.OTHER -> "Other"
}

@Composable
private fun InboxSyncScreen(model: AppViewModel) {
    val state by model.state.collectAsState()
    val consumeClicks = remember { MutableInteractionSource() }
    Box(
        Modifier
            .fillMaxSize()
            .clickable(indication = null, interactionSource = consumeClicks) {},
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(Spacing.screen),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Wordmark()
                Spacer(Modifier.weight(1f))
                CloseButton { model.dismissSync() }
            }
            val titles = if (state.inboxRead.isListing) {
                state.inboxRead.foundTitles.ifEmpty {
                    state.overview?.conversations?.map { it.title }.orEmpty()
                }
            } else {
                state.inboxRead.foundTitles
            }
            if (state.syncErrorTitle != null) {
                Spacer(Modifier.height(Spacing.m))
                Text(state.syncErrorTitle!!, color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 20.sp, textAlign = TextAlign.Center)
                Text(state.syncErrorMessage.orEmpty(), color = Palette.secondaryInk(), textAlign = TextAlign.Center, fontSize = 14.sp)
                Spacer(Modifier.height(Spacing.m))
                when (state.syncPauseKind) {
                    SyncPauseKind.HOLD_OFF, null -> OverlayChoiceRow("Keep going", { model.retryInboxNow() }, "I'll wait") { model.acceptInboxHoldOff(later = false) }
                    SyncPauseKind.RECONNECT -> OverlayChoiceRow("Sign in again", { model.signInAgainFromSync() }, "Not now") { model.dismissSync() }
                    SyncPauseKind.VERIFY -> OverlayChoiceRow("I'll handle it", { model.dismissSync() }, "Not now") { model.dismissSync() }
                    SyncPauseKind.OFFLINE -> OverlayChoiceRow("Try again", { model.retryInboxWhenAllowed() }, "Not now") { model.dismissSync() }
                }
            } else {
                val read = state.inboxRead
                Spacer(Modifier.height(Spacing.s))
                Appear {
                    Text(
                        if (read.isComplete) "All set" else read.headline,
                        color = Palette.ink(),
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                }
                Appear(80) {
                    Text(
                        read.detail,
                        color = Palette.accent,
                        fontFamily = Type.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                    )
                }
                Spacer(Modifier.height(Spacing.s))
                LoreProgressBar(read.fraction)
            }
            Spacer(Modifier.height(Spacing.m))
            Text(
                when {
                    titles.isEmpty() && state.syncErrorTitle == null -> "Names land here as we find them"
                    state.syncErrorTitle != null -> "Kept on this phone · ${titles.size}"
                    !state.inboxRead.isListing -> state.inboxRead.displayChat ?: "This chat"
                    else -> "Found so far · ${titles.size}"
                },
                color = Palette.secondaryInk(),
                fontFamily = Type.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(Spacing.s))
            if (titles.isNotEmpty()) {
                LazyColumn(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                    reverseLayout = true,
                ) {
                    itemsIndexed(titles, key = { index, name -> "$index-$name" }) { index, name ->
                        FoundPersonRow(name = name, newest = index == titles.lastIndex)
                    }
                }
            } else {
                Spacer(Modifier.weight(1f))
            }
            Spacer(Modifier.height(Spacing.s))
            Text("This happens on your phone. You can exit — don't close Retract.", color = Palette.secondaryInk(), textAlign = TextAlign.Center, fontSize = 13.sp)
        }
    }
}

@Composable
private fun HomeScreen(model: AppViewModel) {
    val state by model.state.collectAsState()
    val overview = state.overview
    var query by remember { mutableStateOf("") }
    var selection by remember { mutableStateOf(setOf<ConversationID>()) }
    LaunchedEffect(Unit) { model.deletionAppeared() }
    val people = remember(overview, query) {
        val all = overview?.conversations.orEmpty().sortedBy { it.title.lowercase() }
        if (query.isBlank()) all else all.filter { it.title.contains(query.trim(), ignoreCase = true) }
    }
    val selectedPeople = overview?.conversations.orEmpty().filter { it.id in selection }
    val unreadSelected = selectedPeople.count { !it.messagesLoaded }
    val cleanableSelected = selectedPeople.count { it.isCleanable }
    val canAct = selection.isNotEmpty() && (unreadSelected > 0 || cleanableSelected > 0)
    val actionLabel = when {
        selection.isEmpty() -> "Pick people to retract with"
        unreadSelected > 0 -> "Read ${inflect(unreadSelected, "chat")}"
        cleanableSelected > 0 -> "Retract with ${inflect(selection.size, "person", "people")}"
        else -> "Nothing to retract there"
    }
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .padding(horizontal = Spacing.screen)
                .padding(bottom = when {
                    overview != null && overview.conversations.isNotEmpty() && !model.entitlements.isPro -> 196.dp
                    overview != null && overview.conversations.isNotEmpty() -> 88.dp
                    !model.entitlements.isPro -> 120.dp
                    else -> Spacing.xl
                }),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            Spacer(Modifier.height(Spacing.s))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Wordmark(onSecretUnlock = { model.openSampleInbox() })
                Spacer(Modifier.weight(1f))
                if (overview != null && model.hasLiveSession) {
                    IconButton(
                        onClick = { model.refreshChats() },
                        modifier = Modifier.size(44.dp),
                    ) {
                        Icon(
                            Icons.Filled.Refresh,
                            contentDescription = "Refresh",
                            tint = Palette.ink(),
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
                if (model.entitlements.isPro) {
                    Spacer(Modifier.width(20.dp))
                    Box(Modifier.clickable { model.selectTab(MainTab.SETTINGS) }) {
                        Pill("Pro")
                    }
                }
            }
            val progress = state.progress
            if (progress != null && !progress.status.isFinished) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(Radius.m))
                        .background(Palette.surface())
                        .clickable { model.presentSession(true) }
                        .padding(Metrics.cardInset),
                    verticalArrangement = Arrangement.spacedBy(Spacing.s),
                ) {
                    Row {
                        Text(if (progress.status == JobStatus.Running) "Cleaning now" else "Cleanup paused", color = Palette.ink(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.weight(1f))
                        Text("Open", color = Palette.accent, fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                    }
                    LoreProgressBar(progress.fraction)
                    Text(
                        if (progress.status == JobStatus.Running) "${inflect(progress.remaining, "message")} to go. You can exit — don't close Retract."
                        else "Resume. We won't unsend twice.",
                        color = Palette.secondaryInk(),
                        fontFamily = Type.sans,
                        fontSize = 14.sp,
                    )
                }
            }
            if (overview != null && overview.conversations.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Box(Modifier.weight(1f)) { LoreHeadline("Pick who to retract with.") }
                    if (selection.isNotEmpty()) Pill("${selection.size} picked")
                }
                Text(
                    "${inflect(overview.conversations.size, "person", "people")} in your DMs. We only load a chat after you pick it.",
                    color = Palette.secondaryInk(),
                    fontFamily = Type.sans,
                    fontSize = 15.sp,
                )
                if (!model.hasLiveSession && !state.isDemoMode) {
                    Card {
                        Text("Instagram signed you out", color = Palette.ink(), fontWeight = FontWeight.SemiBold)
                        Text("Progress is still on this phone. Reconnect to keep cleaning — we won't unsend twice.", color = Palette.secondaryInk())
                        SecondaryButton("Reconnect Instagram") { model.beginLogin(LoginPurpose.RECONNECT) }
                    }
                }
                if (state.isDemoMode) {
                    Text(
                        "Sample chats for review. Connect Instagram in Settings to use a real account.",
                        color = Palette.secondaryInk(),
                        fontFamily = Type.sans,
                        fontSize = 14.sp,
                    )
                }
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    placeholder = { Text("Search @username", color = Palette.secondaryInk()) },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null, tint = Palette.secondaryInk()) },
                    trailingIcon = if (query.isNotEmpty()) {
                        {
                            Icon(
                                Icons.Filled.Close,
                                contentDescription = "Clear search",
                                tint = Palette.secondaryInk(),
                                modifier = Modifier.clickable { query = "" },
                            )
                        }
                    } else null,
                    shape = RoundedCornerShape(Radius.m),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Palette.ink(),
                        unfocusedTextColor = Palette.ink(),
                        focusedBorderColor = Palette.accent,
                        unfocusedBorderColor = Palette.hairline(),
                        cursorColor = Palette.accent,
                        focusedContainerColor = Palette.surface(),
                        unfocusedContainerColor = Palette.surface(),
                    ),
                )
                if (people.isEmpty() && query.isNotBlank()) {
                    Text(
                        "No one matches that.",
                        color = Palette.secondaryInk(),
                        fontFamily = Type.sans,
                        fontSize = 15.sp,
                    )
                    Spacer(Modifier.weight(1f))
                } else {
                    LazyColumn(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(Spacing.s),
                        contentPadding = PaddingValues(bottom = 88.dp),
                    ) {
                        items(people, key = { it.id.rawValue }) { chat ->
                            ChatRow(chat, chat.id in selection) {
                                selection = if (chat.id in selection) selection - chat.id else selection + chat.id
                            }
                        }
                    }
                }
            } else if (overview != null) {
                LoreHeadline("No DMs on this account.")
            } else if (state.loadingOverview) {
                LoreHeadline("Finding who you talked to.")
                CircularProgressIndicator(color = Palette.accent)
            } else if (model.hasLiveSession) {
                LoreHeadline("Couldn't find your people.")
                Text("Reconnect Instagram and we'll pull the names again.", color = Palette.secondaryInk(), fontFamily = Type.sans, fontSize = 17.sp)
            } else {
                Spacer(Modifier.height(Spacing.m))
                LoreHeadline()
                Text(
                    "Find who you talked to. Retract what you sent. It stays on this phone.",
                    color = Palette.secondaryInk(),
                    fontFamily = Type.sans,
                    fontSize = 17.sp,
                )
            }
        }
        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = Spacing.screen)
                .padding(bottom = Spacing.s),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            if (overview != null && overview.conversations.isNotEmpty()) {
                PrimaryButton(actionLabel, enabled = canAct && (model.isCleanupAvailable || model.hasUnfinishedSession)) {
                    model.retractWith(selection)
                }
            } else if (overview == null && !state.loadingOverview) {
                Appear(160) {
                    ConnectButton(if (model.hasLiveSession) "Find people" else "Connect Instagram") { model.showConnect() }
                }
            }
            if (!model.entitlements.isPro) {
                UpgradeDock(
                    remaining = model.entitlements.remainingFree,
                ) { model.showSheet(Sheet.Paywall("settings")) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SheetHost(model: AppViewModel, sheet: Sheet) {
    val state by model.state.collectAsState()
    ModalBottomSheet(
        onDismissRequest = { model.showSheet(null) },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = if (sheet is Sheet.Paywall) Palette.backgroundDark else Palette.backgroundDark.copy(alpha = 0.78f),
        scrimColor = Color.Black.copy(alpha = 0.42f),
    ) {
        when (sheet) {
            Sheet.Settings -> SettingsSheet(model)
            Sheet.Privacy -> PrivacySheet()
            Sheet.Support -> FAQSheet()
            Sheet.Terms -> TermsSheet()
            Sheet.ChooseChats -> state.overview?.let { ChooseChatsSheet(model, it) }
            Sheet.Included -> state.overview?.let { IncludedSheet(it) }
            is Sheet.Setup -> state.overview?.let { CleanupSetupSheet(model, it, sheet.scope) }
            is Sheet.Paywall -> PaywallSheet(model)
            Sheet.Unavailable -> UnavailableSheet { model.showSheet(null) }
        }
    }
}

@Composable
private fun SettingsSheet(model: AppViewModel) {
    var confirmErase by remember { mutableStateOf(false) }
    var restoreNotice by remember { mutableStateOf<String?>(null) }
    val restoreScope = rememberCoroutineScope()
    val context = LocalContext.current
    val state by model.state.collectAsState()
    Column(Modifier.verticalScroll(rememberScrollState()).padding(Spacing.screen)) {
        Text("Your plan", color = Palette.ink(), fontWeight = FontWeight.Bold, fontSize = 22.sp)
        Spacer(Modifier.height(Spacing.s))
        Row {
            Text(if (model.entitlements.isPro) "Pro" else "Free", color = Palette.ink(), fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            if (!model.entitlements.isPro) {
                Text("${inflect(model.entitlements.remainingFree, "free message")} left", color = Palette.secondaryInk())
            }
        }
        if (!model.entitlements.isPro) {
            Spacer(Modifier.height(Spacing.s))
            PrimaryButton("Get Pro") { model.showSheet(Sheet.Paywall("settings")) }
        } else if (model.entitlements.hasStoreSubscription) {
            Spacer(Modifier.height(Spacing.s))
            SecondaryButton("Cancel or manage subscription") { openPlaySubscriptions(context) }
        }
        Spacer(Modifier.height(Spacing.s))
        QuietButton("Restore purchases") {
            restoreScope.launch {
                val ok = model.entitlements.restore()
                restoreNotice = if (!ok) "Play Store isn’t reachable."
                else if (!model.entitlements.isPro) "No Pro plan found."
                else "Purchases restored."
            }
        }
        restoreNotice?.let { Text(it, color = Palette.secondaryInk(), fontSize = 13.sp) }
        Spacer(Modifier.height(Spacing.l))
        Text("Your data", color = Palette.ink(), fontWeight = FontWeight.Bold, fontSize = 22.sp)
        QuietButton("How we handle your data") { model.showSheet(Sheet.Privacy) }
        if (!model.hasLiveSession) {
            QuietButton(if (state.isDemoMode) "Connect Instagram" else "Reconnect Instagram") {
                model.showSheet(null)
                model.beginLogin(if (state.isDemoMode) LoginPurpose.CONNECT else LoginPurpose.RECONNECT)
            }
        }
        Spacer(Modifier.height(Spacing.l))
        QuietButton("Support") { model.showSheet(Sheet.Support) }
        QuietButton("Privacy policy") { model.showSheet(Sheet.Privacy) }
        QuietButton("Terms of use") { model.showSheet(Sheet.Terms) }
        Spacer(Modifier.height(Spacing.l))
        QuietButton("Disconnect & delete my data", tint = Palette.danger()) { confirmErase = true }
        Text("Removes your chats, Instagram login, cleanup progress and everything else stored on this phone. Purchases stay with your Google account.", color = Palette.secondaryInk(), fontSize = 12.sp)
        Spacer(Modifier.height(Spacing.m))
        Text("Retract ${BuildConfig.VERSION_NAME} · No analytics. Not affiliated with Instagram or Meta. We are not responsible for anything that happens to your Instagram account.", color = Palette.secondaryInk(), fontSize = 12.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(Spacing.xl))
    }
    if (confirmErase) {
        AlertDialog(
            onDismissRequest = { confirmErase = false },
            title = { Text("Disconnect & delete my data?") },
            text = { Text("This removes chats and login from this phone. Purchases stay with your Google account.") },
            confirmButton = {
                QuietButton("Delete", tint = Palette.danger()) {
                    confirmErase = false
                    model.eraseEverything()
                }
            },
            dismissButton = { QuietButton("Cancel") { confirmErase = false } },
        )
    }
}

@Composable
private fun IncludedSheet(overview: LibraryOverview) {
    Column(Modifier.verticalScroll(rememberScrollState()).padding(Spacing.screen), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Text("What's included", color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
        Card {
            Text("Messages you sent", color = Palette.ink(), fontWeight = FontWeight.Bold)
            KindLine("Texts", overview.sentByKind[MessageKind.TEXT] ?: 0)
            KindLine("Photos & videos", overview.sentByKind[MessageKind.MEDIA] ?: 0)
            KindLine("Links & shared posts", overview.sentByKind[MessageKind.LINK] ?: 0)
            KindLine("Voice messages", overview.sentByKind[MessageKind.VOICE] ?: 0)
            val other = overview.sentByKind[MessageKind.OTHER] ?: 0
            if (other > 0) KindLine("Everything else", other)
        }
        Card {
            Text("Messages from others: never touched", color = Palette.ink(), fontWeight = FontWeight.Bold)
            Text("${inflect(overview.receivedFromOthers, "message")} other people sent you stay exactly where they are. Only you can clean what you sent.", color = Palette.secondaryInk())
        }
        Text("Counts come from the chats we read on this phone. Refresh chats to pick up newer messages. Message requests aren't included.", color = Palette.secondaryInk(), fontSize = 13.sp)
        Spacer(Modifier.height(Spacing.xl))
    }
}

@Composable
private fun KindLine(title: String, count: Int) {
    Row {
        Text(title, color = Palette.ink())
        Spacer(Modifier.weight(1f))
        Text(NumberFormat.getIntegerInstance().format(count), color = Palette.ink(), fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun ChooseChatsSheet(model: AppViewModel, overview: LibraryOverview) {
    var selection by remember { mutableStateOf(setOf<ConversationID>()) }
    val chats = overview.conversations
        .filter { !it.messagesLoaded || it.isCleanable }
        .sortedByDescending { if (it.messagesLoaded) it.sentByOwner else Int.MAX_VALUE - 1 }
    val unreadSelected = chats.count { it.id in selection && !it.messagesLoaded }
    val loadedSelected = chats.filter { it.id in selection && it.messagesLoaded }.sumOf { it.sentByOwner }
    val buttonLabel = when {
        selection.isEmpty() -> "Pick at least one chat"
        unreadSelected > 0 -> "Read ${inflect(unreadSelected, "chat")}"
        else -> "Continue with ${inflect(loadedSelected, "message")}"
    }
    Column(Modifier.fillMaxSize().padding(Spacing.screen)) {
        Text("Choose chats", color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
        Spacer(Modifier.height(Spacing.m))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            chats.forEach { chat ->
                ChatRow(chat, chat.id in selection) {
                    selection = if (chat.id in selection) selection - chat.id else selection + chat.id
                }
            }
        }
        PrimaryButton(
            buttonLabel,
            enabled = selection.isNotEmpty(),
        ) {
            model.showSheet(null)
            model.retractWith(selection)
        }
        Spacer(Modifier.height(Spacing.m))
    }
}

@Composable
private fun OverlayChoiceRow(primary: String, onPrimary: () -> Unit, secondary: String, onSecondary: () -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .weight(1f)
                .height(44.dp)
                .clip(RoundedCornerShape(Radius.m))
                .background(Palette.accent)
                .clickable(onClick = onPrimary),
            contentAlignment = Alignment.Center,
        ) {
            Text(primary, color = Palette.onAccent, fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        }
        Box(
            Modifier
                .weight(1f)
                .height(44.dp)
                .clickable(onClick = onSecondary),
            contentAlignment = Alignment.Center,
        ) {
            Text(secondary, color = Palette.secondaryInk(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        }
    }
}

@Composable
private fun FoundPersonRow(name: String, newest: Boolean) {
    val reduce = reduceMotion()
    val clock = rememberInfiniteTransition(label = "found-row")
    val glow by clock.animateFloat(
        initialValue = 0.22f,
        targetValue = 0.55f,
        animationSpec = infiniteRepeatable(tween(900, easing = EaseInOut), RepeatMode.Reverse),
        label = "found-glow",
    )
    val highlight = if (newest && !reduce) glow else 0.22f
    Appear(if (newest) 0 else 40) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(if (newest) Palette.surfaceElevated else Palette.surface())
                .then(
                    if (newest) Modifier.border(1.dp, Palette.accent.copy(alpha = highlight), RoundedCornerShape(12.dp))
                    else Modifier,
                )
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(
                Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(Palette.accent.copy(alpha = 0.22f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    personInitial(name),
                    color = Palette.accent,
                    fontFamily = Type.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                )
            }
            Text(
                name,
                color = Palette.ink(),
                fontFamily = Type.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (newest) {
                Text("new", color = Palette.accent, fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 11.sp)
            }
        }
    }
}

private fun personInitial(name: String): String {
    val cleaned = name.trim().trimStart('@')
    return cleaned.firstOrNull()?.uppercase() ?: "?"
}

@Composable
private fun ChatRow(chat: ConversationSummary, selected: Boolean, onClick: () -> Unit) {
    val scale by animateFloatAsState(if (selected) 1.02f else 1f, tween(180), label = "chat-scale")
    Row(
        Modifier
            .fillMaxWidth()
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(RoundedCornerShape(16.dp))
            .background(if (selected) Palette.surfaceElevated else Palette.surface())
            .border(
                1.dp,
                if (selected) Palette.accent.copy(alpha = 0.5f) else Color.Transparent,
                RoundedCornerShape(16.dp),
            )
            .clickable(onClick = onClick)
            .padding(Spacing.m),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(44.dp)
                .clip(CircleShape)
                .background(Palette.accent.copy(alpha = if (selected) 1f else 0.22f)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                personInitial(chat.title),
                color = if (selected) Palette.onAccent else Palette.accent,
                fontFamily = Type.sans,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Spacer(Modifier.size(Spacing.m))
        Column(Modifier.weight(1f)) {
            Text(chat.title, color = Palette.ink(), fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                when {
                    !chat.messagesLoaded -> "Name only · tap to load"
                    chat.sentByOwner == 0 -> "Nothing from you"
                    else -> "${inflect(chat.sentByOwner, "message")} from you"
                },
                color = Palette.secondaryInk(),
            )
        }
        Icon(
            if (selected) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
            contentDescription = if (selected) "Selected" else "Not selected",
            tint = if (selected) Palette.accent else Palette.hairline(),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CleanupSetupSheet(model: AppViewModel, overview: LibraryOverview, scope: CleanupScope) {
    val setup = remember(overview, scope) { CleanupSetupState(overview, scope, model.environment) }
    var tick by remember { mutableStateOf(0) }
    fun bump() { tick++ }
    @Suppress("UNUSED_EXPRESSION")
    tick
    val isPro = model.entitlements.isPro
    val scopeHandle = rememberCoroutineScope()
    var showPaywall by remember { mutableStateOf(false) }
    var showDate by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Spacing.screen)) {
        Text("Clean up", color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
        Spacer(Modifier.height(Spacing.l))
        Text("What should go?", color = Palette.ink(), fontWeight = FontWeight.Bold, fontSize = 20.sp)
        Spacer(Modifier.height(Spacing.s))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Segment("Everything", setup.scopeKind == CleanupSetupState.ScopeKind.EVERYTHING) {
                setup.scopeKind = CleanupSetupState.ScopeKind.EVERYTHING
                bump()
            }
            Segment("Chosen chats", setup.scopeKind == CleanupSetupState.ScopeKind.CHOSEN) {
                setup.scopeKind = CleanupSetupState.ScopeKind.CHOSEN
                bump()
            }
        }
        if (setup.scopeKind == CleanupSetupState.ScopeKind.CHOSEN) {
            Spacer(Modifier.height(Spacing.s))
            SecondaryButton(if (setup.chosen.isEmpty()) "Pick chats" else "${inflect(setup.chosen.size, "chat")} picked") {
                model.showSheet(Sheet.ChooseChats)
            }
        }
        Spacer(Modifier.height(Spacing.l))
        Card {
            Row {
                Text("Messages you sent", color = Palette.ink(), fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                Text(NumberFormat.getIntegerInstance().format(setup.estimatedCount), color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 22.sp)
            }
            Row {
                Icon(Icons.Filled.Lock, null, tint = Palette.secondaryInk())
                Spacer(Modifier.size(8.dp))
                Text("Messages from others", color = Palette.secondaryInk())
                Spacer(Modifier.weight(1f))
                Text("Never touched", color = Palette.secondaryInk(), fontWeight = FontWeight.Bold)
            }
        }
        Spacer(Modifier.height(Spacing.l))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Filters", color = Palette.ink(), fontWeight = FontWeight.Bold, fontSize = 20.sp)
            Spacer(Modifier.size(8.dp))
            if (!isPro) Pill("Pro")
        }
        Spacer(Modifier.height(Spacing.s))
        Card {
            Text("When they were sent", color = Palette.ink(), fontWeight = FontWeight.Bold)
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                listOf(
                    CleanupSetupState.DateBound.ANY to "Anytime",
                    CleanupSetupState.DateBound.BEFORE to "Before",
                    CleanupSetupState.DateBound.AFTER to "After",
                ).forEach { (value, label) ->
                    Segment(label, setup.dateBound == value) {
                        if (isPro || value == CleanupSetupState.DateBound.ANY) {
                            setup.dateBound = value
                            bump()
                        } else showPaywall = true
                    }
                }
            }
            if (setup.dateBound != CleanupSetupState.DateBound.ANY) {
                QuietButton(if (setup.dateBound == CleanupSetupState.DateBound.BEFORE) "Sent before" else "Sent after") { showDate = true }
            }
            CleanupSetupState.filterableKinds.forEach { kind ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(kind.title(), color = Palette.ink(), modifier = Modifier.weight(1f))
                    Switch(
                        checked = kind in setup.kinds,
                        onCheckedChange = { on ->
                            if (!isPro) {
                                showPaywall = true
                            } else {
                                setup.kinds = if (on) setup.kinds + kind else setup.kinds - kind
                                bump()
                            }
                        },
                    )
                }
            }
        }
        Spacer(Modifier.height(Spacing.l))
        PrimaryButton(if (setup.isPreparing) "Working…" else "Review", enabled = setup.canContinue && !setup.isPreparing) {
            scopeHandle.launch {
                setup.prepare()
                bump()
            }
        }
        if (setup.failed) {
            Text("We couldn't get your messages ready. Try again.", color = Palette.danger())
        }
        setup.prepared?.let { ConfirmBlock(model, setup, it) { bump() } }
        Spacer(Modifier.height(Spacing.xl))
    }
    if (showPaywall) {
        Box(Modifier.fillMaxSize().background(Palette.backgroundDark)) {
            PaywallSheet(model) { showPaywall = false }
        }
    }
    if (showDate) {
        val picker = rememberDatePickerState(initialSelectedDateMillis = setup.cutoff)
        DatePickerDialog(
            onDismissRequest = { showDate = false },
            confirmButton = {
                QuietButton("OK") {
                    picker.selectedDateMillis?.let { setup.cutoff = it }
                    bump()
                    showDate = false
                }
            },
        ) { DatePicker(state = picker) }
    }
}

@Composable
private fun Segment(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        label,
        color = if (selected) Palette.onVolt else Palette.ink(),
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (selected) Palette.accent else Palette.surface())
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    )
}

@Composable
private fun ConfirmBlock(model: AppViewModel, setup: CleanupSetupState, prepared: PreparedCleanup, bump: () -> Unit) {
    val decision = model.entitlements.allowance(prepared.count, setup.usesAdvancedFilters)
    val scope = rememberCoroutineScope()
    Spacer(Modifier.height(Spacing.l))
    if (prepared.count == 0) {
        Text("Nothing to clean here", color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
        Text("Everything you picked is already gone, or doesn't match your filters.", color = Palette.secondaryInk())
        return
    }
    Text("You're about to unsend ${inflect(prepared.count, "message")}.", color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
    model.ratePolicy.estimatedDuration(prepared.count)?.let {
        Text(StatusCopyFactory.timeRemaining(it), color = Palette.secondaryInk(), fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
    }
    Spacer(Modifier.height(Spacing.m))
    Card {
        PromiseRow(Icons.Filled.Visibility, "Unsent messages may already have been seen, copied, screenshotted, or retained elsewhere.")
        PromiseRow(Icons.Filled.Refresh, "This can't be undone.")
        PromiseRow(Icons.Filled.Person, "Only messages you sent.", "Never anyone else's.")
        PromiseRow(Icons.Filled.Shield, "Slow on purpose.", "We pace unsends because Instagram rate-limits. Big cleanups can take hours. You can exit — don't close Retract. That does not protect your account.")
        PromiseRow(Icons.Filled.Warning, "We are not responsible for anything.", LegalCopy.NOT_RESPONSIBLE)
    }
    Spacer(Modifier.height(Spacing.m))
    when (decision) {
        is CleanupAllowanceDecision.Limited -> {
            Card {
                Text(if (decision.remainingFree > 0) "Free covers ${inflect(decision.remainingFree, "message")}" else "You've used your free cleanups", color = Palette.ink(), fontWeight = FontWeight.Bold)
                Text("Unlock everything to clean it all in one go.", color = Palette.secondaryInk())
                PrimaryButton("Unlock everything") { model.showSheet(Sheet.Paywall("limit")) }
                if (decision.remainingFree > 0) {
                    SecondaryButton("Clean ${decision.remainingFree} for free") {
                        scope.launch {
                            setup.prepare(decision.remainingFree)
                            bump()
                        }
                    }
                }
            }
        }
        CleanupAllowanceDecision.FiltersRequirePro -> {
            Card {
                Text("Filters are part of Pro", color = Palette.ink(), fontWeight = FontWeight.Bold)
                PrimaryButton("Unlock Pro") { model.showSheet(Sheet.Paywall("filters")) }
            }
        }
        is CleanupAllowanceDecision.Allowed -> {
            PrimaryButton("Start cleaning") {
                scope.launch { model.startCleanup(PreparedCleanup(prepared.job, decision)) }
            }
            QuietButton("Not now") { model.showSheet(null) }
        }
    }
}

@Composable
private fun UpgradeDock(remaining: Int, modifier: Modifier = Modifier, onUpgrade: () -> Unit) {
    Row(
        modifier
            .fillMaxWidth()
            .shadow(
                elevation = 20.dp,
                shape = RoundedCornerShape(Radius.l),
                ambientColor = Palette.accent.copy(alpha = 0.18f),
                spotColor = Palette.accent.copy(alpha = 0.18f),
            )
            .clip(RoundedCornerShape(Radius.l))
            .background(Palette.surfaceElevated.copy(alpha = 0.92f))
            .border(1.2.dp, Palette.accent.copy(alpha = 0.45f), RoundedCornerShape(Radius.l))
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                "$remaining free unsends",
                color = Palette.ink(),
                fontFamily = Type.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
            )
            Text("Then Pro takes over", color = Palette.secondaryInk(), fontFamily = Type.sans, fontSize = 13.sp)
        }
        Box(
            Modifier
                .shadow(
                    elevation = 12.dp,
                    shape = RoundedCornerShape(50),
                    ambientColor = Palette.cta.copy(alpha = 0.5f),
                    spotColor = Palette.cta.copy(alpha = 0.45f),
                )
                .clip(RoundedCornerShape(50))
                .background(Palette.cta)
                .clickable(onClick = onUpgrade)
                .padding(horizontal = 18.dp, vertical = 10.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("Upgrade", color = Palette.onCta, fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        }
    }
}

@Composable
private fun PaywallSheet(model: AppViewModel, onClose: () -> Unit = { model.showSheet(null) }) {
    PaywallContent(model, embedded = false, onClose = onClose)
}

@Composable
private fun PaywallContent(model: AppViewModel, embedded: Boolean, onClose: () -> Unit = { model.showSheet(null) }) {
    val activity = LocalContext.current.findActivity()
    val scope = rememberCoroutineScope()
    val plans = model.entitlements.products
        .filter { (it.kind == StoreProduct.Kind.YEARLY || it.kind == StoreProduct.Kind.MONTHLY) && !it.isPromo }
        .sortedBy { if (it.kind == StoreProduct.Kind.YEARLY) 0 else 1 }
    var selected by remember { mutableStateOf(plans.firstOrNull { it.kind == StoreProduct.Kind.YEARLY }?.id) }
    var notice by remember { mutableStateOf<String?>(null) }
    var legal by remember { mutableStateOf<String?>(null) }
    var promoCode by remember { mutableStateOf("") }
    var promoNotice by remember { mutableStateOf<String?>(null) }
    var percentOff by remember { mutableStateOf(model.entitlements.percentOff) }
    var appliedCode by remember { mutableStateOf(model.entitlements.appliedPromoCode) }
    var promoLocked by remember { mutableStateOf(model.entitlements.isPromoLocked) }
    val reduce = reduceMotion()
    val glowPulse by rememberInfiniteTransition(label = "planGlow").animateFloat(
        initialValue = 0.7f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2_400), RepeatMode.Reverse),
        label = "planGlowAmt",
    )
    val glow = if (reduce) 0.78f else glowPulse
    LaunchedEffect(Unit) {
        model.entitlements.loadProducts()
        if (selected == null) {
            selected = model.entitlements.products
                .firstOrNull { it.kind == StoreProduct.Kind.YEARLY }?.id
                ?: model.entitlements.products.firstOrNull { it.kind == StoreProduct.Kind.MONTHLY }?.id
        }
    }
    fun buy(product: StoreProduct) {
        val host = activity
        if (host == null) {
            notice = "Play Store isn’t reachable."
            return
        }
        if (percentOff > 0 && model.entitlements.checkoutProduct(product) == null) {
            notice = "That discount isn’t in the store yet."
            return
        }
        selected = product.id
        scope.launch {
            when (model.entitlements.purchase(host, product)) {
                PurchaseOutcome.PURCHASED -> onClose()
                PurchaseOutcome.PENDING -> notice = "Waiting for approval."
                PurchaseOutcome.CANCELLED -> Unit
                null -> notice = "That didn't go through. You haven't been charged."
            }
        }
    }
    fun applyPromo() {
        when (val result = model.entitlements.redeemPromo(promoCode)) {
            PromoRedeemResult.Empty -> promoNotice = "Enter a code first."
            PromoRedeemResult.Locked -> {
                promoLocked = true
                promoNotice = "That's 3 tries for today. Come back tomorrow."
            }
            is PromoRedeemResult.Invalid -> {
                promoLocked = result.remaining == 0
                promoNotice = if (result.remaining == 0) {
                    "That's 3 tries for today. Come back tomorrow."
                } else {
                    "That code isn't valid. ${result.remaining} ${if (result.remaining == 1) "try" else "tries"} left today."
                }
            }
            is PromoRedeemResult.Applied -> {
                promoCode = ""
                appliedCode = model.entitlements.appliedPromoCode
                percentOff = model.entitlements.percentOff
                when (result.offer) {
                    PromoOffer.COMPLIMENTARY -> onClose()
                    PromoOffer.PERCENT_OFF -> promoNotice = "${PromoCatalog.CAMPAIGN_PERCENT_OFF}% off applied."
                }
            }
        }
    }
    when (legal) {
        "terms" -> TermsSheet(onBack = { legal = null })
        "privacy" -> PrivacySheet(onBack = { legal = null })
        else -> Column(
            Modifier
                .fillMaxWidth()
                .background(Palette.backgroundDark)
                .then(if (embedded) Modifier.statusBarsPadding() else Modifier)
                .verticalScroll(rememberScrollState())
                .padding(Spacing.screen)
                .padding(bottom = Spacing.xl),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
        Text("Go Pro", color = Palette.ink(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 26.sp, lineHeight = 32.sp)
        Text(
            if (model.entitlements.isPro) "You're on Pro" else "Unlimited unsends. Pick a plan.",
            color = if (model.entitlements.isPro) Palette.accent else Palette.secondaryInk(),
            fontFamily = Type.sans,
            fontSize = 15.sp,
        )
        if (!model.entitlements.isPro) {
            Text(LegalCopy.NOT_RESPONSIBLE, color = Palette.secondaryInk(), fontFamily = Type.sans, fontSize = 14.sp)
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Spacing.s),
            ) {
                OutlinedTextField(
                    value = promoCode,
                    onValueChange = { promoCode = it.uppercase() },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    enabled = !promoLocked,
                    placeholder = { Text("Promo code", color = Palette.secondaryInk()) },
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Characters,
                        imeAction = ImeAction.Done,
                    ),
                    keyboardActions = KeyboardActions(onDone = { applyPromo() }),
                    shape = RoundedCornerShape(Radius.m),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Palette.ink(),
                        unfocusedTextColor = Palette.ink(),
                        disabledTextColor = Palette.secondaryInk(),
                        focusedBorderColor = Palette.accent,
                        unfocusedBorderColor = Palette.hairline(),
                        cursorColor = Palette.accent,
                        focusedContainerColor = Palette.surface(),
                        unfocusedContainerColor = Palette.surface(),
                        disabledContainerColor = Palette.surface(),
                    ),
                )
                Text(
                    "Apply",
                    color = if (promoLocked || promoCode.isBlank()) Palette.tertiaryDark else Palette.accent,
                    fontFamily = Type.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    modifier = Modifier
                        .clickable(enabled = !promoLocked && promoCode.isNotBlank()) { applyPromo() }
                        .padding(horizontal = Spacing.s, vertical = Spacing.m),
                )
            }
            if (percentOff > 0 && appliedCode != null) {
                Text("$percentOff% off with $appliedCode", color = Palette.accent, fontFamily = Type.sans, fontSize = 13.sp)
            }
            promoNotice?.let { Text(it, color = Palette.secondaryInk(), fontFamily = Type.sans, fontSize = 13.sp) }
        }
        when {
            model.entitlements.isLoadingProducts && plans.isEmpty() -> {
                CircularProgressIndicator(color = Palette.accent, modifier = Modifier.align(Alignment.CenterHorizontally))
            }
            plans.isEmpty() -> {
                Card {
                    Text("Plans aren't available right now", color = Palette.ink(), fontWeight = FontWeight.SemiBold)
                    SecondaryButton("Try again") { scope.launch { model.entitlements.loadProducts() } }
                }
            }
            else -> {
                Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    plans.forEach { product ->
                        val checkout = model.entitlements.checkoutProduct(product)
                        PlanCard(
                            product = product,
                            selected = product.id == selected,
                            glow = glow,
                            purchasing = model.entitlements.isPurchasing,
                            pro = model.entitlements.isPro,
                            percentOff = percentOff,
                            checkoutPrice = if (percentOff > 0) checkout?.displayPrice else null,
                            checkoutMonthly = if (percentOff > 0) checkout?.monthlyEquivalent else null,
                            discountReady = percentOff <= 0 || checkout != null,
                            onSelect = { selected = product.id },
                            onBuy = { buy(product) },
                        )
                    }
                }
            }
        }
        notice?.let { Text(it, color = Palette.secondaryInk(), fontFamily = Type.sans, fontSize = 14.sp) }
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.l), verticalAlignment = Alignment.CenterVertically) {
            QuietLink("Restore") {
                scope.launch {
                    val ok = model.entitlements.restore()
                    notice = if (!ok) "Play Store isn’t reachable."
                    else if (!model.entitlements.isPro) "No Pro plan found."
                    else null
                    if (ok && model.entitlements.isPro) onClose()
                }
            }
            QuietLink("Terms") { legal = "terms" }
            QuietLink("Privacy") { legal = "privacy" }
        }
        Text(
            LegalCopy.SUBSCRIPTION_FINE_PRINT,
            color = Palette.secondaryInk(),
            fontFamily = Type.sans,
            fontSize = 12.sp,
        )
        }
    }
}

@Composable
private fun PlanCard(
    product: StoreProduct,
    selected: Boolean,
    glow: Float,
    purchasing: Boolean,
    pro: Boolean,
    percentOff: Int = 0,
    checkoutPrice: String? = null,
    checkoutMonthly: String? = null,
    discountReady: Boolean = true,
    onSelect: () -> Unit,
    onBuy: () -> Unit,
) {
    val yearly = product.kind == StoreProduct.Kind.YEARLY
    Column(
        Modifier
            .fillMaxWidth()
            .shadow(
                elevation = if (yearly) 18.dp else 10.dp,
                shape = RoundedCornerShape(Radius.l),
                ambientColor = (if (yearly) Palette.cta else Palette.accent).copy(alpha = if (yearly) 0.32f * glow else 0.22f),
                spotColor = (if (yearly) Palette.cta else Palette.accent).copy(alpha = if (yearly) 0.28f * glow else 0.18f),
            )
            .clip(RoundedCornerShape(Radius.l))
            .background(if (yearly) Palette.surfaceElevated else Palette.surfaceDark)
            .border(
                width = if (yearly) 1.8.dp else 1.4.dp,
                color = if (yearly) {
                    Palette.cta.copy(alpha = if (selected) glow else 0.72f)
                } else {
                    Palette.accent.copy(alpha = if (selected) 0.85f else 0.5f)
                },
                shape = RoundedCornerShape(Radius.l),
            )
            .clickable(onClick = onSelect)
            .padding(if (yearly) 20.dp else 16.dp),
        verticalArrangement = Arrangement.spacedBy(Spacing.s),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (yearly) "Yearly" else "Monthly",
                color = Palette.ink(),
                fontFamily = Type.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = if (yearly) 22.sp else 17.sp,
                modifier = Modifier.weight(1f),
            )
            if (yearly) {
                Box(
                    Modifier
                        .clip(RoundedCornerShape(50))
                        .background(Brush.horizontalGradient(listOf(Palette.valueGold, Palette.valuePink)))
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                ) {
                    Text(
                        "Best value",
                        color = Palette.onCtaSoft,
                        fontFamily = Type.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 11.sp,
                    )
                }
            }
        }
        Row(verticalAlignment = Alignment.Bottom) {
            if (percentOff > 0 && checkoutPrice != null) {
                Text(
                    product.displayPrice,
                    color = Palette.secondaryInk(),
                    fontFamily = Type.sans,
                    fontSize = if (yearly) 20.sp else 16.sp,
                    textDecoration = TextDecoration.LineThrough,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
                Spacer(Modifier.size(8.dp))
                Text(
                    checkoutPrice,
                    color = Palette.ink(),
                    fontFamily = Type.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = if (yearly) 34.sp else 24.sp,
                )
            } else {
                Text(
                    product.displayPrice,
                    color = Palette.ink(),
                    fontFamily = Type.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = if (yearly) 34.sp else 24.sp,
                )
            }
            Spacer(Modifier.size(6.dp))
            Text(
                if (yearly) "/ year" else "/ month",
                color = Palette.secondaryInk(),
                fontFamily = Type.sans,
                fontSize = 15.sp,
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }
        (checkoutMonthly ?: product.monthlyEquivalent)?.takeIf { yearly }?.let { monthly ->
            Text("$monthly / mo", color = Palette.accent, fontFamily = Type.sans, fontSize = 14.sp)
        }
        if (yearly) {
            PrimaryButton(
                if (purchasing && selected) "Working…" else "Subscribe yearly",
                enabled = !purchasing && !pro && discountReady,
                onClick = onBuy,
            )
        } else {
            SecondaryButton(
                if (purchasing && selected) "Working…" else "Subscribe monthly",
                enabled = !purchasing && !pro && discountReady,
                onClick = onBuy,
            )
        }
    }
}

@Composable
private fun UnavailableSheet(onClose: () -> Unit) {
    Column(Modifier.padding(Spacing.screen)) {
        Row { Spacer(Modifier.weight(1f)); CloseButton(onClose) }
        Text("Sign in to Instagram first", color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
        Text("Cleaning uses Instagram's own Unsend action from this phone. Reconnect your account, then try again.", color = Palette.secondaryInk())
        Spacer(Modifier.height(Spacing.m))
        Card {
            PromiseRow(Icons.Filled.Lock, "We never see your password", "You sign in on Instagram's page.")
            PromiseRow(Icons.Filled.Shield, "Still private", "Your login stays on this phone.")
            PromiseRow(Icons.Filled.BarChart, "No analytics", "We don't collect identifiers or usage stats.")
        }
        Spacer(Modifier.height(Spacing.l))
        PrimaryButton("Got it", onClick = onClose)
        Spacer(Modifier.height(Spacing.xl))
    }
}

@Composable
private fun CleanupRunScreen(model: AppViewModel) {
    val state by model.state.collectAsState()
    val progress = state.progress ?: return
    val consumeClicks = remember { MutableInteractionSource() }
    var confirmCancel by remember { mutableStateOf(false) }
    BackHandler { if (progress.status != JobStatus.Running) model.presentSession(false) }
    Box(
        Modifier
            .fillMaxSize()
            .clickable(indication = null, interactionSource = consumeClicks) {},
    ) {
        if (progress.status.isFinished) {
            CleanupDoneScreen(model, progress)
        } else {
            val copy = StatusCopyFactory.make(progress.status, progress.resumeNotBefore ?: state.tryAgainAt)
            Column(
                Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(horizontal = Spacing.screen),
            ) {
                Spacer(Modifier.height(Spacing.m))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Wordmark()
                    Spacer(Modifier.weight(1f))
                    if (progress.status != JobStatus.Running) CloseButton { model.presentSession(false) }
                }
                Spacer(Modifier.weight(1f))
                Text(copy.headline, color = Palette.ink(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 28.sp, lineHeight = 34.sp)
                Spacer(Modifier.height(Spacing.m))
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(NumberFormat.getIntegerInstance().format(progress.processed), color = Palette.ink(), fontFamily = Type.sans, fontSize = 48.sp, fontWeight = FontWeight.SemiBold, lineHeight = 52.sp)
                    Text(" / ${NumberFormat.getIntegerInstance().format(progress.total)}", color = Palette.secondaryInk(), fontWeight = FontWeight.Bold, fontSize = 22.sp)
                }
                LoreProgressBar(progress.fraction)
                if (progress.remaining > 0) {
                    val eta = progress.estimatedSecondsRemaining ?: model.ratePolicy.estimatedDuration(progress.remaining)
                    Text(StatusCopyFactory.timeRemaining(eta), color = Palette.secondaryInk(), fontWeight = FontWeight.SemiBold)
                }
                copy.message?.let { message ->
                    Spacer(Modifier.height(Spacing.m))
                    Card {
                        Row {
                            Icon(if (copy.caution) Icons.Filled.Shield else Icons.Filled.Info, null, tint = if (copy.caution) Palette.accentInk() else Palette.secondaryInk())
                            Spacer(Modifier.size(8.dp))
                            Text(message, color = Palette.ink())
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                Text("You can exit. Don't close Retract.", color = Palette.secondaryInk(), fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(Spacing.s))
                when (copy.action) {
                    StatusCopy.Action.PAUSE -> SecondaryButton("Pause") { model.pauseCleanup() }
                    StatusCopy.Action.RESUME -> PrimaryButton("Resume") { model.resumeCleanup() }
                    StatusCopy.Action.TRY_AGAIN -> PrimaryButton("Try again") { model.resumeCleanup() }
                    StatusCopy.Action.RESUME_AFTER_VERIFYING -> PrimaryButton("I've done that, continue") { model.resumeCleanup(userResolvedIssue = true) }
                    StatusCopy.Action.RECONNECT -> {
                        PrimaryButton("Reconnect Instagram") { model.beginLogin(LoginPurpose.RECONNECT) }
                        SecondaryButton("I've signed in, continue") { model.resumeCleanup(userResolvedIssue = true) }
                    }
                    StatusCopy.Action.NONE -> Unit
                }
                QuietButton("Cancel cleanup", tint = Palette.danger()) { confirmCancel = true }
                Spacer(Modifier.height(Spacing.m))
            }
            if (confirmCancel) {
                AlertDialog(
                    onDismissRequest = { confirmCancel = false },
                    title = { Text("Stop cleaning?") },
                    text = { Text("Messages already unsent stay unsent. The rest stay where they are.") },
                    confirmButton = {
                        QuietButton("Stop cleaning", tint = Palette.danger()) {
                            confirmCancel = false
                            model.cancelCleanup()
                        }
                    },
                    dismissButton = { QuietButton("Keep going") { confirmCancel = false } },
                )
            }
        }
    }
}

@Composable
private fun CleanupDoneScreen(model: AppViewModel, progress: app.delore.android.domain.CleanupProgress) {
    val cancelled = progress.status == JobStatus.Cancelled
    val notCleaned = progress.failed + progress.skipped
    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = Spacing.screen),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        Box(
            Modifier
                .size(64.dp)
                .background(Palette.accent, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(if (cancelled) Icons.Filled.Warning else Icons.Filled.Check, null, tint = Palette.onAccent, modifier = Modifier.size(28.dp))
        }
        Spacer(Modifier.height(Spacing.l))
        Text(if (cancelled) "Cleanup stopped" else "Fresh start ✨", color = Palette.ink(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 28.sp, lineHeight = 34.sp, textAlign = TextAlign.Center)
        Text("${inflect(progress.completed, "message")} cleaned.", color = Palette.secondaryInk(), fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        if (notCleaned > 0) {
            Text("${inflect(notCleaned, "message")} couldn't be unsent. They're still there.", color = Palette.secondaryInk(), textAlign = TextAlign.Center)
        }
        Spacer(Modifier.weight(1f))
        PrimaryButton("Done") { model.closeSession() }
        QuietButton("Clean another chat") { model.closeSession(thenChooseChats = true) }
        Spacer(Modifier.height(Spacing.m))
    }
}

private fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return current as? Activity
}

private fun openPlaySubscriptions(context: Context) {
    val intent = Intent(
        Intent.ACTION_VIEW,
        Uri.parse("https://play.google.com/store/account/subscriptions?package=app.delore.android"),
    )
    if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
}
