#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# idle-suspend — load- and temperature-aware replacement for hypridle's bare
# `systemctl suspend` timeout action.
#
# Why this exists: systemd-sleep only freezes `user.slice`. A nix build runs
# under nix-daemon.service (a *system* service) and takes no inhibitor lock, so
# the old unconditional 30m suspend would drop a fully-loaded machine into
# s2idle mid-build. The EC then applies its suspend-time fan policy while the
# CPU keeps churning, and the laptop cooks with the fans pinned low.
#
# So: at the idle timeout we do not suspend immediately. We poll, and only
# suspend once the machine is genuinely idle *and* cool. Real user activity
# cancels the pending suspend via the listener's on-resume hook.
#
#   start   arm the deferred-suspend watcher (hypridle on-timeout)
#   cancel  disarm it                        (hypridle on-resume)
#   status  report what it would do right now
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/oligarchy-idle-suspend.pid"

# Seconds between busy re-checks once the watcher is armed.
POLL=60
# 1-minute loadavg at or above this counts as busy. Scaled to core count: a
# fixed low bar (1.5) is only ~9% of this 16-thread board and an ordinary idle
# desktop already measures ~1.0, which would defer forever. A real build sits at
# 8-32. nproc/4, floored at 2, cleanly separates the two. This is only a backstop
# anyway — nix_busy/build_busy catch the named tools structurally.
LOAD_MAX=$(awk -v n="$(nproc 2>/dev/null || echo 4)" 'BEGIN { m = n / 4; print (m < 2 ? 2 : m) }')
# Hottest CPU/GPU reading (degrees C) we are willing to suspend at. Suspending a
# hot machine into s2idle parks it with the fans down. Idle on this board sits
# around 50-52C, a sustained build pushes 85-95C, so 65 is "has it actually come
# back down" with margin either side.
TEMP_MAX=65

log() { logger -t oligarchy-idle-suspend "$*" 2>/dev/null || true; }

# ── Busy predicates ──────────────────────────────────────────────────────────

# Active nix build. nix-daemon forks one worker per concurrent build and the
# idle daemon is a single process, so a child count > 1 is the cheapest
# structural signal — it does not depend on what the sandboxed builder happens
# to be named. Also catch a foreground nix / nixos-rebuild run.
#
# NB: match on process names only. `pgrep -x -f PATTERN` requires the pattern to
# match the *entire* command line including arguments, so it never fires on a
# real invocation.
nix_busy() {
  [ "$(pgrep -x nix-daemon 2>/dev/null | wc -l)" -gt 1 ] && return 0
  pgrep -x nix           >/dev/null 2>&1 && return 0
  pgrep -x nix-build     >/dev/null 2>&1 && return 0
  pgrep -x nixos-rebuild >/dev/null 2>&1 && return 0
  return 1
}

# Other long-running build jobs worth not interrupting. Transient compute is
# covered by the loadavg check below.
build_busy() {
  pgrep -x cargo >/dev/null 2>&1 && return 0
  pgrep -x rustc >/dev/null 2>&1 && return 0
  pgrep -x ninja >/dev/null 2>&1 && return 0
  pgrep -x make  >/dev/null 2>&1 && return 0
  return 1
}

load_busy() {
  local load
  load=$(awk '{print $1}' /proc/loadavg 2>/dev/null) || return 1
  awk -v l="$load" -v m="$LOAD_MAX" 'BEGIN { exit !(l >= m) }'
}

# Only CPU package (k10temp) and GPU (amdgpu) count as "compute heat". Do NOT
# scan every hwmon: mt7921_phy0 (the WiFi radio) idles at ~56C on this board and
# acpitz/cros_ec report chassis zones, so a blanket max would sit permanently
# above any sane threshold and quietly turn this into "never suspend".
too_hot() {
  local d name v max=0
  for d in /sys/class/hwmon/hwmon*; do
    name=$(cat "$d/name" 2>/dev/null) || continue
    case "$name" in
      k10temp | amdgpu) ;;
      *) continue ;;
    esac
    for f in "$d"/temp*_input; do
      [ -r "$f" ] || continue
      v=$(cat "$f" 2>/dev/null) || continue   # some sysfs temps EBUSY on read
      [[ $v =~ ^[0-9]+$ ]] || continue
      [ "$v" -gt "$max" ] && max=$v
    done
  done
  [ "$max" -gt 0 ] || return 1                # no readable sensor: don't block
  [ $(( max / 1000 )) -ge "$TEMP_MAX" ]
}

# Prints the reason and exits 0 if busy; exits 1 if idle. Also the entry point
# the detached watcher loop re-invokes.
busy_reason() {
  nix_busy   && { echo "nix build active"; return 0; }
  build_busy && { echo "build job active"; return 0; }
  load_busy  && { echo "loadavg $(awk '{print $1}' /proc/loadavg) >= $LOAD_MAX"; return 0; }
  too_hot    && { echo "still hot (>= ${TEMP_MAX}C)"; return 0; }
  return 1
}

# ── Watcher ──────────────────────────────────────────────────────────────────

is_pending() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

# Runs detached, in its own session. Records its own PID so `cancel` kills the
# loop itself rather than the setsid wrapper.
watch_loop() {
  echo $$ > "$PIDFILE"
  trap 'rm -f "$PIDFILE"; exit 0' TERM INT
  local reason
  while :; do
    if reason=$(busy_reason); then
      log "deferring suspend: $reason"
      sleep "$POLL"
      continue
    fi
    log "idle and cool - suspending"
    rm -f "$PIDFILE"
    exec systemctl suspend
  done
}

start() {
  is_pending && return 0
  # Detach into a new session so the loop outlives the short-lived `sh -c` that
  # hypridle spawns for on-timeout and is immune to a SIGHUP aimed at that
  # shell's process group. The child writes its own pidfile.
  setsid "$SELF" --watch >/dev/null 2>&1 < /dev/null &
  disown 2>/dev/null || true
}

cancel() {
  if is_pending; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    log "pending suspend cancelled by user activity"
  fi
  rm -f "$PIDFILE"
}

case "${1:-start}" in
  start)   start ;;
  cancel)  cancel ;;
  --watch) watch_loop ;;
  status)
    if is_pending; then
      echo "armed, waiting: $(busy_reason || echo 'idle — suspending shortly')"
    elif r=$(busy_reason); then
      echo "not armed; would defer: $r"
    else
      echo "not armed; idle"
    fi
    ;;
  *) echo "usage: idle-suspend {start|cancel|status}" >&2; exit 2 ;;
esac
