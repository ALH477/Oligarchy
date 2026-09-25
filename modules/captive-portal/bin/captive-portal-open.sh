#!/usr/bin/env bash
# captive-portal-open — open the login URL in an ISOLATED browser context.
#
# The page a portal redirects to is attacker-controlled plaintext HTTP: on a
# hostile network anyone owning the gateway can make NetworkManager report
# PORTAL and then serve whatever they like. That page must therefore never
# run in the user's everyday profile, where it could reach live sessions,
# non-Secure cookies for other http:// sites, extensions and history. This
# is what GNOME's portal helper does with a throwaway WebKit view; here it is
# a throwaway browser profile under $XDG_RUNTIME_DIR (0700, gone at logout).
#
# Environment (exported by the Nix wrapper; the no-KVM gate sets fakes):
#   CAPTIVE_BROWSER_KIND   microvm | firefox | chromium | command | xdg-open
#   CAPTIVE_VM_FALLBACK    kind used when the portal VM cannot start (firefox)
#   CAPTIVE_VM_STATUS      the VM launcher's status file, for the reason
#   CAPTIVE_BROWSER_BIN    the browser binary for firefox/chromium kinds
#   CAPTIVE_BROWSER_CMD    the command for kind=command (no isolation added)
#   CAPTIVE_ALLOW_ROOT     test seam only: skip the root refusal
set -euo pipefail

url=${1:?usage: captive-portal-open URL}
: "${CAPTIVE_BROWSER_KIND:=firefox}"

# A browser on attacker content is bad enough; a browser as root is worse,
# and `sudo nmtui-portal` is exactly how it would happen.
if [ "$(id -u)" -eq 0 ] && [ "${CAPTIVE_ALLOW_ROOT:-0}" != 1 ]; then
  echo "captive-portal-open: refusing to open a browser as root; run captive-login as your user" >&2
  exit 3
fi

case "$url" in
  http://*) ;;
  *)
    # The wrapper's URL is asserted http:// at eval; this guards the manual path.
    echo "captive-portal-open: refusing non-http URL '$url' (portals cannot redirect anything else)" >&2
    exit 2
    ;;
esac

# kind=microvm: the page is not opened here at all. The portal VM boots with
# the login URL baked into its verified image, and owns its own VT (or the
# passed-through GPU's monitor). This only asks systemd to start it — the
# polkit rule in the module lets exactly this user start exactly that unit —
# and falls back to the isolated profile below if it will not come up,
# saying why. Nothing is passed to the VM: no URL, no clipboard, no file.
if [ "$CAPTIVE_BROWSER_KIND" = microvm ]; then
  if systemctl start "${CAPTIVE_VM_UNIT:-captive-vm.service}" 2>/dev/null; then
    exit 0
  fi
  why=$(jq -r '.reason // empty' "${CAPTIVE_VM_STATUS:-/run/captive-portal/vm-status}" 2>/dev/null || true)
  notify-send -u critical -a NetworkManager -i network-wireless \
    "Portal VM unavailable" "${why:-it did not start} — using an isolated browser profile instead." \
    2>/dev/null || true
  echo "captive-portal-open: portal VM unavailable (${why:-did not start}); falling back" >&2
  CAPTIVE_BROWSER_KIND=${CAPTIVE_VM_FALLBACK:-firefox}
fi

# Fresh, private profile dir per open. Older ones from this session are
# swept when they are an hour old so a still-open window keeps its dir.
base=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
find "$base" -maxdepth 1 -type d -name 'captive-portal.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
profile=$(mktemp -d "$base/captive-portal.XXXXXX")
chmod 0700 "$profile"

case "$CAPTIVE_BROWSER_KIND" in
  firefox)
    # --no-remote --new-instance: never hand the URL to the running everyday
    # Firefox; --profile on a fresh dir: no cookies, history, extensions.
    exec "${CAPTIVE_BROWSER_BIN:-firefox}" --no-remote --new-instance \
      --profile "$profile" --private-window "$url"
    ;;
  chromium)
    exec "${CAPTIVE_BROWSER_BIN:-chromium}" --user-data-dir="$profile" \
      --incognito --no-first-run --no-default-browser-check \
      --disable-extensions --disable-sync "$url"
    ;;
  command)
    : "${CAPTIVE_BROWSER_CMD:?CAPTIVE_BROWSER_CMD is required for kind=command}"
    rmdir "$profile"
    exec "$CAPTIVE_BROWSER_CMD" "$url"
    ;;
  xdg-open)
    # Explicitly opted into by the option; the everyday profile, no isolation.
    rmdir "$profile"
    exec xdg-open "$url"
    ;;
  *)
    echo "captive-portal-open: unknown CAPTIVE_BROWSER_KIND '$CAPTIVE_BROWSER_KIND'" >&2
    exit 2
    ;;
esac
