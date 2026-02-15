#!/usr/bin/env bash
# Interactive Theme Preview System for Nix Home Manager

set -euo pipefail

# Colors and styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
BOLD='\033[1m'
RESET='\033[0m'

# Configuration
HOME_CONFIG_DIR="$HOME/.config/home-manager"
NIX_HOME_DIR="${HOME_CONFIG_DIR}/nix-home"
THEMES_DIR="${NIX_HOME_DIR}/themes"
HOME_NIX="${NIX_HOME_DIR}/home.nix"
PREVIEW_TEMP="/tmp/nix-theme-preview"
BACKUP_DIR="${HOME_CONFIG_DIR}/backups"

# Available themes
THEMES=("demod" "catppuccin" "nord" "rosepine" "gruvbox" "dracula" "tokyo" "phosphor")

# Current theme
CURRENT_THEME=$(grep "activePalette" "$HOME_NIX" | sed 's/.*"\([^"]*\)".*/\1/' || echo "unknown")

# Theme descriptions
declare -A THEME_DESCRIPTIONS=(
    ["demod"]="Radical retro-tech (turquoise/violet, CRT aesthetic)"
    ["catppuccin"]="Cozy pastel Mocha"
    ["nord"]="Frozen arctic blue"
    ["rosepine"]="Elegant muted rose"
    ["gruvbox"]="Warm retro earth tones"
    ["dracula"]="Dark purple and cyan"
    ["tokyo"]="Clean modern dark theme"
    ["phosphor"]="Neon cyberpunk aesthetic"
)

# Theme colors (sample)
declare -A THEME_COLORS=(
    ["demod"]="#00F5D4"
    ["catppuccin"]="#CBA6F7"
    ["nord"]="#88C0D0"
    ["rosepine"]="#C4A7E7"
    ["gruvbox"]="#d79921"
    ["dracula"]="#bd93f9"
    ["tokyo"]="#7aa2f7"
    ["phosphor"]="#00ffff"
)

# Print header
print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${BOLD}                    NIX THEME PREVIEW SYSTEM                          ${CYAN}║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

# Print theme preview
print_theme_preview() {
    local theme=$1
    local color=${THEME_COLORS[$theme]}
    local description=${THEME_DESCRIPTIONS[$theme]}
    local current_marker=""
    
    if [[ "$theme" == "$CURRENT_THEME" ]]; then
        current_marker="${GREEN}[CURRENT]${RESET} "
    fi
    
    echo -e "${current_marker}${BOLD}${theme}${RESET}"
    echo -e "  ${GRAY}${description}${RESET}"
    echo -e "  Color: ${color}${color}${RESET}████████${RESET}"
    echo ""
}

# Create preview window
create_preview() {
    local theme=$1
    
    # Create temporary preview config
    mkdir -p "$PREVIEW_TEMP"
    
    # Generate preview script
    cat > "$PREVIEW_TEMP/preview-${theme}.nix" << EOF
{ pkgs ? import <nixpkgs> {} }:

let
  home-manager = builtins.fetchTarball "https://github.com/nix-community/home-manager/archive/master.tar.gz";
  nix-home = import ./nix-home {
    inherit pkgs lib;
  };
  
  # Override theme
  themeSystem = import ./nix-home/themes { inherit lib; };
  theme = themeSystem.palettes.${theme};
in
pkgs.mkShell {
  buildInputs = with pkgs; [ home-manager nix ];
  shellHook = ''
    echo "Theme: ${theme}"
    echo "Background: \${theme.bg}"
    echo "Accent: \${theme.accent}"
    echo "Text: \${theme.text}"
    echo ""
    echo "Preview complete. Press any key to continue..."
    read -n 1
  '';
}
EOF
}

# Apply theme
apply_theme() {
    local theme=$1
    
    print_header
    echo -e "${YELLOW}🔄 Applying theme: ${BOLD}${theme}${RESET}"
    echo ""
    
    # Create backup
    local backup_name="backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp "$HOME_NIX" "${BACKUP_DIR}/${backup_name}.nix"
    
    # Apply theme change
    sed -i "s/activePalette = \"[^\"]*\"/activePalette = \"${theme}\"/" "$HOME_NIX"
    
    echo -e "${GREEN}✓ Theme updated to ${BOLD}${theme}${RESET}"
    echo -e "${GRAY}  Backup created: ${backup_name}.nix${RESET}"
    echo ""
    
    # Ask if user wants to rebuild
    echo -e "${CYAN}🔨 Rebuild configuration to apply changes?${RESET}"
    echo -e "  ${WHITE}1${RESET} Yes, rebuild now"
    echo -e "  ${WHITE}2${RESET} No, I'll rebuild manually"
    echo ""
    read -p "Choose option [1-2]: " -n 1 choice
    echo ""
    
    case $choice in
        1)
            echo -e "${YELLOW}⏳ Building configuration...${RESET}"
            cd "$HOME_CONFIG_DIR"
            if home-manager switch; then
                echo -e "${GREEN}✓ Configuration rebuilt successfully!${RESET}"
                echo -e "${GREEN}✨ Theme ${BOLD}${theme}${RESET}${GREEN} is now active!${RESET}"
            else
                echo -e "${RED}✗ Build failed! Restoring backup...${RESET}"
                cp "${BACKUP_DIR}/${backup_name}.nix" "$HOME_NIX"
                echo -e "${YELLOW}↩️ Backup restored${RESET}"
            fi
            ;;
        2)
            echo -e "${CYAN}💡 To apply changes later, run:${RESET}"
            echo -e "${GRAY}  cd $HOME_CONFIG_DIR && home-manager switch${RESET}"
            ;;
    esac
}

# Interactive theme selector
interactive_selector() {
    print_header
    echo -e "${WHITE}🎨 Select a theme to preview:${RESET}"
    echo -e "${GRAY}  Current theme: ${BOLD}${CURRENT_THEME}${RESET}"
    echo ""
    
    local i=1
    for theme in "${THEMES[@]}"; do
        echo -e "  ${WHITE}$i${RESET}. $(print_theme_preview "$theme")"
        ((i++))
    done
    
    echo -e "  ${WHITE}q${RESET}. Quit"
    echo ""
    
    while true; do
        read -p "Select theme [1-8/q]: " -n 1 choice
        echo ""
        
        case $choice in
            [1-8])
                local selected_index=$((choice - 1))
                local selected_theme=${THEMES[$selected_index]}
                show_theme_menu "$selected_theme"
                break
                ;;
            [qQ])
                echo -e "${CYAN}👋 Goodbye!${RESET}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Invalid choice. Please try again.${RESET}"
                ;;
        esac
    done
}

# Theme detail menu
show_theme_menu() {
    local theme=$1
    local color=${THEME_COLORS[$theme]}
    local description=${THEME_DESCRIPTIONS[$theme]}
    
    print_header
    echo -e "${color}${BOLD}═══ ${theme^} Theme Preview ═══${RESET}"
    echo ""
    echo -e "${WHITE}Description:${RESET} ${description}"
    echo -e "${WHITE}Sample Color:${RESET} ${color}${color}████████${RESET}"
    echo ""
    echo -e "${WHITE}🔍 Full Color Palette:${RESET}"
    
    # Show palette colors if we can extract them
    if [[ -f "${THEMES_DIR}/default.nix" ]]; then
        echo -e "${GRAY}$(grep -A 30 "$theme = {" "${THEMES_DIR}/default.nix" | grep -E "(bg|accent|text) =" | head -6 | sed 's/^/    /')${RESET}"
    fi
    
    echo ""
    echo -e "${WHITE}🎯 Actions:${RESET}"
    echo -e "  ${WHITE}1${RESET}. ${GREEN}Apply this theme${RESET}"
    echo -e "  ${WHITE}2${RESET}. ${BLUE}Preview live in terminal${RESET}"
    echo -e "  ${WHITE}3${RESET}. ${YELLOW}View color palette${RESET}"
    echo -e "  ${WHITE}b${RESET}. Back to theme list"
    echo -e "  ${WHITE}q${RESET}. Quit"
    echo ""
    
    while true; do
        read -p "Choose action [1-3/b/q]: " -n 1 action
        echo ""
        
        case $action in
            1)
                apply_theme "$theme"
                return
                ;;
            2)
                preview_theme_terminal "$theme"
                show_theme_menu "$theme"
                ;;
            3)
                show_full_palette "$theme"
                show_theme_menu "$theme"
                ;;
            [bB])
                interactive_selector
                return
                ;;
            [qQ])
                echo -e "${CYAN}👋 Goodbye!${RESET}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Invalid choice. Please try again.${RESET}"
                ;;
        esac
    done
}

# Terminal preview
preview_theme_terminal() {
    local theme=$1
    local color=${THEME_COLORS[$theme]}
    
    # Create color showcase
    echo -e "${color}${BOLD}═══ ${theme^} Theme Terminal Preview ═══${RESET}"
    echo ""
    
    # Sample UI elements with theme colors
    echo -e "${color}┌─────────────────────────────────────┐${RESET}"
    echo -e "${color}│${RESET} ${BOLD}Title Bar${RESET}                         ${color}│${RESET}"
    echo -e "${color}├─────────────────────────────────────┤${RESET}"
    echo -e "${color}│${RESET} 📁 Documents                        ${color}│${RESET}"
    echo -e "${color}│${RESET} 📁 Downloads                       ${color}│${RESET}"
    echo -e "${color}│${RESET} 📁 Pictures                         ${color}│${RESET}"
    echo -e "${color}│${RESET} 📄 theme-preview.txt               ${color}│${RESET}"
    echo -e "${color}├─────────────────────────────────────┤${RESET}"
    echo -e "${color}│${RESET} [${color}●●●○○○${RESET}] 50%                      ${color}│${RESET}"
    echo -e "${color}└─────────────────────────────────────┘${RESET}"
    echo ""
    echo -e "${color}Button:${RESET} [ ${color}${BOLD}Click Me${RESET} ]"
    echo ""
    read -p "Press any key to continue..."
}

# Show full color palette
show_full_palette() {
    local theme=$1
    
    print_header
    echo -e "${BOLD}${theme^} Color Palette${RESET}"
    echo ""
    
    if [[ -f "${THEMES_DIR}/default.nix" ]]; then
        # Extract and display color palette
        echo -e "${CYAN}Base Colors:${RESET}"
        grep -A 50 "$theme = {" "${THEMES_DIR}/default.nix" | \
        grep -E "(bg|surface|border|text) =" | \
        sed 's/.*= "\(.*\)".*/\1/' | \
        head -8 | \
        while read -r color; do
            echo -e "  ${color}████${RESET} $color"
        done
        
        echo ""
        echo -e "${CYAN}Accent Colors:${RESET}"
        grep -A 50 "$theme = {" "${THEMES_DIR}/default.nix" | \
        grep -E "(accent|success|warning|error|info) =" | \
        sed 's/.*= "\(.*\)".*/\1/' | \
        head -6 | \
        while read -r color; do
            echo -e "  ${color}████${RESET} $color"
        done
    fi
    
    echo ""
    read -p "Press any key to continue..."
}

# Main function
main() {
    # Check if we're in the right directory
    if [[ ! -f "$HOME_NIX" ]]; then
        echo -e "${RED}❌ Error: Could not find home.nix at $HOME_NIX${RESET}"
        echo -e "${GRAY}Make sure your nix-home configuration is set up correctly.${RESET}"
        exit 1
    fi
    
    # Check for themes
    if [[ ! -d "$THEMES_DIR" ]]; then
        echo -e "${RED}❌ Error: Could not find themes directory at $THEMES_DIR${RESET}"
        exit 1
    fi
    
    interactive_selector
}

# Run main function
main "$@"