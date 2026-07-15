#!/usr/bin/env bash
# oligarchy-dsp.sh - ArchibaldOS DSP Coprocessor VM Manager
# Part of OligarchyOS Control Center
#
# Usage:
#   oligarchy-dsp start    - Start the DSP VM
#   oligarchy-dsp stop     - Stop the DSP VM
#   oligarchy-dsp restart  - Restart the DSP VM
#   oligarchy-dsp status   - Show VM status
#   oligarchy-dsp logs     - Tail serial console logs
#   oligarchy-dsp monitor  - Open QEMU monitor
#   oligarchy-dsp rebuild  - Rebuild VM image from ArchibaldOS flake
#   oligarchy-dsp vnc      - Connect via VNC (if enabled)

set -euo pipefail

VM_SERVICE="archibaldos-dsp.service"
VM_IMAGE="${HOME}/vms/archibaldos-dsp.qcow2"
SERIAL_LOG="/var/log/qemu-archibaldos-dsp-serial.log"
MONITOR_SOCK="/run/qemu-archibaldos-dsp.sock"
ARCHIBALDOS_DIR="${HOME}/ArchibaldOS"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[DSP VM]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

cmd_start() {
    print_status "Starting DSP VM..."
    sudo systemctl start "$VM_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$VM_SERVICE"; then
        print_success "DSP VM started successfully"
        echo ""
        echo "  Serial log: $SERIAL_LOG"
        echo "  Monitor:    sudo socat - UNIX-CONNECT:$MONITOR_SOCK"
        echo "  NETJACK:    Port 4713 (TCP/UDP)"
    else
        print_error "Failed to start DSP VM"
        journalctl -u "$VM_SERVICE" -n 20 --no-pager
        exit 1
    fi
}

cmd_stop() {
    print_status "Stopping DSP VM..."
    sudo systemctl stop "$VM_SERVICE"
    sleep 2
    if ! systemctl is-active --quiet "$VM_SERVICE"; then
        print_success "DSP VM stopped"
    else
        print_error "Failed to stop DSP VM"
        exit 1
    fi
}

cmd_restart() {
    print_status "Restarting DSP VM..."
    sudo systemctl restart "$VM_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$VM_SERVICE"; then
        print_success "DSP VM restarted successfully"
    else
        print_error "Failed to restart DSP VM"
        journalctl -u "$VM_SERVICE" -n 20 --no-pager
        exit 1
    fi
}

cmd_status() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ArchibaldOS DSP Coprocessor VM Status${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Service status
    if systemctl is-active --quiet "$VM_SERVICE"; then
        print_success "Service: ACTIVE"
    else
        print_error "Service: INACTIVE"
    fi
    
    # QEMU process
    local qemu_pid=$(pgrep -f "qemu-system-x86_64.*archibaldos" || echo "")
    if [[ -n "$qemu_pid" ]]; then
        local cpu_usage=$(ps -p "$qemu_pid" -o %cpu= | xargs)
        local mem_usage=$(ps -p "$qemu_pid" -o rss= | awk '{printf "%.1f", $1/1024}')
        print_success "QEMU Process: PID $qemu_pid (CPU: ${cpu_usage}%, MEM: ${mem_usage}MB)"
    else
        print_error "QEMU Process: NOT RUNNING"
    fi
    
    # Disk image
    if [[ -f "$VM_IMAGE" ]]; then
        local disk_size=$(du -h "$VM_IMAGE" | cut -f1)
        local disk_mtime=$(stat -c %y "$VM_IMAGE" | cut -d'.' -f1)
        print_success "Disk Image: $disk_size (last modified: $disk_mtime)"
    else
        print_error "Disk Image: NOT FOUND"
    fi
    
    # Serial log
    if [[ -f "$SERIAL_LOG" ]]; then
        local log_size=$(du -h "$SERIAL_LOG" | cut -f1)
        print_success "Serial Log: $log_size"
    else
        print_warning "Serial Log: NOT FOUND"
    fi
    
    # Monitor socket
    if [[ -S "$MONITOR_SOCK" ]]; then
        print_success "Monitor Socket: AVAILABLE"
    else
        print_warning "Monitor Socket: NOT FOUND"
    fi
    
    # Network ports
    echo ""
    print_status "Network Ports:"
    if ss -tlnp | grep -q ":4713"; then
        print_success "  NETJACK (4713): LISTENING"
    else
        print_warning "  NETJACK (4713): NOT LISTENING"
    fi
    
    # VFIO devices
    echo ""
    print_status "VFIO Passthrough:"
    if lspci -nnk | grep -A 3 "c7:00.3" | grep -q "vfio-pci"; then
        print_success "  USB Controller 1 (c7:00.3): BOUND"
    else
        print_warning "  USB Controller 1 (c7:00.3): NOT BOUND"
    fi
    
    if lspci -nnk | grep -A 3 "c7:00.4" | grep -q "vfio-pci"; then
        print_success "  USB Controller 2 (c7:00.4): BOUND"
    else
        print_warning "  USB Controller 2 (c7:00.4): NOT BOUND"
    fi
    
    echo ""
}

cmd_logs() {
    if [[ ! -f "$SERIAL_LOG" ]]; then
        print_error "Serial log not found: $SERIAL_LOG"
        exit 1
    fi
    
    print_status "Tailing serial console logs (Ctrl+C to exit)..."
    echo ""
    sudo tail -f "$SERIAL_LOG"
}

cmd_monitor() {
    if [[ ! -S "$MONITOR_SOCK" ]]; then
        print_error "Monitor socket not found: $MONITOR_SOCK"
        print_warning "Is the VM running?"
        exit 1
    fi
    
    print_status "Opening QEMU monitor (type 'quit' to exit)..."
    echo ""
    echo "Common commands:"
    echo "  info status    - VM state"
    echo "  info block     - Disk devices"
    echo "  info network   - Network devices"
    echo "  info vnc       - VNC server status"
    echo "  system_reset   - Reset VM"
    echo "  quit           - Exit monitor"
    echo ""
    sudo socat - UNIX-CONNECT:"$MONITOR_SOCK"
}

cmd_rebuild() {
    print_status "Rebuilding DSP VM image from ArchibaldOS flake..."
    echo ""
    
    if [[ ! -d "$ARCHIBALDOS_DIR" ]]; then
        print_error "ArchibaldOS directory not found: $ARCHIBALDOS_DIR"
        exit 1
    fi
    
    cd "$ARCHIBALDOS_DIR"
    
    print_status "Building qcow2 image..."
    nix build .#dsp-vm-qcow2 --out-link result-dsp-vm
    
    print_status "Copying image to $VM_IMAGE..."
    sudo cp result-dsp-vm/nixos.qcow2 "$VM_IMAGE"
    sudo chown asher:users "$VM_IMAGE"
    
    print_success "Image rebuilt successfully"
    echo ""
    print_warning "Restart the VM to use the new image:"
    echo "  oligarchy-dsp restart"
}

cmd_vnc() {
    print_warning "VNC is not enabled in the current configuration"
    echo ""
    echo "To enable VNC, edit vm-manager/modules/dsp-vm.nix and set:"
    echo "  vnc = true;"
    echo ""
    echo "Then rebuild the host configuration:"
    echo "  sudo nixos-rebuild switch --flake .#nixos"
}

cmd_help() {
    echo "ArchibaldOS DSP Coprocessor VM Manager"
    echo ""
    echo "Usage: oligarchy-dsp <command>"
    echo ""
    echo "Commands:"
    echo "  start    - Start the DSP VM"
    echo "  stop     - Stop the DSP VM"
    echo "  restart  - Restart the DSP VM"
    echo "  status   - Show VM status and diagnostics"
    echo "  logs     - Tail serial console logs"
    echo "  monitor  - Open QEMU monitor console"
    echo "  rebuild  - Rebuild VM image from ArchibaldOS flake"
    echo "  vnc      - Connect via VNC (if enabled)"
    echo "  help     - Show this help message"
    echo ""
    echo "Examples:"
    echo "  oligarchy-dsp status"
    echo "  oligarchy-dsp logs"
    echo "  oligarchy-dsp rebuild"
    echo ""
}

# Main command dispatcher
case "${1:-help}" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs
        ;;
    monitor)
        cmd_monitor
        ;;
    rebuild)
        cmd_rebuild
        ;;
    vnc)
        cmd_vnc
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        print_error "Unknown command: $1"
        echo ""
        cmd_help
        exit 1
        ;;
esac
