package app.delore.android.ui

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.delore.android.AppViewModel
import app.delore.android.BuildConfig
import app.delore.android.CleanupSetupState
import app.delore.android.LoginPurpose
import app.delore.android.PreparedCleanup
import app.delore.android.Route
import app.delore.android.Sheet
import app.delore.android.StatusCopy
import app.delore.android.StatusCopyFactory
import app.delore.android.billing.StoreProduct
import app.delore.android.domain.CleanupAllowanceDecision
import app.delore.android.domain.CleanupScope
import app.delore.android.domain.ConversationID
import app.delore.android.domain.ConversationSummary
import app.delore.android.domain.JobStatus
import app.delore.android.domain.LibraryOverview
import app.delore.android.domain.MessageKind
import app.delore.android.domain.inflect
import app.delore.android.domain.title
import app.delore.android.engine.CleanupForegroundService
import kotlinx.coroutines.launch
import java.text.NumberFormat
import java.util.Locale

@Composable
fun DeLoreRoot(model: AppViewModel) {
    val state by model.state.collectAsState()
    LaunchedEffect(Unit) { model.bootstrap() }
    val running = state.progress?.status == JobStatus.Running
    val context = LocalContext.current
    DisposableEffect(running) {
        if (running) CleanupForegroundService.start(context) else CleanupForegroundService.stop(context)
        onDispose { CleanupForegroundService.stop(context) }
    }
    Box(Modifier.fillMaxSize().background(Palette.background())) {
        when (state.route) {
            Route.LAUNCHING -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Wordmark() }
            Route.WELCOME -> WelcomeScreen { model.getStarted() }
            Route.CONNECT -> ConnectScreen(model)
            Route.HOME -> HomeScreen(model)
        }
        if (state.loginPurpose != null) {
            InstagramLoginScreen(
                onComplete = { session -> model.handleLogin(session, state.loginPurpose!!) },
                onCancel = { model.cancelLogin() },
            )
        }
        if (state.syncing || state.syncErrorTitle != null) {
            InboxSyncScreen(model)
        }
        if (state.sessionPresented && state.progress != null) {
            CleanupRunScreen(model)
        }
        state.sheet?.let { SheetHost(model, it) }
    }
}

@Composable
private fun WelcomeScreen(onStart: () -> Unit) {
    Screen {
        Spacer(Modifier.height(Spacing.m))
        Wordmark()
        Spacer(Modifier.weight(1f))
        Text("Delete", color = Palette.ink(), fontSize = 48.sp, fontWeight = FontWeight.Black)
        Text("the lore.", color = Palette.ink(), fontSize = 48.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(Spacing.m))
        Text("Clean up your old DMs without deleting them one by one.", color = Palette.secondaryInk(), fontSize = 18.sp)
        Spacer(Modifier.weight(1f))
        PrimaryButton("Get started", onClick = onStart)
        Spacer(Modifier.height(Spacing.m))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.secondaryInk())
            Spacer(Modifier.size(8.dp))
            Text("On this phone. No analytics. No identifiers.", color = Palette.secondaryInk(), fontSize = 13.sp)
        }
        Spacer(Modifier.height(Spacing.m))
    }
}

@Composable
private fun ConnectScreen(model: AppViewModel) {
    val state by model.state.collectAsState()
    Screen {
        Spacer(Modifier.height(Spacing.m))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Wordmark()
            Spacer(Modifier.weight(1f))
            if (state.overview != null) CloseButton { model.returnHome() }
        }
        Spacer(Modifier.height(Spacing.l))
        Text("Connect Instagram", color = Palette.ink(), fontSize = 34.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(Spacing.s))
        Text("Sign in with Instagram. You'll use Instagram's own page — we never see your password.", color = Palette.secondaryInk())
        Spacer(Modifier.height(Spacing.l))
        Card {
            PromiseRow(Icons.Filled.Lock, "We never see your password", "You type it into Instagram, not into DeLore.")
            PromiseRow(Icons.Filled.Person, "Only messages you sent", "Other people's messages are never touched.")
            PromiseRow(Icons.Filled.PhoneAndroid, "Your login stays on this phone", "Nothing is sent to a DeLore server.")
            PromiseRow(Icons.Filled.Visibility, "Message text is never saved", "We keep dates and message types, not what you said.")
            PromiseRow(Icons.Filled.BarChart, "No analytics or identifiers", "We don't collect device IDs or usage stats.")
        }
        Spacer(Modifier.height(Spacing.m))
        Text("If Instagram asks you to verify, complete it there. We won't skip that check.", color = Palette.secondaryInk())
        Spacer(Modifier.weight(1f))
        PrimaryButton("Connect Instagram") { model.beginLogin(LoginPurpose.CONNECT) }
        Spacer(Modifier.height(Spacing.m))
    }
}

@Composable
private fun InboxSyncScreen(model: AppViewModel) {
    val state by model.state.collectAsState()
    Box(Modifier.fillMaxSize().background(Palette.background())) {
        Column(Modifier.fillMaxSize().padding(Spacing.screen), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(Modifier.fillMaxWidth()) {
                Spacer(Modifier.weight(1f))
                if (state.syncErrorTitle == null) CloseButton { model.dismissSync() }
            }
            Spacer(Modifier.weight(1f))
            if (state.syncErrorTitle != null) {
                Icon(Icons.Filled.Shield, null, tint = Palette.ink(), modifier = Modifier.size(56.dp))
                Spacer(Modifier.height(Spacing.m))
                Text(state.syncErrorTitle!!, color = Palette.ink(), fontWeight = FontWeight.Bold, fontSize = 22.sp, textAlign = TextAlign.Center)
                Text(state.syncErrorMessage.orEmpty(), color = Palette.secondaryInk(), textAlign = TextAlign.Center)
                Spacer(Modifier.height(Spacing.l))
                PrimaryButton("Try again") {
                    model.dismissSync()
                    model.refreshChats()
                }
                QuietButton("Close") { model.dismissSync() }
            } else {
                CircularProgressIndicator(
                    progress = { state.syncProgress.toFloat().coerceIn(0.04f, 1f) },
                    color = Palette.volt,
                    trackColor = Palette.hairline(),
                    modifier = Modifier.size(140.dp),
                    strokeWidth = 14.dp,
                )
                Spacer(Modifier.height(Spacing.l))
                Text(if (state.syncProgress >= 1) "All set" else "Reading your DMs…", color = Palette.ink(), fontWeight = FontWeight.Bold, fontSize = 24.sp)
                Text("This happens on your phone. Nothing is uploaded.", color = Palette.secondaryInk(), textAlign = TextAlign.Center)
            }
            Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun HomeScreen(model: AppViewModel) {
    val state by model.state.collectAsState()
    val overview = state.overview
    Column(
        Modifier
            .fillMaxSize()
            .background(Palette.background())
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Spacing.screen),
    ) {
        Spacer(Modifier.height(Spacing.m))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Wordmark()
            Spacer(Modifier.weight(1f))
            if (model.entitlements.isPro) Pill("Pro")
            Icon(
                Icons.Filled.AccountCircle,
                contentDescription = "You and settings",
                tint = Palette.ink(),
                modifier = Modifier
                    .size(44.dp)
                    .clickable { model.showSheet(Sheet.Settings) },
            )
        }
        val progress = state.progress
        if (progress != null && !progress.status.isFinished) {
            Spacer(Modifier.height(Spacing.m))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(22.dp))
                    .background(Palette.volt)
                    .clickable { model.presentSession(true) }
                    .padding(Spacing.m),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(if (progress.status == JobStatus.Running) Icons.Filled.Star else Icons.Filled.PauseCircle, null, tint = Palette.onVolt)
                Spacer(Modifier.size(Spacing.m))
                Column(Modifier.weight(1f)) {
                    Text(if (progress.status == JobStatus.Running) "Cleaning in progress" else "Cleanup paused", color = Palette.onVolt, fontWeight = FontWeight.Bold)
                    Text(
                        if (progress.status == JobStatus.Running) "${inflect(progress.remaining, "message")} to go"
                        else "Tap Resume. We won't unsend twice.",
                        color = Palette.onVolt,
                    )
                }
                Icon(Icons.Filled.ChevronRight, null, tint = Palette.onVolt)
            }
        }
        Spacer(Modifier.height(Spacing.l))
        if (overview != null) {
            Text("Your DMs", color = Palette.secondaryInk(), fontWeight = FontWeight.SemiBold)
            Text(NumberFormat.getIntegerInstance(Locale.US).format(overview.sentByOwner), color = Palette.ink(), fontSize = 64.sp, fontWeight = FontWeight.Black)
            Text(
                if (overview.sentByOwner == 1) "message you sent, across ${inflect(overview.cleanableConversations.size, "chat")}."
                else "messages you sent, across ${inflect(overview.cleanableConversations.size, "chat")}.",
                color = Palette.secondaryInk(),
            )
            quip(overview.sentByOwner)?.let {
                Spacer(Modifier.height(Spacing.xs))
                Text(it, color = Palette.accentInk(), fontWeight = FontWeight.Bold)
            }
            if (!model.hasLiveSession) {
                Spacer(Modifier.height(Spacing.m))
                Card {
                    Text("Instagram signed you out", color = Palette.ink(), fontWeight = FontWeight.Bold)
                    Text("Reconnect to keep cleaning. Your progress is still on this phone.", color = Palette.secondaryInk())
                    SecondaryButton("Reconnect Instagram") { model.beginLogin(LoginPurpose.RECONNECT) }
                }
            }
            Spacer(Modifier.height(Spacing.l))
            PrimaryButton("Clean up", enabled = overview.sentByOwner > 0) { model.openSetup(CleanupScope.Everything) }
            Spacer(Modifier.height(Spacing.s))
            SecondaryButton("Choose chats", enabled = overview.sentByOwner > 0) {
                if (model.hasUnfinishedSession) model.openSetup(CleanupScope.Everything)
                else model.showSheet(Sheet.ChooseChats)
            }
            Spacer(Modifier.height(Spacing.s))
            SecondaryButton("See what's included") { model.showSheet(Sheet.Included) }
            QuietButton("Refresh chats") { model.refreshChats() }
        } else if (state.loadingOverview) {
            CircularProgressIndicator(Modifier.padding(80.dp).align(Alignment.CenterHorizontally), color = Palette.ink())
        } else {
            Card {
                Text("We couldn't read your DMs", color = Palette.ink(), fontWeight = FontWeight.Bold)
                Text("Connect Instagram again to continue.", color = Palette.secondaryInk())
                SecondaryButton("Connect Instagram") { model.showConnect() }
            }
        }
        Spacer(Modifier.height(Spacing.xl))
    }
}

private fun quip(count: Int): String? = when (count) {
    0 -> "You're all cleaned up."
    in 1 until 500 -> "Light lore. Easy clean."
    in 500 until 5_000 -> "That's a lot of lore."
    else -> if (count >= 5000) "That's a LOT of lore." else null
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SheetHost(model: AppViewModel, sheet: Sheet) {
    val state by model.state.collectAsState()
    ModalBottomSheet(
        onDismissRequest = { model.showSheet(null) },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Palette.background(),
    ) {
        when (sheet) {
            Sheet.Settings -> SettingsSheet(model)
            Sheet.Privacy -> PrivacySheet()
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
    val uri = LocalUriHandler.current
    var confirmErase by remember { mutableStateOf(false) }
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
        }
        Spacer(Modifier.height(Spacing.l))
        Text("Your data", color = Palette.ink(), fontWeight = FontWeight.Bold, fontSize = 22.sp)
        QuietButton("How we handle your data") { model.showSheet(Sheet.Privacy) }
        QuietButton("Refresh chats") {
            model.showSheet(null)
            model.refreshChats()
        }
        if (!model.hasLiveSession) {
            QuietButton("Reconnect Instagram") {
                model.showSheet(null)
                model.beginLogin(LoginPurpose.RECONNECT)
            }
        }
        Spacer(Modifier.height(Spacing.l))
        QuietButton("Support") { uri.openUri(BuildConfig.SUPPORT_URL) }
        QuietButton("Privacy policy") { uri.openUri(BuildConfig.PRIVACY_URL) }
        QuietButton("Terms of use") { uri.openUri(BuildConfig.TERMS_URL) }
        Spacer(Modifier.height(Spacing.l))
        QuietButton("Disconnect & delete my data", tint = Palette.danger()) { confirmErase = true }
        Text("Removes your chats, Instagram login, cleanup progress and everything else stored on this phone. Purchases stay with your Google account.", color = Palette.secondaryInk(), fontSize = 12.sp)
        Spacer(Modifier.height(Spacing.m))
        Text("DeLore ${BuildConfig.VERSION_NAME} · No analytics. Not affiliated with Instagram or Meta.", color = Palette.secondaryInk(), fontSize = 12.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
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
private fun PrivacySheet() {
    Column(Modifier.verticalScroll(rememberScrollState()).padding(Spacing.screen), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Text("Privacy", color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 28.sp)
        PromiseRow(Icons.Filled.PhoneAndroid, "Your Instagram content is processed on your phone.")
        PromiseRow(Icons.Filled.Lock, "We don't sell or store your messages.")
        PromiseRow(Icons.Filled.Visibility, "We don't need your message content to provide the cleanup.")
        PromiseRow(Icons.Filled.BarChart, "No analytics. No identifiers sent to us.")
        Card {
            Text("What stays on this phone", color = Palette.ink(), fontWeight = FontWeight.Bold)
            Text("Your Instagram login for this app, your chat names, and the date and type of each message you sent. Never what the messages say. It's encrypted on this device and deleted when you tap Disconnect & delete my data.", color = Palette.secondaryInk())
        }
        Card {
            Text("What leaves this phone", color = Palette.ink(), fontWeight = FontWeight.Bold)
            Text("Cleanup talks to Instagram from this phone, the same way you would unsend a message yourself. Nothing from your DMs is sent to a DeLore server. We don't collect analytics, advertising IDs, or other identifiers. There's no tracking or ads. Purchases are handled by Google Play.", color = Palette.secondaryInk())
        }
        Card {
            Text("Your password", color = Palette.ink(), fontWeight = FontWeight.Bold)
            Text("You type it into Instagram's own sign-in page. We never see it, we never store it, and it never leaves this phone through us.", color = Palette.secondaryInk())
        }
        Text("DeLore isn't affiliated with, endorsed by, or connected to Instagram or Meta.", color = Palette.secondaryInk(), fontSize = 13.sp)
        Spacer(Modifier.height(Spacing.xl))
    }
}

@Composable
private fun IncludedSheet(overview: LibraryOverview) {
    Column(Modifier.verticalScroll(rememberScrollState()).padding(Spacing.screen), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Text("What's included", color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 28.sp)
        Card {
            Text("Messages you sent", color = Palette.ink(), fontWeight = FontWeight.Bold)
            KindLine("Texts", overview.sentByKind[MessageKind.TEXT] ?: 0)
            KindLine("Photos & videos", overview.sentByKind[MessageKind.MEDIA] ?: 0)
            KindLine("Links & shared posts", overview.sentByKind[MessageKind.LINK] ?: 0)
            KindLine("Voice messages", overview.sentByKind[MessageKind.VOICE] ?: 0)
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
    val chats = overview.cleanableConversations.sortedByDescending { it.sentByOwner }
    val selectedCount = overview.cleanableConversations.filter { it.id in selection }.sumOf { it.sentByOwner }
    Column(Modifier.fillMaxSize().padding(Spacing.screen)) {
        Text("Choose chats", color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 28.sp)
        Spacer(Modifier.height(Spacing.m))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            chats.forEach { chat ->
                ChatRow(chat, chat.id in selection) {
                    selection = if (chat.id in selection) selection - chat.id else selection + chat.id
                }
            }
        }
        PrimaryButton(
            if (selection.isEmpty()) "Pick at least one chat" else "Continue with ${inflect(selectedCount, "message")}",
            enabled = selection.isNotEmpty(),
        ) { model.openSetup(CleanupScope.Conversations(selection)) }
        Spacer(Modifier.height(Spacing.m))
    }
}

@Composable
private fun ChatRow(chat: ConversationSummary, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Palette.surface())
            .clickable(onClick = onClick)
            .padding(Spacing.m),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(44.dp).clip(CircleShape).background(Palette.lilac), contentAlignment = Alignment.Center) {
            Text(chat.title.take(1).uppercase(), color = Palette.onVolt, fontWeight = FontWeight.Black)
        }
        Spacer(Modifier.size(Spacing.m))
        Column(Modifier.weight(1f)) {
            Text(chat.title, color = Palette.ink(), fontWeight = FontWeight.SemiBold, maxLines = 1)
            Text("${inflect(chat.sentByOwner, "message")} from you", color = Palette.secondaryInk())
        }
        Icon(if (selected) Icons.Filled.CheckCircle else Icons.Filled.Check, null, tint = if (selected) Palette.accentInk() else Palette.hairline())
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
        Text("Clean up", color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 28.sp)
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
                Text(NumberFormat.getIntegerInstance().format(setup.estimatedCount), color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 22.sp)
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
        PaywallSheet(model)
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
            .background(if (selected) Palette.volt else Palette.surface())
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
        Text("Nothing to clean here", color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 28.sp)
        Text("Everything you picked is already gone, or doesn't match your filters.", color = Palette.secondaryInk())
        return
    }
    Text("You're about to unsend ${inflect(prepared.count, "message")}.", color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 28.sp)
    model.ratePolicy.estimatedDuration(prepared.count)?.let {
        Text(StatusCopyFactory.timeRemaining(it), color = Palette.secondaryInk(), fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
    }
    Spacer(Modifier.height(Spacing.m))
    Card {
        PromiseRow(Icons.Filled.Visibility, "Unsent messages may already have been seen, copied, screenshotted, or retained elsewhere.")
        PromiseRow(Icons.Filled.Refresh, "This can't be undone.")
        PromiseRow(Icons.Filled.Person, "Only messages you sent.", "Never anyone else's.")
        PromiseRow(Icons.Filled.Shield, "Slow on purpose.", "We pace things to keep your account safe, so big cleanups can take hours. Keep the app open while cleaning.")
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
            if (decision.consumesPass) Text("Uses your one-time cleanup", color = Palette.secondaryInk())
            PrimaryButton("Start cleaning") {
                scope.launch { model.startCleanup(PreparedCleanup(prepared.job, decision)) }
            }
            QuietButton("Not now") { model.showSheet(null) }
        }
    }
}

@Composable
private fun PaywallSheet(model: AppViewModel) {
    val activity = LocalContext.current as Activity
    val scope = rememberCoroutineScope()
    var selected by remember { mutableStateOf(model.entitlements.products.firstOrNull { it.kind == StoreProduct.Kind.MONTHLY }?.id) }
    var notice by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { model.entitlements.loadProducts() }
    val monthly = model.entitlements.products.firstOrNull { it.kind == StoreProduct.Kind.MONTHLY }?.displayPrice ?: "$19.99"
    Column(Modifier.verticalScroll(rememberScrollState()).padding(Spacing.screen), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Text("Clean it all.", color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 34.sp)
        Text("First ${model.entitlements.freeLimit} messages are free. After that, Pro is $monthly a month — or clean once without a subscription.", color = Palette.secondaryInk())
        PromiseRow(Icons.Filled.Star, "Unlimited cleanup", "Every chat, every message you sent.")
        PromiseRow(Icons.Filled.DateRange, "Date & type filters", "Only old stuff. Only photos. Your call.")
        PromiseRow(Icons.Filled.Lock, "No analytics. No identifiers.", "We don't collect advertising IDs, device IDs, or usage stats.")
        model.entitlements.products.forEach { product ->
            val on = product.id == selected
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(20.dp))
                    .background(if (on) Palette.volt else Palette.surface())
                    .clickable { selected = product.id }
                    .padding(Spacing.m),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    if (product.kind == StoreProduct.Kind.YEARLY) Pill("Best value", filled = !on)
                    Text(
                        when (product.kind) {
                            StoreProduct.Kind.YEARLY -> "Pro · Yearly"
                            StoreProduct.Kind.MONTHLY -> "Pro · Monthly"
                            StoreProduct.Kind.ONE_TIME -> "One-time cleanup"
                        },
                        color = if (on) Palette.onVolt else Palette.ink(),
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        when (product.kind) {
                            StoreProduct.Kind.YEARLY -> product.monthlyEquivalent?.let { "Just $it/month, billed yearly" } ?: "Billed yearly"
                            StoreProduct.Kind.MONTHLY -> "After your free messages. Cancel anytime."
                            StoreProduct.Kind.ONE_TIME -> "Clean everything once. No subscription."
                        },
                        color = if (on) Palette.onVolt else Palette.secondaryInk(),
                    )
                }
                Text(product.displayPrice, color = if (on) Palette.onVolt else Palette.ink(), fontWeight = FontWeight.Black)
            }
        }
        notice?.let { Text(it, color = Palette.secondaryInk()) }
        PrimaryButton(if (model.entitlements.isPurchasing) "Working…" else "Continue", enabled = selected != null && !model.entitlements.isPurchasing) {
            val product = model.entitlements.products.firstOrNull { it.id == selected } ?: return@PrimaryButton
            scope.launch {
                val outcome = model.entitlements.purchase(activity, product)
                if (outcome == null) notice = "That didn't go through. You haven't been charged."
            }
        }
        Text("Pro renews automatically until you cancel in Play Store. A one-time cleanup covers one full cleanup and doesn't renew.", color = Palette.secondaryInk(), fontSize = 12.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(Spacing.xl))
    }
}

@Composable
private fun UnavailableSheet(onClose: () -> Unit) {
    Column(Modifier.padding(Spacing.screen)) {
        Row { Spacer(Modifier.weight(1f)); CloseButton(onClose) }
        Text("Sign in to Instagram first", color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 28.sp)
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
    BackHandler { if (!progress.status.let { it == JobStatus.Running }) model.presentSession(false) }
    if (progress.status.isFinished) {
        CleanupDoneScreen(model, progress)
        return
    }
    val copy = StatusCopyFactory.make(progress.status, progress.resumeNotBefore ?: state.tryAgainAt)
    var confirmCancel by remember { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxSize()
            .background(Palette.background())
            .padding(horizontal = Spacing.screen),
    ) {
        Spacer(Modifier.height(Spacing.m))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Wordmark()
            Spacer(Modifier.weight(1f))
            if (progress.status != JobStatus.Running) CloseButton { model.presentSession(false) }
        }
        Spacer(Modifier.weight(1f))
        Text(copy.headline, color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 32.sp)
        Spacer(Modifier.height(Spacing.m))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(NumberFormat.getIntegerInstance().format(progress.processed), color = Palette.ink(), fontSize = 56.sp, fontWeight = FontWeight.Black)
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
        Text("Keep DeLore open while we clean.", color = Palette.secondaryInk(), fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        Text("If Instagram asks us to wait, we wait — on purpose, to keep your account safe.", color = Palette.secondaryInk(), fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
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

@Composable
private fun CleanupDoneScreen(model: AppViewModel, progress: app.delore.android.domain.CleanupProgress) {
    val cancelled = progress.status == JobStatus.Cancelled
    val notCleaned = progress.failed + progress.skipped
    Column(
        Modifier
            .fillMaxSize()
            .background(Palette.background())
            .padding(horizontal = Spacing.screen),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(128.dp).clip(CircleShape).background(Palette.volt), contentAlignment = Alignment.Center) {
            Icon(if (cancelled) Icons.Filled.Warning else Icons.Filled.Check, null, tint = Palette.onVolt, modifier = Modifier.size(52.dp))
        }
        Spacer(Modifier.height(Spacing.l))
        Text(if (cancelled) "Cleanup stopped" else "Fresh start ✨", color = Palette.ink(), fontWeight = FontWeight.Black, fontSize = 34.sp, textAlign = TextAlign.Center)
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
