#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# clipboard-picker — cliphist history via wofi, with real image thumbnails.
#
# `cliphist list` alone only shows a "binary data 184 KiB image/png"
# placeholder line for image entries, no preview — this decodes each image
# entry once, caches a small thumbnail, and feeds it to wofi via its
# documented dmenu image syntax (`text\0icon\x1f<path>`). Falls back to plain
# text entries for anything that isn't an image, or whose thumbnail fails to
# render, so this never regresses the plain-text behavior it replaces
# ($mod,V previously ran `cliphist list | wofi --dmenu | cliphist decode |
# wl-copy` directly).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

CACHE="$HOME/.cache/oligarchy/clip-thumbs"
mkdir -p "$CACHE"

build_list() {
  local id rest thumb
  cliphist list | while IFS=$'\t' read -r id rest; do
    if [[ "$rest" == *"binary data"*"image/"* ]]; then
      thumb="$CACHE/$id.png"
      if [[ ! -s "$thumb" ]]; then
        cliphist decode "$id" 2>/dev/null | magick - -resize 128x128 "$thumb" 2>/dev/null || true
      fi
      if [[ -s "$thumb" ]]; then
        printf '%s\0icon\x1f%s\n' "$id: $rest" "$thumb"
        continue
      fi
    fi
    printf '%s\t%s\n' "$id" "$rest"
  done
}

choice="$(build_list | wofi --dmenu -p 'Clipboard')"
[[ -z "$choice" ]] && exit 0

# Image entries come back as "<id>: <rest>", text entries as "<id><TAB><rest>"
# — either way the id is whatever precedes the first ':' or tab.
id="${choice%%[:$'\t']*}"
[[ -n "$id" ]] && cliphist decode "$id" | wl-copy

# Prune thumbnails for entries cliphist has since aged out (it caps history
# length itself), so this cache doesn't grow unbounded.
live_ids="$(cliphist list | cut -f1)"
for f in "$CACHE"/*.png; do
  [[ -e "$f" ]] || continue
  fid="$(basename "$f" .png)"
  grep -qx "$fid" <<< "$live_ids" || rm -f "$f"
done
