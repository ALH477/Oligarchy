#!/usr/bin/env bash
set -euo pipefail

# All palette data comes from ~/.config/oligarchy/themes/, rendered by Nix
# from the single source of truth (home/themes/default.nix) — see
# home/apps/theme-variants.nix and the per-app renderers in home/apps/*.nix,
# home/waybar/default.nix, home/terminal/kitty.nix. This script used to carry
# its own hand-copied, already-drifted subset of each palette's colors; now
# it only ever reads what Nix already rendered, so it cannot drift again.
#
# Applying a theme re-points the live symlinks Home Manager created for
# waybar/wofi/hyprlock/gtk3/gtk4 at the selected theme's pre-rendered variant,
# rewrites Kvantum's active-theme pointer, and pushes new colors into any
# running kitty windows over its remote-control socket — no rebuild needed.
# The next `home-manager switch` resets everything back to whatever
# home/themes/default.nix's activeThemeName declares, which is expected:
# this script is a live preview/override, not a second source of truth.

THEMES_DIR="$HOME/.config/oligarchy/themes"
MANIFEST="$THEMES_DIR/manifest.json"
CURRENT_FILE="$HOME/.config/oligarchy/current-theme"
THEME_JSON="$HOME/.config/demod/theme.json"
FALLBACK_THEME="demod"
# Each kitty process listens on its own {kitty_pid}-suffixed socket (see
# home/terminal/kitty.nix) — there is no single well-known path, so glob for
# whatever's currently live.
KITTY_SOCKET_GLOB="/tmp/kitty-$USER-*.sock"

die() { echo "$*" >&2; exit 1; }

[[ -f "$MANIFEST" ]] || die "No theme manifest at $MANIFEST — run 'home-manager switch' first."

theme_ids() { jq -r '.[].id' "$MANIFEST"; }
theme_display_name() { jq -r --arg id "$1" '.[] | select(.id==$id) | .name' "$MANIFEST"; }
theme_exists() { [[ -f "$THEMES_DIR/$1/palette.json" ]]; }

get_current_theme() {
    if [[ -f "$CURRENT_FILE" ]]; then
        cat "$CURRENT_FILE"
    else
        echo "$FALLBACK_THEME"
    fi
}

get_next_theme() {
    local current="$1"
    local ids found=0
    mapfile -t ids < <(theme_ids)
    for id in "${ids[@]}"; do
        if [[ "$found" -eq 1 ]]; then
            echo "$id"
            return
        fi
        [[ "$id" == "$current" ]] && found=1
    done
    echo "${ids[0]}"
}

apply_theme() {
    local id="$1"
    theme_exists "$id" || die "Unknown theme: $id (run '$0 list')"

    local dir="$THEMES_DIR/$id"
    local display_name
    display_name=$(theme_display_name "$id")

    ln -sfn "$dir/waybar.css"    "$HOME/.config/waybar/style.css"
    ln -sfn "$dir/wofi.css"      "$HOME/.config/wofi/style.css"
    ln -sfn "$dir/hyprlock.conf" "$HOME/.config/hypr/hyprlock.conf"
    ln -sfn "$dir/gtk3.css"      "$HOME/.config/gtk-3.0/gtk.css"
    ln -sfn "$dir/gtk4.css"      "$HOME/.config/gtk-4.0/gtk.css"

    # Live wallpaper swap via hyprpaper's IPC socket (ipc = on in
    # hyprpaper.conf). Falls back silently to whatever wallpaper is already
    # loaded if this theme has no generated wallpaper.png yet (e.g. a stale
    # ~/.config/oligarchy/themes from before this existed) or hyprpaper isn't
    # running.
    if [[ -f "$dir/wallpaper.png" ]]; then
        hyprctl hyprpaper preload "$dir/wallpaper.png" >/dev/null 2>&1 || true
        hyprctl hyprpaper wallpaper ",$dir/wallpaper.png" >/dev/null 2>&1 || true
    fi

    # Kvantum keys themes by directory name; every palette's own named dir
    # already exists (home/apps/kvantum.nix), so switching is just this.
    printf '[General]\ntheme=%s\n' "$display_name" > "$HOME/.config/Kvantum/kvantum.kvconfig"

    # Live-recolor every already-running kitty process (each has its own
    # {kitty_pid}-suffixed socket). Requires allow_remote_control/listen_on
    # (home/terminal/kitty.nix); harmless if kitty isn't running, a given
    # socket is stale, or remote control is off.
    shopt -s nullglob
    for sock in $KITTY_SOCKET_GLOB; do
        kitty @ --to "unix:$sock" set-colors --all --configured "$dir/kitty.conf" \
            >/dev/null 2>&1 || true
    done
    shopt -u nullglob

    mkdir -p "$(dirname "$THEME_JSON")" "$(dirname "$CURRENT_FILE")"
    cp "$dir/palette.json" "$THEME_JSON"
    echo "$id" > "$CURRENT_FILE"

    local border_focus border
    border_focus=$(jq -r '.borderFocus' "$dir/palette.json")
    border=$(jq -r '.border' "$dir/palette.json")
    hyprctl keyword "general.col.active_border" "$border_focus" 2>/dev/null || true
    hyprctl keyword "general.col.inactive_border" "$border" 2>/dev/null || true

    # waybar's own file watch doesn't follow a re-pointed symlink; HUP forces
    # it to reload from (the new target of) style.css.
    pkill -HUP waybar 2>/dev/null || true

    notify-send -u low -t 2000 "Theme Changed" "Now using: $display_name" 2>/dev/null || true
}

show_gui_menu() {
    local current="$1"
    local ids=() options=()
    mapfile -t ids < <(theme_ids)
    local id name
    for id in "${ids[@]}"; do
        name=$(theme_display_name "$id")
        if [[ "$id" == "$current" ]]; then
            options+=("$name ✓")
        else
            options+=("$name")
        fi
    done

    local choice
    choice=$(printf '%s\n' "${options[@]}" | wofi --dmenu -I -p "Theme")
    [[ -n "$choice" ]] || return 1
    choice="${choice% ✓}"

    local i
    for i in "${!options[@]}"; do
        if [[ "${options[$i]}" == "$choice"* ]]; then
            echo "${ids[$i]}"
            return
        fi
    done
    return 1
}

show_cli_menu() {
    local current="$1"
    local ids=()
    mapfile -t ids < <(theme_ids)
    echo "Select theme:"
    echo ""

    local i=1 id name
    for id in "${ids[@]}"; do
        name=$(theme_display_name "$id")
        if [[ "$id" == "$current" ]]; then
            echo "$i) $name *"
        else
            echo "$i) $name"
        fi
        ((i++))
    done
    echo ""
    echo -n "Choice: "
    local choice
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#ids[@]}" ]]; then
        echo "${ids[$((choice - 1))]}"
    else
        echo "$current"
    fi
}

case "${1:-toggle}" in
    toggle)
        current=$(get_current_theme)
        next=$(get_next_theme "$current")
        apply_theme "$next"
        ;;
    set)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 set <theme-id>"
            echo "Available:"
            theme_ids
            exit 1
        fi
        apply_theme "$2"
        ;;
    gui)
        current=$(get_current_theme)
        if selected=$(show_gui_menu "$current"); then
            apply_theme "$selected"
        fi
        ;;
    cli)
        current=$(get_current_theme)
        selected=$(show_cli_menu "$current")
        if [[ -n "$selected" ]]; then
            apply_theme "$selected"
        fi
        ;;
    current)
        get_current_theme
        ;;
    list)
        echo "Available themes:"
        while read -r id; do
            echo "  $id: $(theme_display_name "$id")"
        done < <(theme_ids)
        ;;
    *)
        echo "Usage: $0 {toggle|set|gui|cli|current|list}"
        exit 1
        ;;
esac
