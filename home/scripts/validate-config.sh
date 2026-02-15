#!/usr/bin/env bash
# Configuration Validator for Nix Home Manager

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
ERRORS=0
WARNINGS=0

# Print functions
print_header() {
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${CYAN}  Nix Home Configuration Validator${RESET}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${RESET}"
    echo ""
}

print_error() {
    echo -e "${RED}✗ ${WHITE}$1${RESET}"
    ((ERRORS++))
}

print_warning() {
    echo -e "${YELLOW}⚠ ${WHITE}$1${RESET}"
    ((WARNINGS++))
}

print_success() {
    echo -e "${GREEN}✓ $1${RESET}"
}

print_info() {
    echo -e "${BLUE}ℹ ${WHITE}$1${RESET}"
}

# Check if config exists
check_config_exists() {
    print_info "Checking configuration files..."
    
    if [[ ! -d "$CONFIG_DIR" ]]; then
        print_error "Config directory not found: $CONFIG_DIR"
        return 1
    fi
    
    if [[ ! -f "$HOME_NIX" ]]; then
        print_error "home.nix not found: $HOME_NIX"
        return 1
    fi
    
    print_success "Configuration files found"
}

# Validate Nix syntax
validate_nix_syntax() {
    print_info "Validating Nix syntax..."
    
    if ! command -v nix &> /dev/null; then
        print_warning "Nix not installed, skipping syntax check"
        return 0
    fi
    
    if nix-instantiate --parse "$HOME_NIX" > /dev/null 2>&1; then
        print_success "Nix syntax is valid"
    else
        print_error "Nix syntax error in home.nix"
        nix-instantiate --parse "$HOME_NIX" 2>&1 | head -20
    fi
}

# Validate theme
validate_theme() {
    print_info "Validating theme configuration..."
    
    local active_theme
    active_theme=$(grep 'activePalette = "' "$HOME_NIX" | sed 's/.*"\([^"]*\)".*/\1/')
    
    local valid_themes=("demod" "catppuccin" "nord" "rosepine" "gruvbox" "dracula" "tokyo" "phosphor")
    
    if [[ " ${valid_themes[*]} " =~ " $active_theme " ]]; then
        print_success "Theme is valid: $active_theme"
    else
        print_error "Invalid theme: $active_theme"
        print_info "Valid themes: ${valid_themes[*]}"
    fi
}

# Validate features
validate_features() {
    print_info "Validating feature flags..."
    
    local features=("hasBattery" "hasTouchpad" "hasBacklight" "hasBluetooth" "hasNumpad" "enableDev" "enableGaming" "enableAudio")
    
    for feature in "${features[@]}"; do
        if grep -q "$feature = " "$HOME_NIX"; then
            local value
            value=$(grep "$feature = " "$HOME_NIX" | head -1 | sed 's/.*= \([^;]*\);.*/\1/')
            if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
                print_success "$feature = $value"
            else
                print_error "Invalid value for $feature: $value"
            fi
        else
            print_warning "Missing feature flag: $feature"
        fi
    done
}

# Validate imports
validate_imports() {
    print_info "Validating module imports..."
    
    local required_modules=("packages.nix" "waybar" "hyprland" "shell" "terminal" "apps" "scripts")
    
    for module in "${required_modules[@]}"; do
        if [[ -f "${CONFIG_DIR}/${module}" ]] || [[ -d "${CONFIG_DIR}/${module}" ]]; then
            print_success "Module exists: $module"
        else
            print_error "Missing module: $module"
        fi
    done
}

# Validate theme file
validate_theme_file() {
    print_info "Validating theme palette file..."
    
    local theme_file="${CONFIG_DIR}/themes/default.nix"
    
    if [[ ! -f "$theme_file" ]]; then
        print_error "Theme file not found: $theme_file"
        return 1
    fi
    
    # Check for required palettes
    local palettes=("demod" "catppuccin" "nord" "rosepine")
    
    for palette in "${palettes[@]}"; do
        if grep -q "$palette = {" "$theme_file"; then
            print_success "Palette found: $palette"
        else
            print_error "Missing palette: $palette"
        fi
    done
}

# Check for common issues
check_common_issues() {
    print_info "Checking for common issues..."
    
    # Check state version
    if grep -q 'stateVersion = "24.05"' "$HOME_NIX"; then
        print_warning "stateVersion is 24.05 - consider updating to 25.11"
    elif grep -q 'stateVersion = "25.11"' "$HOME_NIX"; then
        print_success "stateVersion is up to date"
    fi
    
    # Check for hardcoded paths
    if grep -q '/home/asher' "$HOME_NIX"; then
        print_warning "Hardcoded username path found - may need adjustment"
    fi
    
    # Check for duplicate imports
    local import_count
    import_count=$(grep -c 'imports = \[' "$HOME_NIX" || true)
    if [[ "$import_count" -gt 1 ]]; then
        print_warning "Multiple imports sections found"
    fi
}

# Test build
test_build() {
    print_info "Testing configuration build..."
    
    read -p "Run test build? [y/N]: " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Running home-manager build..."
        cd "$CONFIG_DIR"
        if home-manager build --dry-run 2>&1 | tail -20; then
            print_success "Build test passed"
        else
            print_error "Build test failed"
        fi
    fi
}

# Main
main() {
    print_header
    
    check_config_exists || exit 1
    echo ""
    
    validate_nix_syntax
    echo ""
    
    validate_theme
    echo ""
    
    validate_features
    echo ""
    
    validate_imports
    echo ""
    
    validate_theme_file
    echo ""
    
    check_common_issues
    echo ""
    
    # Summary
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${WHITE}Summary:${RESET}"
    echo -e "  ${RED}Errors: $ERRORS${RESET}"
    echo -e "  ${YELLOW}Warnings: $WARNINGS${RESET}"
    echo ""
    
    if [[ $ERRORS -gt 0 ]]; then
        echo -e "${RED}Configuration has errors. Please fix before rebuilding.${RESET}"
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        echo -e "${YELLOW}Configuration has warnings but may work.${RESET}"
    else
        echo -e "${GREEN}Configuration looks good!${RESET}"
    fi
    
    test_build
}

main "$@"
