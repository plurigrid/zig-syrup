# Nuworlds System Summary

## Overview

**Nuworlds** is a comprehensive nushell-based environment integrating:
- **OpenBCI** brain-computer interface streaming and processing
- **World A/B Testing** with 3-player multiplayer simultaneity  
- **Immutable (immer)** and **eternal (ewig)** data structures
- **a:// b:// c://** URI scheme world variants
- **Hypergraph** phased processing pipelines

## Statistics

| Metric | Count |
|--------|-------|
| Nushell files | 39 |
| Python files | 1 |
| Documentation files | 3 |
| **Total lines of nushell code** | **18,958** |
| Zig world modules | 15 |
| Zig ewig modules | 9 |

## Module Breakdown

### OpenBCI Core (5 files, ~70KB)
- `openbci_receiver.nu` - TCP/LSL streaming receiver
- `lsl_bridge.py` - Python LSL bridge
- `eeg_types.nu` - Type definitions, band constants
- `signal_processing.nu` - Filters, band power, features
- `visualization.nu` - ASCII plots, sparklines, dashboards

### World System (5 files, ~100KB)
- `world_ab.nu` - World variant management (a://, b://, c://)
- `multiplayer.nu` - 3-player session management
- `immer_ops.nu` - Immutable array/map operations
- `ewig_history.nu` - Eternal append-only history
- `world_protocol.nu` - URI protocol handlers

### Hypergraph Pipeline (7 files, ~90KB)
- `hypergraph.nu` - Graph structure and traversal
- `phase_runner.nu` - Phase execution and orchestration
- `stream_router.nu` - Multicast stream routing
- `bci_pipeline.nu` - Pre-built BCI pipelines
- `world_integration.nu` - World sensor/entity integration
- `state_manager.nu` - Mental state tracking
- `metrics.nu` - Performance metrics and monitoring

### CLI Tools (8 files, ~120KB)
- `openbci.nu` - Main CLI entry point
- `device.nu` - Device management
- `stream.nu` - Streaming commands
- `record.nu` - Recording to CSV/Parquet/EDF
- `analyze.nu` - Signal analysis (PSD, coherence, etc.)
- `viz.nu` - Visualization commands
- `config.nu` - Configuration management
- `pipeline.nu` - Pipeline management

### Utilities (10 files, ~130KB)
- `demo.nu` - Interactive demonstrations
- `workflows.nu` - Pre-built workflows
- `dashboard.nu` - Terminal dashboard
- `repl.nu` - Interactive REPL
- `utils.nu` - Utility functions
- `hooks.nu` - Event hooks
- `themes.nu` - Color themes
- `aliases.nu` - Command shortcuts
- `init.nu` - Initialization script
- `nuworlds.nu` - Master command

### Support Files (3 files)
- `mod.nu` - Module exports
- `test.nu` - Test suite
- `install.nu` - Installation script

## Key Features

### 1. OpenBCI Integration
- Auto-detect Cyton (USB) and Ganglion (BLE) boards
- Dual streaming: LSL (port 16571) and TCP (port 16572)
- Real-time filtering: bandpass 1-50Hz, notch 60Hz
- Feature extraction: band powers, Hjorth parameters
- Visualization: ASCII waveforms, band bars, topographic maps

### 2. World Variants
```nu
world create a://baseline              # Baseline configuration
world create b://variant --param difficulty=hard  # Variant B
world create c://experimental          # Experimental
world compare a://baseline b://variant # Diff worlds
```

### 3. 3-Player Multiplayer
```nu
let session = (mp session new --players 3)
mp session assign $session p1 a://baseline
mp session assign $session p2 b://variant
mp session assign $session p3 c://experimental
mp session sync $session
```

### 4. Immutable Data (immer)
```nu
let arr = (immer array new | immer array push 1 | immer array push 2)
let map = (immer map new | immer map assoc "key" "value")
immer diff $old $new  # Structural diff
```

### 5. Eternal History (ewig)
```nu
ewig log a://baseline                   # Show history
ewig at a://baseline 1699123456789      # State at time T
ewig branch a://baseline experiment-1   # Branch history
ewig merge experiment-1 a://baseline    # Merge branches
```

### 6. A/B Testing
```nu
ab-test init "test" --variants [a b c]
ab-test run "test" --duration 10min
ab-test winner "test"                  # Statistical winner
```

### 7. Pre-built Workflows
- `bci-focus-tracker` - Focus detection and logging
- `ab-test-eeg` - 3-player A/B with EEG input
- `meditation-monitor` - Real-time meditation depth
- `sleep-recorder` - Overnight recording
- `neurofeedback-game` - BCI-controlled game

## Quick Start

```bash
# 1. Enter directory
cd /Users/bob/i/zig-syrup/tools/openbci_host/nuworlds

# 2. Start nushell
nu

# 3. Initialize
source init.nu

# 4. Use nuworlds
use nuworlds.nu *

# 5. Launch demo
nuworlds demo
```

## Zig Integration

Located in `/Users/bob/i/zig-syrup/src/worlds/`:

| File | Purpose |
|------|---------|
| `world.zig` | Core world with immutable state |
| `ab_test.zig` | A/B testing engine |
| `multiplayer.zig` | 3-player simultaneity |
| `immer.zig` | Immutable Array & Map |
| `ewig/*.zig` | 9-module persistence system |
| `uri.zig` | URI resolver |
| `simulation.zig` | Deterministic simulation |

## Data Flow

```
OpenBCI Hardware
    → Receiver (TCP/LSL)
    → Filter (1-50Hz bandpass)
    → Feature Extraction (bands, Hjorth)
    → Stream Router (multicast)
    → World A / World B / World C
    → Session3P (3-player sync)
    → A/B Test (metrics & analysis)
    → Dashboard / Ewig Log
```

## File Locations

```
/Users/bob/i/zig-syrup/
├── src/worlds/              # Zig modules
│   ├── world.zig
│   ├── ab_test.zig
│   ├── multiplayer.zig
│   ├── immer.zig
│   ├── ewig/
│   │   ├── ewig.zig
│   │   ├── log.zig
│   │   ├── timeline.zig
│   │   └── ...
│   └── ...
│
└── tools/openbci_host/
    └── nuworlds/            # Nushell modules (39 files)
        ├── openbci_*.nu
        ├── world_*.nu
        ├── *_pipeline.nu
        ├── demo.nu
        ├── workflows.nu
        ├── dashboard.nu
        └── ...
```

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         NUWORLDS                                 │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ OpenBCI  │  │  World   │  │    A/B   │  │  Multi-  │        │
│  │  Stream  │  │ Variants │  │   Test   │  │  player  │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       │             │             │             │               │
│       └─────────────┴──────┬──────┴─────────────┘               │
│                            │                                    │
│                     ┌──────┴──────┐                            │
│                     │  Hypergraph │                            │
│                     │   Pipeline  │                            │
│                     └──────┬──────┘                            │
│                            │                                    │
│       ┌────────────────────┼────────────────────┐              │
│       ▼                    ▼                    ▼              │
│  ┌─────────┐         ┌─────────┐         ┌─────────┐          │
│  │  Immer  │         │  Ewig   │         │  Theme  │          │
│  │(immutable│        │(eternal)│         │(display)│          │
│  └─────────┘         └─────────┘         └─────────┘          │
│                                                                │
└─────────────────────────────────────────────────────────────────┘
```

## Commands Summary

| Category | Commands |
|----------|----------|
| **OpenBCI** | `openbci device/stream/record/analyze/viz` |
| **World** | `world create/list/compare/clone` |
| **Immer** | `immer array/map new/push/assoc/diff` |
| **Ewig** | `ewig log/at/range/replay/branch/merge` |
| **Multiplayer** | `mp session new/assign/sync/observe` |
| **A/B Test** | `ab-test init/run/monitor/results/winner` |
| **Hypergraph** | `hypergraph new/add-node/add-edge/execute` |
| **Utils** | `nuworlds demo/workflow/dashboard/repl` |

## Aliases

| Alias | Expands To |
|-------|------------|
| `obs` | `openbci stream` |
| `obr` | `openbci record` |
| `oba` | `openbci analyze` |
| `wab` | `world ab` |
| `mp3` | `mp session new --players 3` |
| `focus` | `workflow bci-focus-tracker` |
| `meditate` | `workflow meditation-monitor` |

## Total Code Size

- **Nushell**: 18,958 lines
- **Zig**: ~15,000 lines (worlds + ewig)
- **Python**: ~500 lines (LSL bridge)
- **Total**: ~34,500 lines

