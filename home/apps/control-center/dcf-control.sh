#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dcf-control — DCF/HydraMesh mesh status + control panel.
#
# Previously referenced by a keybind ($mod SHIFT, D, gated on features.enableDCF
# — see home/hyprland/default.nix) and by oligarchy-ctl's `dcf` category, but
# never implemented anywhere in the repo — a dangling reference. This gives it
# a real, minimal implementation: a dedicated fzf panel over the same
# read-only status commands (hydramesh-status/-logs) and mutating actions
# (hydramesh-restart/-pull) oligarchy-ctl's `dcf` category already dispatches
# to, so there is exactly one place that logic lives.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

THEME_JSON="$HOME/.config/demod/theme.json"
accent="#00F5D4"; fg="#EAEAEA"; bg="#1A1A2E"; dim="#808080"
if [ -r "$THEME_JSON" ] && command -v jq >/dev/null 2>&1; then
  accent="$(jq -r '.accent // "#00F5D4"' "$THEME_JSON" 2>/dev/null)"
  fg="$(jq -r '.text // "#EAEAEA"' "$THEME_JSON" 2>/dev/null)"
  bg="$(jq -r '.bg // "#1A1A2E"' "$THEME_JSON" 2>/dev/null)"
  dim="$(jq -r '.textDim // "#808080"' "$THEME_JSON" 2>/dev/null)"
fi
export FZF_DEFAULT_OPTS="--no-multi --height=85% --layout=reverse --border=rounded --color=fg:$fg,bg:$bg,hl:$accent,fg+:$accent,pointer:$accent,prompt:$accent,header:$dim"

header() {
  if command -v hydramesh-status >/dev/null 2>&1; then
    hydramesh-status 2>/dev/null | head -n6
  else
    echo "hydramesh-status unavailable — is custom.hydramesh.enable set?"
  fi
}

while true; do
  hdr="$(header)"
  choice="$(oligarchy-ctl items dcf | awk -F'|' '{print $2}' | fzf --header="$hdr" --prompt='dcf ❯ ')" || exit 0
  [ -z "$choice" ] && exit 0
  act_id="$(oligarchy-ctl items dcf | awk -F'|' -v l="$choice" '$2==l{print $1; exit}')"
  [ -n "$act_id" ] && oligarchy-ctl run "$act_id"
done
