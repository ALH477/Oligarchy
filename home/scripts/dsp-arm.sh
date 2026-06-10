#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dsp-arm — arm/disarm the ArchibaldOS DSP coprocessor at runtime.
# Starts/stops the VM service + the NETJACK bridge. Needs privilege; the
# accompanying polkit rule lets the desktop user manage exactly these units.
#   dsp-arm on|off|toggle|status
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

VM="${OLIGARCHY_DSP_VM:-archibaldos-dsp}"
BRIDGE="dsp-netjack-bridge"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send "🎛 DSP" "$1" || echo "$1"; }
is_armed() { systemctl is-active --quiet "$VM"; }

case "${1:-toggle}" in
  on)
    if systemctl start "$VM" "$BRIDGE" 2>/dev/null; then
      notify "coprocessor armed — patch your rig in"
    else
      notify "arm failed (is the DSP VM built, and the polkit rule present?)"
    fi
    ;;
  off)
    systemctl stop "$BRIDGE" "$VM" 2>/dev/null && notify "coprocessor disarmed" || notify "disarm failed"
    ;;
  toggle)
    if is_armed; then exec "$0" off; else exec "$0" on; fi
    ;;
  status)
    is_armed && echo armed || echo disarmed
    ;;
  *) echo "usage: dsp-arm {on|off|toggle|status}" >&2; exit 2 ;;
esac
