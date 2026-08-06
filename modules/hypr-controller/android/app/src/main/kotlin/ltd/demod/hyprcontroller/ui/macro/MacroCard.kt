// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.macro

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ltd.demod.hyprcontroller.control.Macro
import ltd.demod.hyprcontroller.ui.theme.DeModColors

@Composable
fun MacroCard(
    macro: Macro,
    isRunning: Boolean,
    progressText: String?,
    onRun: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .border(1.dp, DeModColors.Turquoise.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
            .background(Color(0xFF0D0D14))
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Icon badge
            val badge = macro.iconName ?: macro.name.take(3).uppercase()
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .background(DeModColors.Violet.copy(alpha = 0.2f))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            ) {
                Text(
                    badge,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                    fontSize = 10.sp,
                    color = DeModColors.Violet,
                )
            }

            Spacer(Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    macro.name,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                    color = DeModColors.White,
                )
                if (progressText != null) {
                    Text(
                        progressText,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 10.sp,
                        color = DeModColors.Yellow,
                    )
                }
            }

            Spacer(Modifier.width(8.dp))

            // Action buttons
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                MacroMiniButton("RUN", DeModColors.Turquoise, isRunning, onRun)
                MacroMiniButton("EDIT", DeModColors.White.copy(alpha = 0.6f), false, onEdit)
                MacroMiniButton("DEL", DeModColors.Red, false, onDelete)
            }
        }
    }
}

@Composable
private fun MacroMiniButton(
    label: String,
    accent: Color,
    dimmed: Boolean,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .border(1.dp, accent.copy(alpha = 0.4f), RoundedCornerShape(6.dp))
            .background(if (dimmed) accent.copy(alpha = 0.1f) else Color.Transparent)
            .clickable(enabled = !dimmed, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Text(
            label,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
            fontSize = 10.sp,
            color = if (dimmed) accent.copy(alpha = 0.4f) else accent,
        )
    }
}