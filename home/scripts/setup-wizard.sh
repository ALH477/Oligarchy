#!/usr/bin/env bash
# Interactive Setup Wizard for Nix Home Configuration

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
RESET='\033[0m'

# Configuration
CONFIG_DIR="${HOME}/.config/home-manager/nix-home"
HOME_NIX="${CONFIG_DIR}/home.nix"
BACKUP_DIR="${HOME}/.config/home-manager/backups"

# Print functions
print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${BOLD}              NIX HOME CONFIGURATION - SETUP WIZARD                  ${CYAN}║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

print_step() {
    echo -e "${CYAN}▸ ${WHITE}$1${RESET}"
}

print_success() {
    echo -e "${GREEN}✓ $1${RESET}"
}

print_error() {
    echo -e "${RED}✗ $1${RESET}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${RESET}"
}

# Check prerequisites
check_prerequisites() {
    print_header
    echo -e "${WHITE}Checking prerequisites...${RESET}"
    echo ""
    
    local errors=0
    
    # Check Nix installed
    if command -v nix &> /dev/null; then
        print_success "Nix is installed"
    else
        print_error "Nix is not installed"
        ((errors++))
    fi
    
    # Check home-manager
    if command -v home-manager &> /dev/null; then
        print_success "Home Manager is installed"
    else
        print_warning "Home Manager not found in PATH"
    fi
    
    # Check config directory
    if [[ -d "$CONFIG_DIR" ]]; then
        print_success "Config directory exists: $CONFIG_DIR"
    else
        print_error "Config directory not found: $CONFIG_DIR"
        ((errors++))
    fi
    
    # Check home.nix
    if [[ -f "$HOME_NIX" ]]; then
        print_success "home.nix found"
    else
        print_error "home.nix not found"
        ((errors++))
    fi
    
    echo ""
    if [[ $errors -gt 0 ]]; then
        print_warning "Some prerequisites are missing. Setup may not work correctly."
        read -p "Continue anyway? [y/N]: " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    read -p "Press Enter to continue..."
}

# Hardware detection
detect_hardware() {
    print_header
    echo -e "${WHITE}${BOLD}Step 1: Hardware Detection${RESET}"
    echo ""
    
    # Detect laptop vs desktop
    if [[ -d /sys/class/power_supply/BAT0 ]] || [[ -d /sys/class/power_supply/BAT1 ]]; then
        local has_battery="true"
        print_success "Battery detected"
    else
        local has_battery="false"
        print_warning "No battery detected (desktop mode)"
    fi
    
    # Detect touchpad
    if [[ -d /sys/class/input/mouse0 ]]; then
        local has_touchpad="true"
        print_success "Touchpad detected"
    else
        local has_touchpad="false"
        print_warning "No touchpad detected"
    fi
    
    # Detect bluetooth
    if command -v rfkill &> /dev/null; then
        if rfkill list bluetooth &> /dev/null 2>&1; then
            local has_bluetooth="true"
            print_success "Bluetooth detected"
        else
            local has_bluetooth="false"
        fi
    else
        local has_bluetooth="false"
    fi
    
    # Detect backlight
    if [[ -d /sys/class/backlight ]]; then
        local has_backlight="true"
        print_success "Backlight control available"
    else
        local has_backlight="false"
        print_warning "No backlight control detected"
    fi
    
    echo ""
    print_warning "Detected configuration:"
    echo "  hasBattery: $has_battery"
    echo "  hasTouchpad: $has_touchpad"  
    echo "  hasBluetooth: $has_bluetooth"
    echo "  hasBacklight: $has_backlight"
    echo ""
    
    read -p "Use detected settings? [Y/n]: " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "You can manually edit home.nix later"
    fi
    
    echo "$has_battery:$has_touchpad:$has_bluetooth:$has_backlight"
}

# Theme selection
select_theme() {
    print_header
    echo -e "${WHITE}${BOLD}Step 2: Select Theme${RESET}"
    echo ""
    
    local themes=("demod" "catppuccin" "nord" "rosepine" "gruvbox" "dracula" "tokyo" "phosphor")
    local descriptions=(
        "Radical retro-tech (turquoise/violet)"
        "Cozy pastel Mocha"
        "Frozen arctic blue"
        "Elegant muted rose"
        "Warm retro earth tones"
        "Dark purple and cyan"
        "Clean modern dark theme"
        "Neon cyberpunk aesthetic"
    )
    
    local i=0
    for theme in "${themes[@]}"; do
        echo -e "  ${WHITE}$((i+1))${RESET}. ${BOLD}$theme${RESET} - ${descriptions[$i]}"
        ((i++))
    done
    
    echo ""
    read -p "Choose theme [1-8]: " choice
    
    local selected_theme="${themes[$((choice-1))]}"
    echo ""
    print_success "Selected theme: $selected_theme"
    
    echo "$selected_theme"
}

# Feature selection
select_features() {
    print_header
    echo -e "${WHITE}${BOLD}Step 3: Configure Features${RESET}"
    echo ""
    
    echo -e "${WHITE}Enable features:${RESET}"
    echo ""
    
    read -p "Enable development tools? [Y/n]: " -n 1 -r
    echo ""
    local enable_dev="false"
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        enable_dev="true"
    fi
    
    read -p "Enable gaming packages? [y/N]: " -n 1 -r
    echo ""
    local enable_gaming="false"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        enable_gaming="true"
    fi
    
    read -p "Enable audio tools? [Y/n]: " -n 1 -r
    echo ""
    local enable_audio="true"
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        enable_audio="false"
    fi
    
    echo ""
    print_success "Features configured"
    
    echo "$enable_dev:$enable_gaming:$enable_audio"
}

# Apply configuration
apply_config() {
    local theme=$1
    local has_battery=$2
    local has_touchpad=$3
    local has_bluetooth=$4
    local has_backlight=$5
    local enable_dev=$6
    local enable_gaming=$7
    local enable_audio=$8
    
    print_header
    echo -e "${WHITE}${BOLD}Step 4: Apply Configuration${RESET}"
    echo ""
    
    # Create backup
    mkdir -p "$BACKUP_DIR"
    local backup_name="backup-$(date +%Y%m%d_%H%M%S)"
    cp "$HOME_NIX" "${BACKUP_DIR}/${backup_name}.nix"
    print_success "Backup created: ${backup_name}.nix"
    
    # Update home.nix
    # Theme
    sed -i "s/activePalette = \"[^\"]*\"/activePalette = \"$theme\"/" "$HOME_NIX"
    print_success "Theme set to: $theme"
    
    # Features
    sed -i "s/hasBattery = [^;]*/hasBattery = $has_battery;/" "$HOME_NIX"
    sed -i "s/hasTouchpad = [^;]*/hasTouchpad = $has_touchpad;/" "$HOME_NIX"
    sed -i "s/hasBluetooth = [^;]*/hasBluetooth = $has_bluetooth;/" "$HOME_NIX"
    sed -i "s/hasBacklight = [^;]*/hasBacklight = $has_backlight;/" "$HOME_NIX"
    sed -i "s/enableDev = [^;]*/enableDev = $enable_dev;/" "$HOME_NIX"
    sed -i "s/enableGaming = [^;]*/enableGaming = $enable_gaming;/" "$HOME_NIX"
    sed -i "s/enableAudio = [^;]*/enableAudio = $enable_audio;/" "$HOME_NIX"
    
    print_success "Configuration updated"
    
    echo ""
    read -p "Build configuration now? [Y/n]: " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        echo -e "${YELLOW}Building configuration...${RESET}"
        cd "$CONFIG_DIR"
        if home-manager switch --flake .; then
            print_success "Configuration built successfully!"
        else
            print_error "Build failed. Restoring backup..."
            cp "${BACKUP_DIR}/${backup_name}.nix" "$HOME_NIX"
        fi
    else
        echo -e "${CYAN}Run 'home-manager switch' to apply changes${RESET}"
    fi
}

# Main wizard
main() {
    print_header
    echo -e "${WHITE}Welcome to the Nix Home Configuration Setup Wizard${RESET}"
    echo ""
    echo "This wizard will help you configure your system."
    echo ""
    read -p "Press Enter to begin..."
    
    # Run wizard steps
    check_prerequisites
    
    local hw_info
    hw_info=$(detect_hardware)
    IFS=':' read -r has_battery has_touchpad has_bluetooth has_backlight <<< "$hw_info"
    
    local theme
    theme=$(select_theme)
    
    local features
    features=$(select_features)
    IFS=':' read -r enable_dev enable_gaming enable_audio <<< "$features"
    
    apply_config "$theme" "$has_battery" "$has_touchpad" "$has_bluetooth" "$has_backlight" "$enable_dev" "$enable_gaming" "$enable_audio"
    
    print_header
    echo -e "${GREEN}${BOLD}Setup Complete!${RESET}"
    echo ""
    echo "Your Nix Home configuration has been set up."
    echo "You can run this wizard again anytime to reconfigure."
    echo ""
}

main "$@"
