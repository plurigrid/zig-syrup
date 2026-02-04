# OpenBCI Nushell CLI

A comprehensive command-line interface for OpenBCI brain-computer interface operations, built for nushell with first-class support for pipes, structured data, and hypergraph integration.

## Features

- 🧠 **Device Management**: Auto-detect Cyton (USB) and Ganglion (BLE) boards
- 📡 **Real-time Streaming**: Stream EEG data to stdout with nushell pipe support
- 💾 **Flexible Recording**: Save to CSV, Parquet, or EDF+ formats
- 📊 **Signal Analysis**: Band powers, PSD, coherence, Hjorth parameters
- 📈 **Terminal Visualization**: Real-time plots, ASCII brain maps, band bars
- ⚙️ **Configuration Management**: Persistent settings with easy editing
- 🔄 **Processing Pipelines**: Build and run custom data processing workflows
- 🔗 **Hypergraph Integration**: Connect to hypergraph for session storage

## Installation

### Prerequisites

- [Nushell](https://www.nushell.sh/) (version 0.90 or later)
- OpenBCI hardware (Cyton, Cyton+Daisy, or Ganglion)
- Python 3 with `pyedflib` (optional, for EDF export)

### Setup

```nu
# Clone or copy this directory
cp -r nuworlds ~/.config/nushell/openbci

# Add to your config.nu
echo 'use ~/.config/nushell/openbci *' >> ~/.config/nushell/config.nu

# Initialize configuration
openbci config init

# Generate shell completions
openbci complete --shell nu | save ~/.config/openbci/completions.nu
echo 'source ~/.config/openbci/completions.nu' >> ~/.config/nushell/config.nu
```

## Quick Start

```nu
# List connected devices
openbci device list

# Connect to first available device
openbci device connect /dev/ttyUSB0

# Stream data (Ctrl+C to stop)
openbci stream

# Stream specific channels for 60 seconds
openbci stream --channels 0,1,2 --duration 60s

# Stream with filtering
openbci stream | where ch0 > 50 and ch1 > 50

# Record 5 minutes to CSV
openbci record --output session.csv --duration 5min

# Analyze recorded data
openbci analyze session.csv --bands --features

# Real-time visualization
openbci viz --mode terminal
```

## Command Reference

### Device Management

```nu
# List all connected OpenBCI devices
openbci device list
openbci device list --detailed

# Connect to a specific device
openbci device connect /dev/ttyUSB0
openbci device connect ble://xx:xx:xx:xx:xx:xx

# Show device information
openbci device info

# Check electrode impedance
openbci device impedance
openbci device impedance --channel 0

# Disconnect
openbci device disconnect
```

### Streaming

```nu
# Basic streaming (all channels, table output)
openbci stream

# Stream specific channels
openbci stream --channels 0,1,2,3

# Stream for fixed duration
openbci stream --duration 60s
openbci stream --duration 5min

# Output formats
openbci stream --format jsonl    # JSON lines
openbci stream --format csv      # CSV format
openbci stream --format json     # Single JSON array

# Stream with band power filtering
openbci stream bands --band alpha --threshold 0.5

# Real-time band powers
openbci stream powers --channels 0,1

# Pipe to other commands
openbci stream | where ch0 > 100
openbci stream | save stream.csv
openbci stream | analyze --bands
```

### Recording

```nu
# Basic recording
openbci record --output session.csv --duration 60s

# Record to different formats
openbci record --output session.parquet --format parquet
openbci record --output session.edf --format edf --duration 8hr

# Record specific channels
openbci record --output session.csv --channels 0,1 --duration 5min

# Trigger recording on event
openbci record --output blink.csv --trigger blink --duration 30s

# List recordings
openbci record list
openbci record list --directory ~/my_recordings

# Get recording info
openbci record info session.csv

# Convert between formats
openbci record convert session.csv session.parquet

# Trim recording
openbci record trim input.csv output.csv --start 1000 --end 5000
```

### Analysis

```nu
# Analyze a recording file
openbci analyze session.csv

# Calculate band powers
openbci analyze session.csv --bands

# Power spectral density
openbci analyze session.csv --psd

# Inter-channel coherence
openbci analyze session.csv --coherence

# Extract features (Hjorth parameters)
openbci analyze session.csv --features

# Combined analysis
openbci analyze session.csv --bands --psd --features --coherence

# Specific channels
openbci analyze session.csv --bands --channels 0,1,2

# Detect artifacts
openbci analyze artifacts session.csv --threshold 200

# Compare two recordings
openbci analyze compare session1.csv session2.csv

# Pipe from recording
openbci record --duration 60s --output - | openbci analyze --bands
```

### Visualization

```nu
# Real-time terminal plots
openbci viz --mode terminal
openbci viz --mode terminal --channels 0,1 --duration 60s

# ASCII art brain map
openbci viz --mode ascii

# Waveform display
openbci viz --mode waveform

# Band power bars
openbci viz --bands

# Topographic map
openbci viz --mode topo

# Visualize recording file
openbci viz file session.csv --type waveform
openbci viz file session.csv --type bands --start 1000 --duration 10s
```

### Configuration

```nu
# Initialize configuration
openbci config init

# Get configuration values
openbci config get
ten
openbci config get default_sample_rate
openbci config get streaming.buffer_size

# Set configuration values
openbci config set default_sample_rate 500
openbci config set device.preferred_board cyton
openbci config set recording.default_directory ~/eeg_data

# Edit configuration in $EDITOR
openbci config edit

# Show current configuration
openbci config show

# Validate configuration
openbci config validate

# Reset to defaults
openbci config reset --confirm

# Configuration wizard
openbci config wizard

# List all config keys
openbci config keys
```

### Pipelines

```nu
# List pipelines
openbci pipeline list
openbci pipeline list --verbose

# Create a new pipeline
openbci pipeline create my-pipeline

# Edit pipeline
openbci pipeline edit my-pipeline

# Run pipeline
openbci pipeline run my-pipeline
openbci pipeline run my-pipeline --verbose

# Show pipeline details
openbci pipeline show my-pipeline

# Copy pipeline
openbci pipeline copy my-pipeline my-pipeline-v2

# Delete pipeline
openbci pipeline delete my-pipeline --confirm

# View logs
openbci pipeline logs my-pipeline
openbci pipeline logs my-pipeline --tail 50

# Export/Import
openbci pipeline export my-pipeline ./my-pipeline.json
openbci pipeline import ./my-pipeline.json --rename imported-pipeline

# Pre-built pipelines
openbci pipeline alpha --threshold 0.3 --duration 60s
openbci pipeline clean recording.csv --threshold 200 --output cleaned.csv
```

## Pipeline Examples

### Simple Alpha Detection Pipeline

```nu
# stream_alpha.nu
use stream *
use analyze *

export def main [
    --duration: duration = 60sec
    --threshold: float = 0.3
] {
    print "Detecting alpha waves..."
    
    # Stream and calculate band powers
    let data = (main stream powers --duration $duration)
    
    # Count high-alpha samples
    let alpha_count = ($data | filter { |s|
        let avg_alpha = ($s | columns | where { |c| $c | str starts-with "ch" } | each { |ch|
            $s | get $ch | get alpha
        } | math avg)
        $avg_alpha > $threshold
    } | length)
    
    let total = ($data | length)
    let pct = ($alpha_count * 100 / $total)
    
    print $"Alpha detected in ($alpha_count)/($total) samples (($pct)%)"
}
```

### Batch Processing Pipeline

```nu
# batch_process.nu
use analyze *
use record *

export def main [
    input_dir: path = "~/recordings"
    output_dir: path = "~/results"
] {
    mkdir $output_dir
    
    let files = (ls $input_dir | where name =~ '\.csv$')
    
    for file in $files {
        print $"Processing ($file.name)..."
        
        let results = (main analyze $file.name --bands --features)
        let out_file = ($output_dir | path join ($file.name | path basename | str replace ".csv" "_results.json"))
        
        $results | save -f $out_file
    }
    
    print "Batch processing complete!"
}
```

## Advanced Usage

### Complex Pipeline with Pipes

```nu
# Stream -> Filter -> Extract Features -> Classify -> Record
openbci stream 
    | filter { |s| ($s.ch0 | math abs) < 500 }  # Remove artifacts
    | window 256                                # Sliding window
    | each { |w| calc_features $w }            # Extract features
    | where arousal > 0.7                      # Filter by state
    | save high_arousal_segments.csv
```

### Real-time Monitoring with Alert

```nu
# Monitor for seizure-like activity
openbci stream --channels 0,1 | each { |sample|
    let high_freq_power = calc_gamma $sample
    if $high_freq_power > 100 {
        print $"ALERT: High gamma at (date now)!"
        # Could trigger external alert here
    }
    $sample
}
```

### Hypergraph Integration

```nu
# Stream to hypergraph
openbci stream | hypergraph ingest --graph eeg_sessions --session (date now | format date "%Y%m%d_%H%M%S")

# Query historical sessions
hypergraph query 'g.V().hasLabel("eeg_session").values("timestamp")'
```

## Configuration File

Location: `~/.config/openbci/config.nuon`

```nuon
{
    version: "0.2.0"
    default_sample_rate: 250
    default_channels: 8
    default_output_format: "csv"
    
    streaming: {
        buffer_size: 256
        packet_timeout_ms: 1000
        reconnect_attempts: 3
    }
    
    recording: {
        default_directory: "~/openbci_recordings"
        auto_save_metadata: true
    }
    
    device: {
        auto_connect: false
        preferred_board: null
        cyton_baud_rate: 115200
    }
    
    hypergraph: {
        enabled: false
        socket_path: "~/.config/openbci/hypergraph.sock"
    }
}
```

## Troubleshooting

### Device Not Found

```nu
# Check permissions
ls -la /dev/ttyUSB*

# Add user to dialout group (Linux)
sudo usermod -a -G dialout $env.USER

# Check device manually
stty -F /dev/ttyUSB0 115200
echo "v" > /dev/ttyUSB0
cat /dev/ttyUSB0
```

### Permission Denied

```nu
# Fix serial permissions
sudo chmod 666 /dev/ttyUSB0

# Or add udev rule
echo 'SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", MODE="0666"' | sudo tee /etc/udev/rules.d/50-openbci.rules
```

### BLE Connection Issues (Ganglion)

```nu
# Check bluetooth service
systemctl status bluetooth

# Scan for devices
bluetoothctl scan on

# Pair manually
bluetoothctl pair xx:xx:xx:xx:xx:xx
```

### ImportError for EDF export

```bash
# Install pyedflib
pip3 install pyedflib
```

## Shell Completions

Generate completions for your shell:

```nu
# Nushell
openbci complete --shell nu > ~/.config/openbci/completions.nu
echo 'source ~/.config/openbci/completions.nu' >> ~/.config/nushell/config.nu

# Bash
openbci complete --shell bash > /etc/bash_completion.d/openbci

# Zsh
openbci complete --shell zsh > /usr/share/zsh/site-functions/_openbci

# Fish
openbci complete --shell fish > ~/.config/fish/completions/openbci.fish
```

## Architecture

```
openbci/
├── openbci.nu      # Main CLI entry point
├── device.nu       # Device management
├── stream.nu       # Real-time streaming
├── record.nu       # File recording
├── analyze.nu      # Signal analysis
├── viz.nu          # Visualization
├── config.nu       # Configuration
├── pipeline.nu     # Processing pipelines
└── mod.nu          # Module exports
```

## Data Flow

```
OpenBCI Hardware → Device Module → Stream Module → [Pipes/Filters] → Output
                                        ↓
                                   Record Module → Files (CSV/Parquet/EDF)
                                        ↓
                                   Analyze Module → Statistics/Features
                                        ↓
                                   Viz Module → Terminal Display
                                        ↓
                                   Pipeline Module → Custom Workflows
                                        ↓
                                   Hypergraph → Persistent Storage
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with `nu test.nu`
5. Submit a pull request

## License

MIT License - See LICENSE file for details

## Resources

- [OpenBCI Documentation](https://docs.openbci.com/)
- [Nushell Documentation](https://www.nushell.sh/book/)
- [OpenBCI Forum](https://openbci.com/community)

## Support

- Issues: [GitHub Issues](https://github.com/yourusername/openbci-nushell/issues)
- Discussions: [GitHub Discussions](https://github.com/yourusername/openbci-nushell/discussions)

---

Made with ❤️ for the brain-computer interface community
