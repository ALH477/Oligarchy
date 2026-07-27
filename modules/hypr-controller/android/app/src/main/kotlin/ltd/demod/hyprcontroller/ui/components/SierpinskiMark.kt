// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.components

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke

/**
 * The Sierpinski triangle — demod-ui's signature rendering primitive
 * (`/mnt/skills/user/demod-ui`) — reimplemented in Compose Canvas as this app's
 * logo mark instead of a generic launcher glyph. Breathes gently while [pulse]
 * (used for the "discovering" state); sits still and glowing once connected.
 */
@Composable
fun SierpinskiMark(
    modifier: Modifier = Modifier,
    color: Color,
    depth: Int = 4,
    pulse: Boolean = false,
) {
    val infinite = rememberInfiniteTransition(label = "sierpinski-pulse")
    val pulseScale by infinite.animateFloat(
        initialValue = 0.88f,
        targetValue = 1.06f,
        animationSpec = infiniteRepeatable(tween(950, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "sierpinski-scale",
    )
    val scale = if (pulse) pulseScale else 1f

    Canvas(modifier = modifier.scale(scale)) {
        drawSierpinski(color, depth)
    }
}

private fun DrawScope.drawSierpinski(color: Color, depth: Int) {
    val w = size.width
    val h = size.height

    fun recurse(x0: Float, y0: Float, x1: Float, y1: Float, x2: Float, y2: Float, d: Int) {
        if (d == 0) {
            val path = Path().apply {
                moveTo(x0, y0)
                lineTo(x1, y1)
                lineTo(x2, y2)
                close()
            }
            drawPath(path, color = color, style = Stroke(width = 1.6f))
            return
        }
        val mx01 = (x0 + x1) / 2f; val my01 = (y0 + y1) / 2f
        val mx12 = (x1 + x2) / 2f; val my12 = (y1 + y2) / 2f
        val mx20 = (x2 + x0) / 2f; val my20 = (y2 + y0) / 2f
        recurse(x0, y0, mx01, my01, mx20, my20, d - 1)
        recurse(mx01, my01, x1, y1, mx12, my12, d - 1)
        recurse(mx20, my20, mx12, my12, x2, y2, d - 1)
    }

    recurse(w / 2f, 0f, 0f, h, w, h, depth)
}
