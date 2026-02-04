# OpenBCI Host Tools for macOS

Complete toolkit for OpenBCI hardware integration on macOS, including host acquisition, VM passthrough, and remote device access.

## Components

| Component | Description |
|-----------|-------------|
| **Host Acquisition** | Native macOS data acquisition with LSL/TCP streaming |
| **VM Passthrough** | Run OpenBCI hardware in VMs (UTM, Lima, Docker) |
| **BLE Bridge** | Proxy Ganglion BLE data to VMs over network |
| **USB/IP** | Share USB devices over network |

---

## Quick Navigation

- [Host Acquisition System](#host-acquisition-system) - Native macOS streaming
- [VM Passthrough Guide](MACOS_VM_PASSTHROUGH.md) - Complete VM setup guide
- [VM Options](vm_options.md) - Comparison of VM approaches

---

## Host Acquisition System

A complete host-side data acquisition and streaming system for OpenBCI devices on macOS.

### Features

- **Auto-Detection**: Automatically detects connected OpenBCI boards (Cyton USB or Ganglion BLE)
- **BrainFlow Integration**: Uses BrainFlow library for hardware communication
- **Dual Streaming**:
  - Lab Streaming Layer (LSL) on port 16571 for research applications
  - Raw TCP socket on port 16572 for custom integrations
- **Signal Quality Monitoring**: Real-time SNR, RMS, and impedance checking

### Supported Hardware

| Board | Connection | Channels | Sample Rate |
|-------|------------|----------|-------------|
| Cyton | USB Serial | 8 (16 w/ Daisy) | 250 Hz |
| Ganglion | Bluetooth LE | 4 | 200 Hz |

### Quick Start

```bash
cd tools/openbci_host

# Run system checks
./setup_host.sh --check-only

# Install with virtual environment (recommended)
./setup_host.sh --venv

# Run acquisition
python3 host_acquisition.py
```

See full [Host Acquisition Documentation](#host-acquisition-details) below.

---

## VM Passthrough Solutions

When you need to run OpenBCI software in an isolated environment (VM or container), use these tools:

### Comparison

| Approach | USB Passthrough | BLE Support | Best For |
|----------|-----------------|-------------|----------|
| UTM + macOS | ✅ Yes | ⚠️ Bridge | GUI users |
| Lima + Linux | ✅ Yes | ⚠️ Bridge | Developers |
| Docker | ⚠️ Limited | ❌ No | Quick tests |

### Quick Setup

#### UTM (Recommended)

```bash
# 1. Install UTM
brew install --cask utm

# 2. Download macOS IPSW from https://ipsw.me/VirtualMac2,1

# 3. Run setup script
./setup_utm_vm.sh "OpenBCI-macOS" /path/to/UniversalMac.ipsw
```

#### Linux VM with Lima

```bash
# Create and start VM
./create_linux_vm.sh openbci-processor

# Access VM
limactl shell openbci-processor
```

#### BLE Bridge (for Ganglion in VM)

```bash
# On host (has BLE hardware)
python3 ble_bridge.py --mode server --port 12345

# In VM (connects to bridge)
python3 ble_bridge.py --mode client --host host.lan --port 12345
```

#### USB/IP (for Cyton in VM)

```bash
# On host
python3 usbip_server.py --auto --port 3240

# In VM
sudo ./usbip_client.sh attach <host-ip> <busid>
```

---

## File Reference

| File | Purpose |
|------|---------|
| `host_acquisition.py` | Native macOS data acquisition |
| `setup_host.sh` | Host environment setup |
| `setup_utm_vm.sh` | UTM VM setup script |
| `create_linux_vm.sh` | Linux VM creator (Lima/vz/Docker) |
| `ble_bridge.py` | BLE proxy for Ganglion |
| `usbip_server.py` | USB device sharing server |
| `usbip_client.sh` | USB/IP client for VMs |
| `utm_config.plist` | UTM VM configuration template |
| `MACOS_VM_PASSTHROUGH.md` | Complete VM setup guide |
| `vm_options.md` | VM approach comparison |

---

## Host Acquisition Details

### Setup

```bash
cd tools/openbci_host

# Run system checks
./setup_host.sh --check-only

# Install with virtual environment (recommended)
./setup_host.sh --venv

# Or install globally
./setup_host.sh
```

### Run

```bash
# Auto-detect and run
python3 host_acquisition.py

# Manual Cyton configuration
python3 host_acquisition.py --board cyton --port /dev/tty.usbserial-XXXX

# Manual Ganglion configuration
python3 host_acquisition.py --board ganglion --mac XX:XX:XX:XX:XX:XX

# Verbose output
python3 host_acquisition.py -v
```

### Output

The script displays real-time status:

```
============================================================
  OpenBCI Host Acquisition System v1.0.0
  Platform: macOS
============================================================
🔍 Scanning for OpenBCI boards...
✅ Detected Cyton board on /dev/tty.usbserial-DM00D7PA
📋 Board Configuration:
   Type: cyton
   Sampling Rate: 250 Hz
   Channels: 8
🔌 Connecting to cyton...
✅ Board session prepared
✅ Board streaming started
✅ LSL stream started: 'OpenBCI-EEG'
✅ TCP server started on 0.0.0.0:16572

╔══════════════════════════════════════════════════════════╗
║      OpenBCI Host Acquisition System - RUNNING          ║
╠══════════════════════════════════════════════════════════╣
║ Board:        cyton              (8ch @ 250Hz)          ║
║ LSL Stream:   Active             (port 16571)           ║
║ TCP Socket:   Active             (port 16572)           ║
╠══════════════════════════════════════════════════════════╣
║ Press Ctrl+C to stop                                     ║
╚══════════════════════════════════════════════════════════╝
```

### Configuration

Edit `openbci_config.yaml` to customize:

- Board settings (type, channels, sampling rate)
- Serial port patterns for auto-detection
- LSL stream metadata
- TCP server configuration
- Signal processing options

### Streaming Endpoints

#### LSL Stream

- **Name**: `OpenBCI-EEG` (configurable)
- **Type**: `EEG`
- **Channels**: 8 (Cyton) or 4 (Ganglion)
- **Sample Rate**: 250 Hz (Cyton) or 200 Hz (Ganglion)
- **Format**: float32, microvolts

Connect from Python:
```python
from pylsl import StreamInlet, resolve_stream

streams = resolve_stream('name', 'OpenBCI-EEG')
inlet = StreamInlet(streams[0])

sample, timestamp = inlet.pull_sample()
print(f"Sample: {sample}, Timestamp: {timestamp}")
```

#### TCP Socket

- **Host**: `0.0.0.0` (or `127.0.0.1` for local only)
- **Port**: `16572`
- **Protocol**: JSON lines

Connect from Python:
```python
import socket, json

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('localhost', 16572))

# Receive header
header = json.loads(sock.recv(1024).decode().strip())
print(f"Stream info: {header}")

# Receive samples
buffer = ""
while True:
    data = sock.recv(1024).decode()
    buffer += data
    while '\n' in buffer:
        line, buffer = buffer.split('\n', 1)
        sample = json.loads(line)
        print(f"Timestamp: {sample['ts']}, Data: {sample['data']}")
```

### Signal Quality

The system continuously monitors:
- **SNR**: Signal-to-noise ratio in dB
- **RMS**: Root mean square amplitude in µV
- **Noise Floor**: High-frequency noise estimate
- **Impedance**: Electrode impedance (if supported)

Channels with SNR > 10 dB and reasonable amplitude (1-100 µV) are marked as "good".

### Troubleshooting

#### Board Not Detected

**Cyton (USB)**:
```bash
# List USB serial devices
ls -la /dev/tty.usbserial* /dev/cu.usbserial*

# Check USB device info
system_profiler SPUSBDataType | grep -A 10 "FTDI"
```

**Ganglion (BLE)**:
```bash
# Install blueutil for Bluetooth management
brew install blueutil

# Check Bluetooth status
blueutil --power
blueutil --inquiry
```

#### Permission Issues

USB serial devices on macOS are usually accessible without special permissions. If you encounter issues:

```bash
# Add user to dialout group (rarely needed on macOS)
sudo dscl . append /Groups/dialout GroupMembership $USER
```

#### BrainFlow Connection Issues

```bash
# Reset USB device (replace with your device path)
./setup_host.sh --check-only

# Reinstall BrainFlow
pip install --force-reinstall brainflow
```

---

## Dependencies

- **brainflow**: OpenBCI hardware interface
- **pylsl**: Lab Streaming Layer
- **pyserial**: USB serial communication
- **bleak**: Bluetooth LE (Ganglion)
- **pyyaml**: Configuration parsing
- **numpy**: Numerical processing

See `requirements-host.txt` for full list.

---

## License

MIT License - See LICENSE file in project root.
