#!/usr/bin/env nu
# openbci_receiver.nu
# Main receiver script for OpenBCI TCP data streams
# Connects to port 16572 and outputs structured EEG data

use std log
use ./config.nu [load-config tcp-url channel-config]
use ./eeg_types.nu [new-sample is-valid-sample EEGSample]

# =============================================================================
# Module Version
# =============================================================================

const VERSION = "0.1.0"

# =============================================================================
# TCP Connection Functions
# =============================================================================

# Connect to OpenBCI TCP socket
export def connect [
    --host: string = "127.0.0.1"
    --port: int = 16572
    --timeout: int = 5000
] -> any {
    let addr = $"($host):($port)"
    log info $"Connecting to OpenBCI at ($addr)..."
    
    try {
        # Use nushell's tcp command to connect
        let stream = (tcp connect $addr)
        log info "✅ Connected to OpenBCI TCP stream"
        $stream
    } catch {|e|
        log error $"Failed to connect: ($e)"
        error make {msg: $"Could not connect to OpenBCI at ($addr)"}
    }
}

# Read and parse a single JSON line from stream
export def read-sample [stream: any] -> record {
    let line = ($stream | lines | first)
    
    if ($line | is-empty) {
        error make {msg: "Empty line received from stream"}
    }
    
    try {
        let parsed = ($line | from json)
        
        # Handle different packet formats
        let sample = if ($parsed | get ts? | is-not-empty) {
            # Legacy format: {ts, data}
            {
                timestamp: $parsed.ts
                sample_num: ($parsed.sample_num? | default 0)
                channels: $parsed.data
                aux: ($parsed.aux? | default [0.0 0.0 0.0])
            }
        } else if ($parsed | get timestamp? | is-not-empty) {
            # New format: {timestamp, sample_num, channels, aux}
            {
                timestamp: $parsed.timestamp
                sample_num: $parsed.sample_num
                channels: $parsed.channels
                aux: ($parsed.aux? | default [0.0 0.0 0.0])
            }
        } else {
            error make {msg: "Unknown packet format"}
        }
        
        $sample
        
    } catch {|e|
        log debug $"Parse error: ($e)"
        error make {msg: $"Failed to parse sample: ($e)"}
    }
}

# =============================================================================
# Streaming Commands
# =============================================================================

# Stream EEG data continuously from OpenBCI
export def stream [
    --host: string = "127.0.0.1"
    --port: int = 16572
    --config: path = null
    --raw             # Output raw JSON instead of structured records
] {
    let cfg = if ($config | is-not-empty) {
        load-config $config
    } else {
        load-config
    }
    
    let use_host = if ($host != "127.0.0.1") { $host } else { $cfg.tcp_host }
    let use_port = if ($port != 16572) { $port } else { $cfg.tcp_port }
    
    let stream = (connect --host $use_host --port $use_port)
    
    # Skip header line if present
    let first_line = ($stream | lines | first)
    if ($first_line | str starts-with '{"version"') {
        log info "Received stream header"
    } else {
        # Process first line as data
        try {
            if $raw {
                print $first_line
            } else {
                $first_line | from json | format-sample
            }
        } catch {|e|
            log debug $"First line not valid sample: ($e)"
        }
    }
    
    # Stream remaining data
    $stream
    | lines
    | each {|line|
        try {
            if $raw {
                $line
            } else {
                let parsed = ($line | from json)
                format-parsed $parsed
            }
        } catch {|e|
            log debug $"Parse error: ($e)"
            null
        }
    }
    | filter {|x| $x != null}
}

# Format a parsed JSON sample into standard record
export def format-parsed [parsed: record] -> record {
    if ($parsed | get ts? | is-not-empty) {
        {
            timestamp: $parsed.ts
            sample_num: ($parsed.sample_num? | default 0)
            channels: $parsed.data
            aux: ($parsed.aux? | default [0.0 0.0 0.0])
        }
    } else {
        {
            timestamp: $parsed.timestamp
            sample_num: $parsed.sample_num
            channels: $parsed.channels
            aux: ($parsed.aux? | default [0.0 0.0 0.0])
        }
    }
}

# Format a sample for output
export def format-sample [sample: record] -> record {
    $sample
}

# =============================================================================
# Capture Commands
# =============================================================================

# Capture N samples and save to file
export def capture [
    --samples: int = 1000        # Number of samples to capture
    --output: string = null     # Output file (parquet, csv, jsonl)
    --host: string = "127.0.0.1"
    --port: int = 16572
    --duration: duration = null # Alternative to samples (e.g., 10sec)
    --buffer-size: int = 10000  # Buffer before writing
] {
    let cfg = load-config
    let use_host = if ($host != "127.0.0.1") { $host } else { $cfg.tcp_host }
    let use_port = if ($port != 16572) { $port } else { $cfg.tcp_port }
    
    # Calculate samples from duration if provided
    let target_samples = if ($duration | is-not-empty) {
        let seconds = ($duration | into int) / 1_000_000_000
        ($seconds * $cfg.sampling_rate | into int)
    } else {
        $samples
    }
    
    log info $"Capturing ($target_samples) samples from ($use_host):($use_port)..."
    
    let stream = (connect --host $use_host --port $use_port)
    
    # Collect samples
    mut collected = []
    mut count = 0
    
    for line in ($stream | lines) {
        if $count >= $target_samples {
            break
        }
        
        try {
            let parsed = ($line | from json)
            let sample = (format-parsed $parsed)
            $collected = ($collected | append $sample)
            $count = $count + 1
            
            # Progress indicator
            if ($count % 100 == 0) {
                print -n $"\rCollected ($count)/($target_samples) samples..."
            }
        } catch {|e|
            log debug $"Parse error on line: ($e)"
        }
    }
    
    print ""  # New line after progress
    log info $"Capture complete: ($collected | length) samples"
    
    # Convert to table
    let table = ($collected | wrap samples | get samples)
    
    # Save or return
    if ($output | is-not-empty) {
        let ext = ($output | path parse | get extension)
        
        match $ext {
            "parquet" => {
                # Try to use polars if available
                try {
                    let df = ($table | polars into-df)
                    $df | polars save $output
                    log info $"Saved to ($output) (parquet)"
                } catch {|e|
                    log warning $"Polars not available, saving as JSON: ($e)"
                    $table | save $output
                }
            }
            "csv" => {
                $table | to csv | save $output
                log info $"Saved to ($output) (CSV)"
            }
            "jsonl" | "ndjson" => {
                $table | to jsonl | save $output
                log info $"Saved to ($output) (JSONL)"
            }
            _ => {
                # Default to JSONL
                $table | to jsonl | save $output
                log info $"Saved to ($output) (JSONL)"
            }
        }
    }
    
    $table
}

# =============================================================================
# Real-time Monitoring
# =============================================================================

# Monitor signal quality in real-time
export def monitor [
    --host: string = "127.0.0.1"
    --port: int = 16572
    --window: int = 250  # Samples for quality calc (~1 sec at 250Hz)
] {
    let cfg = load-config
    let use_host = if ($host != "127.0.0.1") { $host } else { $cfg.tcp_host }
    let use_port = if ($port != 16572) { $port } else { $cfg.tcp_port }
    
    let stream = (connect --host $use_host --port $use_port)
    
    mut buffer = []
    mut sample_count = 0
    
    $stream
    | lines
    | each {|line|
        try {
            let parsed = ($line | from json)
            let sample = (format-parsed $parsed)
            
            $buffer = ($buffer | append $sample)
            $sample_count = $sample_count + 1
            
            # Calculate quality every window samples
            if ($buffer | length) >= $window {
                let quality = (calculate-quality $buffer $cfg.channel_names)
                display-quality $quality
                $buffer = []
            }
            
            $sample
        } catch {|e|
            null
        }
    }
    | filter {|x| $x != null}
}

# Calculate signal quality metrics for a buffer of samples
export def calculate-quality [samples: list channel_names: list] -> record {
    let n = $samples | length
    let n_ch = ($samples | first).channels | length
    
    mut channel_quality = []
    
    for ch_idx in 0..<($n_ch) {
        let ch_data = ($samples | each {|s| $s.channels | get $ch_idx})
        let mean = ($ch_data | math avg)
        let std = ($ch_data | math stddev)
        let rms = ($ch_data | each {|x| $x * $x} | math avg | math sqrt)
        
        # Simple quality: low std = good signal (assuming centered)
        let snr = if $std > 0 { ($rms / $std) } else { 0 }
        let is_good = ($std > 0.1 and $std < 200)  # Reasonable EEG range
        
        $channel_quality = ($channel_quality | append {
            channel: ($channel_names | get $ch_idx | default $"Ch($ch_idx)")
            mean: $mean
            std: $std
            rms: $rms
            snr: $snr
            is_good: $is_good
        })
    }
    
    {
        timestamp: (date now)
        samples_analyzed: $n
        channels: $channel_quality
        good_count: ($channel_quality | where is_good | length)
        total_channels: $n_ch
    }
}

# Display quality metrics
export def display-quality [quality: record] {
    let status = if $quality.good_count == $quality.total_channels {
        $"(ansi green)● EXCELLENT(ansi reset)"
    } else if $quality.good_count >= ($quality.total_channels // 2) {
        $"(ansi yellow)● FAIR(ansi reset)"
    } else {
        $"(ansi red)● POOR(ansi reset)"
    }
    
    print -n $"\r($status) Channels: ($quality.good_count)/($quality.total_channels) good | "
    
    for ch in $quality.channels {
        let color = if $ch.is_good { "green" } else { "red" }
        let symbol = if $ch.is_good { "●" } else { "○"
        }
        print -n $"(ansi ($color))($symbol)($ch.channel)(ansi reset) "
    }
}

# =============================================================================
# Utility Commands
# =============================================================================

# Test connection to OpenBCI
export def test-connection [
    --host: string = "127.0.0.1"
    --port: int = 16572
] {
    log info $"Testing connection to ($host):($port)..."
    
    try {
        let stream = (connect --host $host --port $port)
        
        # Try to read one sample
        let first_line = ($stream | lines | first)
        
        if ($first_line | str starts-with '{"version"') {
            let header = ($first_line | from json)
            print "✅ Connection successful!"
            print $"   Version: ($header.version)"
            print $"   Board: ($header.board_type)"
            print $"   Channels: ($header.num_channels)"
            print $"   Sample Rate: ($header.sampling_rate) Hz"
            true
        } else {
            let sample = ($first_line | from json | format-parsed $in)
            print "✅ Connection successful!"
            print $"   Received sample at ($sample.timestamp)"
            print $"   Channels: ($sample.channels | length)"
            true
        }
    } catch {|e|
        print $"❌ Connection failed: ($e)"
        false
    }
}

# Show help and usage
export def help [] {
    print "OpenBCI Nuworlds Receiver v" + $VERSION
    print ""
    print "USAGE:"
    print "  openbci <command> [options]"
    print ""
    print "COMMANDS:"
    print "  stream [--host HOST] [--port PORT]     Stream EEG data continuously"
    print "  capture [--samples N] [--output FILE]  Capture samples to file"
    print "  monitor [--window N]                   Real-time quality monitoring"
    print "  test-connection                        Test TCP connection"
    print "  help                                   Show this help"
    print ""
    print "EXAMPLES:"
    print "  # Stream continuously"
    print "  openbci stream | filter {|e| ($e.channels.0 | abs) > 100 }"
    print ""
    print "  # Capture 1000 samples"
    print "  openbci capture --samples 1000 --output eeg_data.parquet"
    print ""
    print "  # Monitor signal quality"
    print "  openbci monitor"
}

# =============================================================================
# Main Entry Point
# =============================================================================

# Main command dispatcher
export def main [
    command: string = "help"    # Command to run
    ...args                     # Additional arguments
] {
    match $command {
        "stream" => { stream ...$args }
        "capture" => { capture ...$args }
        "monitor" => { monitor ...$args }
        "test-connection" => { test-connection ...$args }
        "help" | _ => { help }
    }
}
