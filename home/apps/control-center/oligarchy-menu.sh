#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# oligarchy-menu — Wofi front-end for the Oligarchy control center.
# Picks up the DeMoD-themed ~/.config/wofi/style.css automatically.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

pick() { wofi --dmenu -i -p "$1"; }

label_to_id() { # $1=category $2=chosen-label  -> action id
  oligarchy-ctl items "$1" | awk -F'|' -v l="$2" '$2==l{print $1; exit}'
}

while true; do
  cat_label="$(oligarchy-ctl cats | awk -F'|' '{print $2}' | pick '⌁ Oligarchy')" || exit 0
  [ -z "$cat_label" ] && exit 0
  cat_id="$(oligarchy-ctl cats | awk -F'|' -v l="$cat_label" '$2==l{print $1; exit}')"
  [ -z "$cat_id" ] && exit 0

  item_label="$( { echo '← Back'; oligarchy-ctl items "$cat_id" | awk -F'|' '{print $2}'; } | pick "$cat_label")" || exit 0
  [ -z "$item_label" ] && exit 0
  [ "$item_label" = "← Back" ] && continue

  act_id="$(label_to_id "$cat_id" "$item_label")"
  [ -n "$act_id" ] && oligarchy-ctl run "$act_id"
  exit 0
done
