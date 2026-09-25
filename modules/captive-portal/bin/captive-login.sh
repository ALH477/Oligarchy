#!/usr/bin/env bash
# captive-login — the manual path: re-probe, show per-link DNS, open the login
# page. With a display it opens the default browser; without one (TTY, SSH)
# it opens a text browser and re-probes when that exits.
#
# Environment (see captive-portal-watch.sh for where it comes from):
#   CAPTIVE_LOGIN_URL          required
#   CAPTIVE_PROBE_URI          shown in the banner only
#   CAPTIVE_OPENER             default captive-portal-open (isolated profile)
#   CAPTIVE_TERMINAL_BROWSER   default w3m
#   CAPTIVE_ALLOW_ROOT         test seam only: skip the root refusal
#
# Expected on PATH: nmcli, resolvectl, notify-send, setsid, sed.
set -euo pipefail
export LC_ALL=C

: "${CAPTIVE_LOGIN_URL:?CAPTIVE_LOGIN_URL is required}"
: "${CAPTIVE_PROBE_URI:=<unset>}"
: "${CAPTIVE_OPENER:=captive-portal-open}"
: "${CAPTIVE_TERMINAL_BROWSER:=w3m}"

# Both paths render attacker-controlled HTML; neither may do it as root.
if [ "$(id -u)" -eq 0 ] && [ "${CAPTIVE_ALLOW_ROOT:-0}" != 1 ]; then
  echo "captive-login: refusing to open the portal page as root; run this as your own user (no sudo)." >&2
  exit 3
fi

force=0
case "${1:-}" in
  --force) force=1 ;;
  -h | --help)
    echo "usage: captive-login [--force]"
    echo "  Re-probe connectivity and open the captive portal login page."
    echo "  --force opens the page even when NetworkManager reports full connectivity."
    exit 0
    ;;
esac

echo "Re-probing $CAPTIVE_PROBE_URI ..."
state=$(nmcli networking connectivity check 2>/dev/null || echo unknown)
echo "Connectivity: $state"
echo
echo "DNS servers per link (the portal's DHCP resolver should appear on the Wi-Fi link):"
resolvectl dns 2>/dev/null | sed 's/^/  /' || true
echo

if [ "$state" = full ] && [ "$force" -eq 0 ]; then
  echo "Already online — nothing to log into. (--force opens the page anyway.)"
  exit 0
fi

if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
  notify-send -u critical -a NetworkManager -i network-wireless \
    "Captive portal" "Opening $CAPTIVE_LOGIN_URL — sign in to finish connecting." \
    2>/dev/null || true
  setsid -f "$CAPTIVE_OPENER" "$CAPTIVE_LOGIN_URL" >/dev/null 2>&1 || true
  echo "Opened $CAPTIVE_LOGIN_URL. After signing in: nmcli networking connectivity check"
else
  # No display: do the login in the terminal. Most portal forms are a
  # checkbox and a button, which a text browser handles.
  "$CAPTIVE_TERMINAL_BROWSER" "$CAPTIVE_LOGIN_URL" || true
  echo
  echo "Re-checking ..."
  nmcli networking connectivity check
fi
