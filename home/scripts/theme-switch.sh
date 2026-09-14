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

THEMES_DIR="${THEMES_DIR:-$HOME/.config/oligarchy/themes}"
MANIFEST="${MANIFEST:-$THEMES_DIR/manifest.json}"
CURRENT_FILE="${CURRENT_FILE:-$HOME/.config/oligarchy/current-theme}"
THEME_JSON="${THEME_JSON:-$HOME/.config/demod/theme.json}"
FALLBACK_THEME="demod"
# Each kitty process listens on its own {kitty_pid}-suffixed socket (see
# home/terminal/kitty.nix) — there is no single well-known path, so glob for
# whatever's currently live.
KITTY_SOCKET_GLOB="/tmp/kitty-$USER-*.sock"

die() { echo "$*" >&2; exit 1; }

theme_ids() { jq -r '.[].id' "$MANIFEST"; }
theme_display_name() { jq -r --arg id "$1" '.[] | select(.id==$id) | .name' "$MANIFEST"; }
theme_exists() { [[ -f "$THEMES_DIR/$1/palette.json" ]]; }

# HM writes kvantum.kvconfig and demod/theme.json as symlinks into the
# read-only store, so redirecting/`cp` over them fails. Both paths carry
# `force = true` on the HM side (see home/apps/kvantum.nix,
# home/scripts/default.nix) — meaning HM replaces whatever is here on
# activation — so replacing the symlink with a regular file is safe and
# HM-rebuild loses nothing it can't regenerate.
replace_into() { # $1=dest path, stdin=content
    rm -f "$1"
    cat > "$1"
}

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
    # Empty manifest (mid-rewrite?) -> nothing to cycle to; die in the caller,
    # not inside a $(...) subshell where exit would go unnoticed.
    [[ ${#ids[@]} -gt 0 ]] || return 1
    for id in "${ids[@]}"; do
        if [[ "$found" -eq 1 ]]; then
            echo "$id"
            return
        fi
        [[ "$id" == "$current" ]] && found=1
    done
    echo "${ids[0]}"
}

# Exact label → id. Labels are "<name>", "<name> (id)" when two palettes
# share one display name, plus " ✓" on the current one. Never prefix-match.
label_for() { # $1=id
    local id="$1" name other dupes=0
    name="$(theme_display_name "$id")"
    while IFS= read -r other; do
        [[ "$other" == "$id" ]] && continue
        [[ "$(theme_display_name "$other")" == "$name" ]] && dupes=1
    done < <(theme_ids)
    if [[ "$dupes" -eq 1 ]]; then
        printf '%s (%s)\n' "$name" "$id"
    else
        printf '%s\n' "$name"
    fi
}

pick_id_from_label() {
    local choice="${1% ✓}"
    local id
    while IFS= read -r id; do
        if [[ "$choice" == "$(label_for "$id")" ]]; then
            echo "$id"
            return 0
        fi
    done < <(theme_ids)
    return 1
}

gui_row() { # $1=id → one wofi line (image if wallpaper exists)
    local id="$1" label mark="" img="$THEMES_DIR/$id/wallpaper.png"
    label="$(label_for "$id")"
    [[ "$id" == "$(get_current_theme)" ]] && mark=" ✓"
    if [[ -f "$img" ]]; then
        printf 'img:%s:text:%s%s\n' "$img" "$label" "$mark"
    else
        printf '%s%s\n' "$label" "$mark"
    fi
}

if [[ "${THEME_SWITCH_LIB:-}" == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi

[[ -f "$MANIFEST" ]] || die "No theme manifest at $MANIFEST — run 'home-manager switch' first."

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
    printf '[General]\ntheme=%s\n' "$display_name" | replace_into "$HOME/.config/Kvantum/kvantum.kvconfig"

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
    rm -f "$THEME_JSON"
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

    notify-send -u low -t 4000 "Theme Changed" "Now using: $display_name (live; next rebuild restores Nix default)" 2>/dev/null || true
}

show_gui_menu() {
    local choice
    choice="$(theme_ids | while read -r id; do gui_row "$id"; done | wofi --dmenu -I -i -p "Theme")"
    [[ -n "$choice" ]] || return 1
    # wofi -I may return "img:...:text:Name" or just "Name" depending on
    # version; strip the img prefix if present, then exact-match.
    pick_id_from_label "${choice##*:text:}"
}

show_cli_menu() {
    local current="$1"
    local ids=()
    mapfile -t ids < <(theme_ids)
    echo "Select theme:"
    echo ""

    local i=1 id name
    for id in "${ids[@]}"; do
        name=$(label_for "$id")
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
        next=$(get_next_theme "$current") || die "No themes in $MANIFEST"
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
