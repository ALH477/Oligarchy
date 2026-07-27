// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import ltd.demod.hyprcontroller.ui.ControllerScreen
import ltd.demod.hyprcontroller.ui.theme.DeModTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            DeModTheme {
                ControllerScreen()
            }
        }
    }
}
