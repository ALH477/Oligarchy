// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.panic

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ltd.demod.hyprcontroller.ui.ControllerViewModel
import ltd.demod.hyprcontroller.ui.theme.DeModColors
import ltd.demod.hyprcontroller.ui.theme.neonGlow

@Composable
fun PanicOverlay(vm: ControllerViewModel) {
    var confirmKillAll by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xE0300000)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth(0.85f)
                .clip(RoundedCornerShape(16.dp))
                .background(Color(0xFF1A0000))
                .border(2.dp, DeModColors.Red.copy(alpha = 0.7f), RoundedCornerShape(16.dp))
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "PANIC",
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                fontSize = 32.sp,
                letterSpacing = 4.sp,
                color = DeModColors.Red,
                modifier = Modifier.neonGlow(DeModColors.Red, cornerRadius = 16.dp, intensity = 0.8f),
            )

            Spacer(Modifier.height(20.dp))

            PanicActionButton("LOCK SCREEN", DeModColors.Yellow, Color(0xFF1A1A00)) {
                vm.lockScreen()
                vm.dismissPanic()
            }
            Spacer(Modifier.height(10.dp))

            PanicActionButton("HIDE TO EMPTY WS", DeModColors.Turquoise, Color(0xFF001A1A)) {
                vm.workspace(1)
                vm.dismissPanic()
            }
            Spacer(Modifier.height(10.dp))

            PanicActionButton("KILL ACTIVE WINDOW", Color(0xFFFF8844), Color(0xFF1A0F00)) {
                vm.killActive()
                vm.dismissPanic()
            }
            Spacer(Modifier.height(10.dp))

            PanicActionButton("KILL ALL WINDOWS", DeModColors.Red, Color(0xFF1A0000)) {
                confirmKillAll = true
            }

            AnimatedVisibility(visible = confirmKillAll, enter = fadeIn(), exit = fadeOut()) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        "Close every window on every workspace?",
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        color = DeModColors.White.copy(alpha = 0.8f),
                    )
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        PanicActionButton("CONFIRM", DeModColors.Red, Color(0xFF330000)) {
                            vm.runMacro(ltd.demod.hyprcontroller.control.MacroStore.defaultMacros().first { it.id == "default-close-all" })
                            vm.dismissPanic()
                            confirmKillAll = false
                        }
                        PanicActionButton("CANCEL", DeModColors.White, Color(0xFF16161F)) {
                            confirmKillAll = false
                        }
                    }
                }
            }

            Spacer(Modifier.height(20.dp))

            Text(
                "DISMISS",
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                letterSpacing = 2.sp,
                color = DeModColors.White.copy(alpha = 0.5f),
                modifier = Modifier.clickable { vm.dismissPanic() }.padding(8.dp),
            )
        }
    }
}

@Composable
private fun PanicActionButton(
    label: String,
    accent: Color,
    bgColor: Color,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .border(1.dp, accent.copy(alpha = 0.5f), RoundedCornerShape(10.dp))
            .background(bgColor)
            .clickable(onClick = onClick)
            .padding(vertical = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
            fontSize = 14.sp,
            letterSpacing = 1.5.sp,
            color = accent,
        )
    }
}