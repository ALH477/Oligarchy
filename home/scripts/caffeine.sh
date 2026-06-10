#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# caffeine — toggle idle inhibition (keep-awake).
# Holds a `systemd-inhibit --what=idle:sleep` lock; hypridle honors systemd idle
# inhibitors (ignore_systemd_inhibit = false), so this pauses dim/lock/dpms/suspend.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/oligarchy-caffeine.pid"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send "☕ Caffeine" "$1" || echo "$1"; }

is_on() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

start() {
  is_on && return 0
  systemd-inhibit --what=idle:sleep --who=oligarchy-caffeine \
    --why="manual keep-awake" --mode=block sleep infinity >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  notify "on — the screen stays awake"
}

stop() {
  if is_on; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
  rm -f "$PIDFILE"
  notify "off"
}

case "${1:-toggle}" in
  on)     start ;;
  off)    stop ;;
  toggle) if is_on; then stop; else start; fi ;;
  status) is_on && echo on || echo off ;;
  *) echo "usage: caffeine {on|off|toggle|status}" >&2; exit 2 ;;
esac
