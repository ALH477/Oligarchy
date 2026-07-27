// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

// DeMoD design tokens (see /mnt/skills/user/demod-ui/SKILL.md — "the DeMoD visual
// identity must be followed in all applications"). Oscilloscope phosphor on CRT glass:
// dark backgrounds, glowing accents, monospace type.
object DeModColors {
    val Turquoise = Color(0xFF00F5D4)
    val Violet = Color(0xFF8B5CF6)
    val DeepBlack = Color(0xFF0A0A0F)
    val DarkGray = Color(0xFF1A1A2E)
    val MidGray = Color(0xFF2A2A3E)
    val White = Color(0xFFE8E8F0)
    val Red = Color(0xFFFF4C6A)
    val Green = Color(0xFF4CFF82)
    val Yellow = Color(0xFFFFD94C)
}

private val DeModColorScheme = darkColorScheme(
    primary = DeModColors.Turquoise,
    onPrimary = DeModColors.DeepBlack,
    secondary = DeModColors.Violet,
    onSecondary = DeModColors.White,
    background = DeModColors.DeepBlack,
    onBackground = DeModColors.White,
    surface = DeModColors.DarkGray,
    onSurface = DeModColors.White,
    surfaceVariant = DeModColors.MidGray,
    onSurfaceVariant = DeModColors.White,
    error = DeModColors.Red,
    onError = DeModColors.DeepBlack,
)

private val DeModMono = FontFamily.Monospace

val DeModTypography = Typography(
    headlineSmall = TextStyle(fontFamily = DeModMono, fontWeight = FontWeight.Bold, fontSize = 20.sp, letterSpacing = 1.sp),
    titleMedium = TextStyle(fontFamily = DeModMono, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, letterSpacing = 0.5.sp),
    bodyMedium = TextStyle(fontFamily = DeModMono, fontSize = 14.sp),
    labelLarge = TextStyle(fontFamily = DeModMono, fontWeight = FontWeight.Medium, fontSize = 14.sp),
    labelSmall = TextStyle(fontFamily = DeModMono, fontSize = 11.sp),
)

@Composable
fun DeModTheme(content: @Composable () -> Unit) {
    // Always the dark oscilloscope palette — this is a controller for a Linux box at
    // 2am, not a system-light-mode kind of app.
    MaterialTheme(
        colorScheme = DeModColorScheme,
        typography = DeModTypography,
        content = content,
    )
}
