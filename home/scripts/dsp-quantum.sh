#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dsp-quantum — step the live PipeWire/JACK buffer (latency) on demand.
#   dsp-quantum up | down       move one step along [32..2048]
#   dsp-quantum set N           force a specific quantum
# OSD shows the resulting round-trip latency in ms.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

STEPS=(32 64 128 256 512 1024 2048)

meta() { pw-metadata -n settings 0 2>/dev/null; }
val()  { grep "$1'" | grep -oE "value:'[0-9]+'" | grep -oE '[0-9]+'; }

m="$(meta)"
cur="$(printf '%s\n' "$m" | val clock.force-quantum)"
if [ -z "${cur:-}" ] || [ "${cur:-0}" = "0" ]; then
  cur="$(printf '%s\n' "$m" | val clock.quantum)"
fi
rate="$(printf '%s\n' "$m" | val clock.rate)"; rate="${rate:-48000}"

idx=0
for i in "${!STEPS[@]}"; do [ "${STEPS[$i]}" = "${cur:-}" ] && idx=$i; done

case "${1:-}" in
  up)   idx=$(( idx + 1 < ${#STEPS[@]} ? idx + 1 : ${#STEPS[@]} - 1 )); q="${STEPS[$idx]}" ;;
  down) idx=$(( idx - 1 > 0 ? idx - 1 : 0 )); q="${STEPS[$idx]}" ;;
  set)  q="${2:?usage: dsp-quantum set N}" ;;
  *) echo "usage: dsp-quantum {up|down|set N}" >&2; exit 2 ;;
esac

pw-metadata -n settings 0 clock.force-quantum "$q" >/dev/null 2>&1 || true
ms="$(awk -v q="$q" -v r="$rate" 'BEGIN{ printf "%.2f", q*1000.0/r }')"
msg="Latency: ${ms}ms  (${q} @ ${rate})"
if command -v swayosd-client >/dev/null 2>&1 && swayosd-client --custom-message "$msg" --custom-icon audio-card 2>/dev/null; then
  :
else
  command -v notify-send >/dev/null 2>&1 && notify-send "🎛 DSP" "$msg" || echo "$msg"
fi
