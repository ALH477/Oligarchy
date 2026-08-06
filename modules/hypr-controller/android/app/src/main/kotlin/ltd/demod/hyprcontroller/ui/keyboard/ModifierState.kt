// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui.keyboard

import ltd.demod.hyprcontroller.control.KeyMapping

enum class ModifierMode { STICKY, TOGGLE }

enum class Modifier { CTRL, ALT, SUPER, SHIFT }

data class ModifierState(
    val ctrl: Boolean = false,
    val alt: Boolean = false,
    val superKey: Boolean = false,
    val shift: Boolean = false,
    val mode: ModifierMode = ModifierMode.STICKY,
) {
    fun toHyprMod(): Int =
        (if (shift) KeyMapping.MOD_SHIFT else 0) or
        (if (ctrl) KeyMapping.MOD_CTRL else 0) or
        (if (alt) KeyMapping.MOD_ALT else 0) or
        (if (superKey) KeyMapping.MOD_SUPER else 0)

    fun isAnyActive(): Boolean = ctrl || alt || superKey || shift

    /** In STICKY mode, clear all modifiers after a non-modifier keypress. */
    fun clearAfterKeypress(): ModifierState =
        if (mode == ModifierMode.STICKY) copy(ctrl = false, alt = false, superKey = false, shift = false) else this

    fun toggle(mod: Modifier): ModifierState = when (mod) {
        Modifier.CTRL -> copy(ctrl = !ctrl)
        Modifier.ALT -> copy(alt = !alt)
        Modifier.SUPER -> copy(superKey = !superKey)
        Modifier.SHIFT -> copy(shift = !shift)
    }
}