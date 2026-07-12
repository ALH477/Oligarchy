#!/usr/bin/env bash
# Recover AMD XHCI after "HC died; cleaning up".
# Default: Framework 16 primary controller 0000:c5:00.3 (kbd, USB audio, BT, expansion SSD, USB NIC).
# Intended for SSH:
#   ssh asher@100.84.104.25 'sudo xhci-recover'
# Needs NOPASSWD sudo rule (shipped via configuration.nix).
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "run as root: sudo $0 [PCI_ADDR ...]" >&2
  exit 1
fi

# All AMD Rembrandt XHCIs on this board (safe — o–only the primary usually dies)
DEVS=( "${@:-0000:c5:00.3}" )
if [[ $# -eq 0 ]]; then
  DEVS=(0000:c5:00.3)
fi

log() { echo "[xhci-recover $(date +%H:%M:%S)] $*"; }

rebind() {
  local dev=$1
  if [[ ! -e /sys/bus/pci/devices/$dev ]]; then
    log "WARN: $dev not present"
    return 1
  fi
  if [[ -e /sys/bus/pci/drivers/xhci_hcd/$dev ]]; then
    log "unbind $dev"
    echo "$dev" > /sys/bus/pci/drivers/xhci_hcd/unbind || true
    sleep 2
  fi
  log "bind $dev"
  if ! echo "$dev" > /sys/bus/pci/drivers/xhci_hcd/bind 2>/dev/null; then
    # force via remove/rescan when bind fails because driver still thinks it's dead
    log "bind failed — remove + rescan $dev"
    echo 1 > "/sys/bus/pci/devices/$dev/remove" || true
    sleep 1
    echo 1 > /sys/bus/pci/rescan
    sleep 2
  fi
}

for d in "${DEVS[@]}"; do
  rebind "$d" || true
done

sleep 2

if [[ -d /var/lib/systemd/rfkill ]]; then
  for f in /var/lib/systemd/rfkill/*bluetooth*; do
    [[ -f $f ]] || continue
    echo 0 >"$f" || true
  done
fi
rfkill unblock bluetooth 2>/dev/null || true

log "USB devices now:"
lsusb || true
log "Framework kbd / audio probe:"
lsusb | grep -E '32ac:0012|17cc:|0499:|0e8d:' || log "(not yet re-enumerated — replug or wait)"
log "done"
