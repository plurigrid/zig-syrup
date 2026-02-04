# OpenBCI Nushell Module
# Comprehensive CLI tools for OpenBCI brain-computer interface operations
#
# Usage:
#   use openbci *
#   openbci device list
#   openbci stream | where ch0 > 100
#
# Installation:
#   1. Copy this directory to your nushell modules path
#   2. Add to config.nu: use ~/path/to/openbci *

# =============================================================================
# Module Metadata
# =============================================================================

export const VERSION = "0.2.0"
export const SUPPORTED_BOARDS = [Cyton CytonDaisy Ganglion]
export const EEG_BANDS = {
    delta: { min: 0.5, max: 4.0, color: "blue" }
    theta: { min: 4.0, max: 8.0, color: "cyan" }
    alpha: { min: 8.0, max: 13.0, color: "green" }
    beta: { min: 13.0, max: 30.0, color: "yellow" }
    gamma: { min: 30.0, max: 50.0, color: "red" }
}

# =============================================================================
# Module Exports
# =============================================================================

# Re-export all commands from submodules
export use device *
export use stream *
export use record *
export use analyze *
export use viz *
export use config *
export use pipeline *

# A/B World Testing Modules
export use world_ab.nu *
export use multiplayer.nu *
export use immer_ops.nu *
export use ewig_history.nu *
export use ab_orchestrator.nu *
export use world_protocol.nu *
export use simulation_runner.nu *

# Re-export the main CLI entry point
export use openbci.nu main

# =============================================================================
# Shell Integration Hooks
# =============================================================================

# Setup hook for shell integration
export def setup-shell-integration []: [ nothing -> nothing ] {
    print "Setting up OpenBCI shell integration..."
    
    # Create config directory
    let config_dir = ($nu.home-path | path join ".config" "openbci")
    mkdir $config_dir
    
    # Initialize default config if not exists
    let config_file = ($config_dir | path join "config.nuon")
    if not ($config_file | path exists) {
        print "Initializing default configuration..."
        config init
    }
    
    # Add completions to nushell config if not present
    let completions_file = ($config_dir | path join "completions.nu")
    if not ($completions_file | path exists) {
        print "Generating completions..."
        let completions = (main complete --shell nu)
        $completions | save -f $completions_file
    }
    
    print ""
    print "Add the following to your config.nu to enable completions:"
    print $"  source ($completions_file)"
    print ""
    print "Optional: Add to env.nu for auto-connect:"
    print "  openbci device connect"
}

# =============================================================================
# Utility Functions
# =============================================================================

# Convert microvolts to meaningful signal quality indicator
export def signal-quality [uv: float]: [ nothing -> string ] {
    if ($uv | math abs) < 50 {
        "excellent"
    } else if ($uv | math abs) < 100 {
        "good"
    } else if ($uv | math abs) < 200 {
        "fair"
    } else {
        "poor"
    }
}

# Get color code for signal quality
export def quality-color [quality: string]: [ nothing -> string ] {
    match $quality {
        "excellent" => "\e[32m"  # Green
        "good" => "\e[36m"       # Cyan
        "fair" => "\e[33m"       # Yellow
        "poor" => "\e[31m"       # Red
        _ => "\e[0m"
    }
}

# Format duration in human-readable format
export def format-duration [duration: duration]: [ nothing -> string ] {
    let nanos = ($duration | into int)
    let seconds = ($nanos / 1000000000 | math floor)
    let mins = ($seconds / 60 | math floor)
    let secs = ($seconds mod 60)
    let millis = (($nanos mod 1000000000) / 1000000 | math floor)
    
    if $mins > 0 {
        $"($mins)m ($secs)s"
    } else if $secs > 0 {
        $"($secs).($millis)s"
    } else {
        $"($millis)ms"
    }
}

# Validate EEG channel index
export def validate-channel [ch: int, max_channels: int = 16]: [ nothing -> bool ] {
    $ch >= 0 and $ch < $max_channels
}

# Parse channel list from string
export def parse-channels [channels_str: string, max_channels: int = 16]: [ nothing -> list ] {
    if $channels_str == "all" {
        seq 0 ($max_channels - 1)
    } else {
        $channels_str | split "," | each { into int } | filter { |c| validate-channel $c $max_channels }
    }
}

# Band-pass filter helper (placeholder - actual filtering would use scipy/numpy)
export def bandpass-filter [
    signal: list
    low_freq: float
    high_freq: float
    sample_rate: int = 250
]: [ list -> list ] {
    # Placeholder - returns original signal
    # In production, call Python scipy.signal.butter + filtfilt
    print $"Applying bandpass filter: ($low_freq)-($high_freq) Hz"
    $signal
}

# Notch filter for line noise removal
export def notch-filter [
    signal: list
    freq: float = 60.0
    sample_rate: int = 250
]: [ list -> list ] {
    # Placeholder - returns original signal
    print $"Applying notch filter at ($freq) Hz"
    $signal
}

# =============================================================================
# Data Conversion Utilities
# =============================================================================

# Convert raw ADC values to microvolts
export def adc-to-uv [adc_value: float, gain: float = 24.0]: [ nothing -> float ] {
    # OpenBCI uses 24-bit ADC with programmable gain
    # Vref = 4.5V, gain typically 24
    let vref = 4.5
    let scale_factor = ($vref / ($gain * (2 ** 23 - 1)) * 1000000)  # Convert to µV
    $adc_value * $scale_factor
}

# Convert microvolts to raw ADC values
export def uv-to-adc [uv_value: float, gain: float = 24.0]: [ nothing -> float ] {
    let vref = 4.5
    let scale_factor = ($vref / ($gain * (2 ** 23 - 1)) * 1000000)
    $uv_value / $scale_factor
}

# =============================================================================
# Batch Processing Utilities
# =============================================================================

# Process multiple recordings
export def batch-process [
    files: list           # List of file paths
    processor: closure    # Processing function
    --output-dir: path    # Output directory
]: [ nothing -> table ] {
    mut results = []
    
    for file in $files {
        print $"Processing ($file | path basename)..."
        
        try {
            let result = (do $processor $file)
            $results = ($results | append {
                file: ($file | path basename)
                status: "success"
                result: $result
            })
        } catch { |e|
            $results = ($results | append {
                file: ($file | path basename)
                status: "error"
                error: $e.msg
            })
        }
    }
    
    $results
}

# Parallel processing helper
export def parallel-process [
    items: list
    processor: closure
    --max-jobs: int = 4
]: [ nothing -> list ] {
    # Sequential processing for now
    # Nushell doesn't have built-in parallelism yet
    $items | each { |item| do $processor $item }
}

# =============================================================================
# Reporting Utilities
# =============================================================================

# Generate session report
export def generate-report [
    data: record          # Session data
    --output: path        # Output file
]: [ nothing -> string ] {
    let report = $"# OpenBCI Session Report

Generated: (date now | format date "%Y-%m-%d %H:%M:%S")

## Summary
- Duration: ($data | get -i duration | default "unknown")
- Samples: ($data | get -i samples | default "unknown")
- Channels: ($data | get -i channels | default "unknown")

## Signal Quality
($data | get -i quality | default {} | transpose metric value | each { |row|
    $"- ($row.metric): ($row.value)"
} | str join "\n")

## Band Powers
($data | get -i bands | default {} | transpose band value | each { |row|
    $"- ($row.band): ($row.value | math round -p 2) µV²"
} | str join "\n")

## Notes
($data | get -i notes | default "None")
"
    
    if $output != null {
        $report | save -f $output
    }
    
    $report
}

# Export data to various formats
export def export-data [
    data: any
    format: string
    output: path
]: [ nothing -> nothing ] {
    match $format {
        "csv" => { $data | save -f $output }
        "json" => { $data | to json | save -f $output }
        "jsonl" => { $data | each { |r| $r | to json } | str join "\n" | save -f $output }
        "parquet" => { $data | polars into-df | polars save $output }
        "txt" => { $data | table | save -f $output }
        _ => { error make { msg: $"Unknown format: ($format)" } }
    }
    
    print $"Exported to ($output)"
}

# =============================================================================
# Debugging Utilities
# =============================================================================

# Test connection to device
export def test-connection []: [ nothing -> record ] {
    print "Testing OpenBCI connection..."
    
    let result = {
        timestamp: (date now | format date "%Y-%m-%d %H:%M:%S")
        tests: []
    }
    
    # Test 1: Check for connected devices
    print "  Checking for devices..."
    use device main device list
    let devices = (device list)
    let device_test = {
        name: "device_detection"
        status: (if ($devices | is-empty) { "warning" } else { "pass" })
        devices_found: ($devices | length)
    }
    
    # Test 2: Check config
    print "  Checking configuration..."
    let config = (config get)
    let config_test = {
        name: "configuration"
        status: (if ($config | is-empty) { "fail" } else { "pass" })
        version: ($config | get -i version)
    }
    
    # Test 3: Check dependencies
    print "  Checking dependencies..."
    let python_available = (which python3 | is-not-empty)
    let deps_test = {
        name: "dependencies"
        status: (if $python_available { "pass" } else { "warning" })
        python: $python_available
    }
    
    let final_result = ($result 
        | insert tests [$device_test $config_test $deps_test]
        | insert overall_status (if ($device_test.status == "pass") and ($config_test.status == "pass") { "ready" } else { "needs_attention" })
    )
    
    print ""
    match $final_result.overall_status {
        "ready" => { print "✓ System ready for OpenBCI operations" }
        "needs_attention" => { print "⚠ System has warnings - check test results" }
        _ => { print "✗ System has errors" }
    }
    
    $final_result
}

# Debug packet parsing
export def debug-packets [
    port: string
    --count: int = 10
]: [ nothing -> table ] {
    print $"Reading ($count) packets from ($port)..."
    
    mut packets = []
    
    try {
        for i in 0..<$count {
            # Read raw packet bytes
            let raw = (cat $port | head -c 33 | into binary)
            
            # Parse packet
            let packet = {
                index: $i
                header: ($raw | bytes at 0 | into int | into binary | bytes at 0)
                sample_number: ($raw | bytes at 1 | into int)
                timestamp: (date now | format date "%H:%M:%S%.3f")
                valid: (($raw | bytes at 0 | into int) == 0xA0)
            }
            
            $packets = ($packets | append $packet)
        }
    } catch { |e|
        print $"Error reading packets: ($e.msg)"
    }
    
    $packets
}

# =============================================================================
# Module Initialization
# =============================================================================

# Called when module is loaded
export def init []: [ nothing -> record ] {
    # Ensure directories exist
    mkdir ($nu.home-path | path join ".config" "openbci")
    mkdir ($nu.home-path | path join ".config" "openbci" "pipelines")
    mkdir ($nu.home-path | path join ".config" "openbci" "pipeline_logs")
    mkdir ($nu.home-path | path join "openbci_recordings")
    
    {
        version: $VERSION
        loaded: true
        timestamp: (date now | format date "%Y-%m-%d %H:%M:%S")
    }
}

# Run initialization
init
