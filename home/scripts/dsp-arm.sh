#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dsp-arm — arm/disarm the ArchibaldOS DSP coprocessor at runtime.
# Starts/stops the VM service (system; the polkit rule in dsp-rigs.nix lets
# the desktop user manage exactly that unit) and this host's NetJack2 link to
# it (dsp-netjack, a user unit: PipeWire's netjack2 driver, no privilege).
#   dsp-arm on|off|toggle|status
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

VM="${OLIGARCHY_DSP_VM:-archibaldos-dsp}"
LINK="dsp-netjack"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send "🎛 DSP" "$1" || echo "$1"; }
is_armed() { systemctl is-active --quiet "$VM"; }

case "${1:-toggle}" in
  on)
    err=$( { systemctl start "$VM" && systemctl --user start "$LINK"; } 2>&1)
    if [ -z "$err" ]; then
      notify "coprocessor armed — patch your rig in"
    else
      notify "arm failed (is the DSP VM built, and the polkit rule present?)
$err"
    fi
    ;;
  off)
    systemctl --user stop "$LINK" 2>/dev/null
    systemctl stop "$VM" 2>/dev/null && notify "coprocessor disarmed" || notify "disarm failed"
    ;;
  toggle)
    if is_armed; then exec "$0" off; else exec "$0" on; fi
    ;;
  status)
    is_armed && echo armed || echo disarmed
    ;;
  *) echo "usage: dsp-arm {on|off|toggle|status}" >&2; exit 2 ;;
esac
