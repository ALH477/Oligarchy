#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# oligarchy-control — terminal (fzf) front-end for the Oligarchy control center.
# Works anywhere a terminal does: Hyprland, Plasma, IceWM, a bare TTY, or SSH.
# Branded at runtime from ~/.config/demod/theme.json (no rebuild needed).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

THEME_JSON="$HOME/.config/demod/theme.json"
accent="#00D4AA"; fg="#EAEAEA"; bg="#1A1A2E"
if [ -r "$THEME_JSON" ] && command -v jq >/dev/null 2>&1; then
  accent="$(jq -r '.accent // .borderFocus // "#00D4AA"' "$THEME_JSON" 2>/dev/null)"
  fg="$(jq -r '.text // "#EAEAEA"' "$THEME_JSON" 2>/dev/null)"
  bg="$(jq -r '.bg // "#1A1A2E"' "$THEME_JSON" 2>/dev/null)"
fi
export FZF_DEFAULT_OPTS="--no-multi --height=85% --layout=reverse --border=rounded --color=fg:$fg,bg:$bg,hl:$accent,fg+:$accent,pointer:$accent,prompt:$accent,header:$accent"

while true; do
  hdr="$(oligarchy-ctl status 2>/dev/null)"
  cat_label="$(oligarchy-ctl cats | awk -F'|' '{print $2}' | fzf --header="$hdr" --prompt='⌁ category ❯ ')" || exit 0
  [ -z "$cat_label" ] && exit 0
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
