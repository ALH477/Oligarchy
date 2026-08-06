// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.control

import android.view.KeyEvent as KE

/** Maps Android KeyEvent codes and metaState to Hyprland/XKB key names and modifier bitmask.
 * Hyprland modifier bitmask: Shift=1, Caps=2, Ctrl=4, Alt=8, Super=16. */
object KeyMapping {
    const val MOD_SHIFT = 1
    const val MOD_CAPS = 2
    const val MOD_CTRL = 4
    const val MOD_ALT = 8
    const val MOD_SUPER = 16

    fun metaStateToHyprMod(metaState: Int): Int {
        var mod = 0
        if (metaState and KE.META_SHIFT_ON != 0) mod = mod or MOD_SHIFT
        if (metaState and KE.META_CTRL_ON != 0) mod = mod or MOD_CTRL
        if (metaState and KE.META_ALT_ON != 0) mod = mod or MOD_ALT
        if (metaState and KE.META_META_ON != 0) mod = mod or MOD_SUPER
        return mod
    }

    fun keyCodeToXkb(keyCode: Int): String? = androidToXkb[keyCode]

    private val androidToXkb: Map<Int, String> = mapOf(
        // Letters
        KE.KEYCODE_A to "a", KE.KEYCODE_B to "b", KE.KEYCODE_C to "c",
        KE.KEYCODE_D to "d", KE.KEYCODE_E to "e", KE.KEYCODE_F to "f",
        KE.KEYCODE_G to "g", KE.KEYCODE_H to "h", KE.KEYCODE_I to "i",
        KE.KEYCODE_J to "j", KE.KEYCODE_K to "k", KE.KEYCODE_L to "l",
        KE.KEYCODE_M to "m", KE.KEYCODE_N to "n", KE.KEYCODE_O to "o",
        KE.KEYCODE_P to "p", KE.KEYCODE_Q to "q", KE.KEYCODE_R to "r",
        KE.KEYCODE_S to "s", KE.KEYCODE_T to "t", KE.KEYCODE_U to "u",
        KE.KEYCODE_V to "v", KE.KEYCODE_W to "w", KE.KEYCODE_X to "x",
        KE.KEYCODE_Y to "y", KE.KEYCODE_Z to "z",
        // Digits
        KE.KEYCODE_0 to "0", KE.KEYCODE_1 to "1", KE.KEYCODE_2 to "2",
        KE.KEYCODE_3 to "3", KE.KEYCODE_4 to "4", KE.KEYCODE_5 to "5",
        KE.KEYCODE_6 to "6", KE.KEYCODE_7 to "7", KE.KEYCODE_8 to "8",
        KE.KEYCODE_9 to "9",
        // Navigation & editing
        KE.KEYCODE_ENTER to "Return",
        KE.KEYCODE_ESCAPE to "Escape",
        KE.KEYCODE_TAB to "Tab",
        KE.KEYCODE_BACKSPACE to "BackSpace",
        KE.KEYCODE_DEL to "Delete",
        KE.KEYCODE_SPACE to "space",
        KE.KEYCODE_INSERT to "Insert",
        KE.KEYCODE_HOME to "Home",
        KE.KEYCODE_END to "End",
        KE.KEYCODE_PAGE_UP to "Page_Up",
        KE.KEYCODE_PAGE_DOWN to "Page_Down",
        KE.KEYCODE_DPAD_UP to "Up",
        KE.KEYCODE_DPAD_DOWN to "Down",
        KE.KEYCODE_DPAD_LEFT to "Left",
        KE.KEYCODE_DPAD_RIGHT to "Right",
        KE.KEYCODE_NUMPAD_ENTER to "KP_Enter",
        // Function keys
        KE.KEYCODE_F1 to "F1", KE.KEYCODE_F2 to "F2", KE.KEYCODE_F3 to "F3",
        KE.KEYCODE_F4 to "F4", KE.KEYCODE_F5 to "F5", KE.KEYCODE_F6 to "F6",
        KE.KEYCODE_F7 to "F7", KE.KEYCODE_F8 to "F8", KE.KEYCODE_F9 to "F9",
        KE.KEYCODE_F10 to "F10", KE.KEYCODE_F11 to "F11", KE.KEYCODE_F12 to "F12",
        // Modifiers (left/right variants)
        KE.KEYCODE_SHIFT_LEFT to "Shift_L", KE.KEYCODE_SHIFT_RIGHT to "Shift_R",
        KE.KEYCODE_CTRL_LEFT to "Control_L", KE.KEYCODE_CTRL_RIGHT to "Control_R",
        KE.KEYCODE_ALT_LEFT to "Alt_L", KE.KEYCODE_ALT_RIGHT to "Alt_R",
        KE.KEYCODE_META_LEFT to "Super_L", KE.KEYCODE_META_RIGHT to "Super_R",
        KE.KEYCODE_CAPS_LOCK to "Caps_Lock",
        // Punctuation & symbols
        KE.KEYCODE_GRAVE to "grave",
        KE.KEYCODE_MINUS to "minus",
        KE.KEYCODE_EQUALS to "equal",
        KE.KEYCODE_LEFT_BRACKET to "bracketleft",
        KE.KEYCODE_RIGHT_BRACKET to "bracketright",
        KE.KEYCODE_BACKSLASH to "backslash",
        KE.KEYCODE_SEMICOLON to "semicolon",
        KE.KEYCODE_APOSTROPHE to "apostrophe",
        KE.KEYCODE_COMMA to "comma",
        KE.KEYCODE_PERIOD to "period",
        KE.KEYCODE_SLASH to "slash",
        KE.KEYCODE_NUM to "Num_Lock",
        // Numpad
        KE.KEYCODE_NUMPAD_0 to "KP_0", KE.KEYCODE_NUMPAD_1 to "KP_1",
        KE.KEYCODE_NUMPAD_2 to "KP_2", KE.KEYCODE_NUMPAD_3 to "KP_3",
        KE.KEYCODE_NUMPAD_4 to "KP_4", KE.KEYCODE_NUMPAD_5 to "KP_5",
        KE.KEYCODE_NUMPAD_6 to "KP_6", KE.KEYCODE_NUMPAD_7 to "KP_7",
        KE.KEYCODE_NUMPAD_8 to "KP_8", KE.KEYCODE_NUMPAD_9 to "KP_9",
        KE.KEYCODE_NUMPAD_ADD to "KP_Add", KE.KEYCODE_NUMPAD_SUBTRACT to "KP_Subtract",
        KE.KEYCODE_NUMPAD_MULTIPLY to "KP_Multiply", KE.KEYCODE_NUMPAD_DIVIDE to "KP_Divide",
        KE.KEYCODE_NUMPAD_DOT to "KP_Decimal",
        // Media (map to XF86 keysyms)
        KE.KEYCODE_MEDIA_PLAY_PAUSE to "XF86AudioPlay",
        KE.KEYCODE_MEDIA_STOP to "XF86AudioStop",
        KE.KEYCODE_MEDIA_NEXT to "XF86AudioNext",
        KE.KEYCODE_MEDIA_PREVIOUS to "XF86AudioPrev",
        KE.KEYCODE_MUTE to "XF86AudioMute",
        KE.KEYCODE_VOLUME_UP to "XF86AudioRaiseVolume",
        KE.KEYCODE_VOLUME_DOWN to "XF86AudioLowerVolume",
        // Lock / power
        KE.KEYCODE_POWER to "XF86PowerOff",
        KE.KEYCODE_SLEEP to "XF86Sleep",
        KE.KEYCODE_WAKEUP to "XF86WakeUp",
        // Print / scroll / pause
        KE.KEYCODE_SYSRQ to "Print",
        KE.KEYCODE_SCROLL_LOCK to "Scroll_Lock",
        KE.KEYCODE_BREAK to "Pause",
    )
}