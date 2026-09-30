package app.delore.android.ui

import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.withStyle
import app.delore.android.R
import app.delore.android.ui.ghost.GhostFibersBackground
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.util.lerp
import kotlinx.coroutines.delay

object Palette {
    val accent = Color(0xFFC9B8FF)
    val onAccent = Color(0xFF121018)
    val cta = Color(0xFF4E3AF0)
    val ctaDeep = Color(0xFF3A28D4)
    val onCta = Color(0xFFFFFFFF)
    val ctaSoft = Color(0xFFF3EEFF)
    val onCtaSoft = Color(0xFF161022)
    val valueGold = Color(0xFFFFC857)
    val valuePink = Color(0xFFFF6B9A)
    val backgroundDark = Color(0xFF100C1C)
    val backgroundTop = Color(0xFF141318)
    val surfaceDark = Color(0xFF1C1C22)
    val surfaceElevated = Color(0xFF26262E)
    val inkDark = Color(0xFFF5F5F7)
    val secondaryDark = Color(0x99FFFFFF)
    val tertiaryDark = Color(0x61FFFFFF)
    val hairlineDark = Color(0x1AFFFFFF)
    val dangerDark = Color(0xFFFF6B73)

    val volt = accent
    val onVolt = onAccent
    val lilac = accent

    @Composable fun background(): Color = backgroundDark
    @Composable fun surface(): Color = surfaceDark
    @Composable fun ink(): Color = inkDark
    @Composable fun secondaryInk(): Color = secondaryDark
    @Composable fun hairline(): Color = hairlineDark
    @Composable fun stamp(): Color = surfaceDark
    @Composable fun accentInk(): Color = accent
    @Composable fun danger(): Color = dangerDark
}

object Type {
    val display = FontFamily(Font(R.font.unbounded_extrabold, FontWeight.ExtraBold))
    val sans = FontFamily(
        Font(R.font.geist_regular, FontWeight.Normal),
        Font(R.font.geist_semibold, FontWeight.SemiBold),
    )
}

object Spacing {
    val xs = 4.dp
    val s = 8.dp
    val m = 16.dp
    val l = 24.dp
    val xl = 32.dp
    val screen = 20.dp
}

object Radius {
    val s = 10.dp
    val m = 14.dp
    val l = 18.dp
}

object Metrics {
    val button = 52.dp
    val icon = 20.dp
    val cardInset = 16.dp
    val progress = 6.dp
}

private val tightLines = TextStyle(
    platformStyle = PlatformTextStyle(includeFontPadding = false),
    lineHeightStyle = LineHeightStyle(
        alignment = LineHeightStyle.Alignment.Center,
        trim = LineHeightStyle.Trim.Both,
    ),
)

private val headlineShadow = tightLines.copy(
    shadow = Shadow(
        color = Color(0xE6000000),
        offset = Offset(0f, 1f),
        blurRadius = 18f,
    ),
)

@Composable
fun Wordmark() {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Image(
            painter = painterResource(R.drawable.brand_mark),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape),
        )
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = Palette.ink(), fontFamily = Type.display, fontWeight = FontWeight.ExtraBold)) { append("retract") }
                withStyle(SpanStyle(color = Palette.accent, fontFamily = Type.display, fontWeight = FontWeight.ExtraBold)) { append(".") }
            },
            fontSize = 18.sp,
            lineHeight = 22.sp,
            fontFamily = Type.display,
            style = tightLines,
        )
    }
}

@Composable
fun reduceMotion(): Boolean {
    val context = LocalContext.current
    return remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}

@Composable
fun MeshBackground(modifier: Modifier = Modifier) {
    GhostFibersBackground(modifier.fillMaxSize())
}

@Composable
fun StampBox(
    modifier: Modifier = Modifier,
    fill: Color = Palette.surface(),
    radius: Dp = Radius.m,
    content: @Composable BoxScope.() -> Unit,
) {
    Box(
        modifier
            .clip(RoundedCornerShape(radius))
            .background(fill)
            .border(1.dp, Palette.accent.copy(alpha = 0.16f), RoundedCornerShape(radius)),
        content = content,
    )
}

@Composable
fun Screen(content: @Composable ColumnScope.() -> Unit) {
    Box(Modifier.fillMaxSize().background(Palette.backgroundDark)) {
        MeshBackground(Modifier.fillMaxSize())
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(horizontal = Spacing.screen),
            content = content,
        )
    }
}

@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        modifier
            .fillMaxWidth()
            .height(Metrics.button)
            .shadow(
                elevation = if (enabled) 16.dp else 0.dp,
                shape = RoundedCornerShape(Radius.m),
                ambientColor = Palette.cta.copy(alpha = 0.55f),
                spotColor = Palette.cta.copy(alpha = 0.45f),
            )
            .clip(RoundedCornerShape(Radius.m))
            .background(
                Brush.verticalGradient(
                    listOf(
                        Palette.cta.copy(alpha = if (enabled) 1f else 0.45f),
                        Palette.ctaDeep.copy(alpha = if (enabled) 1f else 0.4f),
                    ),
                ),
            )
            .border(1.dp, Palette.accent.copy(alpha = if (enabled) 0.35f else 0.12f), RoundedCornerShape(Radius.m))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = Palette.onCta.copy(alpha = if (enabled) 1f else 0.7f), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    }
}

@Composable
fun ConnectButton(text: String = "Connect Instagram", modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val reduce = reduceMotion()
    val clock = rememberInfiniteTransition(label = "connect-glow")
    val pulse by clock.animateFloat(
        initialValue = 0.72f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1600, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "connect-pulse",
    )
    val glow = if (reduce || !enabled) 1f else pulse
    Box(
        modifier
            .fillMaxWidth()
            .height(Metrics.button)
            .shadow(
                elevation = if (enabled) (12 + 8 * glow).dp else 0.dp,
                shape = RoundedCornerShape(Radius.m),
                ambientColor = Palette.accent.copy(alpha = 0.28f * glow),
                spotColor = Palette.accent.copy(alpha = 0.22f * glow),
            )
            .clip(RoundedCornerShape(Radius.m))
            .background(Palette.accent.copy(alpha = if (enabled) 1f else 0.4f))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = Palette.onAccent.copy(alpha = if (enabled) 1f else 0.6f), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    }
}

@Composable
fun SecondaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        modifier
            .fillMaxWidth()
            .height(Metrics.button)
            .clip(RoundedCornerShape(Radius.m))
            .background(Palette.ctaSoft.copy(alpha = if (enabled) 1f else 0.4f))
            .border(1.5.dp, Palette.accent.copy(alpha = if (enabled) 0.95f else 0.35f), RoundedCornerShape(Radius.m))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = Palette.onCtaSoft.copy(alpha = if (enabled) 1f else 0.5f), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    }
}

@Composable
fun QuietButton(text: String, tint: Color = Palette.secondaryInk(), onClick: () -> Unit) {
    TextButton(onClick = onClick) {
        Text(text, color = tint, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
    }
}

@Composable
fun Card(content: @Composable ColumnScope.() -> Unit) {
    StampBox {
        Column(
            Modifier.padding(Metrics.cardInset),
            verticalArrangement = Arrangement.spacedBy(Spacing.s),
            content = content,
        )
    }
}

@Composable
fun PromiseRow(icon: ImageVector, title: String, detail: String? = null) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(Metrics.icon))
        Spacer(Modifier.width(Spacing.m))
        Column {
            Text(title, color = Palette.ink(), fontFamily = Type.sans, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            if (detail != null) Text(detail, color = Palette.secondaryInk(), fontFamily = Type.sans, fontSize = 14.sp)
        }
    }
}

@Composable
fun Pill(text: String, filled: Boolean = true) {
    Text(
        text,
        color = if (filled) Palette.onAccent else Palette.secondaryInk(),
        fontWeight = FontWeight.SemiBold,
        fontSize = 12.sp,
        modifier = Modifier
            .background(if (filled) Palette.accent else Palette.surface(), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}

@Composable
fun LoreHeadline(lead: String = "Take it back.", struck: String = "") {
    val reduce = reduceMotion()
    val isWipe = lead == "Take it back." && struck.isEmpty()
    val risen = remember(lead) { Animatable(if (reduce) 1f else 0f) }
    val strike = remember(lead) { Animatable(if (reduce && isWipe) 1f else 0f) }
    LaunchedEffect(lead, reduce) {
        if (reduce) {
            risen.snapTo(1f)
            if (isWipe) strike.snapTo(1f)
            return@LaunchedEffect
        }
        risen.animateTo(1f, tween(450, easing = EaseOut))
        if (isWipe) {
            delay(120)
            strike.animateTo(1f, tween(700, easing = EaseInOut))
        }
    }
    val strikeValue = strike.value
    val risenValue = risen.value
    Box(
        Modifier
            .semantics { contentDescription = lead }
            .graphicsLayer(alpha = risenValue, translationY = lerp(10f, 0f, risenValue)),
    ) {
        if (isWipe) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    "Take it ",
                    color = Palette.ink(),
                    fontSize = 30.sp,
                    lineHeight = 36.sp,
                    fontFamily = Type.sans,
                    fontWeight = FontWeight.SemiBold,
                    style = headlineShadow,
                )
                Text(
                    "back.",
                    color = Palette.ink().copy(alpha = lerp(1f, 0.82f, strikeValue)),
                    fontSize = 30.sp,
                    lineHeight = 36.sp,
                    fontFamily = Type.sans,
                    fontWeight = FontWeight.SemiBold,
                    style = headlineShadow,
                    modifier = Modifier.drawWithContent {
                        drawContent()
                        val y = size.height * 0.56f
                        drawLine(
                            color = Palette.cta,
                            start = Offset(0f, y),
                            end = Offset(size.width * strikeValue, y),
                            strokeWidth = 4.5f,
                            cap = StrokeCap.Round,
                        )
                    },
                )
            }
        } else {
            Text(
                if (struck.isEmpty()) lead else "$lead $struck",
                color = Palette.ink(),
                fontSize = 28.sp,
                lineHeight = 34.sp,
                fontFamily = Type.sans,
                fontWeight = FontWeight.SemiBold,
                style = headlineShadow,
            )
        }
    }
}

@Composable
fun Appear(delayMs: Int = 0, content: @Composable () -> Unit) {
    val reduce = reduceMotion()
    val t = remember { Animatable(if (reduce) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (!reduce) {
            delay(delayMs.toLong())
            t.animateTo(1f, tween(480, easing = EaseOut))
        }
    }
    val progress = t.value
    Box(Modifier.fillMaxWidth().graphicsLayer(alpha = progress, translationY = lerp(12f, 0f, progress))) {
        content()
    }
}

@Composable
fun QuietLink(title: String, enabled: Boolean = true, onClick: () -> Unit) {
    Text(
        title,
        color = Palette.ink().copy(alpha = if (enabled) 1f else 0.4f),
        fontFamily = Type.sans,
        fontWeight = FontWeight.SemiBold,
        fontSize = 15.sp,
        modifier = Modifier
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 10.dp),
    )
}

@Composable
fun LoreProgressBar(fraction: Double) {
    val reduce = reduceMotion()
    val fill = remember { Animatable(fraction.toFloat().coerceIn(0f, 1f)) }
    LaunchedEffect(fraction) {
        fill.animateTo(fraction.toFloat().coerceIn(0f, 1f), tween(420, easing = EaseOut))
    }
    val clock = rememberInfiniteTransition(label = "progress-shimmer")
    val shimmerPulse by clock.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1400, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "shimmer",
    )
    val shimmer = if (reduce) 0f else shimmerPulse
    Box(
        Modifier
            .fillMaxWidth()
            .height(Metrics.progress)
            .clip(RoundedCornerShape(50))
            .background(Palette.surfaceElevated),
    ) {
        Box(
            Modifier
                .fillMaxWidth(fill.value.coerceAtLeast(0.02f))
                .height(Metrics.progress)
                .background(
                    Brush.horizontalGradient(
                        0f to Palette.accent,
                        (shimmer * 0.85f).coerceIn(0f, 1f) to Palette.accent.copy(alpha = 0.55f),
                        1f to Palette.accent,
                    ),
                ),
        )
    }
}

@Composable
fun CloseButton(onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Box(
            Modifier
                .size(36.dp)
                .background(Palette.surface(), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Close, contentDescription = "Close", tint = Palette.ink(), modifier = Modifier.size(14.dp))
        }
    }
}
