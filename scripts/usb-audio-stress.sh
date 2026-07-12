#!/usr/bin/env bash
# Bounded pw-link thrash. Aborts if Framework keyboard disappears or HC dies.
# Modes: single (default) | dual | defaults
set -euo pipefail
MODE=${1:-single}
ROUNDS=${ROUNDS:-20}
LOG=/tmp/oligarchy-xhci-rc/stress-${MODE}.log
mkdir -p /tmp/oligarchy-xhci-rc
: >"$LOG"

KBD() { compgen -G '/dev/input/by-id/usb-Framework_Laptop_16_Keyboard_Module*' >/dev/null 2>&1; }

die_if_dead() {
  if ! KBD; then
    echo "ABORT: keyboard lost" | tee -a "$LOG"
    journalctl -b -k --since '20 sec ago' --no-pager 2>/dev/null | tee -a "$LOG" || true
    exit 3
  fi
  if journalctl -b -k --since '20 sec ago' --no-pager 2>/dev/null | grep -q 'HC died'; then
    echo "ABORT: HC died in kernel log" | tee -a "$LOG"
    exit 4
  fi
}

K2_IN=alsa_input.usb-Native_Instruments_Komplete_Audio_2_0000A748-00.analog-stereo:capture_FL
K2_OUT=alsa_output.usb-Native_Instruments_Komplete_Audio_2_0000A748-00.analog-stereo:playback_FL
MG_IN=alsa_input.usb-Yamaha_Corporation_MG-XU-00.analog-stereo:capture_FL
MG_OUT=alsa_output.usb-Yamaha_Corporation_MG-XU-00.analog-stereo:playback_FL
ON_OUT=alsa_output.pci-0000_c5_00.6.analog-stereo:playback_FL

echo "start mode=$MODE rounds=$ROUNDS $(date)" | tee -a "$LOG"
die_if_dead

for i in $(seq 1 "$ROUNDS"); do
  echo "round $i $(date +%T) mode=$MODE" | tee -a "$LOG"
  case "$MODE" in
    single)
      pw-link "$K2_IN" "$ON_OUT" 2>/dev/null || true
      sleep 0.3
      pw-link -d "$K2_IN" "$ON_OUT" 2>/dev/null || true
      ;;
    dual)
      pw-link "$K2_IN" "$K2_OUT" 2>/dev/null || true
      pw-link "$MG_IN" "$MG_OUT" 2>/dev/null || true
      sleep 0.3
      pw-link -d "$K2_IN" "$K2_OUT" 2>/dev/null || true
      pw-link -d "$MG_IN" "$MG_OUT" 2>/dev/null || true
      ;;
    defaults)
      wpctl status 2>/dev/null | head -40 | tee -a "$LOG" || true
      ;;
    *)
      echo "usage: $0 {single|dual|defaults}" >&2
      exit 2
      ;;
  esac
  die_if_dead
  sleep 0.5
done
echo "PASS mode=$MODE rounds=$ROUNDS" | tee -a "$LOG"
