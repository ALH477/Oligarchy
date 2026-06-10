#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# panic — privacy / panic mode.
# One motion: mute the mic, wipe the clipboard, optionally cut all radios, then
# lock. Bound to Super+Shift+Delete (deliberately awkward).
# Set OLIGARCHY_PANIC_RFKILL=1 to also `rfkill block all` (best-effort; may need
# privilege). Camera kill is left opt-in (needs root: modprobe -r uvcvideo).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

notify() { command -v notify-send >/dev/null 2>&1 && notify-send -u critical "🛡 Panic" "$1" || echo "$1"; }

# 1. Mute the microphone.
wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 1 2>/dev/null || true

# 2. Wipe clipboard history and the live clipboard.
command -v cliphist >/dev/null 2>&1 && cliphist wipe 2>/dev/null || true
command -v wl-copy  >/dev/null 2>&1 && wl-copy --clear 2>/dev/null || true

# 3. Optional: cut every radio (Wi-Fi / Bluetooth).
radios=""
if [ "${OLIGARCHY_PANIC_RFKILL:-0}" = "1" ] && command -v rfkill >/dev/null 2>&1; then
  rfkill block all 2>/dev/null && radios=" · radios off" || true
fi

notify "locked · mic muted · clipboard wiped${radios}"

# 4. Lock last (blocking).
pidof hyprlock >/dev/null 2>&1 || hyprlock
