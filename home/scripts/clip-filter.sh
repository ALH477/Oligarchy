#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# clip-filter — sits between `wl-paste --watch` and `cliphist store`, refusing
# to persist clipboard content that looks like a secret (private keys, common
# cloud-credential prefixes, JWTs) into cliphist's on-disk history.
#
# Best-effort, not a security boundary: whatever's on the live clipboard is
# still readable by any app that reads the clipboard, same as always. This
# only stops that content from also landing in cliphist's persistent history,
# where it would otherwise survive far longer than the copy that put it there
# (and show up in the $mod,V picker for anyone who later uses the machine).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

data="$(cat)"

is_secret() {
  grep -qE \
    -e '-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----' \
    -e '^(AKIA|ASIA)[A-Z0-9]{16}$' \
    -e '^gh[pousr]_[A-Za-z0-9]{36,}$' \
    -e '^xox[baprs]-[A-Za-z0-9-]{10,}$' \
    -e '^ey[A-Za-z0-9_-]{10,}\.ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}$' \
    <<< "$1"
}

if is_secret "$data"; then
  exit 0
fi

printf '%s' "$data" | cliphist store
