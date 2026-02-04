# OpenBCI Recording Module
# Handles recording EEG data to various file formats

use config get-config
use device main device info
use stream generate_simulated_samples, read_samples, start_device_streaming, stop_device_streaming

const DEFAULT_CHANNELS = 8
const DEFAULT_SAMPLE_RATE = 250

# Record EEG data to file
#
# Usage:
#   openbci record --output session.csv           # Record to CSV
#   openbci record --output session.parquet       # Record to Parquet
#   openbci record --format edf --output session.edf  # Record to EDF+
#   openbci record --duration 5min                # Auto-stop after 5 minutes
#   openbci record --trigger "blink"              # Start on event trigger
#
# Examples:
#   openbci record --output brain.csv --duration 60s
#   openbci record --output study.parquet --format parquet --channels 0,1,2,3
#   openbci record --format edf --output overnight.edf --duration 8hr
export def "main record" [
    --output(-o): path                # Output file path (required)
    --duration(-d): duration          # Recording duration (e.g., 60sec, 5min)
    --format: string                  # Output format: csv, parquet, edf (auto-detected from extension)
    --channels(-c): string = "all"    # Channels to record (e.g., "0,1,2")
    --trigger: string                 # Event trigger to start recording
    --metadata: record = {}           # Additional metadata to store
    --buffer-size: int = 256          # Buffer size for writing
]: [ nothing -> record ] {
    
    # Validate output path
    if $output == null {
        error make { msg: "Output path is required. Use --output <path>" }
    }
    
    # Auto-detect format from extension if not specified
    let output_format = if $format != null {
        $format
    } else {
        let ext = ($output | path parse | get extension)
        match $ext {
            "csv" => "csv"
            "parquet" => "parquet"
            "edf" => "edf"
            _ => {
                print $"Unknown extension '.($ext)', defaulting to CSV"
                "csv"
            }
        }
    }
    
    # Parse channel list
    let channel_list = if $channels == "all" {
        seq 0 ($DEFAULT_CHANNELS - 1)
    } else {
        $channels | split "," | each { into int }
    }
    
    # Get device connection
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
    let config = get-config
    let sample_rate = $config | get -i default_sample_rate | default $DEFAULT_SAMPLE_RATE
    
    # Wait for trigger if specified
    if $trigger != null {
        print $"Waiting for trigger: ($trigger)..."
        wait_for_trigger $trigger $port
    }
    
    # Ensure output directory exists
    mkdir ($output | path dirname)
    
    # Start recording
    print $"Starting recording to ($output)"
    print $"Format: ($output_format)"
    print $"Channels: ($channel_list | str join ', ')"
    print $"Sample rate: ($sample_rate) Hz"
    if $duration != null {
        print $"Duration: ($duration)"
    }
    print "Press Ctrl+C to stop recording"
    print ""
    
    # Write header for CSV format
    if $output_format == "csv" {
        let header = ([timestamp, sample_num] | append ($channel_list | each { |i| $"ch($i)" }) | str join ",")
        $header | save -f $output
    }
    
    # Initialize recording stats
    let start_time = date now
    let end_time = if $duration != null {
        $start_time + $duration
    } else {
        null
    }
    
    mut sample_count = 0
    mut file_size = 0
    
    # Start device streaming
    start_device_streaming $port
    
    # Recording loop
    try {
        loop {
            # Check if duration exceeded
            if $end_time != null and (date now) >= $end_time {
                print "\nDuration reached, stopping recording..."
                break
            }
            
            # Read samples from device
            let samples = (read_samples $port $buffer_size $channel_list)
            
            # Write samples based on format
            match $output_format {
                "csv" => { write_csv_samples $output $samples }
                "parquet" => { write_parquet_samples $output $samples $sample_count }
                "edf" => { write_edf_samples $output $samples $channel_list $sample_count $start_time }
                _ => { write_csv_samples $output $samples }
            }
            
            $sample_count = $sample_count + ($samples | length)
            $file_size = (ls $output | get size | first | into filesize)
            
            # Update progress
            let elapsed = (date now) - $start_time
            let elapsed_sec = ($elapsed | into int) / 1000000000
            let current_rate = ($sample_count / $elapsed_sec)
            
            print -n $"\rSamples: ($sample_count) | Elapsed: (format_duration $elapsed) | Rate: ($current_rate | math round -p 1) Hz | Size: ($file_size)"
            
            sleep 10ms
        }
    } catch { |e|
        print $"\nRecording interrupted: ($e.msg)"
    }
    
    # Stop device streaming
    stop_device_streaming $port
    
    # Finalize EDF file if needed
    if $output_format == "edf" {
        finalize_edf_file $output $channel_list $sample_count $sample_rate $start_time $metadata
    }
    
    # Calculate final stats
    let elapsed = (date now) - $start_time
    let elapsed_sec = ($elapsed | into int) / 1000000000
    
    let final_stats = {
        output_file: ($output | path expand)
        format: $output_format
        samples_recorded: $sample_count
        duration_sec: ($elapsed_sec | math round -p 2)
        sample_rate: ($sample_count / $elapsed_sec | math round -p 2)
        file_size: $file_size
        channels: $channel_list
        channel_count: ($channel_list | length)
        started_at: ($start_time | format date "%Y-%m-%d %H:%M:%S")
        metadata: $metadata
    }
    
    print ""
    print ""
    print "Recording complete!"
    print $"File: ($final_stats.output_file)"
    print $"Duration: (format_duration $elapsed)"
    print $"Samples: ($final_stats.samples_recorded)"
    print $"Size: ($final_stats.file_size)"
    
    # Save metadata sidecar file
    let metadata_file = $output | path parse | update extension "json" | path join
    $final_stats | to json | save -f $metadata_file
    print $"Metadata saved to: ($metadata_file)"
    
    $final_stats
}

# Wait for a trigger event
def wait_for_trigger [trigger: string, port: string]: [ nothing -> nothing ] {
    match $trigger {
        "blink" => {
            # Wait for significant change in frontal channels
            print "Waiting for blink detection... (blink now)"
            mut waiting = true
            while $waiting {
                let samples = (read_samples $port 10 [0 1])
                let avg_ch0 = ($samples | get ch0 | math avg)
                if ($avg_ch0 | math abs) > 150 {
                    $waiting = false
                    print "Blink detected! Starting recording..."
                }
                sleep 50ms
            }
        }
        "ready" => {
            print "Press Enter when ready..."
            input
        }
        _ => {
            print $"Unknown trigger '($trigger)', starting immediately..."
        }
    }
}

# Format duration for display
def format_duration [duration: duration]: [ nothing -> string ] {
    let nanos = ($duration | into int)
    let seconds = ($nanos / 1000000000 | math floor)
    let mins = ($seconds / 60 | math floor)
    let secs = ($seconds mod 60)
    let millis = (($nanos mod 1000000000) / 1000000 | math floor)
    
    if $mins > 0 {
        $"($mins)m ($secs).($millis)s"
    } else {
        $"($secs).($millis)s"
    }
}

# Write samples to CSV file
def write_csv_samples [file: path, samples: list]: [ nothing -> nothing ] {
    let csv_lines = ($samples | each { |s|
        let values = ([$s.timestamp, ($s.sample_num | into string)] | append (
            $s | columns | where { |c| $c | str starts-with "ch" } | sort | each { |c| $s | get $c | into string }
        ))
        $values | str join ","
    } | str join "\n")
    
    $csv_lines | save --append $file
}

# Write samples to Parquet file (using polars)
def write_parquet_samples [file: path, samples: list, offset: int]: [ nothing -> nothing ] {
    # Convert samples to a format suitable for polars
    let df_data = ($samples | each { |s|
        mut row = {
            timestamp: $s.timestamp
            sample_num: $s.sample_num
        }
        # Add channel columns
        for col in ($s | columns | where { |c| $c | str starts-with "ch" }) {
            $row = ($row | insert $col ($s | get $col))
        }
        $row
    })
    
    # Use polars to write parquet
    # If first write, create new file; otherwise append
    if $offset == 0 {
        $df_data | polars into-df | polars save $file
    } else {
        # Append mode - read existing, concatenate, save
        try {
            let existing = (polars open $file | polars into-nu)
            let combined = ($existing | append $df_data)
            $combined | polars into-df | polars save $file
        } catch {
            $df_data | polars into-df | polars save $file
        }
    }
}

# Buffer for EDF samples
let EDF_BUFFER = []

# Write samples to EDF buffer (EDF requires finalization)
def write_edf_samples [file: path, samples: list, channels: list, offset: int, start_time: datetime]: [ nothing -> nothing ] {
    # Buffer samples for EDF - we'll write everything at the end
    # because EDF header needs to know total number of records
    $EDF_BUFFER = ($EDF_BUFFER | append $samples)
}

# Finalize EDF file with proper header
def finalize_edf_file [file: path, channels: list, total_samples: int, sample_rate: int, start_time: datetime, metadata: record]: [ nothing -> nothing ] {
    print "\nFinalizing EDF file..."
    
    # Check if pyedflib is available
    let python_check = (try { python3 -c "import pyedflib"; echo "OK" } catch { "MISSING" })
    
    if $python_check == "MISSING" {
        print "Warning: pyedflib not available. Saving as CSV instead."
        let csv_file = $file | path parse | update extension "csv" | path join
        write_csv_samples $csv_file $EDF_BUFFER
        return
    }
    
    # Prepare data for Python EDF writer
    let edf_data = {
        file: $file
        channels: $channels
        sample_rate: $sample_rate
        start_time: ($start_time | format date "%Y-%m-%d %H:%M:%S")
        samples: $EDF_BUFFER
        labels: ($channels | each { |c| $"EEG ch($c)" })
        physical_dim: "uV"
        transducer: "OpenBCI EEG"
    }
    
    # Write EDF using Python helper
    let temp_json = $"/tmp/openbci_edf_(random uuid).json"
    $edf_data | to json | save -f $temp_json
    
    let python_script = $"
import json
import pyedflib
import numpy as np
from datetime import datetime

with open('($temp_json)') as f:
    data = json.load(f)

n_channels = len(data['channels'])
sample_rate = data['sample_rate']
samples = data['samples']

# Convert samples to channel arrays
signals = []
for ch in data['channels']:
    ch_key = f'ch{ch}'
    signal = [s.get(ch_key, 0) for s in samples]
    signals.append(np.array(signal))

# Create EDF file
with pyedflib.EdfWriter(data['file'], n_channels=n_channels) as f:
    channel_info = []
    for i, ch in enumerate(data['channels']):
        ch_dict = {
            'label': data['labels'][i],
            'dimension': data['physical_dim'],
            'sample_rate': sample_rate,
            'physical_max': max(signals[i]) if len(signals[i]) > 0 else 1000,
            'physical_min': min(signals[i]) if len(signals[i]) > 0 else -1000,
            'digital_max': 32767,
            'digital_min': -32768,
            'transducer': data['transducer'],
            'prefilter': ''
        }
        channel_info.append(ch_dict)
    
    f.setSignalHeaders(channel_info)
    f.setStartdatetime(datetime.strptime(data['start_time'], '%Y-%m-%d %H:%M:%S'))
    f.writeSamples(signals)

print(f\"EDF file written: {data['file']}\")
"
    
    python3 -c $python_script
    rm -f $temp_json
}

# List recorded sessions
export def "main record list" [
    --directory(-d): path = "~/openbci_recordings"  # Directory to list
]: [ nothing -> table ] {
    let dir = ($directory | path expand)
    
    if not ($dir | path exists) {
        print $"Directory ($dir) does not exist."
        return []
    }
    
    ls $dir 
    | where name =~ '\.(csv|parquet|edf)$'
    | select name size modified
    | each { |f| 
        let meta_file = ($f.name | path parse | update extension "json" | path join)
        let metadata = if ($meta_file | path exists) {
            try { open $meta_file } catch { {} }
        } else {
            {}
        }
        
        {
            file: ($f.name | path basename)
            format: ($f.name | path parse | get extension)
            size: $f.size
            duration: ($metadata | get -i duration_sec | default "unknown")
            samples: ($metadata | get -i samples_recorded | default "unknown")
            channels: ($metadata | get -i channel_count | default "unknown")
            recorded_at: ($f.modified | format date "%Y-%m-%d %H:%M")
        }
    }
}

# Get recording info
export def "main record info" [
    file: path  # Recording file to analyze
]: [ nothing -> record ] {
    if not ($file | path exists) {
        error make { msg: $"File not found: ($file)" }
    }
    
    let meta_file = ($file | path parse | update extension "json" | path join)
    let metadata = if ($meta_file | path exists) {
        try { open $meta_file } catch { {} }
    } else {
        {}
    }
    
    let file_info = (ls $file | first)
    
    {
        file: ($file | path expand)
        format: ($file | path parse | get extension)
        size: $file_info.size
        modified: $file_info.modified
        metadata: $metadata
    }
}

# Convert recording between formats
export def "main record convert" [
    input: path      # Input file
    output: path     # Output file
]: [ nothing -> record ] {
    if not ($input | path exists) {
        error make { msg: $"Input file not found: ($input)" }
    }
    
    let input_format = ($input | path parse | get extension)
    let output_format = ($output | path parse | get extension)
    
    print $"Converting ($input) [($input_format)] -> ($output) [($output_format)]"
    
    # Read input based on format
    let data = match $input_format {
        "csv" => { open $input }
        "parquet" => { polars open $input | polars into-nu }
        _ => { error make { msg: $"Unsupported input format: ($input_format)" } }
    }
    
    # Write output based on format
    match $output_format {
        "csv" => { $data | save -f $output }
        "parquet" => { $data | polars into-df | polars save $output }
        "json" => { $data | to json | save -f $output }
        "jsonl" => { $data | each { |r| $r | to json } | str join "\n" | save -f $output }
        _ => { error make { msg: $"Unsupported output format: ($output_format)" } }
    }
    
    print $"Conversion complete: ($output)"
    
    {
        input: $input
        output: $output
        input_format: $input_format
        output_format: $output_format
        records: ($data | length)
    }
}

# Trim/crop a recording
export def "main record trim" [
    input: path           # Input file
    output: path          # Output file
    --start: int = 0      # Start sample index
    --end: int            # End sample index (default: end of file)
]: [ nothing -> record ] {
    if not ($input | path exists) {
        error make { msg: $"Input file not found: ($input)" }
    }
    
    let input_format = ($input | path parse | get extension)
    
    # Read data
    let data = match $input_format {
        "csv" => { open $input }
        "parquet" => { polars open $input | polars into-nu }
        _ => { error make { msg: $"Unsupported format: ($input_format)" } }
    }
    
    let total_samples = ($data | length)
    let end_idx = $end | default $total_samples
    
    # Trim data
    let trimmed = ($data | range $start..$end_idx)
    
    # Save
    match ($output | path parse | get extension) {
        "csv" => { $trimmed | save -f $output }
        "parquet" => { $trimmed | polars into-df | polars save $output }
        _ => { $trimmed | save -f $output }
    }
    
    print $"Trimmed ($input): samples ($start) to ($end_idx)"
    print $"Output saved to: ($output)"
    
    {
        input: $input
        output: $output
        original_samples: $total_samples
        trimmed_samples: ($trimmed | length)
        start_sample: $start
        end_sample: $end_idx
    }
}
