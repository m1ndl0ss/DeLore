package app.delore.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object Palette {
    val volt = Color(0xFFD4FF3A)
    val onVolt = Color(0xFF111111)
    val lilac = Color(0xFFB9A8FF)
    private val dangerLight = Color(0xFFC7291F)
    private val dangerDark = Color(0xFFFF7366)
    val backgroundLight = Color(0xFFF7F5F0)
    val backgroundDark = Color(0xFF0E0E10)
    val surfaceLight = Color.White
    val surfaceDark = Color(0xFF1B1B1E)
    val inkLight = Color(0xFF111111)
    val inkDark = Color(0xFFF5F5F2)
    val secondaryLight = Color(0x99000000)
    val secondaryDark = Color(0xA3FFFFFF)
    val hairlineLight = Color(0x14000000)
    val hairlineDark = Color(0x1FFFFFFF)
    val accentInkLight = Color(0xFF4D6600)
    val accentInkDark = Color(0xFFD4FF3A)

    @Composable
    fun background(): Color = if (isSystemInDarkTheme()) backgroundDark else backgroundLight
    @Composable
    fun surface(): Color = if (isSystemInDarkTheme()) surfaceDark else surfaceLight
    @Composable
    fun ink(): Color = if (isSystemInDarkTheme()) inkDark else inkLight
    @Composable
    fun secondaryInk(): Color = if (isSystemInDarkTheme()) secondaryDark else secondaryLight
    @Composable
    fun hairline(): Color = if (isSystemInDarkTheme()) hairlineDark else hairlineLight
    @Composable
    fun accentInk(): Color = if (isSystemInDarkTheme()) accentInkDark else accentInkLight
    @Composable
    fun danger(): Color = if (isSystemInDarkTheme()) dangerDark else dangerLight
}

object Spacing {
    val xs = 6.dp
    val s = 10.dp
    val m = 16.dp
    val l = 24.dp
    val xl = 36.dp
    val screen = 24.dp
}

@Composable
fun Wordmark() {
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(color = Palette.ink(), fontWeight = FontWeight.Black)) { append("delore") }
            withStyle(SpanStyle(color = Palette.accentInk(), fontWeight = FontWeight.Black)) { append(".") }
        },
        fontSize = 20.sp,
        modifier = Modifier.semantics { contentDescription = "DeLore" },
    )
}

@Composable
fun Screen(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .background(Palette.background())
            .padding(horizontal = Spacing.screen),
        content = content,
    )
}

@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier
            .fillMaxWidth()
            .height(56.dp),
        shape = RoundedCornerShape(50),
        colors = ButtonDefaults.buttonColors(containerColor = Palette.volt, contentColor = Palette.onVolt, disabledContainerColor = Palette.volt.copy(alpha = 0.4f)),
    ) {
        Text(text, fontWeight = FontWeight.Bold, fontSize = 17.sp)
    }
}

@Composable
fun SecondaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier
            .fillMaxWidth()
            .height(52.dp),
        shape = RoundedCornerShape(50),
        colors = ButtonDefaults.outlinedButtonColors(containerColor = Palette.surface(), contentColor = Palette.ink()),
        border = androidx.compose.foundation.BorderStroke(1.dp, Palette.hairline()),
    ) {
        Text(text, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun QuietButton(text: String, tint: Color = Palette.secondaryInk(), onClick: () -> Unit) {
    TextButton(onClick = onClick) {
        Text(text, color = tint, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun Card(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(Palette.surface())
            .border(1.dp, Palette.hairline(), RoundedCornerShape(22.dp))
            .padding(Spacing.m),
        verticalArrangement = Arrangement.spacedBy(Spacing.s),
        content = content,
    )
}

@Composable
fun PromiseRow(icon: ImageVector, title: String, detail: String? = null) {
    Row(verticalAlignment = Alignment.Top) {
        Box(
            Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(Palette.volt),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = Palette.onVolt, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.width(Spacing.m))
        Column {
            Text(title, color = Palette.ink(), fontWeight = FontWeight.SemiBold)
            if (detail != null) Text(detail, color = Palette.secondaryInk(), fontSize = 14.sp)
        }
    }
}

@Composable
fun Pill(text: String, filled: Boolean = true) {
    Text(
        text.uppercase(),
        color = if (filled) Palette.onVolt else Palette.ink(),
        fontWeight = FontWeight.Black,
        fontSize = 11.sp,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (filled) Palette.volt else Palette.hairline())
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

@Composable
fun LoreProgressBar(fraction: Double) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(14.dp)
            .clip(RoundedCornerShape(50))
            .background(Palette.hairline()),
    ) {
        Box(
            Modifier
                .fillMaxWidth(fraction.toFloat().coerceIn(0f, 1f).coerceAtLeast(0.02f))
                .height(14.dp)
                .clip(RoundedCornerShape(50))
                .background(Palette.volt),
        )
    }
}

@Composable
fun CloseButton(onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Box(
            Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(Palette.surface())
                .border(1.dp, Palette.hairline(), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Close, contentDescription = "Close", tint = Palette.ink(), modifier = Modifier.size(14.dp))
        }
    }
}
