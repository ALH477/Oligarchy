// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.keyboard

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ltd.demod.hyprcontroller.ui.ControllerViewModel
import ltd.demod.hyprcontroller.ui.theme.DeModColors

@Composable
fun KeyboardScreen(vm: ControllerViewModel) {
    var modifierState by remember { mutableStateOf(ModifierState()) }
    var textInput by remember { mutableStateOf("") }
    var textFieldHasFocus by remember { mutableStateOf(false) }

    // Enable hardware keyboard forwarding when this screen is active, unless the
    // text field has focus (so Android's IME can work normally).
    DisposableEffect(Unit) {
        vm.setKeyboardForwarding(true)
        onDispose { vm.setKeyboardForwarding(false) }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp, vertical = 8.dp),
    ) {
        // ── Hardware keyboard toggle ──────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "FORWARD HW KEYBOARD",
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                letterSpacing = 1.sp,
                color = DeModColors.Turquoise,
            )
            Switch(
                checked = vm.keyboardForwarding.collectAsState().value && !textFieldHasFocus,
                onCheckedChange = { vm.setKeyboardForwarding(it) },
                colors = SwitchDefaults.colors(
                    checkedThumbColor = DeModColors.Turquoise,
                    checkedTrackColor = DeModColors.Turquoise.copy(alpha = 0.35f),
                ),
            )
        }

        Spacer(Modifier.height(8.dp))

        // ── Modifier row ────────────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ModifierButton("CTRL", modifierState.ctrl, DeModColors.Violet) {
                modifierState = modifierState.toggle(Modifier.CTRL)
            }
            ModifierButton("ALT", modifierState.alt, DeModColors.Yellow) {
                modifierState = modifierState.toggle(Modifier.ALT)
            }
            ModifierButton("SUPER", modifierState.superKey, DeModColors.Turquoise) {
                modifierState = modifierState.toggle(Modifier.SUPER)
            }
            ModifierButton("SHIFT", modifierState.White) {
                modifierState = modifierState.toggle(Modifier.SHIFT)
            }
            Spacer(Modifier.weight(1f))
            // Mode toggle
            Text(
                modifierState.mode.name,
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp,
                color = DeModColors.White.copy(alpha = 0.5f),
                modifier = Modifier.clickable {
                    modifierState = modifierState.copy(
                        mode = if (modifierState.mode == ModifierMode.STICKY) ModifierMode.TOGGLE else ModifierMode.STICKY
                    )
                },
            )
        }

        Spacer(Modifier.height(10.dp))

        // ── Function key row ────────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            val fnKeys = listOf("Escape") + (1..12).map { "F$it" }
            for (key in fnKeys) {
                KeyButton(key, accent = DeModColors.Yellow) {
                    vm.sendKeyTap(modifierState.toHyprMod(), key)
                    modifierState = modifierState.clearAfterKeypress()
                }
            }
        }

        Spacer(Modifier.height(10.dp))

        // ── Main key grid ───────────────────────────────────────────────────────────
        val rows = listOf(
            listOf("`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "BackSpace"),
            listOf("Tab", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"),
            listOf("Caps", "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "Return"),
            listOf("Shift", "z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "Left", "Down", "Up", "Right"),
            listOf("Ctrl", "Alt", "Super", "space", "Insert", "Delete", "Home", "End"),
        )

        for (row in rows) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                for (key in row) {
                    val isWide = key == "space" || key == "Return" || key == "BackSpace" || key == "Tab"
                    KeyButton(
                        label = if (key == "space") "SPACE" else key.uppercase(),
                        accent = DeModColors.Turquoise,
                        wide = isWide,
                        modifier = if (key == "space") Modifier.weight(2f) else if (isWide) Modifier.weight(1.5f) else Modifier,
                    ) {
                        vm.sendKeyTap(modifierState.toHyprMod(), key)
                        modifierState = modifierState.clearAfterKeypress()
                    }
                }
            }
        }

        Spacer(Modifier.height(18.dp))

        // ── Text bulk input ─────────────────────────────────────────────────────────
        Text(
            "TYPE TEXT (requires wtype on host)",
            fontFamily = FontFamily.Monospace,
            fontSize = 10.sp,
            color = DeModColors.Yellow.copy(alpha = 0.7f),
        )
        Spacer(Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = textInput,
                onValueChange = { textInput = it },
                label = { Text("text to type", fontFamily = FontFamily.Monospace, fontSize = 12.sp) },
                singleLine = true,
                textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = DeModColors.Turquoise,
                    unfocusedBorderColor = DeModColors.Turquoise.copy(alpha = 0.35f),
                    cursorColor = DeModColors.Turquoise,
                ),
                modifier = Modifier
                    .weight(1f)
                    .onFocusChanged { textFieldHasFocus = it.hasFocus },
            )
            Spacer(Modifier.width(8.dp))
            KeyButton("SEND", accent = DeModColors.Turquoise, wide = true) {
                if (textInput.isNotBlank()) {
                    vm.typeText(textInput)
                    textInput = ""
                }
            }
        }

        Spacer(Modifier.height(28.dp))
    }
}

@Composable
private fun ModifierButton(label: String, active: Boolean, accent: Color, onClick: () -> Unit) {
    val haptic = LocalHapticFeedback.current
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .border(
                1.dp,
                if (active) accent else accent.copy(alpha = 0.3f),
                RoundedCornerShape(6.dp),
            )
            .background(if (active) accent.copy(alpha = 0.22f) else Color(0xFF16161F))
            .clickable {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                onClick()
            }
            .padding(horizontal = 10.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            fontFamily = FontFamily.Monospace,
            fontWeight = if (active) FontWeight.Bold else FontWeight.Normal,
            fontSize = 11.sp,
            color = if (active) accent else DeModColors.White.copy(alpha = 0.6f),
        )
    }
}

@Composable
private fun KeyButton(
    label: String,
    accent: Color,
    wide: Boolean = false,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val haptic = LocalHapticFeedback.current
    Box(
        modifier = modifier
            .height(38.dp)
            .clip(RoundedCornerShape(6.dp))
            .border(1.dp, accent.copy(alpha = 0.3f), RoundedCornerShape(6.dp))
            .background(Color(0xFF12121A))
            .clickable {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                onClick()
            }
            .padding(horizontal = if (wide) 14.dp else 6.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            fontFamily = FontFamily.Monospace,
            fontSize = if (wide) 11.sp else 10.sp,
            fontWeight = FontWeight.Medium,
            color = accent,
            maxLines = 1,
        )
    }
}