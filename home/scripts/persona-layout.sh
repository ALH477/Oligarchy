#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# persona-layout — save/restore which workspace each window class lives on.
# Restore only *moves* already-open windows (the persona "app set" handles
# launching), so it never spawns the wrong thing.
#   persona-layout save [name]      (default name = active persona)
#   persona-layout restore [name]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

DIR="$HOME/.config/oligarchy/layouts"
mkdir -p "$DIR"
name="${2:-$(cat /etc/oligarchy/persona 2>/dev/null || echo default)}"
f="$DIR/$name.json"
note() { command -v notify-send >/dev/null 2>&1 && notify-send "🪟 Layout" "$1" || echo "$1"; }

case "${1:-}" in
  save)
    hyprctl clients -j | jq '[.[] | {class, workspace: .workspace.id, floating}]' > "$f"
    note "saved: $name"
    ;;
  restore)
    [ -f "$f" ] || { echo "no saved layout: $name" >&2; exit 1; }
    hyprctl clients -j | jq -r '.[] | "\(.address)\t\(.class)"' | while IFS=$'\t' read -r addr class; do
      ws="$(jq -r --arg c "$class" 'map(select(.class==$c)) | .[0].workspace // empty' "$f")"
      if [ -n "$ws" ] && [ "$ws" != "null" ]; then
        hyprctl dispatch movetoworkspacesilent "$ws,address:$addr" >/dev/null 2>&1 || true
      fi
    done
    note "restored: $name"
    ;;
  *) echo "usage: persona-layout {save|restore} [name]" >&2; exit 2 ;;
esac
