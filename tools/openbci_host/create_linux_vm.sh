#!/bin/bash
#
# create_linux_vm.sh - Create Linux VM with USB passthrough using vz/Apple Containerization
#
# This script creates a Linux VM optimized for OpenBCI data processing using
# Apple's native virtualization framework with custom USB passthrough support.
#
# Requirements:
#   - macOS 13+ with Apple Silicon
#   - apple/containerization or vz CLI tools
#   - Enough disk space for VM image
#
# Usage:
#   ./create_linux_vm.sh [vm_name] [disk_size_gb]

set -euo pipefail

# Configuration
VM_NAME="${1:-openbci-processor}"
DISK_GB="${2:-40}"
MEMORY_GB="${3:-4}"
CPU_COUNT="${4:-4}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"

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

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check macOS version
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script requires macOS"
        exit 1
    fi
    
    local macos_version
    macos_version=$(sw_vers -productVersion)
    local major_version
    major_version=$(echo "$macos_version" | cut -d. -f1)
    
    if [[ "$major_version" -lt 13 ]]; then
        log_error "macOS 13+ required for Apple Virtualization framework"
        exit 1
    fi
    
    # Check architecture
    if [[ "$(uname -m)" != "arm64" ]]; then
        log_warn "This script is optimized for Apple Silicon (arm64)"
    fi
    
    # Check available tools
    if command -v vz &> /dev/null; then
        log_success "Found: vz CLI"
        TOOL="vz"
    elif command -v tart &> /dev/null; then
        log_success "Found: tart"
        TOOL="tart"
    elif command -v limactl &> /dev/null; then
        log_success "Found: lima"
        TOOL="lima"
    else
        log_warn "No VM management tool found"
        log_info "Will use Docker/Podman with --privileged for USB access"
        TOOL="docker"
    fi
    
    # Check container tools
    if command -v docker &> /dev/null; then
        log_success "Found: Docker"
    elif command -v podman &> /dev/null; then
        log_success "Found: Podman"
    else
        log_warn "No container runtime found"
    fi
    
    log_success "Prerequisites check complete (tool: $TOOL)"
}

# Download Ubuntu cloud image
download_image() {
    local image_file="ubuntu-${UBUNTU_VERSION}-arm64.img"
    local image_url="https://cloud-images.ubuntu.com/minimal/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-minimal-cloudimg-arm64.img"
    
    if [[ -f "$image_file" ]]; then
        log_info "Using existing image: $image_file"
        return 0
    fi
    
    log_info "Downloading Ubuntu ${UBUNTU_VERSION} ARM64 cloud image..."
    log_info "URL: $image_url"
    
    if command -v curl &> /dev/null; then
        curl -L -o "$image_file" "$image_url" --progress-bar
    elif command -v wget &> /dev/null; then
        wget -O "$image_file" "$image_url"
    else
        log_error "Neither curl nor wget found"
        exit 1
    fi
    
    log_success "Downloaded: $image_file"
}

# Create cloud-init configuration
create_cloud_init() {
    log_info "Creating cloud-init configuration..."
    
    mkdir -p cloud-init
    
    # User data
    cat > cloud-init/user-data << 'EOF'
#cloud-config
hostname: openbci-processor
manage_etc_hosts: true
users:
  - name: bciuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin, dialout, plugdev
    home: /home/bciuser
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: 'openbci'
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID placeholder

packages:
  - python3
  - python3-pip
  - python3-venv
  - usbutils
  - libusb-1.0-0
  - udev
  - linux-tools-generic
  - curl
  - wget
  - netcat-traditional
  - socat
  - git
  - build-essential
  - libatlas-base-dev

runcmd:
  # Setup USB device permissions
  - echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6001", MODE="0666", GROUP="dialout"' > /etc/udev/rules.d/99-openbci.rules
  - udevadm control --reload-rules
  - udevadm trigger
  
  # Install Python packages
  - pip3 install pyserial pyusb numpy scipy pandas pyedflib
  
  # Setup USB/IP client
  - modprobe usbip-core || true
  - modprobe vhci-hcd || true
  
  # Create app directory
  - mkdir -p /app/data /app/logs
  - chown -R bciuser:bciuser /app

final_message: "OpenBCI Processor VM ready"
EOF
    
    # Meta data
    cat > cloud-init/meta-data << EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF
    
    # Network config
    cat > cloud-init/network-config << 'EOF'
version: 2
ethernets:
  eth0:
    dhcp4: true
    dhcp6: true
EOF
    
    log_success "Cloud-init configuration created"
}

# Create VM using vz
create_vm_vz() {
    log_info "Creating VM using vz..."
    
    if ! command -v vz &> /dev/null; then
        log_error "vz not installed. Install with: brew install vz"
        exit 1
    fi
    
    # Check if VM exists
    if vz list | grep -q "$VM_NAME"; then
        log_warn "VM $VM_NAME already exists"
        read -p "Delete and recreate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            vz stop "$VM_NAME" 2>/dev/null || true
            vz delete "$VM_NAME"
        else
            log_info "Using existing VM"
            return 0
        fi
    fi
    
    # Create cloud-init ISO
    local ci_iso="${VM_NAME}-cidata.iso"
    if command -v mkisofs &> /dev/null || command -v genisoimage &> /dev/null; then
        log_info "Creating cloud-init ISO..."
        mkisofs -output "$ci_iso" -volid cidata -joliet -rock cloud-init/ 2>/dev/null || \
        genisoimage -output "$ci_iso" -volid cidata -joliet -rock cloud-init/
    else
        log_warn "mkisofs not available, cloud-init may not work"
        ci_iso=""
    fi
    
    # Prepare disk image
    local disk_img="${VM_NAME}.raw"
    if [[ ! -f "$disk_img" ]]; then
        log_info "Preparing disk image (${DISK_GB}GB)..."
        cp "ubuntu-${UBUNTU_VERSION}-arm64.img" "$disk_img"
        qemu-img resize "$disk_img" "${DISK_GB}G" 2>/dev/null || {
            log_warn "qemu-img not available, using truncate"
            truncate -s "${DISK_GB}G" "$disk_img"
        }
    fi
    
    # Create VM
    log_info "Creating VM with vz..."
    vz create "$VM_NAME" \
        --memory "${MEMORY_GB}G" \
        --cpu "$CPU_COUNT" \
        --disk "$disk_img" \
        ${ci_iso:+--cdrom "$ci_iso"} \
        --network shared \
        2>/dev/null || {
        log_error "Failed to create VM with vz"
        log_info "Falling back to manual vz configuration..."
        show_vz_manual_setup
        return 1
    }
    
    log_success "VM created: $VM_NAME"
    
    # Start VM
    log_info "Starting VM..."
    vz start "$VM_NAME"
    
    # Show info
    sleep 5
    vz show "$VM_NAME" 2>/dev/null || true
}

# Create VM using lima
create_vm_lima() {
    log_info "Creating VM using Lima..."
    
    if ! command -v limactl &> /dev/null; then
        log_error "Lima not installed. Install with: brew install lima"
        exit 1
    fi
    
    # Create lima config
    cat > "${VM_NAME}.yaml" << EOF
# Lima configuration for OpenBCI Processor
vmType: vz
rosetta:
  enabled: true
  binfmt: true
images:
  - location: "https://cloud-images.ubuntu.com/minimal/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-minimal-cloudimg-arm64.img"
    arch: "aarch64"
mounts:
  - location: "~"
    writable: true
  - location: "/tmp/lima"
    writable: true
containerd:
  system: false
  user: false
provision:
  - mode: system
    script: |
      #!/bin/bash
      apt-get update
      apt-get install -y python3 python3-pip usbutils libusb-1.0-0 linux-tools-generic
      pip3 install pyserial pyusb numpy scipy pandas
      
      # USB device rules
      cat > /etc/udev/rules.d/99-openbci.rules << 'UDEVRULES'
SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6001", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", MODE="0666"
UDEVRULES
      udevadm control --reload-rules
probe:
  - script: |
      #!/bin/bash
      python3 --version | grep "Python 3"
      pip3 list | grep pyserial
EOF
    
    # Create and start VM
    limactl start --name="$VM_NAME" "${VM_NAME}.yaml"
    
    log_success "Lima VM created and started"
    log_info "Shell access: limactl shell $VM_NAME"
}

# Create Docker-based solution
create_docker_solution() {
    log_info "Creating Docker-based solution..."
    
    # Create Dockerfile for BCI processor
    cat > Dockerfile.bci-vm << 'EOF'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install dependencies
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-venv \
    usbutils libusb-1.0-0 udev \
    linux-tools-usbip usbip \
    socat netcat-traditional \
    curl wget git \
    build-essential \
    libatlas-base-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN pip3 install --break-system-packages \
    pyserial pyusb pylibftdi \
    numpy scipy pandas \
    pylsl pyedflib mne

# USB device rules
RUN echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="0403", MODE="0666"' \
    > /etc/udev/rules.d/99-openbci.rules

# Create user
RUN groupadd -r bciuser && \
    useradd -r -g bciuser -m -s /bin/bash bciuser && \
    usermod -aG dialout,plugdev bciuser

WORKDIR /app

# Copy USB/IP client
COPY usbip_client.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/usbip_client.sh

# Entry point
COPY <<'ENTRYSCRIPT' /entrypoint.sh
#!/bin/bash
set -e

# Setup USB/IP
echo "Setting up USB/IP client..."
/usr/local/bin/usbip_client.sh setup || true

# Show status
echo ""
echo "Container Status:"
echo "================="
lsusb 2>/dev/null || echo "No USB devices visible (may need --privileged)"
echo ""
echo "Serial devices:"
ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "None"
echo ""

# Keep container running
exec "$@"
ENTRYSCRIPT
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
EOF

    # Create docker-compose
    cat > docker-compose.bci.yml << 'EOF'
version: '3.8'

services:
  openbci-processor:
    build:
      context: .
      dockerfile: Dockerfile.bci-vm
    container_name: openbci-processor
    privileged: true  # Required for USB device access
    volumes:
      - /dev:/dev
      - ./data:/app/data
      - ./scripts:/app/scripts
    environment:
      - USBIP_HOST=host.docker.internal
      - USBIP_PORT=3240
    network_mode: host  # For USB/IP communication
    stdin_open: true
    tty: true
    command: sleep infinity

  # USB/IP client sidecar
  usbip-client:
    build:
      context: .
      dockerfile: Dockerfile.bci-vm
    container_name: openbci-usbip
    privileged: true
    network_mode: host
    environment:
      - USBIP_HOST=host.docker.internal
      - USBIP_PORT=3240
    command: >
      bash -c "
        /usr/local/bin/usbip_client.sh setup &&
        /usr/local/bin/usbip_client.sh attach-all &&
        sleep infinity
      "
    depends_on:
      - openbci-processor
EOF

    log_success "Docker configuration created"
    log_info "Build and run with:"
    log_info "  docker-compose -f docker-compose.bci.yml up -d"
    log_info "  docker exec -it openbci-processor bash"
}

# Show vz manual setup
show_vz_manual_setup() {
    cat << 'EOF'

╔══════════════════════════════════════════════════════════════════════════════╗
║                       vz Manual Setup Instructions                            ║
╚══════════════════════════════════════════════════════════════════════════════╝

1. INSTALL VZ
   brew install vz

2. DOWNLOAD UBUNTU CLOUD IMAGE
   curl -O https://cloud-images.ubuntu.com/minimal/releases/24.04/release/\
ubuntu-24.04-minimal-cloudimg-arm64.img

3. PREPARE DISK IMAGE
   cp ubuntu-24.04-minimal-cloudimg-arm64.img openbci.raw
   qemu-img resize openbci.raw 40G

4. CREATE CLOUD-INIT ISO
   mkdir -p cloud-init
   # Create user-data and meta-data files
   mkisofs -output cidata.iso -volid cidata -joliet -rock cloud-init/

5. CREATE AND START VM
   vz create openbci-processor \
     --memory 4G \
     --cpu 4 \
     --disk openbci.raw \
     --cdrom cidata.iso
   
   vz start openbci-processor

6. ACCESS VM
   vz show openbci-processor  # Get IP address
   ssh bciuser@<ip>

7. USB PASSTHROUGH
   USB passthrough requires additional configuration using:
   - USB/IP server on host (run usbip_server.py)
   - USB/IP client in VM (run usbip_client.sh)

═══════════════════════════════════════════════════════════════════════════════

EOF
}

# Generate helper scripts
generate_scripts() {
    log_info "Generating helper scripts..."
    
    # VM control script
    cat > "${VM_NAME}_control.sh" << 'EOF'
#!/bin/bash
# VM Control Script

VM_NAME="openbci-processor"

 case "${1:-status}" in
    start)
        vz start "$VM_NAME" 2>/dev/null || \
        limactl start "$VM_NAME"
        ;;
    stop)
        vz stop "$VM_NAME" 2>/dev/null || \
        limactl stop "$VM_NAME"
        ;;
    shell|ssh)
        vz shell "$VM_NAME" 2>/dev/null || \
        limactl shell "$VM_NAME"
        ;;
    ip)
        vz show "$VM_NAME" 2>/dev/null | grep -i ip || \
        limactl list "$VM_NAME" --format json 2>/dev/null | grep -i ip
        ;;
    status)
        vz list 2>/dev/null | grep "$VM_NAME" || \
        limactl list 2>/dev/null | grep "$VM_NAME" || \
        echo "VM status unknown"
        ;;
    usb-status)
        echo "USB/IP Status:"
        ./usbip_client.sh status
        ;;
    usb-attach)
        ./usbip_client.sh attach-all
        ;;
    *)
        echo "Usage: $0 {start|stop|shell|ip|status|usb-status|usb-attach}"
        ;;
esac
EOF
    chmod +x "${VM_NAME}_control.sh"
    
    # Serial forwarder
    cat > serial_forward.sh << 'EOF'
#!/bin/bash
# Forward serial data from VM to local port

VM_IP="${1:-$(./openbci-processor_control.sh ip | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')}"
REMOTE_PORT="${2:-12345}"
LOCAL_PORT="${3:-16572}"

echo "Forwarding $VM_IP:$REMOTE_PORT to localhost:$LOCAL_PORT"

socat TCP-LISTEN:$LOCAL_PORT,fork TCP:$VM_IP:$REMOTE_PORT
EOF
    chmod +x serial_forward.sh
    
    log_success "Helper scripts created"
}

# Main function
main() {
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║           Linux VM Creator for OpenBCI with USB Passthrough                 ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo
    
    check_prerequisites
    
    # Create working directory
    mkdir -p "${VM_NAME}_vm"
    cd "${VM_NAME}_vm"
    
    case "$TOOL" in
        vz)
            download_image
            create_cloud_init
            create_vm_vz
            ;;
        lima)
            create_vm_lima
            ;;
        docker)
            create_docker_solution
            ;;
        *)
            log_warn "No VM tool available, creating Docker solution only"
            create_docker_solution
            ;;
    esac
    
    generate_scripts
    
    echo
    log_success "Setup complete!"
    echo
    log_info "Next steps:"
    log_info "  1. Start the VM: ./${VM_NAME}_control.sh start"
    log_info "  2. Access shell: ./${VM_NAME}_control.sh shell"
    log_info "  3. For USB devices:"
    log_info "     - Start USB/IP server on host: python3 usbip_server.py"
    log_info "     - Attach in VM: ./usbip_client.sh attach-all"
    log_info "  4. For BLE devices:"
    log_info "     - Use ble_bridge.py on host"
    log_info "     - Connect VM client to bridge"
    echo
}

# Run main
main "$@"
