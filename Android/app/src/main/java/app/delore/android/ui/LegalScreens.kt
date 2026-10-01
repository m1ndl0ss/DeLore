package app.delore.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

@Composable
fun FAQSheet(onBack: (() -> Unit)? = null) {
    val uri = LocalUriHandler.current
    Column(
        Modifier
            .fillMaxWidth()
            .background(Palette.backgroundDark)
            .verticalScroll(rememberScrollState())
            .padding(Spacing.screen),
        verticalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        onBack?.let { QuietButton("Back", onClick = it) }
        Text("FAQ", color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
        Text(
            "If this doesn’t cover it, email $SUPPORT_EMAIL.",
            color = Palette.secondaryInk(),
            fontFamily = Type.sans,
            fontSize = 15.sp,
        )
        LegalCopy.faq.forEach { item ->
            Card {
                Text(item.question, color = Palette.ink(), fontWeight = FontWeight.Bold)
                Text(item.answer, color = Palette.secondaryInk())
            }
        }
        QuietButton("Email $SUPPORT_EMAIL") { uri.openUri(SUPPORT_MAILTO) }
        Spacer(Modifier.height(Spacing.xl))
    }
}

@Composable
fun TermsSheet(onBack: (() -> Unit)? = null) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Palette.backgroundDark)
            .verticalScroll(rememberScrollState())
            .padding(Spacing.screen),
        verticalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        onBack?.let { QuietButton("Back", onClick = it) }
        Text("Terms of use", color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
        LegalCopy.terms.forEach { section ->
            Card {
                Text(section.title, color = Palette.ink(), fontWeight = FontWeight.Bold)
                Text(section.body, color = Palette.secondaryInk())
            }
        }
        Spacer(Modifier.height(Spacing.xl))
    }
}

@Composable
fun TermsAcceptScreen(
    reminder: Boolean,
    onPrimary: (dontShowAgain: Boolean) -> Unit,
    onCancel: () -> Unit,
    onReviewDemo: () -> Unit = {},
) {
    val scroll = rememberScrollState()
    var agreed by remember { mutableStateOf(false) }
    var readThis by remember { mutableStateOf(false) }
    var dontShowAgain by remember { mutableStateOf(false) }
    var measured by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(80)
        measured = true
    }
    val reachedEnd by remember {
        derivedStateOf {
            measured && (scroll.maxValue == 0 || scroll.value >= scroll.maxValue - 32)
        }
    }
    val canContinue = reachedEnd && if (reminder) readThis else agreed
    BackHandler(onBack = onCancel)
    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = Spacing.screen)
            .padding(top = Spacing.s, bottom = Spacing.s),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Wordmark(onSecretUnlock = onReviewDemo)
            Spacer(Modifier.weight(1f))
            CloseButton(onCancel)
        }
        Spacer(Modifier.height(Spacing.m))
        Text(
            if (reminder) "Read this" else "Read this first",
            color = Palette.ink(),
            fontWeight = FontWeight.SemiBold,
            fontSize = 28.sp,
            lineHeight = 34.sp,
        )
        Text(
            if (reminder) "We are not responsible for anything."
            else "Retract is at your own risk. Scroll to the end, then agree, before Instagram.",
            color = Palette.secondaryInk(),
            fontFamily = Type.sans,
            fontSize = 16.sp,
        )
        Spacer(Modifier.height(Spacing.m))
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(scroll),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            LegalCopy.terms.forEach { section ->
                Card {
                    Text(section.title, color = Palette.ink(), fontWeight = FontWeight.Bold)
                    Text(section.body, color = Palette.secondaryInk())
                }
            }
            Spacer(Modifier.height(Spacing.s))
        }
        Spacer(Modifier.height(Spacing.s))
        if (reminder) {
            TermsCheckRow("I read this", readThis) { readThis = it }
            TermsCheckRow("Don't show this again", dontShowAgain) { dontShowAgain = it }
        } else {
            TermsCheckRow("I understand I use Retract at my own risk.", agreed) { agreed = it }
        }
        PrimaryButton(
            when {
                !reachedEnd -> "Scroll to the end first"
                reminder -> "Proceed"
                else -> "I agree — open Instagram"
            },
            enabled = canContinue,
            onClick = { onPrimary(if (reminder) dontShowAgain else true) },
        )
    }
}

@Composable
private fun TermsCheckRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Checkbox) { onCheckedChange(!checked) }
            .padding(vertical = Spacing.s),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.s),
    ) {
        Checkbox(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = CheckboxDefaults.colors(
                checkedColor = Palette.accent,
                uncheckedColor = Palette.secondaryInk(),
                checkmarkColor = Palette.onAccent,
            ),
        )
        Text(
            label,
            color = Palette.ink(),
            fontFamily = Type.sans,
            fontWeight = FontWeight.SemiBold,
            fontSize = 15.sp,
        )
    }
}

@Composable
fun PrivacySheet(onBack: (() -> Unit)? = null) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Palette.backgroundDark)
            .verticalScroll(rememberScrollState())
            .padding(Spacing.screen),
        verticalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        onBack?.let { QuietButton("Back", onClick = it) }
        Text("Privacy", color = Palette.ink(), fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
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
            Text("Cleanup talks to Instagram from this phone, the same way you would unsend a message yourself. Nothing from your DMs is sent to a Retract server. We don't collect analytics, advertising IDs, or other identifiers. There's no tracking or ads. Purchases are handled by Google Play.", color = Palette.secondaryInk())
        }
        Card {
            Text("Sample data", color = Palette.ink(), fontWeight = FontWeight.Bold)
            Text("Retract may include sample chats for App Review and testing. Sample data is fake, stays on this phone, and never contacts Instagram or a real account.", color = Palette.secondaryInk())
        }
        Card {
            Text("Your password", color = Palette.ink(), fontWeight = FontWeight.Bold)
            Text("You type it into Instagram's own sign-in page. We never see it, we never store it, and it never leaves this phone through us.", color = Palette.secondaryInk())
        }
        Text("Retract isn't affiliated with, endorsed by, or connected to Instagram or Meta.", color = Palette.secondaryInk(), fontSize = 13.sp)
        Spacer(Modifier.height(Spacing.xl))
    }
}
