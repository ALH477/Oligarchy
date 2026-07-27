// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlin.math.floor
import kotlin.math.sin

/** Cheap, allocation-free hash noise (the classic GLSL `sin(x*k)*big` trick) — used
 * for the "searching" jitter so the draw loop never allocates a Random per frame. */
private fun hashNoise(seed: Float): Float {
    val s = sin(seed * 12.9898f) * 43758.5453f
    return s - floor(s) // fractional part, range 0 up to (but not including) 1
}

/**
 * A live oscilloscope-style trace standing in for connection state: flat when idle,
 * jittery while [scanning], a smooth travelling sine once [active]. Echoes the
 * `dm.waveform` ring-buffer widget from `/mnt/skills/user/demod-ui`.
 */
@Composable
fun SignalWaveform(
    modifier: Modifier = Modifier,
    color: Color,
    active: Boolean,
    scanning: Boolean = false,
    strokeWidth: Float = 2.6f,
) {
    val infinite = rememberInfiniteTransition(label = "waveform")
    val phase by infinite.animateFloat(
        initialValue = 0f,
        targetValue = (2 * Math.PI).toFloat(),
        animationSpec = infiniteRepeatable(tween(1600, easing = LinearEasing)),
        label = "phase",
    )
    Canvas(modifier = modifier) {
        val midY = size.height / 2f
        val path = Path()
        val step = 4f
        var x = 0f
        var first = true
        while (x <= size.width) {
            val y = when {
                scanning -> midY + (hashNoise(phase * 3f + x * 0.15f) - 0.5f) * size.height * 0.7f
                active -> midY + sin((x / size.width) * 4f * Math.PI.toFloat() + phase) * size.height * 0.32f
                else -> midY
            }
            if (first) {
                path.moveTo(x, y)
                first = false
            } else {
                path.lineTo(x, y)
            }
            x += step
        }
        drawPath(path, color = color, style = Stroke(width = strokeWidth, cap = StrokeCap.Round))
        if (!active && !scanning) {
            // a flat trace alone reads as "frozen"; a very faint baseline glow keeps
            // it legible as "idle instrument", not "broken widget"
            drawLine(color.copy(alpha = 0.15f), Offset(0f, midY), Offset(size.width, midY), strokeWidth = strokeWidth)
        }
    }
}
