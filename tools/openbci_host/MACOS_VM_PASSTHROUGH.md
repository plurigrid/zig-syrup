# macOS VM with OpenBCI Hardware Passthrough - Complete Guide

This guide covers setting up a virtual machine on macOS with hardware passthrough for OpenBCI devices (Cyton, Ganglion).

## Table of Contents

1. [Overview](#overview)
2. [Comparison of Approaches](#comparison-of-approaches)
3. [Recommended Solution: UTM](#recommended-solution-utm)
4. [Alternative: Linux VM](#alternative-linux-vm)
5. [BLE Bridge Solution](#ble-bridge-solution)
6. [USB/IP Solution](#usbip-solution)
7. [Troubleshooting](#troubleshooting)
8. [Security Considerations](#security-considerations)

---

## Overview

Running OpenBCI hardware in a VM requires special handling because:
- **USB Serial Devices** (Cyton dongle): Can be passed through using USB filters
- **Bluetooth LE Devices** (Ganglion): Cannot be directly passed through; requires a bridge

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           macOS Host (Apple Silicon)                         │
│                                                                              │
│  ┌─────────────────┐     ┌─────────────────┐     ┌──────────────────┐     │
│  │  OpenBCI Cyton  │     │ Ganglion BLE    │     │  UTM / Lima VM   │     │
│  │  USB Dongle     │     │ Board           │     │  (macOS/Linux)   │     │
│  │                 │     │                 │     │                  │     │
│  │  VID: 0x0403    │     │  Needs bleak    │     │  ┌────────────┐  │     │
│  │  PID: 0x6001    │     │  on host        │     │  │ OpenBCI    │  │     │
│  └────────┬────────┘     └────────┬────────┘     │  │ GUI/CLI    │  │     │
│           │                       │              │  └─────┬──────┘  │     │
│           │ USB Passthrough       │ BLE Bridge   │        │         │     │
│           │ (UTM/Lima)            │ (Python)     │        │         │     │
│           ▼                       ▼              │        ▼         │     │
│  ┌─────────────────────────────────────────┐    │  ┌────────────┐  │     │
│  │  Virtual USB Controller                 │    │  │ ble_bridge │  │     │
│  │  (qemu-xhci)                            │    │  │ (TCP/VM)   │  │     │
│  └─────────────────────────────────────────┘    │  └────────────┘  │     │
│                                                 └──────────────────┘     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Comparison of Approaches

| Approach | Best For | USB | BLE | Complexity | Cost |
|----------|----------|-----|-----|------------|------|
| **UTM + macOS** | GUI users | ✅ Yes | ⚠️ Bridge | Medium | Free |
| **Lima + Linux** | Developers | ✅ Yes | ⚠️ Bridge | Low | Free |
| **UTM + Linux** | Flexibility | ✅ Yes | ⚠️ Bridge | Medium | Free |
| **Docker (privileged)** | Quick tests | ⚠️ Limited | ❌ No | Low | Free |
| **Parallels/VMware** | Enterprise | ✅ Yes | ❌ No | Low | Paid |

---

## Recommended Solution: UTM

UTM is the recommended free solution for running a macOS guest with OpenBCI hardware.

### Prerequisites

- macOS 13+ (Ventura or later)
- Apple Silicon Mac (M1/M2/M3)
- 16GB+ RAM recommended (8GB minimum)
- 100GB+ free disk space

### Installation Steps

#### 1. Install UTM

```bash
# Using Homebrew
brew install --cask utm

# Or download from https://mac.getutm.app/
```

#### 2. Download macOS IPSW

```bash
# Get latest macOS restore image for Apple Silicon
# Visit: https://ipsw.me/VirtualMac2,1

# Or use this direct link pattern (check for latest version):
curl -O https://updates.cdn-apple.com/2024FallFCS/fullrestores/072-01350/F64ACC.../UniversalMac_15.1.1_24B91_Restore.ipsw
```

#### 3. Create VM

**Option A: Using the setup script**

```bash
cd tools/openbci_host
chmod +x setup_utm_vm.sh
./setup_utm_vm.sh "OpenBCI-macOS" /path/to/UniversalMac.ipsw
```

**Option B: Manual setup**

1. Open UTM → "Create a New Virtual Machine"
2. Select **"Virtualize"** (not "Emulate")
3. Select **"macOS"**
4. Choose your downloaded IPSW file
5. Configure:
   - **Memory**: 8192 MB (8GB) or more
   - **CPU Cores**: 4
   - **Storage**: 64GB minimum
6. Complete setup and start VM

#### 4. Configure USB Passthrough

1. **Shut down** the VM (not suspend)
2. Select VM → **Settings** → **USB**
3. Click **+** to add USB filter:

| Setting | Value |
|---------|-------|
| Vendor ID | 1027 (0x0403) |
| Product ID | 24577 (0x6001) |
| Name | OpenBCI Cyton |

4. Enable **"Share USB device with VM"**
5. Save and start VM

#### 5. Install OpenBCI Software in VM

```bash
# Inside the VM, open Terminal
# Download OpenBCI GUI
curl -L -o OpenBCI_GUI.zip \
  "https://github.com/OpenBCI/OpenBCI_GUI/releases/latest/download/OpenBCI_GUI-mac.zip"

# Or install via Homebrew
brew install --cask openbci-gui
```

#### 6. Verify Device Passthrough

```bash
# In the VM Terminal, check USB devices:
system_profiler SPUSBDataType | grep -A10 "OpenBCI\|FT232"

# Should show:
# FT232R USB UART:
#   Product ID: 0x6001
#   Vendor ID: 0x0403 (Future Technology Devices International Limited)
```

---

## Alternative: Linux VM

For headless/server use cases, a Linux VM is more efficient.

### Using Lima (Recommended for Developers)

```bash
# Install Lima
brew install lima

# Create VM with our config
cd tools/openbci_host
limactl start --name=openbci ./create_linux_vm.sh lima

# Access VM shell
limactl shell openbci

# Check USB devices
lsusb
ls /dev/ttyUSB*
```

### Using Docker (Quick Test)

```bash
# Build container
docker build -f Dockerfile.bci-vm -t openbci-processor .

# Run with USB access (requires --privileged)
docker run -it --rm \
  --privileged \
  -v /dev:/dev \
  --network host \
  openbci-processor

# Inside container:
lsusb
ls /dev/ttyUSB*
```

---

## BLE Bridge Solution

Bluetooth LE devices **cannot** be directly passed through to VMs. Use this bridge solution.

### How It Works

```
┌─────────────┐      BLE       ┌─────────────┐      TCP       ┌─────────────┐
│   Ganglion  │◄──────────────►│  ble_bridge │◄──────────────►│  VM Client  │
│    Board    │   (host only)  │   (host)    │   (network)    │   (in VM)   │
└─────────────┘                └─────────────┘                └─────────────┘
```

### Setup

#### 1. Install Dependencies on Host

```bash
pip3 install bleak numpy asyncio
```

#### 2. Start BLE Bridge Server (on Host)

```bash
cd tools/openbci_host

# Scan for Ganglion devices first
python3 ble_bridge.py --mode scan

# Start bridge server
python3 ble_bridge.py --mode server --port 12345
```

#### 3. Connect Client in VM

```bash
# Inside VM, connect to bridge
python3 ble_bridge.py --mode client --host host.lan --port 12345

# Or use the simple TCP client
nc host.lan 12345 | tee eeg_data.csv
```

### Data Format

The bridge outputs data in JSON format:

```json
{
  "timestamp": 1704501234.567,
  "sample_number": 1234,
  "channel_data": [12.34, -5.67, 8.90, -1.23],
  "packet_type": "standard"
}
```

Or CSV format with `--format csv`:

```
1234,12.34,-5.67,8.90,-1.23,1704501234.567
```

---

## USB/IP Solution

USB/IP allows sharing USB devices over the network from host to VM.

### When to Use

- Multiple VMs need same device (not simultaneously)
- Device is physically distant from VM
- Native passthrough not working

### Setup

#### 1. Start USB/IP Server (on Host)

```bash
cd tools/openbci_host

# List available devices
python3 usbip_server.py --list

# Start server
python3 usbip_server.py --auto --port 3240
```

#### 2. Attach Device in VM

```bash
cd tools/openbci_host

# Setup USB/IP client
sudo ./usbip_client.sh setup

# List remote devices
./usbip_client.sh list <host-ip>

# Attach device
sudo ./usbip_client.sh attach <host-ip> <busid>

# Example:
sudo ./usbip_client.sh attach 192.168.1.100 1-1

# Verify
lsusb
ls /dev/ttyUSB*
```

### Docker Compose with USB/IP

```yaml
# docker-compose.yml
version: '3.8'
services:
  openbci-processor:
    build: .
    privileged: true
    network_mode: host
    environment:
      - USBIP_HOST=host.docker.internal
    volumes:
      - /dev:/dev
    command: >
      bash -c "
        /usr/local/bin/usbip_client.sh setup &&
        /usr/local/bin/usbip_client.sh attach-all &&
        sleep infinity
      "
```

---

## Troubleshooting

### USB Device Not Appearing in VM

1. **Check host recognition**:
   ```bash
   # On host
   system_profiler SPUSBDataType | grep -A5 "OpenBCI"
   ls /dev/cu.usbserial-*
   ```

2. **Ensure VM is fully shut down** (not suspended) before changing USB settings

3. **Try different USB port** (direct to Mac, not through hub)

4. **Reset USB in UTM**:
   - VM Settings → USB → Remove and re-add filter
   - Check "Force device sharing"

5. **Use USB/IP as fallback**:
   ```bash
   # Host
   python3 usbip_server.py --auto
   
   # VM
   sudo ./usbip_client.sh attach-all
   ```

### Serial Port Permission Denied

```bash
# In Linux VM
sudo usermod -aG dialout $USER
sudo usermod -aG plugdev $USER

# Or set udev rules
sudo tee /etc/udev/rules.d/99-openbci.rules << 'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="0403", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", MODE="0666"
EOF
sudo udevadm control --reload-rules
```

### BLE Bridge Connection Fails

1. **Check firewall**:
   ```bash
   # On host (macOS)
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add $(which python3)
   ```

2. **Verify bleak installation**:
   ```bash
   python3 -c "import bleak; print(bleak.__version__)"
   ```

3. **Test BLE directly**:
   ```bash
   python3 ble_bridge.py --mode scan
   ```

### Performance Issues

| Issue | Solution |
|-------|----------|
| High latency | Enable memory ballooning in VM settings |
| Frame drops | Increase VM CPU cores to 4+ |
| Buffer overflow | Increase serial buffer size: `stty -F /dev/ttyUSB0 115200 cs8 -ixon` |

### VM Won't Start

```bash
# Check UTM logs
# Help → Send Feedback → View Logs

# Common fixes:
# 1. Re-download IPSW (may be corrupted)
# 2. Reduce memory allocation
# 3. Enable "Use Hypervisor" in VM settings
# 4. Clear UTM cache: rm -rf ~/Library/Containers/com.utmapp.UTM/Data/Library/Caches
```

---

## Security Considerations

### Network Exposure

- **USB/IP**: Exposes USB devices over network. Use only on trusted networks.
- **BLE Bridge**: Use firewall rules to restrict access.

```bash
# macOS firewall: Allow only local network
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add $(which python3)
# Then configure in System Preferences → Security → Firewall
```

### Privileged Containers

Docker with `--privileged` and `/dev` mount is powerful but reduces isolation:

```bash
# More restrictive alternative:
docker run --device=/dev/ttyUSB0:/dev/ttyUSB0 ...
```

### Data Privacy

EEG data is sensitive biometric information:
- Encrypt data at rest: `gpg -c eeg_data.csv`
- Use secure network protocols: SSH tunnel, VPN
- Clear data after processing: `shred -u eeg_data.csv`

---

## Quick Reference

### Common Commands

```bash
# UTM Control
vz start OpenBCI-macOS
vz stop OpenBCI-macOS
vz shell OpenBCI-macOS

# USB/IP
python3 usbip_server.py --auto &
sudo ./usbip_client.sh attach-all

# BLE Bridge
python3 ble_bridge.py --mode server &
python3 ble_bridge.py --mode client --host host.lan

# Serial Port
stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb
cat /dev/ttyUSB0 | tee data.csv
```

### File Locations

| File | Purpose |
|------|---------|
| `setup_utm_vm.sh` | UTM VM setup script |
| `utm_config.plist` | UTM configuration template |
| `ble_bridge.py` | BLE proxy for Ganglion |
| `usbip_server.py` | USB device sharing server |
| `usbip_client.sh` | USB/IP client for VM |
| `create_linux_vm.sh` | Linux VM creator |

---

## Resources

- [UTM Documentation](https://docs.getutm.app/)
- [OpenBCI Docs](https://docs.openbci.com/)
- [USB/IP Protocol](https://www.kernel.org/doc/html/latest/usb/usbip_protocol.html)
- [Apple Virtualization Framework](https://developer.apple.com/documentation/virtualization)

---

*Last updated: 2024*
