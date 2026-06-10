#!/usr/bin/env bash
# dsp-latency — effective PipeWire/JACK latency (ms) + active rig, for the
# waybar DSP HUD. Computed from the live clock quantum/rate.
set -uo pipefail

m="$(pw-metadata -n settings 0 2>/dev/null)" || { echo "n/a"; exit 0; }

q="$(printf '%s\n' "$m" | grep 'clock.force-quantum' | grep -oE "value:'[0-9]+'" | grep -oE '[0-9]+')"
if [ -z "${q:-}" ] || [ "${q:-0}" = "0" ]; then
  q="$(printf '%s\n' "$m" | grep "clock.quantum'" | grep -oE "value:'[0-9]+'" | grep -oE '[0-9]+')"
fi
r="$(printf '%s\n' "$m" | grep "clock.rate'" | grep -oE "value:'[0-9]+'" | grep -oE '[0-9]+')"
rig="$(cat "$HOME/.config/oligarchy/rig" 2>/dev/null || true)"

if [ -n "${q:-}" ] && [ -n "${r:-}" ] && [ "${r:-0}" -gt 0 ]; then
  awk -v q="$q" -v r="$r" -v rig="${rig:-}" 'BEGIN{ printf "%.2fms%s", q*1000.0/r, (rig!="" ? " · " rig : "") }'
else
  echo "n/a"
fi
