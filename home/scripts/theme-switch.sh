#!/usr/bin/env bash
set -euo pipefail

THEME_FILE="$HOME/.config/demod/theme.json"
THEMES_DIR="$HOME/.config/nix-home/themes"
FALLBACK_THEME="demod"

declare -A THEMES=(
    ["demod"]="DeMoD"
    ["catppuccin"]="Catppuccin"
    ["nord"]="Nord"
    ["rosepine"]="Rosé Pine"
    ["gruvbox"]="Gruvbox"
    ["dracula"]="Dracula"
    ["tokyo"]="Tokyo Night"
    ["phosphor"]="Phosphor"
)

get_current_theme() {
    if [[ -f "$THEME_FILE" ]]; then
        jq -r '.name // empty' "$THEME_FILE" 2>/dev/null || echo "$FALLBACK_THEME"
    else
        echo "$FALLBACK_THEME"
    fi
}

get_next_theme() {
    local current="$1"
    local keys=("${!THEMES[@]}")
    local found=0
    for key in "${keys[@]}"; do
        if [[ "$key" == "$current" ]]; then
            found=1
        elif [[ $found -eq 1 ]]; then
            echo "$key"
            return
        fi
    done
    echo "${keys[0]}"
}

apply_theme() {
    local theme_name="$1"
    local theme_json="$2"
    
    mkdir -p "$(dirname "$THEME_FILE")"
    echo "$theme_json" > "$THEME_FILE"
    
    local accent border border_focus
    accent=$(echo "$theme_json" | jq -r '.accent // "#00F5D4"')
    border=$(echo "$theme_json" | jq -r '.border // "#252530"')
    border_focus=$(echo "$theme_json" | jq -r '.borderFocus // "#00F5D4"')
    
    hyprctl keyword "general.col.active_border" "$border_focus" 2>/dev/null || true
    hyprctl keyword "general.col.inactive_border" "$border" 2>/dev/null || true
    
    pkill -HUP waybar 2>/dev/null || true
    
    notify-send -u low -t 2000 "Theme Changed" "Now using: ${THEMES[$theme_name]}"
}

get_theme_json() {
    local theme_name="$1"
    
    if [[ "$theme_name" == "custom" ]] && [[ -f "$HOME/.config/demod/custom-theme.json" ]]; then
        cat "$HOME/.config/demod/custom-theme.json"
        return
    fi
    
    case "$theme_name" in
        demod)
            cat << 'EOF'
{"name":"demod","bg":"#080810","bgAlt":"#0C0C14","surface":"#101018","surfaceAlt":"#161620","overlay":"#1C1C28","border":"#252530","borderFocus":"#00F5D4","borderHover":"#8B5CF6","accent":"#00F5D4","accentAlt":"#00E5C7","accentDim":"#00B89F","text":"#FFFFFF","textAlt":"#E0E0E0","textDim":"#808080","success":"#39FF14","warning":"#FFE814","error":"#FF3B5C","info":"#00F5D4"}
EOF
            ;;
        catppuccin)
            cat << 'EOF'
{"name":"catppuccin","bg":"#11111B","bgAlt":"#181825","surface":"#1E1E2E","surfaceAlt":"#313244","overlay":"#45475A","border":"#45475A","borderFocus":"#CBA6F7","borderHover":"#F5C2E7","accent":"#CBA6F7","accentAlt":"#F5C2E7","accentDim":"#B4A0E5","text":"#CDD6F4","textAlt":"#BAC2DE","textDim":"#6C7086","success":"#A6E3A1","warning":"#F9E2AF","error":"#F38BA8","info":"#89DCEB"}
EOF
            ;;
        nord)
            cat << 'EOF'
{"name":"nord","bg":"#242933","bgAlt":"#2E3440","surface":"#3B4252","surfaceAlt":"#434C5E","overlay":"#4C566A","border":"#4C566A","borderFocus":"#88C0D0","borderHover":"#81A1C1","accent":"#88C0D0","accentAlt":"#81A1C1","accentDim":"#5E81AC","text":"#ECEFF4","textAlt":"#E5E9F0","textDim":"#D8DEE9","success":"#A3BE8C","warning":"#EBCB8B","error":"#BF616A","info":"#81A1C1"}
EOF
            ;;
        rosepine)
            cat << 'EOF'
{"name":"rosepine","bg":"#191724","bgAlt":"#1F1D2E","surface":"#26233A","surfaceAlt":"#2A273F","overlay":"#393552","border":"#403D52","borderFocus":"#C4A7E7","borderHover":"#EBBCBA","accent":"#C4A7E7","accentAlt":"#EBBCBA","accentDim":"#9C8EC4","text":"#E0DEF4","textAlt":"#908CAA","textDim":"#6E6A86","success":"#9CCFD8","warning":"#F6C177","error":"#EB6F92","info":"#31748F"}
EOF
            ;;
        gruvbox)
            cat << 'EOF'
{"name":"gruvbox","bg":"#1d2021","bgAlt":"#282828","surface":"#3c3836","surfaceAlt":"#504945","overlay":"#665c54","border":"#665c54","borderFocus":"#d79921","borderHover":"#98971a","accent":"#d79921","accentAlt":"#98971a","accentDim":"#b16286","text":"#ebdbb2","textAlt":"#d5c4a1","textDim":"#a89984","success":"#b8bb26","warning":"#fabd2f","error":"#fb4934","info":"#83a598"}
EOF
            ;;
        dracula)
            cat << 'EOF'
{"name":"dracula","bg":"#282a36","bgAlt":"#44475a","surface":"#44475a","surfaceAlt":"#6272a4","overlay":"#6272a4","border":"#6272a4","borderFocus":"#bd93f9","borderHover":"#ff79c6","accent":"#bd93f9","accentAlt":"#ff79c6","accentDim":"#8be9fd","text":"#f8f8f2","textAlt":"#e9e9f4","textDim":"#6272a4","success":"#50fa7b","warning":"#f1fa8c","error":"#ff5555","info":"#8be9fd"}
EOF
            ;;
        tokyo)
            cat << 'EOF'
{"name":"tokyo","bg":"#1a1b26","bgAlt":"#24283b","surface":"#414868","surfaceAlt":"#565f89","overlay":"#565f89","border":"#565f89","borderFocus":"#7aa2f7","borderHover":"#bb9af7","accent":"#7aa2f7","accentAlt":"#bb9af7","accentDim":"#9ece6a","text":"#c0caf5","textAlt":"#a9b1d6","textDim":"#565f89","success":"#9ece6a","warning":"#e0af68","error":"#f7768e","info":"#7aa2f7"}
EOF
            ;;
        phosphor)
            cat << 'EOF'
{"name":"phosphor","bg":"#0a0a0a","bgAlt":"#141414","surface":"#1a1a1a","surfaceAlt":"#262626","overlay":"#404040","border":"#404040","borderFocus":"#00ffff","borderHover":"#ff00ff","accent":"#00ffff","accentAlt":"#ff00ff","accentDim":"#00ff00","text":"#ffffff","textAlt":"#e0e0e0","textDim":"#808080","success":"#00ff00","warning":"#ffff00","error":"#ff0040","info":"#00ffff"}
EOF
            ;;
        *)
            echo '{"name":"demod","bg":"#080810","surface":"#101018","border":"#252530","borderFocus":"#00F5D4","accent":"#00F5D4","text":"#FFFFFF","textDim":"#808080","success":"#39FF14","warning":"#FFE814","error":"#FF3B5C","info":"#00F5D4"}'
            ;;
    esac
}

show_gui_menu() {
    local current="$1"
    local options=()
    local keys=()
    
    for key in "${!THEMES[@]}"; do
        keys+=("$key")
        if [[ "$key" == "$current" ]]; then
            options+=("${THEMES[$key]} ✓")
        else
            options+=("${THEMES[$key]}")
        fi
    done
    options+=("Custom theme...")
    keys+=("custom")
    
    local choice
    choice=$(printf '%s\n' "${options[@]}" | wofi --dmenu -I -p "Theme" --define parse_markup=true)
    
    if [[ -z "$choice" ]]; then
        return 1
    fi
    
    choice="${choice% ✓}"
    
    for i in "${!options[@]}"; do
        if [[ "${options[$i]}" == "$choice"* ]]; then
            echo "${keys[$i]}"
            return
        fi
    done
    
    echo "custom"
}

show_cli_menu() {
    local current="$1"
    echo "Select theme:"
    echo ""
    
    local i=1
    for key in "${!THEMES[@]}"; do
        if [[ "$key" == "$current" ]]; then
            echo "$i) ${THEMES[$key]} *"
        else
            echo "$i) ${THEMES[$key]}"
        fi
        ((i++))
    done
    echo "$i) Custom theme..."
    echo ""
    echo -n "Choice: "
    
    local choice
    read -r choice
    
    local keys=("${!THEMES[@]}")
    local idx=$((choice - 1))
    
    if [[ $choice -ge 1 ]] && [[ $choice -le $i ]]; then
        if [[ $choice -eq $i ]]; then
            echo "custom"
        else
            echo "${keys[$idx]}"
        fi
    else
        echo "$current"
    fi
}

create_custom_theme() {
    local custom_file="$HOME/.config/demod/custom-theme.json"
    
    echo "Creating custom theme..."
    echo -n "Enter theme name: "
    read -r custom_name
    
    if [[ -z "$custom_name" ]]; then
        echo "Cancelled"
        return 1
    fi
    
    cat > "$custom_file" << EOF
{
  "name": "custom",
  "bg": "#1a1b26",
  "bgAlt": "#24283b",
  "surface": "#414868",
  "surfaceAlt": "#565f89",
  "overlay": "#565f89",
  "border": "#565f89",
  "borderFocus": "#7aa2f7",
  "borderHover": "#bb9af7",
  "accent": "#7aa2f7",
  "accentAlt": "#bb9af7",
  "accentDim": "#9ece6a",
  "text": "#c0caf5",
  "textAlt": "#a9b1d6",
  "textDim": "#565f89",
  "success": "#9ece6a",
  "warning": "#e0af68",
  "error": "#f7768e",
  "info": "#7aa2f7"
}
EOF
    
    echo "Custom theme file created at: $custom_file"
    echo "Edit it with your custom colors, then run this script again."
}

case "${1:-toggle}" in
    toggle)
        current=$(get_current_theme)
        next=$(get_next_theme "$current")
        theme_json=$(get_theme_json "$next")
        apply_theme "$next" "$theme_json"
        ;;
    set)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 set <theme-name>"
            echo "Available: ${!THEMES[@]}"
            exit 1
        fi
        theme_name="$2"
        if [[ -z "${THEMES[$theme_name]:-}" ]] && [[ "$theme_name" != "custom" ]]; then
            echo "Unknown theme: $theme_name"
            exit 1
        fi
        theme_json=$(get_theme_json "$theme_name")
        apply_theme "$theme_name" "$theme_json"
        ;;
    gui)
        current=$(get_current_theme)
        selected=$(show_gui_menu "$current")
        if [[ -n "$selected" ]]; then
            if [[ "$selected" == "custom" ]]; then
                create_custom_theme
                exit 0
            fi
            theme_json=$(get_theme_json "$selected")
            apply_theme "$selected" "$theme_json"
        fi
        ;;
    cli)
        current=$(get_current_theme)
        selected=$(show_cli_menu "$current")
        if [[ -n "$selected" ]]; then
            if [[ "$selected" == "custom" ]]; then
                create_custom_theme
                exit 0
            fi
            theme_json=$(get_theme_json "$selected")
            apply_theme "$selected" "$theme_json"
        fi
        ;;
    current)
        echo "$(get_current_theme)"
        ;;
    list)
        echo "Available themes:"
        for key in "${!THEMES[@]}"; do
            echo "  $key: ${THEMES[$key]}"
        done
        ;;
    *)
        echo "Usage: $0 {toggle|set|gui|cli|current|list}"
        exit 1
        ;;
esac
