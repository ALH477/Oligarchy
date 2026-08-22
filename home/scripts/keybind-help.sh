#!/usr/bin/env bash
# Keybinding Help System for Hyprland

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
BOLD='\033[1m'
RESET='\033[0m'

# Configuration
HYPR_CONFIG="${HOME}/.config/hypr/hyprland.conf"
KEYBIND_FILE="${HOME}/.config/hypr/scripts/keybinds.txt"

# Categories and their patterns
declare -A CATEGORIES=(
    ["Window Management"]="killactive|move|resize|fullscreen|togglefloating|split"
    ["Workspace Navigation"]="workspace|movetoworkspace"
    ["Application Launchers"]="exec|wofi|kitty|brave"
    ["System Controls"]="exit|reload|screenshot|volume|brightness"
    ["Special Features"]="submap|pseudo|group"
)

# Print functions
print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${BOLD}                    HYPRLAND KEYBINDINGS HELP                      ${CYAN}║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

print_category() {
    echo -e "${WHITE}${BOLD}$1${RESET}"
    echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"
}

print_binding() {
    local key=$1
    local action=$2
    printf "  ${GREEN}%-15s${RESET} → ${WHITE}%s${RESET}\n" "$key" "$action"
}

# Parse keybindings from hyprland config
parse_keybindings() {
    if [[ ! -f "$HYPR_CONFIG" ]]; then
        echo -e "${RED}Hyprland config not found: $HYPR_CONFIG${RESET}"
        return 1
    fi
    
    grep -E "^bind" "$HYPR_CONFIG" | grep -v "^bindl" | sed 's/bind = //' | tr -d '",' | while read -r line; do
        local key action
        key=$(echo "$line" | awk '{print $1}')
        action=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
        echo "$key|$action"
    done
}

# Get category for action
get_category() {
    local action=$1
    for category in "${!CATEGORIES[@]}"; do
        if echo "$action" | grep -qiE "${CATEGORIES[$category]}"; then
            echo "$category"
            return
        fi
    done
    echo "Other"
}

# Show all keybindings
show_all_bindings() {
    local bindings
    bindings=$(parse_keybindings)
    
    local current_category=""
    local first=true
    
    while IFS='|' read -r key action; do
        local category
        category=$(get_category "$action")
        
        if [[ "$category" != "$current_category" ]]; then
            if [[ "$first" != "true" ]]; then
                echo ""
            fi
            print_category "$category"
            current_category="$category"
            first=false
        fi
        
        print_binding "$key" "$action"
    done <<< "$bindings"
}

# Show bindings for specific category
show_category() {
    local target_category=$1
    local bindings
    bindings=$(parse_keybindings)
    
    print_category "$target_category"
    
    while IFS='|' read -r key action; do
        local category
        category=$(get_category "$action")
        
        if [[ "$category" == "$target_category" ]]; then
            print_binding "$key" "$action"
        fi
    done <<< "$bindings"
}

# Interactive menu — a single fuzzy-searchable fzf list (type to filter by
# key, action, or category; Esc/Ctrl-C quits). Replaces the old numbered
# category picker and the separate `search` flow with one live-searchable
# view, matching the fzf UI used everywhere else in this repo's tooling
# (oligarchy-ctl.sh's persona/action pickers, theme-switch.sh's gui menu).
interactive_menu() {
    local initial_query="${1:-}"
    local bindings
    bindings=$(parse_keybindings)

    local rows
    rows=$(while IFS='|' read -r key action; do
        local category
        category=$(get_category "$action")
        printf '%-22s  %-45s  [%s]\n' "$key" "$action" "$category"
    done <<< "$bindings")

    echo "$rows" | fzf \
        --prompt="Keybinds > " \
        --header="Type to search — Esc to quit" \
        --height=80% --reverse --border \
        --preview-window=hidden \
        --query="$initial_query" \
        >/dev/null || true
}

# Main
main() {
    case "${1:-menu}" in
        "menu")
            interactive_menu
            ;;
        "all")
            print_header
            show_all_bindings
            ;;
        "search")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 search <term>"
                exit 1
            fi
            interactive_menu "$2"
            ;;
        *)
            echo "Usage: $0 {menu|all|search <term>}"
            exit 1
            ;;
    esac
}

main "$@"
