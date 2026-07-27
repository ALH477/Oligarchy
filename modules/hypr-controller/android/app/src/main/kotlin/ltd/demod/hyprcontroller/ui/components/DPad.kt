// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import kotlin.math.abs

/**
 * A proper cross-shaped D-pad, hand-drawn on a single [Canvas] with per-region hit
 * testing — not four Material buttons wearing arrow glyphs. Fires [onMove] once per
 * press with 'u'/'d'/'l'/'r', matching `HyprController.moveFocus`.
 */
@Composable
fun DPad(modifier: Modifier = Modifier, accentColor: Color, onMove: (Char) -> Unit) {
    val haptic = LocalHapticFeedback.current
    var pressedDir by remember { mutableStateOf<Char?>(null) }

    Canvas(
        modifier = modifier
            .size(176.dp)
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = { offset ->
                        val dir = regionFor(offset.x, offset.y, size.width.toFloat(), size.height.toFloat())
                        if (dir != null) {
                            pressedDir = dir
                            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                            onMove(dir)
                        }
                        tryAwaitRelease()
                        pressedDir = null
                    },
                )
            },
    ) {
        drawDPad(accentColor, pressedDir)
    }
}

private fun regionFor(px: Float, py: Float, w: Float, h: Float): Char? {
    val dx = px - w / 2f
    val dy = py - h / 2f
    val deadZone = minOf(w, h) * 0.16f
    if (abs(dx) < deadZone && abs(dy) < deadZone) return null
    return if (abs(dx) > abs(dy)) (if (dx > 0) 'r' else 'l') else (if (dy > 0) 'd' else 'u')
}

private fun DrawScope.drawDPad(accent: Color, pressed: Char?) {
    val w = size.width
    val h = size.height
    val cx = w / 2f
    val cy = h / 2f
    val aw = minOf(w, h) * 0.17f // arm half-width

    val plate = Path().apply {
        moveTo(cx - aw, 0f)
        lineTo(cx + aw, 0f)
        lineTo(cx + aw, cy - aw)
        lineTo(w, cy - aw)
        lineTo(w, cy + aw)
        lineTo(cx + aw, cy + aw)
        lineTo(cx + aw, h)
        lineTo(cx - aw, h)
        lineTo(cx - aw, cy + aw)
        lineTo(0f, cy + aw)
        lineTo(0f, cy - aw)
        lineTo(cx - aw, cy - aw)
        close()
    }
    drawPath(plate, color = Color(0xFF1A1A2E))
    drawPath(plate, color = accent.copy(alpha = 0.45f), style = Stroke(width = 2.5f))

    pressed?.let { dir ->
        val (topLeft, regionSize) = when (dir) {
            'u' -> Offset(cx - aw, 0f) to androidx.compose.ui.geometry.Size(aw * 2, cy - aw)
            'd' -> Offset(cx - aw, cy + aw) to androidx.compose.ui.geometry.Size(aw * 2, cy - aw)
            'l' -> Offset(0f, cy - aw) to androidx.compose.ui.geometry.Size(cx - aw, aw * 2)
            else -> Offset(cx + aw, cy - aw) to androidx.compose.ui.geometry.Size(cx - aw, aw * 2)
        }
        drawRect(color = accent.copy(alpha = 0.4f), topLeft = topLeft, size = regionSize)
    }

    drawCircle(color = Color(0xFF2A2A3E), radius = aw * 1.1f, center = Offset(cx, cy))
    drawCircle(color = accent, radius = aw * 1.1f, center = Offset(cx, cy), style = Stroke(width = 2f))

    arrowGlyph('u', accent, pressed, cx, cy, w, h, aw)
    arrowGlyph('d', accent, pressed, cx, cy, w, h, aw)
    arrowGlyph('l', accent, pressed, cx, cy, w, h, aw)
    arrowGlyph('r', accent, pressed, cx, cy, w, h, aw)
}

private fun DrawScope.arrowGlyph(
    dir: Char,
    accent: Color,
    pressed: Char?,
    cx: Float,
    cy: Float,
    w: Float,
    h: Float,
    aw: Float,
) {
    val half = aw * 0.8f
    val path = Path()
    when (dir) {
        'u' -> {
            val tipY = aw * 0.9f; val baseY = aw * 2.0f
            path.moveTo(cx, tipY); path.lineTo(cx - half, baseY); path.lineTo(cx + half, baseY); path.close()
        }
        'd' -> {
            val tipY = h - aw * 0.9f; val baseY = h - aw * 2.0f
            path.moveTo(cx, tipY); path.lineTo(cx - half, baseY); path.lineTo(cx + half, baseY); path.close()
        }
        'l' -> {
            val tipX = aw * 0.9f; val baseX = aw * 2.0f
            path.moveTo(tipX, cy); path.lineTo(baseX, cy - half); path.lineTo(baseX, cy + half); path.close()
        }
        else -> {
            val tipX = w - aw * 0.9f; val baseX = w - aw * 2.0f
            path.moveTo(tipX, cy); path.lineTo(baseX, cy - half); path.lineTo(baseX, cy + half); path.close()
        }
    }
    val glyphColor = if (pressed == dir) Color(0xFF0A0A0F) else accent.copy(alpha = 0.9f)
    drawPath(path, color = glyphColor)
}
