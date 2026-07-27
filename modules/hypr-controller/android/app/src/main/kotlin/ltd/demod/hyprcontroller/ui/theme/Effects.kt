// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.theme

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * A soft "neon" glow behind whatever this modifier is chained before (i.e. put it
 * ahead of `.background()`/`.border()` in the chain, so it paints underneath).
 * Approximated as three stacked, expanding, low-alpha copies of the same rounded
 * rect rather than a true Gaussian blur — [android.graphics.RenderEffect] needs API
 * 31, and this app's minSdk is 26, so this keeps the look on every supported device.
 */
fun Modifier.neonGlow(color: Color, cornerRadius: Dp = 12.dp, intensity: Float = 1f): Modifier = drawBehind {
    val cr = cornerRadius.toPx()
    val layers = listOf(20f to 0.05f, 12f to 0.09f, 6f to 0.16f)
    for ((spreadDp, alpha) in layers) {
        val spread = spreadDp * intensity
        drawRoundRect(
            color = color.copy(alpha = alpha * intensity),
            topLeft = Offset(-spread, -spread),
            size = Size(size.width + spread * 2, size.height + spread * 2),
            cornerRadius = CornerRadius(cr + spread),
        )
    }
}

/**
 * The oscilloscope-phosphor backdrop: a dark radial gradient, faint horizontal
 * scanlines, and a slow, quiet vertical sweep highlight — the same aesthetic
 * `/mnt/skills/user/demod-ui` applies to every DeMoD application, ported to Compose.
 */
@Composable
fun CrtBackground(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val infinite = rememberInfiniteTransition(label = "crt-sweep")
    val sweep by infinite.animateFloat(
        initialValue = -0.25f,
        targetValue = 1.25f,
        animationSpec = infiniteRepeatable(tween(7000, easing = LinearEasing)),
        label = "sweep",
    )
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.radialGradient(
                    colors = listOf(Color(0xFF12121C), DeModColors.DeepBlack),
                    radius = 1600f,
                ),
            )
            .drawBehind {
                var y = 0f
                val gap = 5.dp.toPx()
                while (y < size.height) {
                    drawLine(
                        color = Color.White.copy(alpha = 0.018f),
                        start = Offset(0f, y),
                        end = Offset(size.width, y),
                        strokeWidth = 1f,
                    )
                    y += gap
                }
                val sweepY = sweep * size.height
                drawRect(
                    brush = Brush.verticalGradient(
                        colors = listOf(Color.Transparent, DeModColors.Turquoise.copy(alpha = 0.05f), Color.Transparent),
                        startY = sweepY - 90f,
                        endY = sweepY + 90f,
                    ),
                    topLeft = Offset(0f, sweepY - 90f),
                    size = Size(size.width, 180f),
                )
            },
        content = content,
    )
}
