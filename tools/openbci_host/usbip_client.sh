#!/bin/bash
#
# usbip_client.sh - USB/IP Client for Attaching Remote USB Devices
#
# This script runs inside the VM/container to connect to a USB/IP server
# and attach remote USB devices (like OpenBCI dongles).
#
# Requirements:
#   - Linux VM with usbip-client or usbutils
#   - Network access to USB/IP server
#
# Usage:
#   ./usbip_client.sh attach <server_host> <busid>
#   ./usbip_client.sh detach <busid>
#   ./usbip_client.sh list <server_host>

set -euo pipefail

# Configuration
USBIP_PORT="${USBIP_PORT:-3240}"
USBIP_HOST="${USBIP_HOST:-host.docker.internal}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if running as root (required for USB/IP)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (for USB/IP kernel module access)"
        log_info "Try: sudo $0 $*"
        return 1
    fi
}

# Check USB/IP prerequisites
check_prerequisites() {
    local missing=()
    
    # Check for usbip command
    if ! command -v usbip &> /dev/null; then
        missing+=("usbip")
    fi
    
    # Check for kernel module
    if [[ ! -d /sys/bus/usbip ]]; then
        log_warn "usbip kernel module not loaded"
        log_info "Attempting to load module..."
        modprobe usbip-core 2>/dev/null || true
        modprobe vhci-hcd 2>/dev/null || true
        
        if [[ ! -d /sys/bus/usbip ]]; then
            log_error "Failed to load usbip kernel module"
            missing+=("usbip-kernel-module")
        fi
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites: ${missing[*]}"
        show_install_help
        return 1
    fi
    
    return 0
}

# Show installation help
show_install_help() {
    cat << 'EOF'

USB/IP Installation Guide:

Ubuntu/Debian:
  sudo apt-get update
  sudo apt-get install linux-tools-generic usbutils
  sudo modprobe usbip-core
  sudo modprobe vhci-hcd

Fedora/RHEL:
  sudo dnf install usbip usbutils
  sudo modprobe usbip-core
  sudo modprobe vhci-hcd

Alpine (container):
  apk add usbip linux-tools-usbip
  modprobe usbip-core 2>/dev/null || true

macOS (host only):
  USB/IP server runs on macOS host
  Use this script in Linux VM only

EOF
}

# List devices on remote server
list_remote_devices() {
    local host="${1:-$USBIP_HOST}"
    
    log_info "Querying USB/IP server at $host:$USBIP_PORT..."
    
    if ! command -v usbip &> /dev/null; then
        # Fallback using netcat for basic protocol
        log_warn "usbip command not found, using basic protocol query"
        
        # Send USB/IP OP_REQ_DEVLIST command
        # Format: version (2) + command (2) + status (4) = 8 bytes
        printf '\x01\x11\x80\x05\x00\x00\x00\x00' | \
            nc -w 5 "$host" "$USBIP_PORT" 2>/dev/null | \
            xxd | head -50 || {
            log_error "Failed to connect to USB/IP server"
            return 1
        }
        return 0
    fi
    
    # Use native usbip command
    usbip list --remote="$host" || {
        log_error "Failed to list devices from $host"
        return 1
    }
}

# Attach remote device
attach_device() {
    local host="${1:-$USBIP_HOST}"
    local busid="${2:-}"
    
    if [[ -z "$busid" ]]; then
        log_error "Bus ID required for attach"
        log_info "Usage: $0 attach <host> <busid>"
        log_info "Example: $0 attach 192.168.1.100 1-1"
        
        # Show available devices
        log_info "Available devices on $host:"
        list_remote_devices "$host"
        return 1
    fi
    
    check_root || return 1
    check_prerequisites || return 1
    
    log_info "Attaching device $busid from $host..."
    
    # Attach using usbip
    if usbip attach --remote="$host" --busid="$busid" 2>/dev/null; then
        log_success "Device attached successfully"
        
        # Wait for device to appear
        sleep 2
        
        # Show attached device
        log_info "Attached USB devices:"
        lsusb | grep -v "Linux Foundation" || true
        
        # Show serial ports
        log_info "Serial ports:"
        ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true
        
        return 0
    else
        log_error "Failed to attach device"
        log_info "Make sure the device is not already attached"
        return 1
    fi
}

# Detach device
detach_device() {
    local port="${1:-}"
    
    check_root || return 1
    check_prerequisites || return 1
    
    if [[ -z "$port" ]]; then
        log_info "Listing attached devices:"
        usbip port || {
            log_warn "No devices attached or usbip error"
        }
        
        echo ""
        log_info "To detach, specify port number:"
        log_info "  $0 detach <port-number>"
        return 0
    fi
    
    log_info "Detaching device on port $port..."
    
    if usbip detach --port="$port"; then
        log_success "Device detached"
        return 0
    else
        log_error "Failed to detach device"
        return 1
    fi
}

# Attach all OpenBCI devices
attach_all() {
    local host="${1:-$USBIP_HOST}"
    
    log_info "Attaching all OpenBCI devices from $host..."
    
    check_root || return 1
    check_prerequisites || return 1
    
    # Get list of devices
    local devices
    devices=$(usbip list --remote="$host" 2>/dev/null | grep -E "^\s+[0-9-]+:" | awk '{print $1}' | tr -d ':') || true
    
    if [[ -z "$devices" ]]; then
        log_warn "No devices found on $host"
        return 1
    fi
    
    local attached=0
    for busid in $devices; do
        log_info "Attaching device: $busid"
        if usbip attach --remote="$host" --busid="$busid" 2>/dev/null; then
            ((attached++))
        fi
    done
    
    log_success "Attached $attached device(s)"
    
    # Show status
    sleep 2
    log_info "Attached devices:"
    lsusb | grep -v "Linux Foundation" || true
}

# Show status
show_status() {
    echo ""
    echo "USB/IP Client Status"
    echo "===================="
    echo ""
    
    # Check kernel modules
    echo "Kernel Modules:"
    if lsmod | grep -q usbip; then
        echo "  ✓ usbip-core loaded"
    else
        echo "  ✗ usbip-core NOT loaded"
    fi
    
    if lsmod | grep -q vhci_hcd; then
        echo "  ✓ vhci-hcd loaded"
    else
        echo "  ✗ vhci-hcd NOT loaded"
    fi
    
    echo ""
    echo "Attached Devices:"
    if command -v usbip &> /dev/null; then
        usbip port 2>/dev/null || echo "  None"
    else
        echo "  usbip command not available"
    fi
    
    echo ""
    echo "USB Serial Devices:"
    ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  None found"
    
    echo ""
}

# Setup script for running in container
setup_container() {
    log_info "Setting up USB/IP client in container..."
    
    # Install packages if needed
    if command -v apt-get &> /dev/null; then
        log_info "Installing usbip (Debian/Ubuntu)..."
        apt-get update -qq
        apt-get install -y -qq usbip usbutils 2>/dev/null || {
            log_warn "Failed to install via apt, trying alternative..."
        }
    elif command -v apk &> /dev/null; then
        log_info "Installing usbip (Alpine)..."
        apk add --no-cache usbip usbutils linux-tools-usbip 2>/dev/null || true
    elif command -v dnf &> /dev/null; then
        log_info "Installing usbip (Fedora)..."
        dnf install -y usbip usbutils 2>/dev/null || true
    fi
    
    # Try to load kernel module (may fail in unprivileged containers)
    log_info "Attempting to load kernel modules..."
    modprobe usbip-core 2>/dev/null || log_warn "Could not load usbip-core (may require --privileged)"
    modprobe vhci-hcd 2>/dev/null || log_warn "Could not load vhci-hcd (may require --privileged)"
    
    log_info "Setup complete. Run 'show' to check status."
}

# Main function
main() {
    local cmd="${1:-help}"
    shift || true
    
    case "$cmd" in
        list|ls)
            list_remote_devices "$@"
            ;;
        attach|a)
            attach_device "$@"
            ;;
        attach-all|aa)
            attach_all "$@"
            ;;
        detach|d)
            detach_device "$@"
            ;;
        status|show|s)
            show_status
            ;;
        setup)
            setup_container
            ;;
        help|-h|--help)
            cat << 'EOF'
USB/IP Client for OpenBCI Devices

Usage:
  $0 <command> [options]

Commands:
  list [host]           List devices on USB/IP server (default: host.docker.internal)
  attach <host> <busid> Attach specific device
  attach-all [host]     Attach all available devices
  detach [port]         Detach device (or list attached if no port specified)
  status                Show client status and attached devices
  setup                 Install prerequisites (for containers)
  help                  Show this help

Environment Variables:
  USBIP_HOST            Default host (default: host.docker.internal)
  USBIP_PORT            Default port (default: 3240)

Examples:
  # List devices on host
  $0 list 192.168.1.100

  # Attach OpenBCI dongle
  sudo $0 attach 192.168.1.100 1-1

  # Check status
  $0 status

  # Detach all
  sudo $0 detach

Note:
  This script requires root privileges for USB/IP kernel module access.
  In Docker containers, run with --privileged flag.

EOF
            ;;
        *)
            log_error "Unknown command: $cmd"
            log_info "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Run main
main "$@"
