// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.macro

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ltd.demod.hyprcontroller.control.Macro
import ltd.demod.hyprcontroller.ui.ControllerViewModel
import ltd.demod.hyprcontroller.ui.theme.DeModColors

@Composable
fun MacroScreen(vm: ControllerViewModel) {
    val macros by vm.macros.collectAsState()
    val macroRunning by vm.macroRunning.collectAsState()
    val macroProgress by vm.macroProgress.collectAsState()
    var editingMacro by remember { mutableStateOf<Macro?>(null) }
    var showEditor by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { vm.loadMacros() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp, vertical = 8.dp),
    ) {
        // Channel label
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 8.dp)) {
            Box(Modifier.width(3.dp).height(14.dp).background(DeModColors.Turquoise, CircleShape))
            Spacer(Modifier.width(8.dp))
            Text(
                "CH.7  MACROS",
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.5.sp,
                fontSize = 12.sp,
                color = DeModColors.Turquoise,
            )
        }

        Spacer(Modifier.height(8.dp))

        // Macro list
        for (macro in macros) {
            MacroCard(
                macro = macro,
                isRunning = macroRunning,
                progressText = if (macroRunning) macroProgress else null,
                onRun = { vm.runMacro(macro) },
                onEdit = { editingMacro = macro; showEditor = true },
                onDelete = { vm.deleteMacro(macro.id) },
            )
            Spacer(Modifier.height(8.dp))
        }

        // New macro button
        MacroCard(
            macro = Macro(name = "+ NEW MACRO", steps = emptyList(), iconName = "+"),
            isRunning = false,
            progressText = null,
            onRun = {},
            onEdit = { editingMacro = null; showEditor = true },
            onDelete = {},
        )

        Spacer(Modifier.height(28.dp))
    }

    if (showEditor) {
        MacroEditorDialog(
            initialMacro = editingMacro,
            onSave = { macro ->
                if (editingMacro != null) vm.updateMacro(macro) else vm.addMacro(macro)
                showEditor = false
            },
            onDismiss = { showEditor = false },
        )
    }
}