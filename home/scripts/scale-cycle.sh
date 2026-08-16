#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scale-cycle — cycle the focused monitor's UI scale live via
# `hyprctl keyword monitor`. Like theme-switch.sh, this is a live override,
# not a second source of truth: it reverts to home/hyprland/default.nix's
# static per-monitor scale on the next config reload/rebuild.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCALES=(1 1.25 1.5)

command -v hyprctl >/dev/null 2>&1 || { echo "hyprctl unavailable" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq unavailable" >&2; exit 1; }

mon_json="$(hyprctl monitors -j)"
name="$(jq -r '.[] | select(.focused==true) | .name' <<< "$mon_json")"
[[ -z "$name" || "$name" == "null" ]] && name="$(jq -r '.[0].name // empty' <<< "$mon_json")"
[[ -z "$name" ]] && { echo "no monitor found" >&2; exit 1; }

read -r cur width height refresh x y < <(
  jq -r --arg n "$name" '.[] | select(.name==$n) | "\(.scale) \(.width) \(.height) \(.refreshRate) \(.x) \(.y)"' \
    <<< "$mon_json"
)

next=""
for i in "${!SCALES[@]}"; do
  if awk -v a="${SCALES[$i]}" -v b="$cur" 'BEGIN{exit !(a==b)}'; then
    next="${SCALES[$(( (i + 1) % ${#SCALES[@]} ))]}"
    break
  fi
done
[[ -z "$next" ]] && next="${SCALES[0]}"

hyprctl keyword monitor "$name,${width}x${height}@${refresh},${x}x${y},${next}" >/dev/null
notify-send -t 1500 "Display scale" "$name → ${next}x" 2>/dev/null || true
