#!/usr/bin/env bash
# No-KVM gate for modules/captive-portal: drives the three real scripts with a
# fake nmcli and asserts the state machine, the debounce, the display/TTY
# split and the nmtui hand-off. Run from anywhere:
#   bash modules/captive-portal/tests/run.sh
# or, hermetically, `nix build .#captive-portal-tests`.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=${BIN:-$here/../bin}
FAKES=$here/fakes

work=$(mktemp -d)
cleanup() {
  [ -n "${wpid:-}" ] && kill -- -"$wpid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# nmtui-portal execs `captive-login` by name, as the Nix wrapper puts it on
# PATH; here that name resolves to the real script under test.
mkdir -p "$work/bin"
printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$BIN/captive-login.sh" > "$work/bin/captive-login"
chmod +x "$work/bin/captive-login"
export PATH="$FAKES:$work/bin:$PATH"
export FAKE_NM_STATE=$work/state
export FAKE_NM_EVENTS=$work/events
export FAKE_NM_CALLS=$work/calls
export FAKE_OPENED=$work/opened
export FAKE_TUI_OPENED=$work/tui-opened
export CAPTIVE_LOGIN_URL="http://portal.example/"
export CAPTIVE_PROBE_URI="http://probe.example/check"
export CAPTIVE_OPENER="$FAKES/fake-open"
export CAPTIVE_TERMINAL_BROWSER="$FAKES/fake-tui"
export CAPTIVE_PROBE_TRIES=3
export CAPTIVE_PROBE_DELAY=0
unset DISPLAY WAYLAND_DISPLAY
: > "$FAKE_NM_EVENTS" ; : > "$FAKE_NM_CALLS" ; : > "$FAKE_OPENED" ; : > "$FAKE_TUI_OPENED"

ran=0
fail=0
check() { # check <name> <command...>
  local name=$1; shift
  ran=$((ran + 1))
  if "$@"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name" >&2
    fail=1
  fi
}
lines() { wc -l < "$1" | tr -d ' '; }
# wait_lines <file> <n> — up to ~5 s for the file to reach n lines.
wait_lines() {
  local _i
  for _i in $(seq 1 50); do
    [ "$(lines "$1")" -ge "$2" ] && return 0
    sleep 0.1
  done
  return 1
}
# settled_lines <file> <n> — the file holds exactly n lines and stays there.
settled_lines() { sleep 0.5; [ "$(lines "$1")" -eq "$2" ]; }
event() { echo "Connectivity is now '$1'" >> "$FAKE_NM_EVENTS"; }
tui_last() { tail -n 1 "$FAKE_TUI_OPENED"; }

# ── watcher ────────────────────────────────────────────────────────────────
echo portal > "$FAKE_NM_STATE"
setsid bash "$BIN/captive-portal-watch.sh" > "$work/watch.log" 2>&1 &
wpid=$!

check "watcher: portal already up at start opens once" \
  wait_lines "$FAKE_OPENED" 1
check "watcher: opens the configured login URL" \
  grep -qx "$CAPTIVE_LOGIN_URL" "$FAKE_OPENED"
check "watcher: sends a notification" \
  grep -q '^notify ' "$FAKE_NM_CALLS"

event portal
check "watcher: repeated portal while unpaid does not reopen" \
  settled_lines "$FAKE_OPENED" 1

event limited
event portal
check "watcher: limited does not re-arm" \
  settled_lines "$FAKE_OPENED" 1

event full
event portal
check "watcher: full re-arms, next portal opens again" \
  wait_lines "$FAKE_OPENED" 2

event none
event portal
check "watcher: none re-arms, next portal opens again" \
  wait_lines "$FAKE_OPENED" 3

echo "Connectivity is now 'portal' extra" >> "$FAKE_NM_EVENTS"
echo "Networkmanager is now in the 'connected' state" >> "$FAKE_NM_EVENTS"
check "watcher: unrelated monitor lines are ignored" \
  settled_lines "$FAKE_OPENED" 3

check "watcher: still running after the event stream" \
  kill -0 "$wpid"
kill -- -"$wpid" 2>/dev/null || true
unset wpid

# ── captive-login ──────────────────────────────────────────────────────────
: > "$FAKE_OPENED"; : > "$FAKE_NM_CALLS"
echo portal > "$FAKE_NM_STATE"
out=$(bash "$BIN/captive-login.sh")
check "login/tty: on a portal with no display, uses the text browser" \
  test "$(tui_last)" = "$CAPTIVE_LOGIN_URL"
check "login/tty: re-probes after the browser exits" \
  test "$(grep -c '^check$' "$FAKE_NM_CALLS")" -eq 2
check "login/tty: never calls the graphical opener" \
  test "$(lines "$FAKE_OPENED")" -eq 0
check "login: prints the connectivity state" \
  grep -q '^Connectivity: portal$' <<< "$out"
check "login: prints per-link DNS" \
  grep -q 'Link 2 (wlan0): 192.0.2.1' <<< "$out"

: > "$FAKE_TUI_OPENED"; : > "$FAKE_NM_CALLS"
echo full > "$FAKE_NM_STATE"
out=$(bash "$BIN/captive-login.sh")
check "login: already online does nothing" \
  grep -q 'Already online' <<< "$out"
check "login: already online opens no browser" \
  test "$(lines "$FAKE_TUI_OPENED")" -eq 0

out=$(bash "$BIN/captive-login.sh" --force)
check "login: --force opens even when online" \
  test "$(tui_last)" = "$CAPTIVE_LOGIN_URL"

: > "$FAKE_OPENED"; : > "$FAKE_TUI_OPENED"
echo portal > "$FAKE_NM_STATE"
out=$(WAYLAND_DISPLAY=wayland-1 bash "$BIN/captive-login.sh")
check "login/gui: with a display, uses the graphical opener" \
  wait_lines "$FAKE_OPENED" 1
check "login/gui: with a display, never uses the text browser" \
  test "$(lines "$FAKE_TUI_OPENED")" -eq 0
check "login/gui: tells the user how to re-check" \
  grep -q 'nmcli networking connectivity check' <<< "$out"

# Into a file, not a pipe: with pipefail, grep -q closing the pipe early would
# hand the producer a SIGPIPE and turn a pass into a flaky fail.
help_ok() { bash "$BIN/captive-login.sh" --help > "$work/help" && grep -q '^usage: captive-login' "$work/help"; }
check "login: --help prints usage and exits 0" help_ok

# ── nmtui-portal ───────────────────────────────────────────────────────────
: > "$FAKE_TUI_OPENED"; : > "$FAKE_NM_CALLS"
echo portal > "$FAKE_NM_STATE"
out=$(bash "$BIN/nmtui-portal.sh" connect)
check "nmtui-portal: runs nmtui with the given arguments" \
  grep -qx 'nmtui connect' "$FAKE_NM_CALLS"
check "nmtui-portal: portal after nmtui hands off to captive-login" \
  test "$(tui_last)" = "$CAPTIVE_LOGIN_URL"

: > "$FAKE_TUI_OPENED"; : > "$FAKE_NM_CALLS"
echo full > "$FAKE_NM_STATE"
out=$(bash "$BIN/nmtui-portal.sh")
check "nmtui-portal: full after nmtui reports online" \
  grep -qx 'Online.' <<< "$out"
check "nmtui-portal: full opens nothing" \
  test "$(lines "$FAKE_TUI_OPENED")" -eq 0

: > "$FAKE_NM_CALLS"
echo limited > "$FAKE_NM_STATE"
out=$(bash "$BIN/nmtui-portal.sh")
check "nmtui-portal: limited retries CAPTIVE_PROBE_TRIES times then gives up" \
  test "$(grep -c '^check$' "$FAKE_NM_CALLS")" -eq "$CAPTIVE_PROBE_TRIES"
check "nmtui-portal: limited names captive-login as the manual path" \
  grep -q 'Run captive-login' <<< "$out"

: > "$FAKE_NM_CALLS"
echo full > "$FAKE_NM_STATE"
out=$(FAKE_NMTUI_EXIT=1 bash "$BIN/nmtui-portal.sh")
check "nmtui-portal: a failing nmtui still probes" \
  grep -qx 'Online.' <<< "$out"

# ── contract ───────────────────────────────────────────────────────────────
no_url() { ! CAPTIVE_LOGIN_URL='' bash "$BIN/captive-portal-watch.sh" 2>/dev/null; }
check "watch: refuses to run without CAPTIVE_LOGIN_URL" no_url

expected=29
echo
echo "captive-portal-tests: $ran checks run, expected $expected"
if [ "$ran" -ne "$expected" ]; then
  echo "captive-portal-tests: check count drifted — update 'expected' with the new checks" >&2
  exit 1
fi
[ "$fail" -eq 0 ] || { echo "captive-portal-tests: FAILED" >&2; exit 1; }
echo "captive-portal-tests: OK"
