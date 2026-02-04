# Nuworlds BCI Hypergraph Module

Hypergraph-based BCI (Brain-Computer Interface) data processing system for nuworlds. Implements a phased pipeline architecture with acquisition → preprocessing → analysis → output flow.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         NUWORLDS BCI HYPERGRAPH                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌──────────────┐      ┌──────────────┐      ┌──────────────┐             │
│   │ Acquisition  │─────▶│ Preprocessing│─────▶│   Analysis   │             │
│   │   (Source)   │      │  (Process)   │      │  (Transform) │             │
│   └──────────────┘      └──────────────┘      └──────┬───────┘             │
│          │                                           │                       │
│          │              ┌──────────────┐            │                       │
│          └─────────────▶│   Output     │◀───────────┘                       │
│                         │ (Visualize)  │                                    │
│                         └──────────────┘                                    │
│                                                                              │
│   Nodes: Processing phases    Edges: Data streams (hyperedges)              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Module Structure

```
nuworlds/
├── mod.nu              # Main module exports
├── hypergraph.nu       # Core hypergraph data structure
├── phase_runner.nu     # Phase execution and orchestration
├── stream_router.nu    # Stream routing and multicast
├── bci_pipeline.nu     # Pre-built BCI pipeline
├── world_integration.nu # World sensor/entity integration
├── state_manager.nu    # BCI state tracking
└── metrics.nu          # Performance metrics
```

## Quick Start

### Import the module

```nu
use nuworlds *

# Show version and available commands
nuworlds version
nuworlds help

# Run demo
nuworlds demo

# Run full example
nuworlds full-example
```

### Basic Hypergraph Usage

```nu
use nuworlds *

# Create a pipeline hypergraph
let pipeline = (hypergraph new | 
    hypergraph add-node acquisition "acquisition" {
        type: "source", 
        port: 16572,
        sample_rate: 250
    } |
    hypergraph add-node filter "preprocessing" {
        type: "process", 
        cmd: "bandpass 1-50",
        executor: {|input, config, ctx|
            print $"Filtering with ($config.cmd)"
            $input | insert filtered true
        }
    } |
    hypergraph add-node classify "analysis" {
        type: "classifier",
        method: "lda"
    } |
    hypergraph add-edge acquisition filter {stream: "raw_eeg"} |
    hypergraph add-edge filter classify {stream: "filtered"}
)

# Visualize
$pipeline | hypergraph visualize

# Execute
let result = ($pipeline | hypergraph execute --input {samples: []})
```

### Stream Routing

```nu
use nuworlds *

# Create router
mut router = (router create)

# Create streams
$router = ($router | 
    router stream-create "raw_eeg" --buffer-size 5000 --backpressure "drop_oldest" |
    router stream-create "features" --buffer-size 1000 --backpressure "block"
)

# Subscribe handlers
$router = ($router | router subscribe "raw_eeg" {|data, meta|
    print $"Received ($data | describe)"
})

# Publish data
$router | router publish "raw_eeg" {
    timestamp: (date now),
    channels: [1.2, 3.4, 5.6, 7.8]
}

# Pipe between streams
$router | router pipe "raw_eeg" "features" --transform {|data, meta|
    $data | insert features {alpha: 0.5, beta: 0.3}
}
```

### BCI Pipeline

```nu
use nuworlds *

# Create and start standard BCI pipeline
let config = {
    sample_rate: 250,
    channels: 8,
    channel_labels: ["Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2"],
    lowcut: 1.0,
    highcut: 50.0,
    classifier: "lda"
}

# Start pipeline
let instance = (bci-pipeline start --config $config --name "my_bci")

# Check status
bci-pipeline status --name "my_bci"

# Get metrics
bci-pipeline metrics --name "my_bci"

# Stop pipeline
bci-pipeline stop --name "my_bci"

# Run calibration
bci-pipeline calibrate --duration 30sec --classes ["rest", "left_hand", "right_hand"]
```

### World Integration

```nu
use nuworlds *

# Create BCI world with EEG entities
let world = (world create-bci 
    --channels ["Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2"]
)

# Add sensors
let world = ($world | world add-sensor "eeg_primary" "eeg" 
    --channels ["Fp1", "Fp2", "C3", "C4"]
    --sample-rate 250
    --location {x: 0, y: 0, z: 0}
)

# Update sensor data
let world = ($world | world update-sensor "eeg_primary" {
    timestamp: (date now),
    samples: [0.1, 0.2, 0.3, 0.4]
})

# Query world state
$world | world query "eeg.alpha > 0.5"

# Event system
let world = ($world | world on "blink" { |event, data|
    print "Blink detected!"
} --priority 10)

# Trigger event
$world | world trigger "blink" --data {strength: 0.8}

# Convert hypergraph to world
let pipeline = (bci-pipeline create)
let world = (world create | world from-hypergraph $pipeline)
```

### State Management

```nu
use nuworlds *

# Create state manager
mut state_mgr = (state new)

# Add triggers
$state_mgr = ($state_mgr | state trigger "focused" { |s, c|
    print $"Focus achieved! Confidence: ($c)"
} --confidence-threshold 0.7)

$state_mgr = ($state_mgr | state trigger "relaxed" { |s, c|
    print $"Relaxation state entered"
} --enter true)

# Update state (simulated from EEG features)
$state_mgr = ($state_mgr | state update "relaxed" --confidence 0.75)
sleep 2sec
$state_mgr = ($state_mgr | state update "focused" --confidence 0.82)

# Query state
$state_mgr | state current
$state_mgr | state history --last 5min
$state_mgr | state transitions --from "relaxed" --to "focused"

# Statistics
$state_mgr | state stats
$state_mgr | state predict
```

### Metrics Collection

```nu
use nuworlds *

# Create collector
mut metrics = (metrics new)

# Record stream latency
for i in 1..100 {
    $metrics = ($metrics | metrics record-latency "raw_eeg" (random float 2..8))
}

# Update channel metrics
for ch in ["Fp1", "Fp2", "C3", "C4"] {
    $metrics = ($metrics | metrics update-channel $ch 
        --snr (random float 8..15) 
        --impedance (random float 4..6)
    )
}

# Record throughput
$metrics = ($metrics | metrics record-throughput 
    --samples 250 
    --bytes 1024 
    --delay_ms 4.2
)

# Check for sample drops
$metrics = ($metrics | metrics check-drops 250 248)

# Get summary
$metrics | metrics summary

# Real-time dashboard
$metrics | metrics dashboard --interval 1sec

# Export for monitoring
$metrics | metrics export-prometheus

# Check alerts
$metrics | metrics check-alerts --max-latency-ms 10 --max-drop-rate 0.01
```

## Phase Runner Examples

### Sequential Execution

```nu
use nuworlds *

let hg = (hypergraph new | 
    hypergraph add-node "acquire" "acquisition" {type: "source"} |
    hypergraph add-node "process" "preprocessing" {type: "filter"} |
    hypergraph add-node "analyze" "analysis" {type: "classify"} |
    hypergraph add-edge "acquire" "process" {stream: "raw"} |
    hypergraph add-edge "process" "analyze" {stream: "filtered"}
)

# Run pipeline
let result = (phase pipeline $hg --parallel false)
print $result
```

### Parallel Execution

```nu
# Phases at the same dependency level run in parallel
let result = (phase pipeline $hg --parallel true)

# Monitor phases
phase monitor "acquire" --interval 5sec --restart true

# Batch execution
let phases = [
    {name: "p1", phase: "preprocessing", config: {}, dependencies: []},
    {name: "p2", phase: "preprocessing", config: {}, dependencies: []},
    {name: "p3", phase: "analysis", config: {}, dependencies: ["p1", "p2"]}
]
phase batch $phases --parallel true --max-concurrency 4
```

## Advanced Usage

### Custom Processing Nodes

```nu
let custom_pipeline = (bci-pipeline create | bci-pipeline add-node 
    "custom_feature" 
    "analysis" 
    {
        type: "custom",
        executor: {|input, config, ctx|
            # Custom feature extraction
            let alpha_power = $input.features.alpha.power
            let beta_power = $input.features.beta.power
            
            $input | insert custom_features {
                alpha_beta_ratio: ($alpha_power / $beta_power),
                complexity: ($alpha_power + $beta_power) / 2
            }
        }
    }
    --after "feature_extract"
    --before "classify"
)
```

### Complex Stream Routing

```nu
# Split stream based on condition
$router | router split "raw_eeg" --branches {
    good_signal: {|data, meta| ($data.quality? | default 0) > 0.8},
    poor_signal: {|data, meta| ($data.quality? | default 0) <= 0.8}
}

# Merge multiple streams
$router | router merge ["alpha_power", "beta_power", "theta_power"] "all_bands"

# TCP bridge
$router | router tcp-listen 8080 --stream "raw_eeg" --format json
$router | router tcp-connect "192.168.1.100" 8080 --stream "processed"
```

### State Machine Patterns

```nu
# Create complex state transitions
mut sm = (state new)

# Trigger on exit
$sm = ($sm | state trigger "focused" { |s, c|
    print "Leaving focused state"
} --exit true)

# One-time trigger
$sm = ($sm | state trigger "calibrated" { |s, c|
    print "Calibration complete - starting main loop"
} --once true)

# Pattern detection
$sm | state patterns --min-length 3
```

## Integration with OpenBCI

```nu
use nuworlds *

# Configuration for OpenBCI Cyton
let openbci_config = {
    sample_rate: 250,
    channels: 8,
    channel_labels: ["Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2"],
    lowcut: 1.0,
    highcut: 50.0,
    notch: 60.0,
    board_type: "cyton",
    port: "/dev/ttyUSB0"
}

# Start pipeline with OpenBCI config
let pipeline = (bci-pipeline start --config $openbci_config)

# Create monitoring dashboard
metrics new | metrics dashboard
```

## Testing

```nu
# Test hypergraph operations
let test_hg = (hypergraph new | 
    hypergraph add-node "a" "test" {} |
    hypergraph add-node "b" "test" {} |
    hypergraph add-edge "a" "b" {stream: "test"}
)

assert (($test_hg | hypergraph list-nodes | length) == 2)
assert (($test_hg | hypergraph list-edges | length) == 1)

# Test traversal
let traversal = ($test_hg | hypergraph traverse "a" --mode bfs)
assert (($traversal | length) == 2)

# Test topological sort
let order = ($test_hg | hypergraph topo-sort)
assert ($order.0 == "a")
assert ($order.1 == "b")
```

## Performance Considerations

1. **Buffer Sizes**: Adjust based on expected data rates
2. **Backpressure**: Choose strategy based on latency requirements
3. **Parallelism**: Enable for CPU-intensive phases
4. **Health Monitoring**: Restart phases that fail

## Nushell Patterns Used

- **Records and Tables**: All data structures
- **Closures**: Phase implementations and event handlers
- **Pipes**: Data flow between operations
- **Job Spawn**: Background tasks for acquisition and monitoring
- **Error Handling**: `try`, `catch` for robustness

## License

MIT License - Part of zig-syrup BCI processing framework
