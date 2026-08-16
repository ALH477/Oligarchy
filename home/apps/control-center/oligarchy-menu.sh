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

SEARCH_ALL="🔎 Search all actions…"

# Flat fuzzy search across every category's actions in one list — wofi's own
# insensitive/contains matching (~/.config/wofi/config) does the fuzzy work.
# Falls back to the two-level category→action browse below.
search_all() {
  local act_label act_id
  act_label="$(oligarchy-ctl all-items | awk -F'|' '{print $2}' | pick '⌁ Search')" || exit 0
  [ -z "$act_label" ] && exit 0
  act_id="$(oligarchy-ctl all-items | awk -F'|' -v l="$act_label" '$2==l{print $1; exit}')"
  [ -n "$act_id" ] && oligarchy-ctl run "$act_id"
  exit 0
}

while true; do
  cat_label="$( { echo "$SEARCH_ALL"; oligarchy-ctl cats | awk -F'|' '{print $2}'; } | pick '⌁ Oligarchy')" || exit 0
  [ -z "$cat_label" ] && exit 0
  [ "$cat_label" = "$SEARCH_ALL" ] && search_all
  cat_id="$(oligarchy-ctl cats | awk -F'|' -v l="$cat_label" '$2==l{print $1; exit}')"
  [ -z "$cat_id" ] && exit 0

  item_label="$( { echo '← Back'; oligarchy-ctl items "$cat_id" | awk -F'|' '{print $2}'; } | pick "$cat_label")" || exit 0
  [ -z "$item_label" ] && exit 0
  [ "$item_label" = "← Back" ] && continue

  act_id="$(label_to_id "$cat_id" "$item_label")"
  [ -n "$act_id" ] && oligarchy-ctl run "$act_id"
  exit 0
done
