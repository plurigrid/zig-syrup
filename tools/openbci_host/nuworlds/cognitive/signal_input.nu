# signal_input.nu
# Signal acquisition and preprocessing for cognitive architecture
# Handles raw OpenBCI EEG input with quality checks and preprocessing

use std log
use ../eeg_types.nu *
use ../signal_processing.nu *

# =============================================================================
# Signal Acquisition
# =============================================================================

# Default signal input configuration
export def SignalConfig [] {
    {
        # Acquisition settings
        sample_rate: 250,
        channels: 8,
        channel_labels: ["Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2"],
        
        # Signal types to acquire
        signal_types: ["eeg", "emg", "ecg", "accel"],
        
        # Quality thresholds
        quality_thresholds: {
            snr_min: 5.0,           # Minimum SNR in dB
            impedance_max: 10.0,    # Maximum impedance in kOhm
            flatline_threshold: 0.01, # µV variance threshold for flatline detection
            saturation_threshold: 10000.0 # µV threshold for saturation
        },
        
        # Preprocessing settings
        preprocessing: {
            highpass: 0.5,          # High-pass filter cutoff (Hz)
            lowpass: 100.0,         # Low-pass filter cutoff (Hz)
            notch: 60.0,            # Notch filter frequency (Hz, use 50 for EU)
            filter_order: 4,
            remove_dc: true,
            normalize: false
        },
        
        # Windowing settings
        window: {
            size_ms: 1000,          # Window size in milliseconds
            overlap_ms: 500,        # Overlap in milliseconds
            min_windows: 3          # Minimum windows for quality check
        },
        
        # Buffer settings
        buffer: {
            duration_sec: 10,       # Buffer duration in seconds
            max_samples: 2500       # Maximum samples to buffer
        }
    }
}

# Signal input state
export def SignalState [] {
    {
        config: (SignalConfig),
        buffer: [],
        windows: [],
        quality_history: [],
        last_acquisition: null,
        samples_acquired: 0,
        samples_dropped: 0,
        active: false
    }
}

# =============================================================================
# Signal Acquire Commands
# =============================================================================

# Acquire signals from OpenBCI with quality checks
export def "signal acquire" [
    --duration: duration = 60sec      # Acquisition duration
    --channels: list = null           # Channel indices to acquire (null = all)
    --signal-types: list = null       # Signal types: eeg, emg, ecg, accel
    --simulate: bool = false          # Use simulated data instead of hardware
    --quality-check: bool = true      # Enable real-time quality checking
]: [ nothing -> record ] {
    let cfg = (SignalConfig)
    let ch_list = if ($channels | is-not-empty) { $channels } else { 0..<($cfg.channels) }
    let types = if ($signal_types | is-not-empty) { $signal_types } else { $cfg.signal_types }
    
    log info $"Starting signal acquisition: duration=($duration), channels=($ch_list | length), types=($types | str join ', ')"
    
    mut state = (SignalState)
    $state = ($state | upsert active true)
    
    let start_time = date now
    let end_time = $start_time + $duration
    
    mut samples = []
    mut sample_count = 0
    
    # Acquisition loop
    while (date now) < $end_time {
        let sample = if $simulate {
            generate-simulated-sample $sample_count $ch_list $types
        } else {
            # In production: read from OpenBCI hardware
            # This would interface with the openbci_receiver
            acquire-hardware-sample $ch_list $types
        }
        
        # Quality check on each sample
        let sample_with_quality = if $quality_check {
            $sample | upsert quality (check-sample-quality $sample $cfg)
        } else {
            $sample | upsert quality { quality_score: 1.0 }
        }
        
        $samples = ($samples | append $sample_with_quality)
        $sample_count = $sample_count + 1
        
        # Maintain buffer size
        if ($samples | length) > $cfg.buffer.max_samples {
            $samples = ($samples | last $cfg.buffer.max_samples)
        }
        
        # Sleep for sample period (4ms for 250Hz)
        sleep 4ms
    }
    
    let actual_duration = (date now) - $start_time
    
    $state = ($state 
        | upsert buffer $samples
        | upsert samples_acquired $sample_count
        | upsert last_acquisition (date now)
        | upsert active false
    )
    
    log info $"Acquisition complete: ($sample_count) samples in ($actual_duration)"
    
    {
        state: $state,
        samples: $samples,
        metadata: {
            duration: $actual_duration,
            sample_count: $sample_count,
            channels: ($ch_list | length),
            signal_types: $types,
            sample_rate: $cfg.sample_rate,
            simulated: $simulate
        }
    }
}

# Generate a simulated sample for testing
export def generate-simulated-sample [
    sample_num: int
    channels: list
    signal_types: list
]: [ nothing -> record ] {
    mut channel_data = []
    
    for ch in $channels {
        # Generate synthetic EEG-like signal with noise
        let time = ($sample_num | into float) / 250.0
        let alpha = 10.0 * (2 * 3.14159 * 10.0 * $time | math sin)  # 10 Hz alpha
        let beta = 5.0 * (2 * 3.14159 * 20.0 * $time | math sin)    # 20 Hz beta
        let theta = 8.0 * (2 * 3.14159 * 6.0 * $time | math sin)    # 6 Hz theta
        let noise = (random float -2.0..2.0)
        
        let value = $alpha + $beta + $theta + $noise
        $channel_data = ($channel_data | append $value)
    }
    
    mut aux_data = []
    if "accel" in $signal_types {
        # Simulate accelerometer data
        $aux_data = [
            (random float -1.0..1.0)
            (random float -1.0..1.0)
            (random float -1.0..1.0)
        ]
    }
    
    {
        timestamp: (date now | into int) / 1_000_000_000.0,
        sample_num: $sample_num,
        channels: $channel_data,
        aux: $aux_data,
        signal_types: $signal_types
    }
}

# Acquire sample from hardware (placeholder for actual implementation)
export def acquire-hardware-sample [
    channels: list
    signal_types: list
]: [ nothing -> record ] {
    # This would interface with the actual OpenBCI hardware
    # For now, return a placeholder
    {
        timestamp: (date now | into int) / 1_000_000_000.0,
        sample_num: 0,
        channels: ($channels | each { 0.0 }),
        aux: [0.0 0.0 0.0],
        signal_types: $signal_types,
        hardware: true
    }
}

# Check quality of a single sample
export def check-sample-quality [
    sample: record
    config: record
]: [ nothing -> record ] {
    let thresholds = $config.quality_thresholds
    
    mut checks = {}
    
    # Check channel values for saturation
    let max_val = ($sample.channels | each { |x| $x | math abs } | math max)
    let is_saturated = $max_val > $thresholds.saturation_threshold
    
    # Check for flatline (would need history, simplified here)
    let is_flatline = false  # Requires window analysis
    
    # Calculate sample-level metrics
    let mean_val = ($sample.channels | math avg)
    let std_val = ($sample.channels | math stddev)
    
    # Quality score (0-1)
    let quality_score = if $is_saturated {
        0.0
    } else if $is_flatline {
        0.1
    } else {
        1.0
    }
    
    {
        quality_score: $quality_score,
        is_saturated: $is_saturated,
        is_flatline: $is_flatline,
        max_amplitude_uv: $max_val,
        mean_uv: $mean_val,
        std_uv: $std_val,
        timestamp: (date now)
    }
}

# =============================================================================
# Signal Preprocessing
# =============================================================================

# Preprocess signals: filter, artifact removal, notch
export def "signal preprocess" [
    --highpass: float = null      # High-pass cutoff (Hz)
    --lowpass: float = null       # Low-pass cutoff (Hz)
    --notch-freq: float = null    # Notch filter frequency (Hz)
    --remove-dc: bool = true      # Remove DC offset
    --normalize: bool = false     # Normalize channels
]: [ list -> list ] {
    let data = $in
    let cfg = (SignalConfig).preprocessing
    
    log info "Starting signal preprocessing..."
    
    let hp = if ($highpass | is-not-empty) { $highpass } else { $cfg.highpass }
    let lp = if ($lowpass | is-not-empty) { $lowpass } else { $cfg.lowpass }
    let notch = if ($notch_freq | is-not-empty) { $notch_freq } else { $cfg.notch }
    
    mut processed = $data
    
    # Remove DC offset
    if $remove_dc {
        log info "Removing DC offset..."
        $processed = ($processed | normalize --per-channel)
    }
    
    # Apply high-pass filter (simplified approximation)
    if ($hp > 0) {
        log info $"Applying high-pass filter: ($hp) Hz"
        $processed = ($processed | highpass-filter --channel null)
    }
    
    # Apply low-pass filter (simplified approximation)
    if ($lp > 0) {
        log info $"Applying low-pass filter: ($lp) Hz"
        # Would use actual filter implementation
    }
    
    # Apply notch filter for line noise
    if ($notch > 0) {
        log info $"Applying notch filter: ($notch) Hz"
        $processed = ($processed | notch-filter $notch)
    }
    
    # Normalize if requested
    if $normalize {
        log info "Normalizing channels..."
        $processed = ($processed | normalize --per-channel)
    }
    
    log info "Preprocessing complete"
    
    $processed | each { |row| $row | insert preprocessed true }
}

# =============================================================================
# Signal Window Management
# =============================================================================

# Create sliding windows from signal data
export def "signal window" [
    --size-ms: int = null         # Window size in milliseconds
    --overlap-ms: int = null      # Overlap in milliseconds
    --step-ms: int = null         # Step size (alternative to overlap)
]: [ list -> list ] {
    let data = $in
    let cfg = (SignalConfig).window
    
    let window_size = if ($size_ms | is-not-empty) { $size_ms } else { $cfg.size_ms }
    let overlap = if ($overlap_ms | is-not-empty) { $overlap_ms } else { $cfg.overlap_ms }
    let step = if ($step_ms | is-not-empty) { $step_ms } else { $window_size - $overlap }
    
    let sample_rate = 250  # Hz
    let samples_per_window = (($window_size * $sample_rate) / 1000 | into int)
    let samples_per_step = (($step * $sample_rate) / 1000 | into int)
    
    log info $"Creating windows: size=($window_size)ms, step=($step)ms, samples/window=($samples_per_window)"
    
    mut windows = []
    let data_len = $data | length
    
    mut start = 0
    while $start + $samples_per_window <= $data_len {
        let window_data = ($data | range $start..<($start + $samples_per_window))
        let window_end = $start + $samples_per_window
        
        let window = {
            index: ($windows | length),
            start_sample: $start,
            end_sample: $window_end,
            timestamp: ($window_data | first).timestamp,
            duration_ms: $window_size,
            samples: $window_data,
            sample_count: ($window_data | length)
        }
        
        $windows = ($windows | append $window)
        $start = $start + $samples_per_step
    }
    
    log info $"Created ($windows | length) windows"
    
    $windows
}

# Apply function to each window
export def window-map [
    fn: closure    # Function to apply to each window
]: [ list -> list ] {
    let windows = $in
    
    $windows | each { |window|
        let result = (do $fn $window)
        $window | merge $result
    }
}

# Filter windows based on criteria
export def window-filter [
    predicate: closure  # Predicate function for filtering
]: [ list -> list ] {
    let windows = $in
    $windows | filter { |w| do $predicate $w }
}

# =============================================================================
# Signal Quality Monitoring
# =============================================================================

# Monitor signal quality: SNR, impedance, artifacts
export def "signal quality" [
    --window-size: duration = 5sec    # Analysis window size
    --detailed: bool = false          # Show detailed per-channel info
]: [ list -> record ] {
    let data = $in
    let cfg = (SignalConfig)
    
    let n_samples = $data | length
    let n_channels = if ($data | length) > 0 { ($data | first).channels | length } else { 0 }
    
    log info $"Analyzing signal quality: ($n_samples) samples, ($n_channels) channels"
    
    mut channel_quality = []
    
    for ch in 0..<$n_channels {
        let ch_values = ($data | each { |row| $row.channels | get $ch })
        let ch_name = if ($cfg.channel_labels | length) > $ch {
            ($cfg.channel_labels | get $ch)
        } else {
            $"Ch($ch)"
        }
        
        # Calculate statistics
        let mean = ($ch_values | math avg)
        let std = ($ch_values | math stddev)
        let variance = ($ch_values | math variance)
        let rms = ($ch_values | each { |x| $x * $x } | math avg | math sqrt)
        let max_amp = ($ch_values | each { |x| $x | math abs } | math max)
        
        # Detect flatline
        let is_flatline = $std < $cfg.quality_thresholds.flatline_threshold
        
        # Detect saturation
        let is_saturated = $max_amp > $cfg.quality_thresholds.saturation_threshold
        
        # Estimate SNR (simplified: signal variance / assumed noise floor)
        let noise_floor = 1.0  # µV
        let snr = if $std > $noise_floor {
            20 * ($std / $noise_floor | math log10)
        } else {
            0.0
        }
        
        # Estimate impedance (simplified model)
        # Real impedance would require calibration and known test signal
        let estimated_impedance = if $std > 0 {
            5.0 + (100.0 / ($std + 1.0))  # Simplified model
        } else {
            999.0  # Very high for flatline
        }
        
        # Overall quality score
        let quality_score = if $is_flatline or $is_saturated {
            0.0
        } else if $snr < $cfg.quality_thresholds.snr_min {
            ($snr / $cfg.quality_thresholds.snr_min) * 0.5
        } else if $estimated_impedance > $cfg.quality_thresholds.impedance_max {
            0.5
        } else {
            1.0
        }
        
        $channel_quality = ($channel_quality | append {
            channel: $ch,
            name: $ch_name,
            mean_uv: $mean,
            std_uv: $std,
            variance_uv2: $variance,
            rms_uv: $rms,
            max_amplitude_uv: $max_amp,
            snr_db: $snr,
            estimated_impedance_kohm: $estimated_impedance,
            is_flatline: $is_flatline,
            is_saturated: $is_saturated,
            quality_score: $quality_score,
            status: (if $quality_score > 0.8 { "good" } else if $quality_score > 0.4 { "fair" } else { "poor" })
        })
    }
    
    let overall_score = ($channel_quality | get quality_score | math avg)
    
    let result = {
        timestamp: (date now),
        overall_score: $overall_score,
        overall_status: (if $overall_score > 0.8 { "good" } else if $overall_score > 0.4 { "fair" } else { "poor" }),
        sample_count: $n_samples,
        channels: ($channel_quality | if $detailed { } else { select channel name quality_score status }),
        detailed_channels: $channel_quality,
        summary: {
            good_channels: ($channel_quality | where quality_score > 0.8 | length),
            fair_channels: ($channel_quality | where quality_score > 0.4 and quality_score <= 0.8 | length),
            poor_channels: ($channel_quality | where quality_score <= 0.4 | length),
            flatline_detected: ($channel_quality | where is_flatline | length) > 0,
            saturation_detected: ($channel_quality | where is_saturated | length) > 0
        }
    }
    
    if not $detailed {
        $result | reject detailed_channels
    } else {
        $result
    }
}

# Continuous quality monitoring
export def "quality monitor" [
    --interval: duration = 1sec       # Check interval
    --callback: closure = null        # Callback for quality changes
]: [ list -> record ] {
    let data = $in
    
    log info $"Starting quality monitoring with ($interval) interval"
    
    mut last_quality = null
    mut alerts = []
    
    # This would typically run in a loop for streaming data
    # For now, perform a single quality check
    let current_quality = ($data | signal quality --detailed)
    
    # Check for significant changes
    if ($last_quality | is-not-empty) {
        let score_change = ($current_quality.overall_score - $last_quality.overall_score) | math abs
        
        if $score_change > 0.2 {
            $alerts = ($alerts | append {
                type: "quality_change",
                severity: (if $score_change > 0.5 { "high" } else { "medium" }),
                message: $"Quality score changed by ($score_change | math round -p 2)",
                timestamp: (date now)
            })
            
            if ($callback | is-not-empty) {
                do $callback $current_quality $last_quality
            }
        }
    }
    
    $last_quality = $current_quality
    
    {
        quality: $current_quality,
        alerts: $alerts,
        monitoring: true,
        interval: $interval
    }
}

# =============================================================================
# Multi-Signal Type Support
# =============================================================================

# Route different signal types to appropriate processing
export def "signal route" [
    --eeg-handler: closure = null     # Handler for EEG data
    --emg-handler: closure = null     # Handler for EMG data
    --ecg-handler: closure = null     # Handler for ECG data
    --accel-handler: closure = null   # Handler for accelerometer data
]: [ record -> record ] {
    let input = $in
    let signal_types = $input.signal_types? | default ["eeg"]
    
    mut routed = {}
    
    for signal_type in $signal_types {
        $routed = match $signal_type {
            "eeg" => { 
                if ($eeg_handler | is-not-empty) {
                    $routed | insert eeg (do $eeg_handler $input)
                } else { $routed }
            },
            "emg" => {
                if ($emg_handler | is-not-empty) {
                    $routed | insert emg (do $emg_handler $input)
                } else { $routed }
            },
            "ecg" => {
                if ($ecg_handler | is-not-empty) {
                    $routed | insert ecg (do $ecg_handler $input)
                } else { $routed }
            },
            "accel" => {
                if ($accel_handler | is-not-empty) {
                    $routed | insert accel (do $accel_handler $input)
                } else { $routed }
            },
            _ => $routed
        }
    }
    
    $input | insert routed $routed
}

# Extract specific signal type from multi-signal data
export def "signal extract" [
    signal_type: string   # Signal type to extract: eeg, emg, ecg, accel
]: [ record -> record ] {
    let input = $in
    
    match $signal_type {
        "eeg" => {
            $input | select timestamp? sample_num? channels? | rename -c { channels: eeg_channels }
        },
        "emg" => {
            $input | select timestamp? sample_num? | insert emg_data []  # Would extract EMG-specific channels
        },
        "ecg" => {
            $input | select timestamp? sample_num? | insert ecg_data []  # Would extract ECG-specific channels
        },
        "accel" => {
            $input | select timestamp? sample_num? aux? | rename -c { aux: accel_data }
        },
        _ => $input
    }
}

# =============================================================================
# Module Info
# =============================================================================

export def module-info [] {
    {
        name: "signal_input",
        version: "0.1.0",
        description: "Signal acquisition and preprocessing for cognitive architecture",
        commands: [
            "signal acquire",
            "signal preprocess",
            "signal window",
            "signal quality",
            "quality monitor",
            "signal route",
            "signal extract"
        ]
    }
}
