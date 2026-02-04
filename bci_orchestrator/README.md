# BCI Hypergraph Orchestration System

A hypergraph-based orchestration system for managing phased BCI (Brain-Computer Interface) processing pipelines.

## Overview

This system manages data flow between acquisition → processing → analysis phases using a hypergraph structure where:
- **Nodes** represent processing phases (host processes or containers)
- **Hyperedges** represent multicast data streams connecting multiple phases

## Architecture

```
┌─────────────────┐
│   acquisition   │  Host process (hardware source)
│    (LSL:16571)  │
└────────┬────────┘
         │ raw_eeg (multicast)
         ▼
┌─────────────────────────────────────────┐
│           Hypergraph Edge               │
│  ┌──────────┬──────────┬──────────┐     │
│  ▼          ▼          ▼          ▼     │
│preprocess visualizer   storage          │
└─────────────────────────────────────────┘
         │
    filtered_eeg, features
         ▼
    ┌──────────┐
    │ analysis │  Container (ML classification)
    │(WS:16575)│
    └────┬─────┘
         │ classification
         ▼
      [storage]
```

## Components

### 1. Hypergraph Orchestrator (`hypergraph_orchestrator.py`)
- Defines processing pipeline as hypergraph structure
- Manages container lifecycle via Apple Containerization CLI
- Handles node states and transitions

### 2. Stream Router (`stream_router.py`)
- Receives single input stream
- Multicasts to multiple consumers (hypergraph edges)
- Implements backpressure handling
- Stream synchronization for multi-modal data

### 3. Phase Coordinator (`phase_coordinator.py`)
- Manages transitions between pipeline phases
- Handles container startup/shutdown ordering
- Health monitoring with auto-restart
- Dependency-aware pipeline orchestration

### 4. CLI Tool (`bci_orchestrator.py`)
```bash
# Start full pipeline
./bci_orchestrator start --foreground

# Scale a phase
./bci_orchestrator scale preprocessing 3

# Check status
./bci_orchestrator status --watch

# Stop pipeline
./bci_orchestrator stop
```

### 5. Monitor (`monitor.py`)
- Real-time ASCII dashboard
- Optional web dashboard (port 8080)
- Stream throughput metrics
- Container resource usage
- Phase latency measurements

## Configuration

Edit `hypergraph_config.yaml`:

```yaml
phases:
  - name: acquisition
    type: host_process
    command: python host_acquisition.py
    outputs: [raw_eeg]

  - name: preprocessing
    type: container
    image: bci-processor:latest
    inputs: [raw_eeg]
    outputs: [filtered_eeg, features]
    replicas: 2

streams:
  raw_eeg:
    protocol: lsl
    port: 16571
    format: float32
    channels: 8
    sampling_rate: 256

hyperedges:
  - name: raw_distribution
    source: acquisition
    targets: [preprocessing, visualizer, storage]
    stream: raw_eeg
    multicast: true
```

## Installation

```bash
# Install dependencies
pip install pyyaml numpy

# Optional: Web dashboard
pip install aiohttp

# Optional: LSL support
pip install pylsl

# Optional: WebSocket support
pip install websockets
```

## Usage

### Command Line

```bash
# Start the pipeline
python -m bci_orchestrator start --foreground

# Scale preprocessing to 3 replicas
python -m bci_orchestrator scale preprocessing 3

# Check status
python -m bci_orchestrator status

# Visualize hypergraph
python -m bci_orchestrator viz

# Stop gracefully
python -m bci_orchestrator stop
```

### Programmatic API

```python
import asyncio
from bci_orchestrator import HypergraphOrchestrator

async def main():
    orchestrator = HypergraphOrchestrator("hypergraph_config.yaml")
    
    # Start pipeline
    await orchestrator.start_pipeline()
    
    # Get status
    status = orchestrator.get_status()
    print(status)
    
    # Scale a phase
    await orchestrator.scale_phase("preprocessing", 3)
    
    # Visualize
    print(orchestrator.visualize_hypergraph())
    
    # Stop after some time
    await asyncio.sleep(60)
    await orchestrator.stop_pipeline()

asyncio.run(main())
```

## Monitoring

### ASCII Dashboard
```bash
python -m bci_orchestrator.monitor --ascii
```

### Web Dashboard
```bash
python -m bci_orchestrator.monitor --web --web-port 8080
```

## Hypergraph Features

### Multicast (Fan-Out)
One producer can send to multiple consumers:
```yaml
hyperedges:
  - source: acquisition
    targets: [preprocessing, visualizer, storage]
    multicast: true
```

### Fan-In
Multiple feature streams can be combined:
```yaml
hyperedges:
  - source: feature_extractor_1
    targets: [fusion_module]
  - source: feature_extractor_2
    targets: [fusion_module]
```

### Dynamic Reconfiguration
Add/remove consumers without stopping acquisition:
```python
# Add a new consumer dynamically
consumer = Consumer(
    id="new_analyzer",
    protocol=StreamProtocol.TCP,
    host="localhost",
    port=16579
)
router.add_consumer(consumer)
```

## Stream Protocols

| Protocol | Port | Use Case |
|----------|------|----------|
| LSL | 16571 | Raw EEG acquisition |
| TCP | 16573-16778 | Inter-container data |
| WebSocket | 16575 | Real-time visualization |

## Backpressure Strategies

- **DROP_OLDEST**: Drop oldest data when buffer full (default)
- **DROP_NEWEST**: Drop newest data when buffer full
- **BLOCK**: Block producer until space available
- **THROTTLE**: Dynamically reduce producer rate

## Health Monitoring

The system automatically:
- Checks phase health every 10 seconds
- Restarts failed phases (max 5 restarts in 5 minutes)
- Applies exponential backoff on restarts
- Tracks health failure history

## Development

### Project Structure
```
bci_orchestrator/
├── __init__.py                  # Package exports
├── hypergraph_orchestrator.py   # Main orchestrator
├── stream_router.py             # Stream multicast router
├── phase_coordinator.py         # Phase lifecycle manager
├── bci_orchestrator.py          # CLI tool
├── monitor.py                   # Monitoring dashboard
├── hypergraph_config.yaml       # Configuration
└── README.md                    # This file
```

### Running Tests
```bash
# Validate configuration
python -m bci_orchestrator config validate

# Test stream router
python -m bci_orchestrator.stream_router

# Test phase coordinator
python -m bci_orchestrator.phase_coordinator
```

## License

MIT License - See LICENSE file

## Contributing

Contributions welcome! Please ensure:
1. Code follows existing style
2. Tests pass
3. Documentation is updated
4. Commit messages are descriptive
