#!/bin/bash
#
# setup_utm_vm.sh - Configure UTM VM for OpenBCI hardware passthrough
#
# This script helps set up a UTM virtual machine with USB passthrough
# for OpenBCI devices on Apple Silicon Macs.
#
# Usage: ./setup_utm_vm.sh [vm_name] [macos_ipsw_path]

set -euo pipefail

# Configuration
VM_NAME="${1:-OpenBCI-macOS}"
MACOS_IPSW="${2:-}"
MEMORY_GB="${3:-8}"
DISK_GB="${4:-64}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running on macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script must run on macOS"
        exit 1
    fi
    
    # Check if UTM is installed
    if ! command -v utmctl &> /dev/null; then
        log_error "UTM is not installed. Please install UTM from https://mac.getutm.app/"
        log_info "Or install via Homebrew: brew install --cask utm"
        exit 1
    fi
    
    # Check architecture
    ARCH=$(uname -m)
    if [[ "$ARCH" != "arm64" ]]; then
        log_warn "This script is optimized for Apple Silicon (arm64). Intel Macs may have different requirements."
    fi
    
    # Check available memory
    TOTAL_MEM=$(sysctl -n hw.memsize)
    TOTAL_MEM_GB=$((TOTAL_MEM / 1024 / 1024 / 1024))
    if [[ $TOTAL_MEM_GB -lt $MEMORY_GB ]]; then
        log_warn "System has ${TOTAL_MEM_GB}GB RAM, but VM is configured for ${MEMORY_GB}GB"
        log_warn "Consider reducing VM memory or closing other applications"
    fi
    
    log_success "Prerequisites check passed"
}

# Download macOS IPSW if not provided
download_macos_ipsw() {
    if [[ -z "$MACOS_IPSW" ]]; then
        log_info "No macOS IPSW provided. Attempting to download latest..."
        log_warn "Note: Downloading macOS IPSW requires significant disk space and time"
        
        # Get latest IPSW URL (this is a simplified example)
        log_info "Please download macOS IPSW manually from:"
        log_info "https://ipsw.me/VirtualMac2,1"
        log_info ""
        log_info "Then re-run this script with the IPSW path:"
        log_info "  ./setup_utm_vm.sh \"$VM_NAME\" /path/to/UniversalMac.ipsw"
        exit 1
    fi
    
    if [[ ! -f "$MACOS_IPSW" ]]; then
        log_error "IPSW file not found: $MACOS_IPSW"
        exit 1
    fi
    
    log_success "Using IPSW: $MACOS_IPSW"
}

# Create UTM VM configuration
create_vm() {
    log_info "Creating UTM VM: $VM_NAME"
    
    # Check if VM already exists
    if utmctl list | grep -q "$VM_NAME"; then
        log_warn "VM '$VM_NAME' already exists"
        read -p "Delete and recreate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            utmctl stop "$VM_NAME" 2>/dev/null || true
            sleep 2
            utmctl delete "$VM_NAME"
        else
            log_info "Using existing VM"
            return
        fi
    fi
    
    # Create VM using utmctl
    # Note: UTM 4.0+ supports command-line creation
    log_info "Creating VM with ${MEMORY_GB}GB RAM, ${DISK_GB}GB disk..."
    
    # Create VM configuration
    utmctl create "$VM_NAME" \
        --arch arm64 \
        --memory $((MEMORY_GB * 1024)) \
        --disk-size "${DISK_GB}G" \
        --macos "$MACOS_IPSW" 2>/dev/null || {
        log_warn "Command-line creation failed. Falling back to manual configuration guide."
        show_manual_setup
        exit 0
    }
    
    log_success "VM created successfully"
}

# Configure USB passthrough for OpenBCI devices
configure_usb_passthrough() {
    log_info "Configuring USB passthrough for OpenBCI devices..."
    
    # OpenBCI device USB IDs
    # Cyton dongle (FT232R USB UART)
    CYTON_VID="0403"
    CYTON_PID="6001"
    
    # Ganglion dongle (CSR8510 A10 - if using dongle)
    GANGLION_VID="0a12"
    GANGLION_PID="0001"
    
    # Alternative FTDI devices
    FTDI_VID="0403"
    
    log_info "USB device filter configuration:"
    log_info "  - Cyton: VID=${CYTON_VID}, PID=${CYTON_PID}"
    log_info "  - FTDI devices: VID=${FTDI_VID}"
    
    # Note: UTM uses QEMU's USB passthrough
    # The actual configuration is stored in the VM's plist file
    # This would require modifying UTM's internal configuration
    
    log_warn "USB passthrough must be configured in UTM GUI:"
    log_warn "  1. Open UTM and select '$VM_NAME'"
    log_warn "  2. Click 'Settings' → 'USB'"
    log_warn "  3. Add USB filter for OpenBCI devices:"
    log_warn "     - Vendor ID: 0403 (FTDI)"
    log_warn "     - Product ID: 6001 (FT232R)"
    log_warn "  4. Enable 'Share USB device with VM'"
}

# Generate UTM configuration plist
generate_utm_config() {
    local config_file="utm_config.plist"
    
    log_info "Generating UTM configuration: $config_file"
    
    cat > "$config_file" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- UTM VM Configuration for OpenBCI -->
    <key>ConfigurationVersion</key>
    <integer>4</integer>
    
    <key>Information</key>
    <dict>
        <key>Icon</key>
        <string>macOS</string>
        <key>IconCustom</key>
        <false/>
        <key>Name</key>
        <string>OpenBCI-macOS</string>
        <key>UUID</key>
        <string>OPENBCI-VM-UUID-PLACEHOLDER</string>
    </dict>
    
    <key>System</key>
    <dict>
        <key>Architecture</key>
        <string>arm64</string>
        <key>CPU</key>
        <string>default</string>
        <key>CPUCount</key>
        <integer>4</integer>
        <key>MemorySize</key>
        <integer>8192</integer>
        <key>Boot</key>
        <dict>
            <key>BootOrder</key>
            <array>
                <string>cd</string>
                <string>hd</string>
            </array>
            <key>UEFIBoot</key>
            <true/>
        </dict>
    </dict>
    
    <key>Display</key>
    <dict>
        <key>RetinaMode</key>
        <true/>
    </dict>
    
    <key>Input</key>
    <dict>
        <key>InputUSB</key>
        <array>
            <!-- OpenBCI Cyton FT232R USB UART -->
            <dict>
                <key>VendorID</key>
                <integer>1027</integer>
                <key>ProductID</key>
                <integer>24577</integer>
                <key>Name</key>
                <string>OpenBCI Cyton Dongle</string>
            </dict>
            <!-- FTDI Generic -->
            <dict>
                <key>VendorID</key>
                <integer>1027</integer>
                <key>Name</key>
                <string>FTDI Devices</string>
            </dict>
        </array>
    </dict>
    
    <key>Network</key>
    <dict>
        <key>NetworkEnabled</key>
        <true/>
        <key>NetworkMode</key>
        <string>shared</string>
    </dict>
    
    <key>Sharing</key>
    <dict>
        <key>ClipboardSharing</key>
        <true/>
        <key>DirectorySharing</key>
        <true/>
        <key>DirectorySharePath</key>
        <string>~/OpenBCI-Shared</string>
    </dict>
</dict>
</plist>
EOF
    
    log_success "Generated: $config_file"
    log_info "Import this configuration into UTM manually"
}

# Show manual setup instructions
show_manual_setup() {
    cat << 'EOF'

╔══════════════════════════════════════════════════════════════════════════════╗
║                    UTM Manual Setup Instructions                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

1. OPEN UTM APPLICATION
   - Download from: https://mac.getutm.app/
   - Or: brew install --cask utm

2. CREATE NEW VM
   - Click "Create a New Virtual Machine"
   - Select "Virtualize" (for Apple Silicon)
   - Select "macOS"

3. CONFIGURE MACOS
   - Select your IPSW file (download from ipsw.me)
   - Allocate RAM: 8GB recommended (minimum 4GB)
   - Allocate Storage: 64GB recommended

4. CONFIGURE USB PASSTHROUGH
   - Select VM → Settings → USB
   - Click "+" to add USB filter:
     
     For OpenBCI Cyton (FT232R):
     - Vendor ID: 0x0403 (1027)
     - Product ID: 0x6001 (24577)
     - Name: "OpenBCI Cyton"
     
     For Generic FTDI:
     - Vendor ID: 0x0403 (1027)
     - Leave Product ID empty

5. START VM AND COMPLETE MACOS SETUP
   - Follow macOS setup wizard
   - Install OpenBCI GUI from: https://openbci.com/downloads

6. VERIFY USB PASSTHROUGH
   In VM Terminal, run:
     system_profiler SPUSBDataType | grep -A5 "OpenBCI\|FT232"
   
   You should see the FT232R USB UART device listed.

7. OPTIONAL: SHARED FOLDER
   - Settings → Sharing → Directory Sharing
   - Enable for easy file transfer between host and VM

═══════════════════════════════════════════════════════════════════════════════

EOF
}

# Main execution
main() {
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║           UTM VM Setup for OpenBCI Hardware Passthrough                       ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo
    
    check_prerequisites
    download_macos_ipsw
    create_vm
    configure_usb_passthrough
    generate_utm_config
    
    echo
    log_success "Setup preparation complete!"
    echo
    log_info "Next steps:"
    log_info "  1. Open UTM application"
    log_info "  2. Import or create VM using settings above"
    log_info "  3. Configure USB passthrough for OpenBCI devices"
    log_info "  4. Install OpenBCI software in VM"
    echo
    log_info "For BLE devices (Ganglion), use ble_bridge.py instead of passthrough"
    echo
}

# Run main function
main "$@"
