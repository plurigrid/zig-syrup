#!/usr/bin/env nu
# demo_pipeline.nu
# Demonstration of OpenBCI nuworlds integration pipeline

use ../mod.nu *
use ../eeg_types.nu [CYTON_CHANNELS_8]
use ../signal_processing.nu [band-power all-band-powers extract-features]
use ../visualization.nu [eeg-plot band-bars topo-preview dashboard]

# =============================================================================
# Demo 1: Basic Streaming
# =============================================================================

def demo_stream [] {
    print "╔════════════════════════════════════════════════════════════════╗"
    print "║  Demo 1: Basic Streaming                                       ║"
    print "╚════════════════════════════════════════════════════════════════╝"
    print ""
    print "Streaming 10 samples from OpenBCI..."
    print ""
    
    # Capture just 10 samples and display
    let samples = (capture --samples 10)
    
    print ""
    print "Sample structure:"
    $samples | first | describe
    
    print ""
    print "First 3 samples:"
    $samples | first 3
}

# =============================================================================
# Demo 2: Processing Pipeline
# =============================================================================

def demo_processing [] {
    print ""
    print "╔════════════════════════════════════════════════════════════════╗"
    print "║  Demo 2: Signal Processing Pipeline                            ║"
    print "╚════════════════════════════════════════════════════════════════╝"
    print ""
    
    # Capture some samples
    print "Capturing 500 samples for processing..."
    let data = (capture --samples 500)
    
    print ""
    print "--- Original Statistics ---"
    let stats = ($data | extract-features)
    $stats.channels | items {|name, feat| {channel: $name, mean: $feat.mean, std: $feat.std}}
    
    print ""
    print "--- After Notch Filter (60Hz) ---"
    let filtered = ($data | notch-filter --sampling-rate 250)
    let filtered_stats = ($filtered | extract-features)
    $filtered_stats.channels | items {|name, feat| {channel: $name, mean: $feat.mean, std: $feat.std}}
    
    print ""
    print "--- Band Powers ---"
    let powers = ($data | all-band-powers --sampling-rate 250)
    print $"Total Power: ($powers.total_power | into int) µV²"
    print "Relative Powers:"
    $powers.relative | items {|band, val| {band: $band, percentage: $"($val * 100 | into int)%"}}
}

# =============================================================================
# Demo 3: Visualization
# =============================================================================

def demo_visualization [] {
    print ""
    print "╔════════════════════════════════════════════════════════════════╗"
    print "║  Demo 3: Terminal Visualization                                ║"
    print "╚════════════════════════════════════════════════════════════════╝"
    print ""
    
    print "Capturing 250 samples (1 second at 250Hz)..."
    let data = (capture --samples 250)
    
    print ""
    print "--- Channel Signal Plot ---"
    $data | eeg-plot --width 40 --scale normalized
    
    print ""
    print "--- Band Power Distribution ---"
    $data | band-bars --width 30 --relative
    
    print ""
    print "--- Topographic Preview ---"
    let current = $data | last | get channels
    topo-preview --channel-values $current
}

# =============================================================================
# Demo 4: Real-time Filtering
# =============================================================================

def demo_filtering [] {
    print ""
    print "╔════════════════════════════════════════════════════════════════╗"
    print "║  Demo 4: Real-time Filtering                                   ║"
    print "╚════════════════════════════════════════════════════════════════╝"
    print ""
    
    print "Capturing 1000 samples..."
    let data = (capture --samples 1000)
    
    print ""
    print "--- Artifact Detection (values > 500 µV) ---"
    let artifacts = ($data | filter {|e| ($e.channels | math max | math abs) > 500})
    print $"Found ($artifacts | length) samples with artifacts"
    
    print ""
    print "--- Clean Data (RMS by channel) ---"
    let clean = ($data | filter {|e| ($e.channels | math max | math abs) < 500})
    let rms_values = ($clean | rms)
    $rms_values | items {|ch, val| {channel: $ch, rms_uv: ($val | into int)}}
    
    print ""
    print "--- Moving Average Smoothing ---"
    let smoothed = ($clean | moving-average 10)
    print $"Original: ($data | length) samples"
    print $"Smoothed: ($smoothed | length) samples (window=10)"
}

# =============================================================================
# Demo 5: Complete Pipeline
# =============================================================================

def demo_complete [] {
    print ""
    print "╔════════════════════════════════════════════════════════════════╗"
    print "║  Demo 5: Complete Data Pipeline                                ║"
    print "╚════════════════════════════════════════════════════════════════╝"
    print ""
    
    print "Step 1: Capture data from OpenBCI"
    let raw_data = (capture --samples 500)
    print $"✓ Captured ($raw_data | length) samples"
    
    print ""
    print "Step 2: Apply signal processing"
    let processed = ($raw_data 
        | notch-filter --sampling-rate 250      # Remove 60Hz noise
        | moving-average 5                      # Light smoothing
        | normalize                             # Zero-mean
    )
    print "✓ Applied notch filter, moving average, normalization"
    
    print ""
    print "Step 3: Extract features"
    let features = ($processed | extract-features --sampling-rate 250)
    print "✓ Feature extraction complete"
    $features.channels | items {|name, feat| {
        channel: $name
        mean_uv: ($feat.mean | into int)
        rms_uv: ($feat.rms | into int)
    }}
    
    print ""
    print "Step 4: Calculate band powers"
    let powers = ($processed | all-band-powers)
    print "✓ Band power analysis"
    $powers.relative | items {|band, val| {
        band: $band
        relative: $"($val * 100 | into int)%"
    }}
    
    print ""
    print "Step 5: Visualize"
    $processed | eeg-plot --width 50 --scale normalized
}

# =============================================================================
# Main Demo Runner
# =============================================================================

def main [
    demo?: string = "all"   # Which demo to run: all, stream, processing, visualization, filtering, complete
] {
    print ""
    print "╔════════════════════════════════════════════════════════════════╗"
    print "║         OpenBCI Nuworlds Integration Demo                      ║"
    print "║         =================================                      ║"
    print "║                                                                ║"
    print "║  This demo shows various ways to process EEG data in nushell   ║"
    print "╚════════════════════════════════════════════════════════════════╝"
    print ""
    
    # Check if OpenBCI is running
    print "Checking OpenBCI connection..."
    let connected = (test-connection 2>/dev/null | complete).exit_code == 0
    
    if not $connected {
        print "⚠️  Warning: Could not connect to OpenBCI"
        print "   Make sure host_acquisition.py is running first."
        print ""
        print "   cd /Users/bob/i/zig-syrup/tools/openbci_host"
        print "   python host_acquisition.py"
        print ""
        return 1
    }
    
    print "✓ OpenBCI connection successful"
    print ""
    
    match $demo {
        "all" => {
            demo_stream
            demo_processing
            demo_visualization
            demo_filtering
            demo_complete
        }
        "stream" => { demo_stream }
        "processing" => { demo_processing }
        "visualization" => { demo_visualization }
        "filtering" => { demo_filtering }
        "complete" => { demo_complete }
        _ => {
            print $"Unknown demo: ($demo)"
            print "Available: all, stream, processing, visualization, filtering, complete"
        }
    }
    
    print ""
    print "╔════════════════════════════════════════════════════════════════╗"
    print "║                   Demo Complete!                               ║"
    print "╚════════════════════════════════════════════════════════════════╝"
}
