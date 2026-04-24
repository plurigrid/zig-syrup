# BCI Data Processing Container

A containerized Brain-Computer Interface (BCI) data processing system designed for Apple's Containerization framework, implementing a **phased hypergraph processing pipeline** for real-time EEG analysis.

## Overview

This system runs inside a Linux container on macOS (Apple Containerization) and processes EEG data from OpenBCI hardware connected to the host machine via network protocols (LSL or TCP). No USB/Bluetooth access is required within the container.

## Architecture

### Phased Processing Pipeline

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Phase 1: RAW   │ →  │  Phase 2:       │ →  │  Phase 3:       │ →  │  Phase 4:       │
│   Ingestion     │    │   Filtering     │    │   Features      │    │  Classification │
│                 │    │                 │    │                 │    │                 │
│ • Circular      │    │ • Bandpass      │    │ • Band Powers   │    │ • Threshold     │
│   Buffer        │    │   1-50Hz        │    │ • Hjorth        │    │   Rules         │
│ • LSL/TCP       │    │ • Notch 60Hz    │    │   Parameters    │    │ • ML Classifier │
│   Input         │    │ • Artifact      │    │ • Spectral      │    │ • State         │
│                 │    │   Detection     │    │   Features      │    │   Detection     │
└─────────────────┘    └─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │                       │
         └───────────────────────┴───────────────────────┴───────────────────────┘
                                           │
                              ┌────────────┴────────────┐
                              │      OUTPUT LAYER       │
                              ├─────────────────────────┤
                              │ • LSL Output Stream     │
                              │ • WebSocket (Port 8080) │
                              │ • EDF+ Recording        │
                              └─────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `Containerfile.bci-processor` | Container definition (Ubuntu 24.04 base) |
| `container_receiver.py` | Main Python application with async processing |
| `processors/buffer.py` | Circular buffer for streaming data (Phase 1) |
| `processors/filter.py` | Real-time filtering (Phase 2) |
| `processors/features.py` | EEG feature extraction (Phase 3) |
| `processors/classifier.py` | State classification (Phase 4) |
| `start_processor.sh` | Container entrypoint script |
| `requirements-container.txt` | Python dependencies |
| `build_apple_container.sh` | Build script for Apple Containerization |
| `run_apple_container.sh` | Run script with network configuration |

## Quick Start

### 1. Build the Container

```bash
./build_apple_container.sh
```

Or manually:
```bash
container build -f Containerfile.bci-processor -t bci-processor:latest .
```

### 2. Run the Container

```bash
./run_apple_container.sh
```

This will:
- Start the container with proper network configuration
- Map ports for LSL (16571), TCP (16572), WebSocket (8080), and health checks (8081)
- Mount volumes for recordings and logs
- Wait for LSL stream from host

### 3. Verify Health

```bash
curl http://localhost:8081/health
```

## Network Configuration

The container communicates with the host via network:

| Port | Protocol | Purpose |
|------|----------|---------|
| 16571 | LSL | Lab Streaming Layer input/output |
| 16572 | TCP | Fallback TCP data stream |
| 8080 | WebSocket | Real-time visualization |
| 8081 | HTTP | Health check endpoint |

## Host Setup (macOS)

On the macOS host, you need to stream OpenBCI data to the container:

### Using Lab Streaming Layer (LSL)

1. Install pylsl on host:
```bash
pip install pylsl
```

2. Stream from OpenBCI GUI or Python script:
```python
from pylsl import StreamInfo, StreamOutlet
import openbci

# Create LSL stream
info = StreamInfo('OpenBCI', 'EEG', 8, 250, 'float32', 'openbci-cyton')
outlet = StreamInfo(info)

# Push samples as they arrive
while True:
    sample = board.get_sample()
    outlet.push_sample(sample)
```

### Using TCP Bridge

Create a simple TCP bridge on the host:
```python
import socket
import serial

# Connect to OpenBCI via serial
board = serial.Serial('/dev/cu.usbserial-*', 115200)

# Create TCP server
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.bind(('0.0.0.0', 16572))
server.listen(1)

conn, addr = server.accept()
while True:
    data = board.readline()
    conn.send(data)
```

## Configuration

Environment variables for container:

| Variable | Default | Description |
|----------|---------|-------------|
| `LSL_INPUT_NAME` | OpenBCI | Name of input LSL stream |
| `LSL_OUTPUT_NAME` | BCI-Processed | Name of output LSL stream |
| `WEBSOCKET_PORT` | 8080 | WebSocket server port |
| `HEALTH_PORT` | 8081 | Health check port |
| `RECORDING_DIR` | /app/data/recordings | EDF+ recording directory |
| `LOG_DIR` | /app/logs | Log directory |

## Processing Stages

### Phase 1: Raw Data Ingestion
- Circular buffer with configurable size
- LSL stream resolution by name or type
- Automatic sample rate detection
- Buffer readiness tracking

### Phase 2: Filtering
- Butterworth bandpass filter (1-50 Hz)
- Notch filter for 60 Hz mains interference
- Second-order sections (SOS) for numerical stability
- Real-time causal filtering with state preservation

### Phase 3: Feature Extraction

**Band Powers:**
- Delta (0.5-4 Hz)
- Theta (4-8 Hz)
- Alpha (8-13 Hz)
- Beta (13-30 Hz)
- Gamma (30-50 Hz)

**Hjorth Parameters:**
- Activity (signal variance)
- Mobility (mean frequency)
- Complexity (bandwidth)

**Spectral Features:**
- Spectral entropy
- Spectral edge frequency
- Spectral centroid
- Spectral flatness

**Statistical Features:**
- Mean, variance, standard deviation
- Skewness, kurtosis
- RMS, range

### Phase 4: Classification

**Brain States Detected:**
- `relaxed` - High alpha, low beta
- `focused` - Low theta/beta ratio
- `drowsy` - Increased theta
- `excited` - Increased beta/gamma
- `stressed` - High beta, low alpha
- `meditative` - High theta/alpha coherence

**Classification Methods:**
- Threshold-based rule system (default)
- Machine learning (scikit-learn)
- Hybrid approach

## WebSocket API

Real-time data is broadcast via WebSocket on port 8080:

```json
{
  "timestamp": 1234567890.123,
  "session": "a1b2c3d4",
  "sample_count": 1000,
  "raw_sample": [12.3, -5.2, 8.1, ...],
  "features": {
    "band_powers": {
      "alpha": [123.4, 234.5, ...],
      "beta": [56.7, 67.8, ...]
    },
    "hjorth": {
      "activity": [100.0, 200.0, ...],
      "mobility": [0.5, 0.6, ...]
    }
  },
  "classification": {
    "state": "focused",
    "confidence": 0.85,
    "method": "threshold"
  }
}
```

## EDF+ Recording

Processed data can be recorded to EDF+ format for offline analysis:

```python
# Inside container, recordings are saved to:
/app/data/recordings/bci_recording_{session}_{timestamp}.edf
```

## Development

### Testing Locally

Run the processor without containerization:

```bash
pip install -r requirements-container.txt
python container_receiver.py
```

### Extending the Pipeline

Add new processing phases by extending the `BCIDataProcessor` class:

```python
class MyCustomProcessor(BCIDataProcessor):
    async def process_sample(self, sample, timestamp):
        # Call parent processing
        result = await super().process_sample(sample, timestamp)
        
        # Add custom processing
        result['custom_feature'] = my_analysis(result)
        
        return result
```

## Troubleshooting

### Container can't find LSL stream
- Ensure host LSL stream is broadcasting to `0.0.0.0` not just `localhost`
- Check firewall settings on macOS
- Verify `host.containers.internal` resolves correctly

### Permission denied on scripts
```bash
chmod +x *.sh
```

### Build fails on ARM64
The Containerfile is optimized for Apple Silicon. For Intel Macs, remove:
```dockerfile
--platform linux/arm64
```

### WebSocket connection refused
Ensure port 8080 is not in use:
```bash
lsof -i :8080
```

## Architecture Notes

This system implements a **phased hypergraph processing pipeline** where:

- **Phases** are sequential processing stages with defined inputs/outputs
- **Hypergraph** refers to the multi-way data relationships (channels × time × features × states)
- Each phase can be parallelized and distributed independently
- State is maintained between phases for temporal continuity

The design supports:
- Horizontal scaling (multiple containers processing different streams)
- Vertical scaling (GPU acceleration for ML classification)
- Hot-swapping of processing modules
- Real-time and offline processing modes

## License

This BCI processing system is part of the zig-syrup project.
