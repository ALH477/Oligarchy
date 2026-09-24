#!/usr/bin/env bash
# captive-portal-watch — follow NetworkManager's connectivity state and open
# the login page once per portal episode.
#
# Configuration comes from the environment (the Nix wrapper in
# modules/captive-portal/default.nix exports it; the no-KVM gate in
# modules/captive-portal/tests/run.sh sets it to fakes):
#   CAPTIVE_LOGIN_URL  plain-http page for the portal to hijack (required)
#   CAPTIVE_OPENER     command given the URL; default xdg-open
#
# Expected on PATH: nmcli, notify-send, setsid.
set -euo pipefail

# nmcli localises its monitor lines; the match below needs the C strings.
export LC_ALL=C

: "${CAPTIVE_LOGIN_URL:?CAPTIVE_LOGIN_URL is required}"
: "${CAPTIVE_OPENER:=xdg-open}"

open_login() {
  notify-send -u critical -a NetworkManager -i network-wireless \
    "Captive portal" "Opening $CAPTIVE_LOGIN_URL — sign in to finish connecting." \
    2>/dev/null || true
  # Detached: the browser must outlive this service's cgroup.
  setsid -f "$CAPTIVE_OPENER" "$CAPTIVE_LOGIN_URL" >/dev/null 2>&1 || true
}

# Open at most once per portal episode. Re-armed on full (logged in) or none
# (disconnected), so the next portal network opens again, but NM's periodic
# re-probe while still on the portal never spawns a second tab.
opened=0
handle() {
  case "$1" in
    portal)
      if [ "$opened" -eq 0 ]; then
        opened=1
        open_login
      fi
      ;;
    full | none) opened=0 ;;
  esac
}

# Catch a portal that was already up before this session started.
handle "$(nmcli -t -g CONNECTIVITY general 2>/dev/null || true)"

# Process substitution, not a pipe: keeps `opened` in this shell.
while IFS= read -r line; do
  case "$line" in
    "Connectivity is now '"*"'")
      state=${line#"Connectivity is now '"}
      handle "${state%"'"}"
      ;;
  esac
done < <(nmcli monitor)
