# Nuworlds - Complete System Documentation

**Nuworlds** is a comprehensive nushell-based environment for OpenBCI brain-computer interfaces, world A/B testing, and multiplayer simultaneity.

## Quick Start

```bash
# Enter nuworlds environment
cd /Users/bob/i/zig-syrup/tools/openbci_host/nuworlds
nu

# Initialize (first run only)
source init.nu

# Use the complete system
use nuworlds.nu *

# Launch interactive demo
nuworlds demo

# Or start the REPL
nuworlds repl

# Or run a workflow
nuworlds workflow bci-focus-tracker

# Or launch dashboard
nuworlds dashboard
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         NUWORLDS                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   OpenBCI    │  │    World     │  │     A/B      │          │
│  │    Stream    │  │   Variants   │  │    Test      │          │
│  │  (a://b://c) │  │  (immer/ewig)│  │  (3-player)  │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                  │                  │
│         └────────┬────────┴────────┬─────────┘                  │
│                  ▼                 ▼                            │
│           ┌────────────┐    ┌────────────┐                     │
│           │ Hypergraph │◄──►│  Session   │                     │
│           │  Pipeline  │    │    3P      │                     │
│           └────────────┘    └────────────┘                     │
│                  │                 │                            │
│                  └────────┬────────┘                            │
│                           ▼                                     │
│                  ┌────────────────┐                            │
│                  │   Dashboard    │                            │
│                  │  (Terminal UI) │                            │
│                  └────────────────┘                            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Module Structure

### Core Modules (29 files, ~500KB)

| Category | Files | Purpose |
|----------|-------|---------|
| **OpenBCI** | `openbci_receiver.nu`, `lsl_bridge.py`, `eeg_types.nu`, `signal_processing.nu`, `visualization.nu` | EEG streaming, processing, visualization |
| **Worlds** | `world_ab.nu`, `multiplayer.nu`, `immer_ops.nu`, `ewig_history.nu`, `world_protocol.nu` | A/B testing, 3-player, immutable data, eternal persistence |
| **Hypergraph** | `hypergraph.nu`, `phase_runner.nu`, `stream_router.nu`, `bci_pipeline.nu`, `world_integration.nu`, `state_manager.nu`, `metrics.nu` | Phased processing pipelines |
| **CLI** | `openbci.nu`, `device.nu`, `stream.nu`, `record.nu`, `analyze.nu`, `viz.nu`, `config.nu`, `pipeline.nu` | Complete command-line interface |
| **Utilities** | `demo.nu`, `workflows.nu`, `dashboard.nu`, `repl.nu`, `utils.nu`, `hooks.nu`, `themes.nu`, `aliases.nu`, `init.nu`, `nuworlds.nu`, `test.nu` | Tools, demos, themes, setup |

## Commands Reference

### OpenBCI Commands

```nu
# Device management
openbci device list                    # List connected devices
openbci device connect <port>          # Connect to specific port
openbci device info                    # Show device details
openbci device impedance               # Check electrode impedance

# Streaming
openbci stream                         # Stream to stdout (table)
openbci stream --channels 0,1,2        # Filter channels
openbci stream --duration 60s          # Stream for fixed time
openbci stream --format jsonl          # JSON lines output
openbci stream | where ch0 > 100       # Filter by amplitude

# Recording
openbci record --output session.csv    # Record to CSV
openbci record --output session.parquet # Record to Parquet
openbci record --format edf            # EDF+ format
openbci record --duration 5min         # Auto-stop

# Analysis
openbci analyze file.csv --bands       # Calculate band powers
openbci analyze file.csv --psd         # Power spectral density
openbci analyze file.csv --coherence   # Inter-channel coherence

# Visualization
openbci viz --mode terminal            # Real-time plots
openbci viz --mode ascii               # ASCII brain map
openbci viz --bands                    # Frequency band bars
```

### World Commands

```nu
# Create worlds
world create a://baseline              # Create variant A
world create b://variant --param difficulty=hard  # With params
world create c://experimental          # Create variant C

# World operations
world list                             # List all worlds
world compare a://baseline b://variant # Diff two worlds
world clone a://baseline a://copy      # Clone world
world snapshot a://baseline            # Create snapshot
world info a://baseline                # Show world info

# Immer (immutable data)
immer array new                        # Create persistent array
immer array push $arr $val             # Append (returns new)
immer map new                          # Create persistent map
immer map assoc $map $key $val         # Associate (returns new)
immer diff $old $new                   # Show structural diff
immer hash $value                      # Content hash

# Ewig (eternal history)
ewig log a://baseline                 # Show append-only log
ewig at a://baseline <timestamp>       # State at time T
ewig range a://baseline -1h now        # Events in range
ewig replay a://baseline               # Replay events
ewig branch a://baseline new-branch    # Branch history
ewig merge new-branch a://baseline     # Merge branches
```

### Multiplayer Commands

```nu
# Session management
mp session new --players 3             # Create 3-player session
mp session assign <session> <player> <world-uri>  # Assign player
mp session sync <session>              # Synchronize all players
mp session observe <session>           # Watch real-time state
mp session metrics <session>           # Show per-variant metrics
mp session resolve <session> <action>  # Resolve conflicts
mp session start <session>             # Start session
mp session end <session>               # End session
```

### A/B Testing Commands

```nu
# Test orchestration
ab-test init "test-name" --variants [a b c] --players-per-variant 1
ab-test run "test-name" --duration 10min
ab-test monitor "test-name"            # Live monitoring
ab-test results "test-name"            # Statistical analysis
ab-test winner "test-name"             # Determine winner
ab-test promote "test-name" b          # Promote winner
ab-test list                           # List all tests
ab-test info "test-name"               # Test details
ab-test stop "test-name"               # Stop test
ab-test delete "test-name"             # Delete test
```

### Hypergraph Commands

```nu
# Pipeline management
hypergraph new                         # Create empty hypergraph
hypergraph add-node <name> {type: "source", cmd: "..."}
hypergraph add-edge <from> <to> {stream: "..."}
hypergraph traverse <graph>            # Walk the graph
hypergraph execute <graph>             # Run pipeline
hypergraph visualize <graph>           # Generate diagram

# BCI Pipeline
bci-pipeline create                    # Create standard pipeline
bci-pipeline start                     # Start pipeline
bci-pipeline stop                      # Stop pipeline
bci-pipeline status                    # Show status
bci-pipeline calibrate                 # Calibration sequence
bci-pipeline metrics                   # Performance metrics

# Stream routing
router create                          # Initialize router
router subscribe <stream> <handler>    # Add consumer
router publish <stream> <data>         # Broadcast
router pipe <from> <to>                # Connect streams
router split <stream> <n>              # Split stream
router merge <streams>                 # Merge streams
```

### Utility Commands

```nu
# Workflows
nuworlds workflow bci-focus-tracker    # Focus detection workflow
nuworlds workflow ab-test-eeg          # 3-player A/B test with EEG
nuworlds workflow meditation-monitor   # Meditation depth tracking
nuworlds workflow sleep-recorder       # Overnight recording
nuworlds workflow neurofeedback-game   # BCI-controlled game

# Dashboard
nuworlds dashboard                     # Launch terminal dashboard
nuworlds dashboard --theme ocean       # With theme

# REPL
nuworlds repl                          # Interactive REPL
nuworlds repl --theme matrix           # Themed REPL

# Utilities
nuworlds doctor                        # System health check
nuworlds update                        # Check for updates
nuworlds demo                          # Interactive demo
nuworlds demo --mode quick             # Quick demo
nuworlds demo --mode full              # Full demonstration

# Hooks
hook on-blink { echo "Blink!" }        # Trigger on blink
hook on-focus { echo "Focused!" }      # Trigger on focus
hook on-relax { echo "Relaxed!" }      # Trigger on relax
hook on-artifact { echo "Artifact!" }  # Trigger on artifact

# Utils
wait-for-device                        # Poll until device detected
auto-config                            # Auto-detect and configure
export-all <session> <dir>             # Export in all formats
compare-sessions <a> <b>               # Compare recordings
validate-setup                         # Check dependencies
```

### Aliases

```nu
obs    # openbci stream
obr    # openbci record
oba    # openbci analyze
obv    # openbci viz
obc    # openbci config
wab    # world ab
mp3    # mp session new --players 3
focus  # workflow bci-focus-tracker
meditate # workflow meditation-monitor
dashboard # nuworlds dashboard
repl   # nuworlds repl
```

## Workflows

### 1. BCI Focus Tracker

```nu
#!/usr/bin/env nu
use nuworlds *

# Start focus tracking workflow
nuworlds workflow bci-focus-tracker

# Or manually:
openbci stream 
| band-power 8 12    # Alpha waves
| state track-focus  # Track focus state
| where focus > 0.7  # High focus only
| record --output focus-sessions.csv
```

### 2. 3-Player A/B EEG Test

```nu
#!/usr/bin/env nu
use nuworlds *

# Create worlds
world create a://baseline
world create b://variant
world create c://experimental

# Create 3-player session
let session = (mp session new --players 3)

# Assign to variants
mp session assign $session alice a://baseline
mp session assign $session bob b://variant
mp session assign $session charlie c://experimental

# Stream BCI to all worlds
openbci stream | tee {
    |sample| $sample | world add-sensor a://baseline
} | tee {
    |sample| $sample | world add-sensor b://variant
} | world add-sensor c://experimental

# Run A/B test
ab-test init "bci-test" --variants [a b c]
ab-test run "bci-test" --duration 10min
ab-test winner "bci-test"
```

### 3. Meditation Monitor

```nu
#!/usr/bin/env nu
use nuworlds *

nuworlds workflow meditation-monitor

# Or manually:
openbci stream
| band-power 8 12       # Alpha
| band-power 4 8        # Theta
| calc-meditation-score # Custom calculation
| viz --meditation-bars # Visual feedback
| hook on-deep-meditation { 
    # Play bell sound
    ^afplay /System/Library/Sounds/Glass.aiff
}
```

### 4. Sleep Recorder

```nu
#!/usr/bin/env nu
use nuworlds *

nuworlds workflow sleep-recorder

# Records overnight with:
# - EEG at 250Hz
# - Auto stage detection (awake/REM/light/deep)
# - Movement artifact detection
# - Morning report generation
```

### 5. Neurofeedback Game

```nu
#!/usr/bin/env nu
use nuworlds *

nuworlds workflow neurofeedback-game

# Simple game controlled by brain state:
# - Focus = speed up
# - Relax = slow down
# - Alpha bursts = power-ups
```

## Data Flow

```
OpenBCI Hardware
      │
      ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Receiver   │────►│   Filter    │────►│   Feature   │
│  (TCP/LSL)  │     │ (1-50Hz)    │     │ Extraction  │
└─────────────┘     └─────────────┘     └──────┬──────┘
                                               │
                          ┌────────────────────┼────────────────────┐
                          │                    │                    │
                          ▼                    ▼                    ▼
                   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
                   │   World A   │     │   World B   │     │   World C   │
                   │  (baseline) │     │  (variant)  │     │(experimental│
                   └──────┬──────┘     └──────┬──────┘     └──────┬──────┘
                          │                    │                    │
                          └────────────────────┼────────────────────┘
                                               │
                                               ▼
                                        ┌─────────────┐
                                        │  Session3P  │
                                        │ (3-player   │
                                        │  simultaneity│
                                        └──────┬──────┘
                                               │
                                               ▼
                                        ┌─────────────┐
                                        │   A/B Test  │
                                        │  (metrics & │
                                        │   analysis) │
                                        └─────────────┘
```

## Configuration

Config stored in `~/.config/openbci/config.nuon`:

```nuon
{
    device: {
        board_type: "cyton"
        serial_port: "/dev/tty.usbserial-*"
        sample_rate: 250
    }
    
    streaming: {
        lsl_enabled: true
        lsl_port: 16571
        tcp_enabled: true
        tcp_port: 16572
        buffer_size: 450000
    }
    
    processing: {
        notch_filter: 60
        bandpass_low: 1.0
        bandpass_high: 50.0
        artifact_threshold: 100
    }
    
    worlds: {
        default_variant: "a"
        cache_size_mb: 100
        persistence_enabled: true
        persistence_dir: "~/.local/share/nuworlds"
    }
    
    display: {
        theme: "default"
        update_rate_hz: 30
        show_raw: true
        show_bands: true
        show_focus: true
    }
}
```

## Themes

```nu
# Available themes
themes list
# - default
# - minimal
# - high-contrast
# - ocean
# - matrix

# Apply theme
themes apply ocean
themes apply matrix
```

## Troubleshooting

```nu
# System health check
nuworlds doctor

# Validate setup
validate-setup

# Check device detection
openbci device list --verbose

# Test stream without hardware
openbci stream --simulate

# Debug mode
nuworlds demo --verbose
```

## Integration with Zig Syrup

The nuworlds system integrates with the Zig syrup backend:

```zig
const worlds = @import("worlds");

// Create worlds from Zig
var ctx = worlds.init(allocator);
defer ctx.deinit();

const world_a = try ctx.createWorld("a://baseline");
const world_b = try ctx.createWorld("b://variant");

// Run A/B test
var test = try ctx.createABTest("my_test", &[_]WorldVariant{ .A, .B });
```

## File Sizes

```
Total: ~500KB across 33 nushell files

Core:        150KB  (OpenBCI streaming & processing)
Worlds:      150KB  (A/B, multiplayer, immer, ewig)
Hypergraph:  100KB  (Pipelines, routing, metrics)
Utils:       100KB  (Demo, workflows, dashboard, etc.)
```

## License

MIT - See LICENSE file in project root.
