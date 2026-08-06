// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
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
import ltd.demod.hyprcontroller.control.ConnState
import ltd.demod.hyprcontroller.ui.components.DPad
import ltd.demod.hyprcontroller.ui.components.SierpinskiMark
import ltd.demod.hyprcontroller.ui.components.SignalWaveform
import ltd.demod.hyprcontroller.ui.theme.DeModColors
import ltd.demod.hyprcontroller.ui.theme.neonGlow

@Composable
fun ControllerScreen(vm: ControllerViewModel) {
    val connection by vm.connection.collectAsState()
    val activeWorkspace by vm.activeWorkspace.collectAsState()
    val activeWindow by vm.activeWindow.collectAsState()
    val categories by vm.categories.collectAsState()
    val items by vm.items.collectAsState()
    val statusMessage by vm.statusMessage.collectAsState()

    var selectedCategory by remember { mutableStateOf<String?>(null) }
    var moveMode by remember { mutableStateOf(false) }
    var showManualEntry by remember { mutableStateOf(false) }
    var manualHost by remember { mutableStateOf("") }
    var showExecField by remember { mutableStateOf(false) }
    var execCommand by remember { mutableStateOf("") }

    LaunchedEffect(Unit) { vm.loadCategories() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp, vertical = 8.dp),
    ) {
                Header(
                    connected = connection is ConnState.Connected,
                    onManualToggle = { showManualEntry = !showManualEntry },
                    onReconnect = vm::reconnect,
                )

                if (showManualEntry) {
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = manualHost,
                            onValueChange = { manualHost = it },
                            label = { Text("Tailscale / LAN IP", fontFamily = FontFamily.Monospace, fontSize = 12.sp) },
                            singleLine = true,
                            textStyle = TextStyle(fontFamily = FontFamily.Monospace),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = DeModColors.Turquoise,
                                unfocusedBorderColor = DeModColors.Turquoise.copy(alpha = 0.35f),
                                cursorColor = DeModColors.Turquoise,
                            ),
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(8.dp))
                        GlyphButton("CONNECT", DeModColors.Turquoise) { vm.connectManually(manualHost) }
                    }
                }

                Spacer(Modifier.height(14.dp))
                StatusBezel(connection)

                Spacer(Modifier.height(10.dp))
                TelemetryReadout(activeWorkspace, activeWindow)

                Spacer(Modifier.height(22.dp))
                ChannelLabel(1, "WORKSPACES", DeModColors.Turquoise)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "MOVE",
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        letterSpacing = 1.sp,
                        color = if (moveMode) DeModColors.Violet else DeModColors.White.copy(alpha = 0.4f),
                    )
                    Switch(
                        checked = moveMode,
                        onCheckedChange = { moveMode = it },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = DeModColors.Violet,
                            checkedTrackColor = DeModColors.Violet.copy(alpha = 0.35f),
                        ),
                    )
                }
                Spacer(Modifier.height(4.dp))
                WorkspaceGrid(activeWorkspace = activeWorkspace) { n ->
                    if (moveMode) vm.moveToWorkspace(n) else vm.workspace(n)
                }

                Spacer(Modifier.height(22.dp))
                ChannelLabel(2, "FOCUS", DeModColors.Turquoise)
                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    DPad(accentColor = DeModColors.Turquoise, onMove = vm::moveFocus)
                }

                Spacer(Modifier.height(22.dp))
                ChannelLabel(3, "WINDOW", DeModColors.Turquoise)
                QuickActionsRow(onFloat = vm::toggleFloating, onFullscreen = vm::toggleFullscreen, onKill = vm::killActive)
                Spacer(Modifier.height(8.dp))
                ScratchpadRow(onToggle = vm::toggleScratchpad)

                Spacer(Modifier.height(22.dp))
                ChannelLabel(4, "MEDIA", DeModColors.Turquoise)
                MediaRow(onPrevious = vm::mediaPrevious, onPlayPause = vm::mediaPlayPause, onNext = vm::mediaNext)
                Spacer(Modifier.height(8.dp))
                VolumeRow(onDown = vm::volumeDown, onMute = vm::volumeMuteToggle, onUp = vm::volumeUp)

                Spacer(Modifier.height(22.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ChannelLabel(5, "QUICK EXEC", DeModColors.Yellow)
                    GlyphButton(if (showExecField) "HIDE" else "ADV", DeModColors.Yellow) { showExecField = !showExecField }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    GlyphButton("LOCK", DeModColors.Turquoise, onClick = vm::lockScreen)
                    GlyphButton("SHOT", DeModColors.Turquoise, onClick = vm::screenshot)
                }
                if (showExecField) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "raw shell on the box, as your user \u2014 prefer Tailscale or USB-gadget over untrusted LAN",
                        fontFamily = FontFamily.Monospace,
                        fontSize = 10.sp,
                        color = DeModColors.Red.copy(alpha = 0.8f),
                    )
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = execCommand,
                            onValueChange = { execCommand = it },
                            label = { Text("command", fontFamily = FontFamily.Monospace, fontSize = 12.sp) },
                            singleLine = true,
                            textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = DeModColors.Yellow,
                                unfocusedBorderColor = DeModColors.Yellow.copy(alpha = 0.35f),
                                cursorColor = DeModColors.Yellow,
                            ),
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(8.dp))
                        GlyphButton("RUN", DeModColors.Red) {
                            vm.runExec(execCommand)
                            execCommand = ""
                        }
                    }
                }

                Spacer(Modifier.height(26.dp))
                ChannelLabel(6, "CONTROL CENTER", DeModColors.Violet)
                CategoryChips(categories, selectedCategory) { cat ->
                    selectedCategory = cat
                    vm.loadItems(cat)
                }
                if (selectedCategory != null) {
                    Spacer(Modifier.height(8.dp))
                    ItemsList(items, onRun = vm::runAction)
                }

                statusMessage?.let {
                    Spacer(Modifier.height(14.dp))
                    Text(
                        "> $it",
                        color = DeModColors.Yellow,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                    )
                }
                Spacer(Modifier.height(28.dp))
            }
}

@Composable
private fun Header(connected: Boolean, onManualToggle: () -> Unit, onReconnect: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 6.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SierpinskiMark(
            modifier = Modifier
                .size(30.dp)
                .neonGlow(DeModColors.Turquoise, cornerRadius = 15.dp, intensity = if (connected) 0.7f else 0.3f),
            color = DeModColors.Turquoise,
            depth = 3,
            pulse = !connected,
        )
        Spacer(Modifier.width(10.dp))
        Text(
            "HYPRCONTROLLER",
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
            letterSpacing = 2.sp,
            fontSize = 16.sp,
            color = DeModColors.White,
        )
        Spacer(Modifier.weight(1f))
        GlyphButton("IP", DeModColors.Turquoise, onManualToggle)
        Spacer(Modifier.width(8.dp))
        GlyphButton("\u21bb", DeModColors.Violet, onReconnect)
    }
}

@Composable
private fun GlyphButton(label: String, accent: Color, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .border(1.dp, accent.copy(alpha = 0.45f), RoundedCornerShape(8.dp))
            .background(accent.copy(alpha = 0.08f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = accent)
    }
}

private data class StatusVisual(val color: Color, val label: String, val active: Boolean, val scanning: Boolean)

private fun statusVisual(state: ConnState): StatusVisual = when (state) {
    is ConnState.Connected -> StatusVisual(DeModColors.Green, "LINK UP \u00b7 ${state.via} \u00b7 ${state.host}", active = true, scanning = false)
    ConnState.Discovering -> StatusVisual(DeModColors.Yellow, "SEARCHING\u2026", active = false, scanning = true)
    ConnState.Disconnected -> StatusVisual(DeModColors.Red, "NO LINK", active = false, scanning = false)
}

@Composable
private fun StatusBezel(state: ConnState) {
    val v = statusVisual(state)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF0D0D14))
            .border(1.dp, v.color.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(9.dp)
                    .neonGlow(v.color, cornerRadius = 5.dp, intensity = if (v.active) 1f else 0.5f)
                    .clip(CircleShape)
                    .background(v.color),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                v.label,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                letterSpacing = 0.5.sp,
                color = DeModColors.White.copy(alpha = 0.9f),
            )
        }
        Spacer(Modifier.height(10.dp))
        SignalWaveform(
            modifier = Modifier.fillMaxWidth().height(44.dp),
            color = v.color,
            active = v.active,
            scanning = v.scanning,
        )
    }
}

@Composable
private fun TelemetryReadout(activeWorkspace: String?, activeWindow: String?) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0xFF0D0D14))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Text(
            "WS ${activeWorkspace ?: "\u2014"}",
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            fontSize = 13.sp,
            color = DeModColors.Turquoise,
        )
        Text(
            activeWindow ?: "no active window data yet",
            fontFamily = FontFamily.Monospace,
            fontSize = 11.sp,
            color = DeModColors.White.copy(alpha = 0.5f),
            maxLines = 1,
        )
    }
}

@Composable
private fun ChannelLabel(index: Int, text: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 8.dp)) {
        Box(Modifier.width(3.dp).height(14.dp).background(color))
        Spacer(Modifier.width(8.dp))
        Text(
            "CH.$index  $text",
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.5.sp,
            fontSize = 12.sp,
            color = color,
        )
    }
}

@Composable
private fun WorkspaceGrid(activeWorkspace: String?, onTap: (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (row in 0..1) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                for (col in 1..5) {
                    val n = row * 5 + col
                    WorkspaceCell(n, activeWorkspace == n.toString(), onTap)
                }
            }
        }
    }
}

@Composable
private fun RowScope.WorkspaceCell(n: Int, active: Boolean, onTap: (Int) -> Unit) {
    val haptic = LocalHapticFeedback.current
    val glowIntensity by animateFloatAsState(if (active) 1f else 0f, label = "cell-glow")
    Box(
        modifier = Modifier
            .weight(1f)
            .aspectRatio(1f)
            .then(if (active) Modifier.neonGlow(DeModColors.Turquoise, 10.dp, glowIntensity) else Modifier)
            .clip(RoundedCornerShape(10.dp))
            .background(if (active) DeModColors.Turquoise.copy(alpha = 0.16f) else Color(0xFF16161F))
            .border(1.dp, if (active) DeModColors.Turquoise else DeModColors.Turquoise.copy(alpha = 0.2f), RoundedCornerShape(10.dp))
            .clickable {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                onTap(n)
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (n == 10) "0" else n.toString(),
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
            fontSize = 17.sp,
            color = if (active) DeModColors.Turquoise else DeModColors.White.copy(alpha = 0.65f),
        )
    }
}

@Composable
private fun QuickActionsRow(onFloat: () -> Unit, onFullscreen: () -> Unit, onKill: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        GlyphButton("FLOAT", DeModColors.Turquoise, onFloat)
        GlyphButton("FULL", DeModColors.Turquoise, onFullscreen)
        GlyphButton("KILL", DeModColors.Red, onKill)
    }
}

@Composable
private fun ScratchpadRow(onToggle: (String) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        GlyphButton("TERM", DeModColors.Violet) { onToggle("term") }
        GlyphButton("NOTES", DeModColors.Violet) { onToggle("notes") }
        GlyphButton("MON", DeModColors.Violet) { onToggle("mon") }
    }
}

@Composable
private fun MediaRow(onPrevious: () -> Unit, onPlayPause: () -> Unit, onNext: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        GlyphButton("\u23ee PREV", DeModColors.Turquoise, onClick = onPrevious)
        GlyphButton("\u23ef PLAY", DeModColors.Turquoise, onClick = onPlayPause)
        GlyphButton("\u23ed NEXT", DeModColors.Turquoise, onClick = onNext)
    }
}

@Composable
private fun VolumeRow(onDown: () -> Unit, onMute: () -> Unit, onUp: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        GlyphButton("VOL \u2212", DeModColors.Violet, onClick = onDown)
        GlyphButton("MUTE", DeModColors.Violet, onClick = onMute)
        GlyphButton("VOL +", DeModColors.Violet, onClick = onUp)
    }
}

@Composable
private fun CategoryChips(categories: List<Pair<String, String>>, selected: String?, onSelect: (String) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        for ((id, label) in categories) {
            val isSelected = id == selected
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(20.dp))
                    .border(
                        1.dp,
                        if (isSelected) DeModColors.Violet else DeModColors.Violet.copy(alpha = 0.3f),
                        RoundedCornerShape(20.dp),
                    )
                    .background(if (isSelected) DeModColors.Violet.copy(alpha = 0.22f) else Color.Transparent)
                    .clickable { onSelect(id) }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            ) {
                Text(
                    label,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    color = if (isSelected) DeModColors.Violet else DeModColors.White.copy(alpha = 0.7f),
                )
            }
        }
    }
}

@Composable
private fun ItemsList(items: List<Pair<String, String>>, onRun: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0xFF0D0D14))
            .border(1.dp, DeModColors.Violet.copy(alpha = 0.25f), RoundedCornerShape(10.dp)),
    ) {
        for ((id, label) in items) {
            Text(
                "\u203a $label",
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onRun(id) }
                    .padding(horizontal = 14.dp, vertical = 11.dp),
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
                color = DeModColors.White.copy(alpha = 0.85f),
            )
        }
    }
}
