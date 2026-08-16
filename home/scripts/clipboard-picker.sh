#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# clipboard-picker — cliphist history via wofi, with real image thumbnails.
#
# `cliphist list` alone only shows a "[[ binary data 184 KiB png 640x480 ]]"
# placeholder line for image entries, no preview. This decodes each image
# entry once, caches a small thumbnail, and feeds wofi the whole list via
# stdin using its documented image syntax (`img:PATH:text:DESCRIPTION`,
# confirmed against a live wofi 1.5.1 session — an earlier NUL+unit-
# separator guess silently rendered no icon at all).
#
# Deliberately NOT using wofi's --pre-display-cmd for this: that runs a
# shell command with the (untrusted, attacker-influenceable) clipboard
# preview text substituted into the command line unquoted. Confirmed live —
# a clipboard entry containing `"; touch ~/pwned ; echo "` executes on
# open, before any entry is even selected. Building the whole list here and
# handing it to wofi over stdin never puts clipboard content on a command
# line, so it can't be interpreted as shell syntax.
#
# cliphist's own preview format for binary entries is
# "[[ binary data <size> <format> <WxH> ]]" — <format> is a bare word like
# "png"/"jpeg", not an "image/png" MIME string — also confirmed live.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

CACHE="$HOME/.cache/oligarchy/clip-thumbs"
mkdir -p "$CACHE"

build_list() {
  local id rest thumb
  cliphist list | while IFS=$'\t' read -r id rest; do
    if [[ "$rest" == *"binary data"* && "$rest" =~ (png|jpe?g|gif|bmp|webp) ]]; then
      thumb="$CACHE/$id.png"
      if [[ ! -s "$thumb" ]]; then
        cliphist decode "$id" 2>/dev/null | magick - -resize 128x128 "$thumb" 2>/dev/null || true
      fi
      if [[ -s "$thumb" ]]; then
        printf 'img:%s:text:%s\t%s\n' "$thumb" "$id" "$rest"
        continue
      fi
    fi
    printf '%s\t%s\n' "$id" "$rest"
  done
}

choice="$(build_list | wofi --dmenu --allow-images -p 'Clipboard')"
[[ -z "$choice" ]] && exit 0

# Without --pre-display-cmd, wofi returns the *whole* rendered line on
# selection — for image entries that's "img:PATH:text:<id><TAB><rest>", not
# just "<id><TAB><rest>" (verified live: confirm before trusting either way,
# these two entry shapes are not the same). Strip the image wrapper first
# if present, then either form starts with the id up to the first tab.
if [[ "$choice" == img:*:text:* ]]; then
  choice="${choice#*:text:}"
fi
id="${choice%%$'\t'*}"
[[ -n "$id" ]] && cliphist decode "$id" | wl-copy

# Prune thumbnails for entries cliphist has since aged out (it caps history
# length itself), so this cache doesn't grow unbounded.
live_ids="$(cliphist list | cut -f1)"
for f in "$CACHE"/*.png; do
  [[ -e "$f" ]] || continue
  fid="$(basename "$f" .png)"
  grep -qx "$fid" <<< "$live_ids" || rm -f "$f"
done
