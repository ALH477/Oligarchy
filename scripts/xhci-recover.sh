#!/usr/bin/env bash
# Root-only: rebind AMD XHCI after "HC died". Default 0000:c5:00.3 (Framework 16 primary).
set -euo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "run as root: sudo $0 [PCI_ADDR]" >&2
  exit 1
fi
DEV=${1:-0000:c5:00.3}
echo "Unbinding $DEV from xhci_hcd"
echo "$DEV" > /sys/bus/pci/drivers/xhci_hcd/unbind
sleep 2
echo "Binding $DEV to xhci_hcd"
echo "$DEV" > /sys/bus/pci/drivers/xhci_hcd/bind
sleep 2
lsusb
if [[ -d /var/lib/systemd/rfkill ]]; then
  for f in /var/lib/systemd/rfkill/*bluetooth*; do
    [[ -f $f ]] || continue
    echo 0 >"$f" || true
  done
fi
rfkill unblock bluetooth || true
echo "done — check keyboard / audio re-enumeration"
