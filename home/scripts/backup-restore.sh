#!/usr/bin/env bash
# Backup and Restore System for Nix Home Configuration

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
BACKUP_DIR="${HOME}/.config/home-manager/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Print functions
print_header() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${CYAN}  Nix Home Configuration - Backup & Restore${RESET}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════${RESET}"
    echo ""
}

print_error() {
    echo -e "${RED}✗ $1${RESET}"
}

print_success() {
    echo -e "${GREEN}✓ $1${RESET}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${RESET}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${RESET}"
}

# Create backup
do_backup() {
    local name="${1:-${TIMESTAMP}}"
    local backup_path="${BACKUP_DIR}/${name}"
    
    print_info "Creating backup: $name"
    
    mkdir -p "$backup_path"
    
    # Backup main config files
    cp -r "$CONFIG_DIR" "$backup_path/nix-home"
    print_success "Configuration backed up"
    
    # Backup waybar config if exists
    if [[ -d "${HOME}/.config/waybar" ]]; then
        cp -r "${HOME}/.config/waybar" "$backup_path/"
        print_success "Waybar config backed up"
    fi
    
    # Backup hyprland config if exists
    if [[ -d "${HOME}/.config/hypr" ]]; then
        cp -r "${HOME}/.config/hypr" "$backup_path/"
        print_success "Hyprland config backed up"
    fi
    
    # Create backup info
    cat > "$backup_path/backup-info.txt" << EOF
Backup Date: $(date)
Hostname: $(hostname)
User: $(whoami)
 Nix Version: $(nix --version 2>/dev/null || echo "N/A")
Home Manager: $(home-manager --version 2>/dev/null || echo "N/A")
EOF
    
    # Compress backup
    cd "$BACKUP_DIR"
    tar -czf "${name}.tar.gz" "$name" && rm -rf "$name"
    
    print_success "Backup complete: ${name}.tar.gz"
    echo ""
    echo "Backup location: ${BACKUP_DIR}/${name}.tar.gz"
}

# List backups
list_backups() {
    print_header
    echo -e "${WHITE}Available Backups:${RESET}"
    echo ""
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_warning "No backups found"
        return
    fi
    
    local count=0
    for backup in "$BACKUP_DIR"/*.tar.gz; do
        if [[ -f "$backup" ]]; then
            local size
            size=$(du -h "$backup" | cut -f1)
            local date
            date=$(tar -tzf "$backup" | head -1 | cut -d'/' -f1 | sed 's/backup-//')
            echo -e "  ${WHITE}$((++count))${RESET}. $(basename "$backup")"
            echo -e "      ${GRAY}Size: $size | Date: $date${RESET}"
            echo ""
        fi
    done
    
    if [[ $count -eq 0 ]]; then
        print_warning "No backups found"
    fi
}

# Restore backup
do_restore() {
    local backup_name=$1
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    print_warning "This will overwrite your current configuration!"
    read -p "Are you sure? [y/N]: " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Restore cancelled"
        return
    fi
    
    # Extract backup
    print_info "Extracting backup..."
    tar -xzf "${BACKUP_DIR}/${backup_name}" -C "$BACKUP_DIR/"
    
    # Restore nix-home
    if [[ -d "${BACKUP_DIR}/${backup_name%.tar.gz}/nix-home" ]]; then
        rm -rf "$CONFIG_DIR"
        cp -r "${BACKUP_DIR}/${backup_name%.tar.gz}/nix-home" "$CONFIG_DIR"
        print_success "Configuration restored"
    fi
    
    # Ask about other configs
    read -p "Restore waybar config? [y/N]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [[ -d "${BACKUP_DIR}/${backup_name%.tar.gz}/waybar" ]]; then
            rm -rf "${HOME}/.config/waybar"
            cp -r "${BACKUP_DIR}/${backup_name%.tar.gz}/waybar" "${HOME}/.config/"
            print_success "Waybar config restored"
        fi
    fi
    
    read -p "Restore hyprland config? [y/N]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [[ -d "${BACKUP_DIR}/${backup_name%.tar.gz}/hypr" ]]; then
            rm -rf "${HOME}/.config/hypr"
            cp -r "${BACKUP_DIR}/${backup_name%.tar.gz}/hypr" "${HOME}/.config/"
            print_success "Hyprland config restored"
        fi
    fi
    
    # Cleanup
    rm -rf "${BACKUP_DIR}/${backup_name%.tar.gz}"
    
    print_success "Restore complete!"
    echo ""
    print_info "Run 'home-manager switch' to apply changes"
}

# Delete backup
delete_backup() {
    local backup_name=$1
    
    print_warning "This will permanently delete: $backup_name"
    read -p "Are you sure? [y/N]: " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "${BACKUP_DIR}/${backup_name}"
        print_success "Backup deleted"
    else
        print_info "Delete cancelled"
    fi
}

# Show backup info
show_info() {
    local backup_name=$1
    local extract_dir="/tmp/nix-backup-info-$$"
    
    mkdir -p "$extract_dir"
    tar -xzf "${BACKUP_DIR}/${backup_name}" -C "$extract_dir/"
    
    local backup_dir="${extract_dir}/${backup_name%.tar.gz}"
    
    if [[ -f "$backup_dir/backup-info.txt" ]]; then
        cat "$backup_dir/backup-info.txt"
    else
        print_warning "No backup info found"
    fi
    
    rm -rf "$extract_dir"
}

# Main menu
main() {
    case "${1:-menu}" in
        "backup")
            do_backup "${2:-}"
            ;;
        "list"|"ls")
            list_backups
            ;;
        "restore")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 restore <backup-name>"
                list_backups
                exit 1
            fi
            do_restore "$2"
            ;;
        "delete"|"rm")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 delete <backup-name>"
                list_backups
                exit 1
            fi
            delete_backup "$2"
            ;;
        "info")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 info <backup-name>"
                exit 1
            fi
            show_info "$2"
            ;;
        "menu"|*)
            while true; do
                print_header
                echo -e "${WHITE}Choose an option:${RESET}"
                echo ""
                echo "  ${WHITE}1${RESET}. Create backup"
                echo "  ${WHITE}2${RESET}. List backups"
                echo "  ${WHITE}3${RESET}. Restore backup"
                echo "  ${WHITE}4${RESET}. Delete backup"
                echo "  ${WHITE}5${RESET}. Show backup info"
                echo "  ${WHITE}q${RESET}. Quit"
                echo ""
                
                read -p "Choose [1-5/q]: " -n 1 choice
                echo ""
                
                case $choice in
                    1)
                        read -p "Backup name [default: timestamp]: " name
                        do_backup "$name"
                        read -p "Press Enter to continue..."
                        ;;
                    2)
                        list_backups
                        read -p "Press Enter to continue..."
                        ;;
                    3)
                        list_backups
                        echo ""
                        read -p "Enter backup number to restore: " num
                        backup_file=$(ls -1 "$BACKUP_DIR"/*.tar.gz | sed -n "${num}p")
                        if [[ -n "$backup_file" ]]; then
                            do_restore "$(basename "$backup_file")"
                        else
                            print_error "Invalid selection"
                        fi
                        read -p "Press Enter to continue..."
                        ;;
                    4)
                        list_backups
                        echo ""
                        read -p "Enter backup number to delete: " num
                        backup_file=$(ls -1 "$BACKUP_DIR"/*.tar.gz | sed -n "${num}p")
                        if [[ -n "$backup_file" ]]; then
                            delete_backup "$(basename "$backup_file")"
                        else
                            print_error "Invalid selection"
                        fi
                        read -p "Press Enter to continue..."
                        ;;
                    5)
                        list_backups
                        echo ""
                        read -p "Enter backup number: " num
                        backup_file=$(ls -1 "$BACKUP_DIR"/*.tar.gz | sed -n "${num}p")
                        if [[ -n "$backup_file" ]]; then
                            show_info "$(basename "$backup_file")"
                        else
                            print_error "Invalid selection"
                        fi
                        read -p "Press Enter to continue..."
                        ;;
                    [qQ])
                        echo -e "${CYAN}Goodbye!${RESET}"
                        exit 0
                        ;;
                esac
            done
            ;;
    esac
}

main "$@"
