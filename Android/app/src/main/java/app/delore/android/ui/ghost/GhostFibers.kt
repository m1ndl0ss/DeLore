package app.delore.android.ui.ghost

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import app.delore.android.ui.reduceMotion
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

private val Field = Color(0xFF1A1033)

/** Fiber field painted in Compose so it always sits in the UI layer. */
@Composable
fun GhostFibersBackground(modifier: Modifier = Modifier) {
    val reduce = reduceMotion()
    var time by remember { mutableFloatStateOf(1.6f) }
    LaunchedEffect(reduce) {
        if (reduce) {
            time = 1.6f
            return@LaunchedEffect
        }
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                if (last != 0L) time += (now - last) / 1_000_000_000f
                last = now
            }
        }
    }
    Box(
        modifier
            .fillMaxSize()
            .background(Field),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val w = size.width
            val h = size.height
            if (w < 1f || h < 1f) return@Canvas
            val cx = w * 0.5f
            val cy = h * 0.42f
            drawRect(Field)
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(Color(0xCC7A52E8), Color(0x887050C8), Color.Transparent),
                    center = Offset(cx + w * 0.12f * sin(time * 0.31f), cy + h * 0.08f * cos(time * 0.24f)),
                    radius = min(w, h) * 0.85f,
                ),
            )
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(Color(0x668B6CFF), Color.Transparent),
                    center = Offset(w * 0.18f, h * 0.78f),
                    radius = min(w, h) * 0.48f,
                ),
            )
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(Color(0x5530A0C8), Color.Transparent),
                    center = Offset(w * 0.86f, h * 0.22f),
                    radius = min(w, h) * 0.40f,
                ),
            )
            for (i in 0 until 10) {
                val path = Path()
                val amp = h * (0.045f + i * 0.012f)
                val y0 = h * (0.08f + i * 0.09f)
                val freq = 1.35f + i * 0.19f
                val phase = time * (0.7f + i * 0.09f) + i * 0.8f
                path.moveTo(-60f, y0)
                var x = -60f
                while (x <= w + 60f) {
                    val u = x / w
                    val y = y0 +
                        sin(u * freq * 6.2832f + phase) * amp +
                        sin(u * 2.4f + phase * 0.65f) * amp * 0.45f
                    path.lineTo(x, y)
                    x += 12f
                }
                drawPath(
                    path,
                    Color(0xFFE8DCFF).copy(alpha = 0.28f + (i % 4) * 0.08f),
                    style = Stroke(width = 2.4f + i * 0.5f, cap = StrokeCap.Round),
                )
            }
            drawRect(
                brush = Brush.verticalGradient(
                    0f to Color(0x33120A24),
                    0.55f to Color.Transparent,
                    1f to Color(0x66120A24),
                ),
            )
        }
    }
}
