#!/usr/bin/env bash
# nmtui-portal — run nmtui, then probe once it exits and hand off to
# captive-login if the network just joined turned out to be a portal. nmtui
# itself has no notion of connectivity and never reports one.
#
# Deliberately NOT named `nmtui`: shadowing the NM binary would surprise
# anything that scripts it.
#
# Environment:
#   CAPTIVE_PROBE_TRIES   probes after nmtui exits; default 5
#   CAPTIVE_PROBE_DELAY   seconds between them; default 2
#
# Expected on PATH: nmtui, nmcli, captive-login, sleep.
set -euo pipefail
export LC_ALL=C

: "${CAPTIVE_PROBE_TRIES:=5}"
: "${CAPTIVE_PROBE_DELAY:=2}"

nmtui "$@" || true

# A fresh association needs a moment for DHCP before the probe means
# anything; `connectivity check` itself blocks until NM's probe returns.
state=unknown
for _ in $(seq 1 "$CAPTIVE_PROBE_TRIES"); do
  state=$(nmcli networking connectivity check 2>/dev/null || echo unknown)
  case "$state" in
    full)
      echo "Online."
      exit 0
      ;;
    portal) exec captive-login ;;
  esac
  sleep "$CAPTIVE_PROBE_DELAY"
done
echo "Connectivity: $state (no portal detected). Run captive-login to force the login page."
