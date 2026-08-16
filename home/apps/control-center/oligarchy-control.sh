#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# oligarchy-control — terminal (fzf) front-end for the Oligarchy control center.
# Works anywhere a terminal does: Hyprland, Plasma, IceWM, a bare TTY, or SSH.
# Branded at runtime from ~/.config/demod/theme.json (no rebuild needed).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

THEME_JSON="$HOME/.config/demod/theme.json"
accent="#00F5D4"; fg="#EAEAEA"; bg="#1A1A2E"; purple="#8B5CF6"; green="#39FF14"; yellow="#FFE814"; red="#FF3B5C"; dim="#808080"
if [ -r "$THEME_JSON" ] && command -v jq >/dev/null 2>&1; then
  accent="$(jq -r '.accent // .borderFocus // "#00F5D4"' "$THEME_JSON" 2>/dev/null)"
  fg="$(jq -r '.text // "#EAEAEA"' "$THEME_JSON" 2>/dev/null)"
  bg="$(jq -r '.bg // "#1A1A2E"' "$THEME_JSON" 2>/dev/null)"
  purple="$(jq -r '.purple // "#8B5CF6"' "$THEME_JSON" 2>/dev/null)"
  green="$(jq -r '.success // "#39FF14"' "$THEME_JSON" 2>/dev/null)"
  yellow="$(jq -r '.warning // "#FFE814"' "$THEME_JSON" 2>/dev/null)"
  red="$(jq -r '.error // "#FF3B5C"' "$THEME_JSON" 2>/dev/null)"
  dim="$(jq -r '.textDim // "#808080"' "$THEME_JSON" 2>/dev/null)"
fi
export FZF_DEFAULT_OPTS="--no-multi --height=85% --layout=reverse --border=rounded --color=fg:$fg,bg:$bg,hl:$accent,fg+:$accent,pointer:$accent,prompt:$accent,header:$accent"

SEARCH_ALL="🔎 Search all actions…"

# Flat fuzzy search across every category's actions in one list — fzf's own
# fuzzy matching does the work. Falls back to the two-level browse below.
search_all() {
  local hdr act_label act_id
  hdr="$(oligarchy-ctl status 2>/dev/null)"
  act_label="$(oligarchy-ctl all-items | awk -F'|' '{print $2}' | fzf --header="$hdr" --prompt='⌁ search ❯ ')" || return 0
  [ -z "$act_label" ] && return 0
  act_id="$(oligarchy-ctl all-items | awk -F'|' -v l="$act_label" '$2==l{print $1; exit}')"
  [ -n "$act_id" ] && oligarchy-ctl run "$act_id"
}

while true; do
  hdr="$(oligarchy-ctl status 2>/dev/null)"
  cat_label="$( { echo "$SEARCH_ALL"; oligarchy-ctl cats | awk -F'|' '{print $2}'; } | fzf --header="$hdr" --prompt='⌁ category ❯ ')" || exit 0
  [ -z "$cat_label" ] && exit 0
  if [ "$cat_label" = "$SEARCH_ALL" ]; then search_all; continue; fi
  cat_id="$(oligarchy-ctl cats | awk -F'|' -v l="$cat_label" '$2==l{print $1; exit}')"
  [ -z "$cat_id" ] && continue

  while true; do
    item_label="$( { echo '← Back'; oligarchy-ctl items "$cat_id" | awk -F'|' '{print $2}'; } | fzf --header="$cat_label" --prompt='action ❯ ')" || break
    [ -z "$item_label" ] && break
    [ "$item_label" = "← Back" ] && break
    act_id="$(oligarchy-ctl items "$cat_id" | awk -F'|' -v l="$item_label" '$2==l{print $1; exit}')"
    [ -n "$act_id" ] && oligarchy-ctl run "$act_id"
  done
done
