#!/usr/bin/env bash
# Theme Switcher Script for Nix Home Manager

set -euo pipefail

# Configuration
HOME_CONFIG_DIR="$HOME/.config/home-manager"
NIX_HOME_DIR="${HOME_CONFIG_DIR}/nix-home"
HOME_NIX="${NIX_HOME_DIR}/home.nix"

# Available themes
THEMES=("demod" "catppuccin" "nord" "rosepine" "gruvbox" "dracula" "tokyo" "phosphor")

# Get current theme
CURRENT_THEME=$(grep "activePalette" "$HOME_NIX" | sed 's/.*"\([^"]*\)".*/\1/' || echo "unknown")

# Cycle to next theme
switch_theme() {
    local new_theme="$1"
    
    # Update theme in home.nix
    sed -i "s/activePalette = \"[^\"]*\"/activePalette = \"$new_theme\"/" "$HOME_NIX"
    
    # Rebuild with home-manager
    cd "$HOME_CONFIG_DIR"
    if home-manager switch; then
        notify-send "Theme Changed" "Switched to $new_theme theme" --urgency=low
        echo "Theme switched to $new_theme"
    else
        notify-send "Theme Failed" "Could not switch to $new_theme" --urgency=critical
        echo "Failed to switch theme"
    fi
}

# Cycle through themes
cycle_theme() {
    local current_index=-1
    local i=0
    
    # Find current theme index
    for theme in "${THEMES[@]}"; do
        if [[ "$theme" == "$CURRENT_THEME" ]]; then
            current_index=$i
            break
        fi
        ((i++))
    done
    
    # Move to next theme
    local next_index=$(( (current_index + 1) % ${#THEMES[@]} ))
    local next_theme=${THEMES[$next_index]}
    
    switch_theme "$next_theme"
}

# Show available themes
show_themes() {
    echo "Available themes:"
    for theme in "${THEMES[@]}"; do
        if [[ "$theme" == "$CURRENT_THEME" ]]; then
            echo "  ✓ $theme (current)"
        else
            echo "    $theme"
        fi
    done
}

# Main menu
case "${1:-cycle}" in
    "cycle")
        cycle_theme
        ;;
    "show"|"list")
        show_themes
        ;;
    *)
        if [[ " ${THEMES[*]} " =~ " $1 " ]]; then
            switch_theme "$1"
        else
            echo "Usage: $0 {cycle|show|<theme_name>}"
            echo "Available themes: ${THEMES[*]}"
            exit 1
        fi
        ;;
esac