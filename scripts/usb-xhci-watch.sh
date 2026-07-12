#!/usr/bin/env bash
# Poll XHCI + Framework keyboard + USB audio presence. Exit 2 if keyboard vanishes.
set -euo pipefail
LOG=${1:-/tmp/oligarchy-xhci-rc/watch.log}
mkdir -p "$(dirname "$LOG")"
KBD_GLOB='/dev/input/by-id/usb-Framework_Laptop_16_Keyboard_Module*'
end=$((SECONDS + ${WATCH_SECS:-120}))
prev=""
while (( SECONDS < end )); do
  s=""
  for d in /sys/bus/pci/devices/*/; do
    c=$(cat "$d/class" 2>/dev/null) || continue
    [[ $c == 0x0c0330* ]] || continue
    s+="$(basename "$d")=$(cat "$d/power/control")/$(cat "$d/power/runtime_status"); "
  done
  kbd=0
  # shellcheck disable=SC2086
  if compgen -G $KBD_GLOB >/dev/null 2>&1; then kbd=1; fi
  cards=$(grep -E 'K2|MGXU|usb' /proc/asound/cards 2>/dev/null | tr '\n' ' ' || true)
  bt=$(rfkill list 2>/dev/null | awk '/Bluetooth/{f=1} f&&/Soft blocked/{print $3; exit}')
  line="$(date +%H:%M:%S) kbd=$kbd bt_soft=${bt:-?} cards=[$cards] $s"
  if [[ $line != "$prev" ]]; then
    echo "$line" | tee -a "$LOG"
    prev=$line
  fi
  if [[ $kbd -eq 0 ]]; then
    echo "FATAL: keyboard gone — abort watch" | tee -a "$LOG"
    journalctl -b -k --since '30 sec ago' --no-pager 2>/dev/null | tee -a "$LOG" || true
    exit 2
  fi
  if journalctl -b -k --since '5 sec ago' --no-pager 2>/dev/null | grep -q 'HC died'; then
    echo "FATAL: HC died" | tee -a "$LOG"
    exit 4
  fi
  sleep 1
done
echo "WATCH OK $(date +%H:%M:%S)" | tee -a "$LOG"
