// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller

import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import ltd.demod.hyprcontroller.control.KeyMapping
import ltd.demod.hyprcontroller.ui.ControllerViewModel
import ltd.demod.hyprcontroller.ui.HyprControllerApp
import ltd.demod.hyprcontroller.ui.theme.DeModTheme

class MainActivity : ComponentActivity() {
    private lateinit var vm: ControllerViewModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        vm = ViewModelProvider(this)[ControllerViewModel::class.java]
        enableEdgeToEdge()
        setContent {
            DeModTheme {
                HyprControllerApp(vm = vm)
            }
        }
    }

    // Forward hardware keyboard events to Hyprland when the Keyboard screen
    // has forwarding enabled. Modifier keys are forwarded but also passed to
    // super so Android tracks metaState; non-modifier keys are consumed.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (!vm.keyboardForwarding.value) return super.dispatchKeyEvent(event)

        val xkbKey = KeyMapping.keyCodeToXkb(event.keyCode)
        if (xkbKey == null) return super.dispatchKeyEvent(event)

        val isModifier = event.keyCode in MODIFIER_KEYCODES
        val mod = KeyMapping.metaStateToHyprMod(event.metaState)
        val state = when (event.action) {
            KeyEvent.ACTION_DOWN -> 0
            KeyEvent.ACTION_UP -> 1
            else -> return super.dispatchKeyEvent(event)
        }

        CoroutineScope(Dispatchers.IO).launch {
            vm.controller.sendKeyState(mod, xkbKey, state)
        }

        return if (isModifier) super.dispatchKeyEvent(event) else true
    }

    companion object {
        private val MODIFIER_KEYCODES = setOf(
            KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT,
            KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT,
            KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT,
            KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT,
        )
    }
}