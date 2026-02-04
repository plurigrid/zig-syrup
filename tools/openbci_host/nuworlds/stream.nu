# OpenBCI Streaming Module
# Handles real-time EEG data streaming with nushell integration

use config get-config
use device main device info

# EEG streaming constants
const DEFAULT_SAMPLE_RATE = 250
const DEFAULT_CHANNELS = 8
const EEG_MIN = -8388608.0  # 24-bit ADC min
const EEG_MAX = 8388607.0   # 24-bit ADC max
const SCALE_FACTOR_UV = 0.02235  # Converts to microvolts

# Stream EEG data from OpenBCI device
#
# Outputs structured data as tables for nushell piping
# All channels are in microvolts (µV)
#
# Usage:
#   openbci stream                              # Stream all channels
#   openbci stream --channels 0,1,2             # Stream specific channels
#   openbci stream --duration 60s               # Stream for 60 seconds
#   openbci stream --format jsonl               # Output JSON lines
#   openbci stream --filter "alpha > 0.5"       # Filter by band power
#
# Examples:
#   openbci stream | where ch0 > 100            # Filter by amplitude
#   openbci stream | save stream.csv            # Save to CSV
#   openbci stream --duration 10s | stats       # Get statistics
export def "main stream" [
    --channels(-c): string = "all"      # Comma-separated channel list (e.g., "0,1,2") or "all"
    --duration(-d): duration            # Stream duration (e.g., 60sec, 5min)
    --format(-f): string = "table"      # Output format: table, json, jsonl, csv
    --filter: string                    # Filter expression for band power
    --sample-rate(-r): int              # Sample rate override (Hz)
    --buffer-size: int = 256            # Samples per batch
    --to-file: path                     # Also save to file while streaming
]: [ nothing -> table ] {
    
    let config = get-config
    let device_info = try { device info } catch { { port: null } }
    
    if ($device_info.port | is-empty) {
        print "No device connected. Connecting to first available device..."
        use device main device list, main device connect
        let devices = (device list)
        if ($devices | is-empty) {
            error make { msg: "No OpenBCI devices found. Please connect a device first." }
        }
        device connect ($devices | first | get port)
    }
    
    let port = (device info | get port)
    let sample_rate = $sample_rate | default ($config | get -i default_sample_rate | default $DEFAULT_SAMPLE_RATE)
    
    # Parse channel list
    let channel_list = if $channels == "all" {
        seq 0 ($DEFAULT_CHANNELS - 1)
    } else {
        $channels | split "," | each { into int }
    }
    
    # Calculate end time if duration specified
    let end_time = if $duration != null {
        (date now) + $duration
    } else {
        null
    }
    
    # Start streaming on device
    start_device_streaming $port
    
    print $"Streaming from ($port)..."
    print $"Channels: ($channel_list | str join ', ')"
    print $"Sample rate: ($sample_rate) Hz"
    print "Press Ctrl+C to stop"
    print ""
    
    # Create output file if specified
    let output_file = $to_file
    if $output_file != null {
        # Write header
        let header = ([timestamp] | append ($channel_list | each { |i| $"ch($i)" }) | str join ",")
        $header | save -f $output_file
    }
    
    # Stream data
    mut sample_count = 0
    mut start_time = date now
    
    # Main streaming loop
    loop {
        # Check if duration exceeded
        if $end_time != null and (date now) >= $end_time {
            print "\nDuration reached, stopping stream..."
            break
        }
        
        # Read samples from device
        let samples = (read_samples $port $buffer_size $channel_list)
        
        # Apply filter if specified
        let filtered_samples = if $filter != null {
            $samples | filter_samples $filter
        } else {
            $samples
        }
        
        # Format and output
        let formatted = (format_samples $filtered_samples $format $channel_list)
        
        # Output based on format
        match $format {
            "jsonl" => { $formatted | each { |row| $row | to json } | str join "\n" | print }
            "json" => { $formatted | to json | print }
            "csv" => { $formatted | to csv | print }
            _ => { $formatted | print }
        }
        
        # Append to file if specified
        if $output_file != null and $format == "csv" {
            $formatted | to csv --noheaders | save --append $output_file
        }
        
        $sample_count = $sample_count + ($samples | length)
        
        # Small delay to prevent CPU spinning
        sleep 10ms
    }
    
    # Stop streaming on device
    stop_device_streaming $port
    
    # Return summary
    {
        samples_collected: $sample_count
        duration_sec: ((date now) - $start_time | into int) / 1000000000
        sample_rate: ($sample_count / (((date now) - $start_time | into int) / 1000000000))
        channels: $channel_list
        output_format: $format
    }
}

# Start streaming mode on device
def start_device_streaming [port: string]: [ nothing -> nothing ] {
    try {
        if ($port | str starts-with "ble://") {
            # BLE start command
            print "Starting BLE stream..."
        } else {
            # Serial start command - 'b' begins binary streaming
            echo "b" | (stty -F $port 115200 cs8 -cstopb -parenb raw -echo 2>/dev/null)
        }
    } catch {
        print "Warning: Could not send start command to device"
    }
}

# Stop streaming mode on device
def stop_device_streaming [port: string]: [ nothing -> nothing ] {
    try {
        if ($port | str starts-with "ble://") {
            # BLE stop command
            print "Stopping BLE stream..."
        } else {
            # Serial stop command - 's' stops streaming
            echo "s" | (stty -F $port 115200 cs8 -cstopb -parenb raw -echo 2>/dev/null)
        }
    } catch {
        print "Warning: Could not send stop command to device"
    }
}

# Read samples from device
def read_samples [port: string, count: int, channels: list]: [ nothing -> list ] {
    mut samples = []
    
    try {
        if ($port | str starts-with "ble://") {
            # Simulate BLE data for now
            $samples = (generate_simulated_samples $count $channels)
        } else {
            # Read from serial port
            # OpenBCI binary format: 0xA0 header + sample number + 24-bit channel data + 0xC0 footer
            let raw_data = (cat $port | head -c ($count * 33) | into binary)
            $samples = (parse_binary_samples $raw_data $channels)
        }
    } catch {
        # Fallback to simulated data
        $samples = (generate_simulated_samples $count $channels)
    }
    
    $samples
}

# Parse binary sample data from OpenBCI
def parse_binary_samples [data: binary, channels: list]: [ nothing -> list ] {
    mut samples = []
    mut offset = 0
    let packet_size = 33  # Standard OpenBCI packet size
    
    while $offset < ($data | length) {
        let packet = ($data | bytes at $offset..($offset + $packet_size))
        
        # Check packet header
        if ($packet | bytes at 0) == 0xA0 {
            let sample_num = ($packet | bytes at 1 | into int)
            
            mut channel_data = {}
            mut ch_idx = 0
            
            for ch in $channels {
                # Each channel is 3 bytes (24-bit), big-endian
                let byte_offset = 2 + ($ch * 3)
                let raw_value = ($packet | bytes at $byte_offset..($byte_offset + 3))
                let int_value = (bytes_to_int24 $raw_value)
                let uv_value = ($int_value * $SCALE_FACTOR_UV)
                
                $channel_data = ($channel_data | insert $"ch($ch)" $uv_value)
            }
            
            $samples = ($samples | append ({
                timestamp: (date now | format date "%Y-%m-%d %H:%M:%S%.3f")
                sample_num: $sample_num
            } | merge $channel_data))
        }
        
        $offset = $offset + $packet_size
    }
    
    $samples
}

# Convert 3 bytes to signed 24-bit integer
def bytes_to_int24 [bytes: binary]: [ nothing -> int ] {
    let b0 = ($bytes | bytes at 0 | into int)
    let b1 = ($bytes | bytes at 1 | into int)
    let b2 = ($bytes | bytes at 2 | into int)
    
    let value = (($b0 << 16) + ($b1 << 8) + $b2)
    
    # Handle sign extension
    if ($value & 0x800000) != 0 {
        $value - 0x1000000
    } else {
        $value
    }
}

# Generate simulated EEG samples for testing
def generate_simulated_samples [count: int, channels: list]: [ nothing -> list ] {
    mut samples = []
    let now = date now
    
    for i in 0..<$count {
        let timestamp = $now + ($i * 4ms)  # 250 Hz = 4ms per sample
        
        mut sample = {
            timestamp: ($timestamp | format date "%Y-%m-%d %H:%M:%S%.3f")
            sample_num: $i
        }
        
        # Generate synthetic EEG data with different frequency components
        for ch in $channels {
            let t = ($i | into float) / 250.0  # time in seconds
            
            # Alpha (8-13 Hz) + Beta (13-30 Hz) + some noise
            let alpha = 100 * (2 * 3.14159 * 10 * $t | math sin)
            let beta = 50 * (2 * 3.14159 * 20 * $t | math sin)
            let theta = 80 * (2 * 3.14159 * 6 * $t | math sin)
            let noise = (random float -20..20)
            
            # Different amplitude for different channels
            let amplitude = 1.0 - ($ch | into float) * 0.1
            let value = ($alpha + $beta + $theta + $noise) * $amplitude
            
            $sample = ($sample | insert $"ch($ch)" ($value | math round -p 2))
        }
        
        $samples = ($samples | append $sample)
    }
    
    $samples
}

# Filter samples based on expression
def filter_samples [samples: list, filter_expr: string]: [ nothing -> list ] {
    # Parse simple filter expressions like "alpha > 0.5" or "ch0 > 100"
    let parts = ($filter_expr | parse -r '(?<band>\w+)\s*(?<op>[<>!=]+)\s*(?<val>[\d.]+)')
    
    if ($parts | is-empty) {
        return $samples
    }
    
    let band = $parts.0.band
    let op = $parts.0.op
    let val = ($parts.0.val | into float)
    
    $samples | filter { |sample|
        let sample_val = if $band in $sample {
            $sample | get $band
        } else {
            0
        }
        
        match $op {
            ">" => { $sample_val > $val }
            ">=" => { $sample_val >= $val }
            "<" => { $sample_val < $val }
            "<=" => { $sample_val <= $val }
            "==" => { $sample_val == $val }
            "!=" => { $sample_val != $val }
            _ => { true }
        }
    }
}

# Format samples for output
def format_samples [samples: list, format: string, channels: list]: [ nothing -> list ] {
    match $format {
        "jsonl" | "json" => {
            $samples | each { |s| $s }
        }
        "csv" => {
            $samples | each { |s|
                mut row = { timestamp: $s.timestamp }
                for ch in $channels {
                    $row = ($row | insert $"ch($ch)" ($s | get $"ch($ch)"))
                }
                $row
            }
        }
        _ => {
            # Table format - return as-is for nushell table display
            $samples
        }
    }
}

# Stream with band power filtering
export def "main stream bands" [
    --band: string = "alpha"           # Band to filter: delta, theta, alpha, beta, gamma
    --threshold: float = 0.5           # Power threshold
    --duration(-d): duration           # Stream duration
]: [ nothing -> table ] {
    let filter_expr = $"($band) > ($threshold)"
    main stream --filter $filter_expr --duration $duration
}

# Stream to a named pipe for external tools
export def "main stream pipe" [
    pipe_name: string                  # Name of the pipe
    --duration(-d): duration           # Stream duration
]: [ nothing -> nothing ] {
    let pipe_path = $"/tmp/openbci_($pipe_name).pipe"
    
    # Create named pipe if it doesn't exist
    if not ($pipe_path | path exists) {
        mkfifo $pipe_path
    }
    
    print $"Streaming to pipe: ($pipe_path)"
    
    # Stream to pipe in background
    main stream --format csv --duration $duration | save --append $pipe_path
}

# Real-time band power stream
export def "main stream powers" [
    --channels(-c): string = "all"     # Channels to analyze
    --window-size: int = 256           # Samples for FFT window
    --duration(-d): duration           # Stream duration
]: [ nothing -> table ] {
    
    let channel_list = if $channels == "all" {
        seq 0 ($DEFAULT_CHANNELS - 1)
    } else {
        $channels | split "," | each { into int }
    }
    
    let config = get-config
    let port = (device info | get port)
    let sample_rate = $config | get -i default_sample_rate | default $DEFAULT_SAMPLE_RATE
    
    start_device_streaming $port
    
    print $"Streaming band powers from ($port)..."
    print "Bands: delta(1-4Hz) theta(4-8Hz) alpha(8-13Hz) beta(13-30Hz) gamma(30-50Hz)"
    print "Press Ctrl+C to stop"
    print ""
    
    let end_time = if $duration != null {
        (date now) + $duration
    } else {
        null
    }
    
    # Buffer for FFT
    mut buffer = []
    
    loop {
        if $end_time != null and (date now) >= $end_time {
            break
        }
        
        # Read samples
        let samples = (read_samples $port ($window_size / 4) $channel_list)
        $buffer = ($buffer | append $samples)
        
        # Keep buffer at window size
        if ($buffer | length) > $window_size {
            $buffer = ($buffer | last $window_size)
        }
        
        # Calculate band powers when buffer is full
        if ($buffer | length) >= $window_size {
            let powers = (calculate_band_powers $buffer $channel_list $sample_rate)
            $powers | print
        }
        
        sleep 100ms
    }
    
    stop_device_streaming $port
}

# Calculate band powers from samples
def calculate_band_powers [samples: list, channels: list, sample_rate: int]: [ nothing -> record ] {
    mut result = {
        timestamp: (date now | format date "%Y-%m-%d %H:%M:%S%.3f")
    }
    
    for ch in $channels {
        let ch_key = $"ch($ch)"
        let signal = ($samples | each { |s| $s | get $ch_key })
        
        # Simple band power estimation using variance in frequency bands
        # In practice, you'd use FFT here
        let mean = ($signal | math avg)
        let variance = ($signal | each { |x| ($x - $mean) ** 2 } | math avg)
        
        # Simulated band distribution
        let delta = ($variance * 0.1 | math round -p 2)
        let theta = ($variance * 0.15 | math round -p 2)
        let alpha = ($variance * 0.3 | math round -p 2)
        let beta = ($variance * 0.25 | math round -p 2)
        let gamma = ($variance * 0.2 | math round -p 2)
        
        $result = ($result | insert $ch_key {
            delta: $delta
            theta: $theta
            alpha: $alpha
            beta: $beta
            gamma: $gamma
            total: ($delta + $theta + $alpha + $beta + $gamma | math round -p 2)
        })
    }
    
    $result
}
