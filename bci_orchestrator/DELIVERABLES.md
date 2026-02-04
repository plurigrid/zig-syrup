# BCI Hypergraph Orchestration System - Deliverables

## Summary

A complete hypergraph-based orchestration system for phased BCI processing pipelines with the following components:

## Core Components

### 1. Hypergraph Orchestrator (`hypergraph_orchestrator.py`)
- **Lines**: ~800
- **Purpose**: Main orchestration engine
- **Features**:
  - Defines pipeline as hypergraph structure
  - Nodes: host_acquisition, container_processor, container_analyzer, container_visualizer, container_storage
  - Hyperedges: multicast streams connecting multiple nodes
  - Container lifecycle management via Apple Containerization CLI
  - ASCII hypergraph visualization
  - Phase scaling and restart capabilities

### 2. Configuration (`hypergraph_config.yaml`)
- **Purpose**: Declarative pipeline configuration
- **Sections**:
  - `phases`: 5 pipeline phases with types, commands, images, resources
  - `streams`: 7 data streams (LSL, TCP, WebSocket)
  - `hyperedges`: 4 multicast relationships
  - `orchestration`: Startup/shutdown ordering, restart policies, monitoring

### 3. Stream Router (`stream_router.py`)
- **Lines**: ~700
- **Purpose**: Multicast data distribution
- **Features**:
  - Single input to multiple outputs
  - Protocol abstraction (LSL, TCP, WebSocket, UDP)
  - Backpressure strategies: DROP_OLDEST, DROP_NEWEST, BLOCK, THROTTLE
  - Stream synchronization for multi-modal data
  - Per-consumer queue management
  - Packet serialization/deserialization

### 4. Phase Coordinator (`phase_coordinator.py`)
- **Lines**: ~750
- **Purpose**: Phase transition and lifecycle management
- **Features**:
  - Dependency-aware startup/shutdown ordering
  - Topological sort for pipeline ordering
  - Health monitoring with auto-restart
  - Exponential backoff for restarts
  - State machine transitions
  - Rolling update support

### 5. CLI Tool (`bci_orchestrator.py`)
- **Lines**: ~550
- **Purpose**: Command-line interface
- **Commands**:
  - `start [--foreground]` - Launch full pipeline
  - `stop [--force]` - Graceful shutdown
  - `status [--watch]` - Show phase states
  - `scale <phase> <n>` - Run multiple instances
  - `restart <phase>` - Restart a phase
  - `logs <phase>` - Show phase logs
  - `config show/validate` - Configuration management
  - `viz` - Visualize hypergraph

### 6. Monitoring Dashboard (`monitor.py`)
- **Lines**: ~750
- **Purpose**: Real-time monitoring
- **Features**:
  - ASCII dashboard with terminal UI
  - Optional web dashboard (port 8080)
  - Stream throughput metrics
  - Container resource usage (CPU, memory)
  - Phase latency measurements with sparklines
  - Metrics history and rate calculations

## Example Modules

### `examples/host_acquisition.py`
- Simulates EEG acquisition device
- Generates synthetic 8-channel EEG data at 256 Hz
- Supports LSL and TCP streaming protocols
- Configurable via environment variables

### `examples/simple_processor.py`
- Example container processor
- Receives raw EEG, applies filtering, extracts features
- Demonstrates filter bank and feature extraction
- Multiple output streams (filtered, features)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Hypergraph Structure                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌─────────────┐                                               │
│   │ acquisition │◄── Host process (hardware source)            │
│   │  (LSL/TCP)  │                                               │
│   └──────┬──────┘                                               │
│          │ raw_eeg                                              │
│          ▼                                                      │
│   ┌─────────────────────────────────────────────────────┐       │
│   │  HYPEREDGE: raw_distribution (multicast)            │       │
│   │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │       │
│   └──┤preprocess│  │visualizer│  │ storage  ├───────────┘       │
│      └────┬─────┘  └──────────┘  └──────────┘                   │
│           │ filtered_eeg, features                              │
│           ▼                                                     │
│      ┌──────────┐                                               │
│      │ analysis │◄── Container (ML classification)             │
│      │(WebSock) │                                               │
│      └────┬─────┘                                               │
│           │ classification                                      │
│           ▼                                                     │
│      [visualizer, storage]                                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Stream Protocols & Ports

| Stream | Protocol | Port | Description |
|--------|----------|------|-------------|
| raw_eeg | LSL/TCP | 16571 | Raw 8-channel EEG data |
| filtered_eeg | TCP | 16573 | Filtered EEG output |
| features | TCP | 16574 | Extracted features (JSON) |
| classification | WebSocket | 16575 | ML classification results |
| states | TCP | 16576 | BCI state information |
| display_stream | TCP | 16577 | Real-time display data |
| storage_confirm | TCP | 16578 | Storage acknowledgments |

## Key Features

### Hypergraph Capabilities
1. **Multicast (Fan-Out)**: One producer → multiple consumers
2. **Fan-In**: Multiple sources → one consumer
3. **Dynamic Reconfiguration**: Add/remove consumers without stopping acquisition

### Backpressure Handling
- Per-consumer buffer management
- Configurable strategies per consumer
- Automatic consumer disconnect handling

### Health Monitoring
- 10-second health check interval
- Auto-restart with exponential backoff
- Max 5 restarts per 5-minute window
- Health failure tracking

### Container Management
- Apple Containerization CLI integration
- Resource limits (CPU, memory)
- Volume mounting
- Port mapping for streams

## Usage Example

```bash
# 1. Start the pipeline
python -m bci_orchestrator start --foreground

# 2. In another terminal, scale preprocessing
python -m bci_orchestrator scale preprocessing 3

# 3. Monitor in real-time
python -m bci_orchestrator status --watch

# 4. Visualize the hypergraph
python -m bci_orchestrator viz

# 5. Stop gracefully
python -m bci_orchestrator stop
```

## API Usage

```python
import asyncio
from bci_orchestrator import HypergraphOrchestrator

async def main():
    # Initialize
    orch = HypergraphOrchestrator("hypergraph_config.yaml")
    
    # Start pipeline
    await orch.start_pipeline()
    
    # Scale a phase
    await orch.scale_phase("preprocessing", 3)
    
    # Get status
    status = orch.get_status()
    print(status)
    
    # Visualize
    print(orch.visualize_hypergraph())
    
    # Cleanup
    await orch.stop_pipeline()

asyncio.run(main())
```

## File Summary

| File | Lines | Purpose |
|------|-------|---------|
| hypergraph_orchestrator.py | ~800 | Core orchestration engine |
| stream_router.py | ~700 | Multicast stream routing |
| phase_coordinator.py | ~750 | Phase lifecycle management |
| bci_orchestrator.py | ~550 | CLI tool |
| monitor.py | ~750 | Monitoring dashboard |
| __init__.py | ~150 | Package exports |
| hypergraph_config.yaml | ~150 | Configuration |
| examples/host_acquisition.py | ~350 | Acquisition example |
| examples/simple_processor.py | ~350 | Processor example |
| README.md | ~350 | Documentation |
| **Total** | **~4,900** | |

## Dependencies

```
pyyaml>=6.0
numpy>=1.24.0
aiohttp>=3.8.0 (optional, web dashboard)
pylsl>=1.16.0 (optional, LSL support)
websockets>=11.0 (optional, WebSocket support)
```

## Next Steps for Production

1. **Add authentication** for CLI and web dashboard
2. **Implement persistent storage** for metrics
3. **Add distributed mode** for multi-machine pipelines
4. **Integrate with container registries** for image management
5. **Add pipeline versioning** and rollback capabilities
6. **Implement canary deployments** for phase updates
