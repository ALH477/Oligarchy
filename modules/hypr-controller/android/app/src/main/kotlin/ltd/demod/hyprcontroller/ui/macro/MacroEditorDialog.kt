// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.macro

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ltd.demod.hyprcontroller.control.Macro
import ltd.demod.hyprcontroller.control.MacroStep
import ltd.demod.hyprcontroller.ui.theme.DeModColors
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MacroEditorDialog(
    initialMacro: Macro?,
    onSave: (Macro) -> Unit,
    onDismiss: () -> Unit,
) {
    var name by remember { mutableStateOf(initialMacro?.name ?: "") }
    var steps by remember { mutableStateOf(initialMacro?.steps ?: emptyList()) }
    var addTypeExpanded by remember { mutableStateOf(false) }
    var addTypeSelected by remember { mutableStateOf("hypr_dispatch") }

    val stepTypes = listOf(
        "hypr_dispatch" to "Hypr Dispatch",
        "send_shortcut" to "Send Shortcut",
        "send_keystate" to "Send Key State",
        "ctl_run" to "Ctl Run",
        "exec" to "Exec",
        "delay" to "Delay",
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xE0000000)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth(0.92f)
                .fillMaxHeight(0.85f)
                .clip(RoundedCornerShape(16.dp))
                .background(Color(0xFF0D0D14))
                .border(1.dp, DeModColors.Turquoise.copy(alpha = 0.4f), RoundedCornerShape(16.dp))
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            Text(
                if (initialMacro != null) "EDIT MACRO" else "NEW MACRO",
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                fontSize = 14.sp,
                letterSpacing = 2.sp,
                color = DeModColors.Turquoise,
            )

            Spacer(Modifier.height(12.dp))

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("name", fontFamily = FontFamily.Monospace, fontSize = 12.sp) },
                singleLine = true,
                textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = DeModColors.Turquoise,
                    unfocusedBorderColor = DeModColors.Turquoise.copy(alpha = 0.35f),
                    cursorColor = DeModColors.Turquoise,
                ),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(16.dp))

            // Step list
            Text("STEPS", fontFamily = FontFamily.Monospace, fontSize = 11.sp, letterSpacing = 1.sp, color = DeModColors.White.copy(alpha = 0.6f))
            Spacer(Modifier.height(8.dp))

            for ((index, step) in steps.withIndex()) {
                StepRow(step, index, steps.size, onRemove = {
                    steps = steps.toMutableList().apply { removeAt(index) }
                }, onMoveUp = {
                    if (index > 0) {
                        steps = steps.toMutableList().apply {
                            val tmp = this[index]
                            this[index] = this[index - 1]
                            this[index - 1] = tmp
                        }
                    }
                }, onMoveDown = {
                    if (index < steps.size - 1) {
                        steps = steps.toMutableList().apply {
                            val tmp = this[index]
                            this[index] = this[index + 1]
                            this[index + 1] = tmp
                        }
                    }
                })
                Spacer(Modifier.height(4.dp))
            }

            Spacer(Modifier.height(12.dp))

            // Add step
            Row(verticalAlignment = Alignment.CenterVertically) {
                ExposedDropdownMenuBox(
                    expanded = addTypeExpanded,
                    onExpandedChange = { addTypeExpanded = !addTypeExpanded },
                ) {
                    OutlinedTextField(
                        value = stepTypes.first { it.first == addTypeSelected }.second,
                        onValueChange = {},
                        readOnly = true,
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = addTypeExpanded) },
                        textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = DeModColors.White),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = DeModColors.Turquoise,
                            unfocusedBorderColor = DeModColors.Turquoise.copy(alpha = 0.35f),
                        ),
                        modifier = Modifier.menuAnchor().weight(1f),
                    )
                    ExposedDropdownMenu(
                        expanded = addTypeExpanded,
                        onDismissRequest = { addTypeExpanded = false },
                    ) {
                        for ((value, label) in stepTypes) {
                            DropdownMenuItem(
                                text = { Text(label, fontFamily = FontFamily.Monospace, fontSize = 11.sp) },
                                onClick = { addTypeSelected = value; addTypeExpanded = false },
                                colors = MenuDefaults.itemColors(textColor = DeModColors.White),
                            )
                        }
                    }
                }

                Spacer(Modifier.width(8.dp))

                var paramText by remember { mutableStateOf("") }
                var paramText2 by remember { mutableStateOf("") }

                when (addTypeSelected) {
                    "hypr_dispatch", "exec", "ctl_run" -> {
                        OutlinedTextField(
                            value = paramText,
                            onValueChange = { paramText = it },
                            label = { Text(if (addTypeSelected == "hypr_dispatch") "dispatcher" else if (addTypeSelected == "exec") "command" else "action id", fontFamily = FontFamily.Monospace, fontSize = 10.sp) },
                            singleLine = true,
                            textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = DeModColors.Turquoise,
                                unfocusedBorderColor = DeModColors.Turquoise.copy(alpha = 0.35f),
                                cursorColor = DeModColors.Turquoise,
                            ),
                            modifier = Modifier.weight(1f),
                        )
                    }
                    "send_shortcut" -> {
                        OutlinedTextField(
                            value = paramText,
                            onValueChange = { paramText = it },
                            label = { Text("mod,key", fontFamily = FontFamily.Monospace, fontSize = 10.sp) },
                            singleLine = true,
                            textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = DeModColors.Turquoise,
                                unfocusedBorderColor = DeModColors.Turquoise.copy(alpha = 0.35f),
                                cursorColor = DeModColors.Turquoise,
                            ),
                            modifier = Modifier.weight(1f),
                        )
                    }
                    "send_keystate" -> {
                        OutlinedTextField(
                            value = paramText,
                            onValueChange = { paramText = it },
                            label = { Text("mod,key,state", fontFamily = FontFamily.Monospace, fontSize = 10.sp) },
                            singleLine = true,
                            textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = DeModColors.Turquoise,
                                unfocusedBorderColor = DeModColors.Turquoise.copy(alpha = 0.35f),
                                cursorColor = DeModColors.Turquoise,
                            ),
                            modifier = Modifier.weight(1f),
                        )
                    }
                    "delay" -> {
                        OutlinedTextField(
                            value = paramText,
                            onValueChange = { paramText = it },
                            label = { Text("ms", fontFamily = FontFamily.Monospace, fontSize = 10.sp) },
                            singleLine = true,
                            textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = DeModColors.Turquoise,
                                unfocusedBorderColor = DeModColors.Turquoise.copy(alpha = 0.35f),
                                cursorColor = DeModColors.Turquoise,
                            ),
                            modifier = Modifier.weight(1f),
                        )
                    }
                }

                Spacer(Modifier.width(8.dp))

                // Add button
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .border(1.dp, DeModColors.Turquoise.copy(alpha = 0.4f), RoundedCornerShape(6.dp))
                        .background(DeModColors.Turquoise.copy(alpha = 0.12f))
                        .clickable {
                            val newStep: MacroStep? = when (addTypeSelected) {
                                "hypr_dispatch" -> if (paramText.isNotBlank()) MacroStep.HyprDispatch(paramText.trim()) else null
                                "send_shortcut" -> {
                                    val parts = paramText.split(",")
                                    if (parts.size >= 2) MacroStep.SendShortcut(parts[0].trim().toIntOrNull() ?: 0, parts[1].trim()) else null
                                }
                                "send_keystate" -> {
                                    val parts = paramText.split(",")
                                    if (parts.size >= 3) MacroStep.SendKeyState(parts[0].trim().toIntOrNull() ?: 0, parts[1].trim(), parts[2].trim().toIntOrNull() ?: 2) else null
                                }
                                "ctl_run" -> if (paramText.isNotBlank()) MacroStep.CtlRun(paramText.trim()) else null
                                "exec" -> if (paramText.isNotBlank()) MacroStep.Exec(paramText.trim()) else null
                                "delay" -> paramText.trim().toLongOrNull()?.let { MacroStep.Delay(it) }
                                else -> null
                            }
                            if (newStep != null) {
                                steps = steps + newStep
                                paramText = ""
                                paramText2 = ""
                            }
                        }
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    Text("+", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = DeModColors.Turquoise)
                }
            }

            Spacer(Modifier.height(24.dp))

            // Save / Cancel
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .border(1.dp, DeModColors.White.copy(alpha = 0.3f), RoundedCornerShape(6.dp))
                        .clickable { onDismiss() }
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Text("CANCEL", fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = DeModColors.White.copy(alpha = 0.6f))
                }
                Spacer(Modifier.width(12.dp))
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .border(1.dp, DeModColors.Turquoise.copy(alpha = 0.5f), RoundedCornerShape(6.dp))
                        .background(DeModColors.Turquoise.copy(alpha = 0.12f))
                        .clickable(enabled = name.isNotBlank()) {
                            onSave(Macro(
                                id = initialMacro?.id ?: UUID.randomUUID().toString(),
                                name = name.trim(),
                                steps = steps,
                                iconName = initialMacro?.iconName,
                            ))
                        }
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Text("SAVE", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 12.sp, color = DeModColors.Turquoise)
                }
            }
        }
    }
}

@Composable
private fun StepRow(
    step: MacroStep,
    index: Int,
    total: Int,
    onRemove: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    val label = when (step) {
        is MacroStep.HyprDispatch -> "hypr ${step.dispatcher}"
        is MacroStep.SendShortcut -> "shortcut ${step.mod},${step.key}"
        is MacroStep.SendKeyState -> "keystate ${step.mod},${step.key},${step.state}"
        is MacroStep.CtlRun -> "ctl run ${step.actionId}"
        is MacroStep.Exec -> "exec ${step.command}"
        is MacroStep.Delay -> "delay ${step.ms}ms"
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(6.dp))
            .background(Color(0xFF16161F))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "${index + 1}.",
            fontFamily = FontFamily.Monospace,
            fontSize = 10.sp,
            color = DeModColors.White.copy(alpha = 0.4f),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            label,
            fontFamily = FontFamily.Monospace,
            fontSize = 11.sp,
            color = DeModColors.White.copy(alpha = 0.85f),
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(4.dp))
        SmallButton("↑", index > 0, onMoveUp)
        SmallButton("↓", index < total - 1, onMoveDown)
        SmallButton("✕", true, onRemove)
    }
}

@Composable
private fun SmallButton(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 2.dp),
    ) {
        Text(
            label,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            color = if (enabled) DeModColors.White.copy(alpha = 0.7f) else DeModColors.White.copy(alpha = 0.2f),
        )
    }
}