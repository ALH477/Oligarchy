#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export THEMES_DIR="$ROOT/testdata/themes"
export MANIFEST="$THEMES_DIR/manifest.json"
export CURRENT_FILE="$ROOT/testdata/current-theme"
echo alpha > "$CURRENT_FILE"

THEME_SWITCH_LIB=1
# shellcheck source=theme-switch.sh
source "$ROOT/theme-switch.sh"

id="$(pick_id_from_label "Night")"
[[ "$id" == "alpha" ]] || { echo "FAIL pick Night → $id (want alpha)"; exit 1; }
id="$(pick_id_from_label "Night Owl")"
[[ "$id" == "beta" ]] || { echo "FAIL pick Night Owl → $id (want beta)"; exit 1; }
id="$(pick_id_from_label "Night ✓")"
[[ "$id" == "alpha" ]] || { echo "FAIL pick Night ✓ → $id (want alpha)"; exit 1; }
echo "ok pick_id_from_label"
