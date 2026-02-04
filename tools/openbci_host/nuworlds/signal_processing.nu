# signal_processing.nu
# EEG signal processing functions for nushell
# Band power calculations, filtering, and metrics

use std log
use ./eeg_types.nu [BANDS all-bands]

# =============================================================================
# Power Calculations
# =============================================================================

# Calculate Root Mean Square of channel values
export def rms [
    --channel: int = null  # Specific channel (null = all)
] {
    let data = $in
    
    if ($channel | is-not-empty) {
        # Single channel RMS
        let values = ($data | each {|row| $row.channels | get $channel})
        let mean_square = ($values | each {|x| $x * $x} | math avg)
        $mean_square | math sqrt
    } else {
        # All channels RMS
        let n_ch = ($data | first).channels | length
        mut result = {}
        
        for ch in 0..<($n_ch) {
            let values = ($data | each {|row| $row.channels | get $ch})
            let mean_square = ($values | each {|x| $x * $x} | math avg)
            let rms_val = ($mean_square | math sqrt)
            $result = ($result | insert $"ch($ch)" $rms_val)
        }
        
        $result
    }
}

# Calculate mean absolute value
export def mav [
    --channel: int = null
] {
    let data = $in
    
    if ($channel | is-not-empty) {
        let values = ($data | each {|row| $row.channels | get $channel})
        $values | each {|x| $x | math abs} | math avg
    } else {
        let n_ch = ($data | first).channels | length
        mut result = {}
        
        for ch in 0..<($n_ch) {
            let values = ($data | each {|row| $row.channels | get $ch})
            let mav_val = ($values | each {|x| $x | math abs} | math avg)
            $result = ($result | insert $"ch($ch)" $mav_val)
        }
        
        $result
    }
}

# Calculate variance of channels
export def variance [
    --channel: int = null
] {
    let data = $in
    
    if ($channel | is-not-empty) {
        let values = ($data | each {|row| $row.channels | get $channel})
        $values | math variance
    } else {
        let n_ch = ($data | first).channels | length
        mut result = {}
        
        for ch in 0..<($n_ch) {
            let values = ($data | each {|row| $row.channels | get $ch})
            let var = ($values | math variance)
            $result = ($result | insert $"ch($ch)" $var)
        }
        
        $result
    }
}

# =============================================================================
# Windowing Operations
# =============================================================================

# Apply moving average filter to data
export def moving-average [
    window: int              # Window size in samples
    --channel: int = null    # Specific channel (null = all)
] {
    let data = $in
    let n = $data | length
    
    if ($n < $window) {
        log warning $"Data length ($n) < window size ($window)"
        return $data
    }
    
    mut result = []
    
    for i in $window..<($n) {
        let window_data = ($data | range ($i - $window)..<$i)
        let timestamp = ($data | get $i | get timestamp)
        
        if ($channel | is-not-empty) {
            # Single channel
            let values = ($window_data | each {|row| $row.channels | get $channel})
            let avg = ($values | math avg)
            
            $result = ($result | append {
                timestamp: $timestamp
                channel: $channel
                value: $avg
            })
        } else {
            # All channels
            let n_ch = ($data | first).channels | length
            mut channels = []
            
            for ch in 0..<($n_ch) {
                let values = ($window_data | each {|row| $row.channels | get $ch})
                let avg = ($values | math avg)
                $channels = ($channels | append $avg)
            }
            
            $result = ($result | append {
                timestamp: $timestamp
                channels: $channels
            })
        }
    }
    
    $result
}

# Extract a time window from the data
export def time-window [
    start: duration          # Start offset from beginning
    end?: duration           # End offset (null = to end)
    --from-start             # Interpret as from start of data
] {
    let data = $in
    let start_sec = ($start | into int) / 1_000_000_000
    
    let start_time = if $from_start {
        let first_ts = ($data | first).timestamp
        $first_ts + $start_sec
    } else {
        $start_sec
    }
    
    let end_time = if ($end | is-not-empty) {
        let end_sec = ($end | into int) / 1_000_000_000
        if $from_start {
            let first_ts = ($data | first).timestamp
            $first_ts + $end_sec
        } else {
            $end_sec
        }
    } else {
        1e308  # Infinity
    }
    
    $data | filter {|row| $row.timestamp >= $start_time and $row.timestamp <= $end_time}
}

# Downsample data by factor N
export def downsample [
    factor: int              # Downsample factor
] {
    let data = $in
    mut result = []
    mut count = 0
    
    for row in $data {
        if ($count % $factor) == 0 {
            $result = ($result | append $row)
        }
        $count = $count + 1
    }
    
    $result
}

# =============================================================================
# Simple Filter Approximations
# =============================================================================

# Simple high-pass filter (removes DC offset)
# Uses exponential moving average to estimate DC
export def highpass-filter [
    alpha: float = 0.99      # Smoothing factor (closer to 1 = lower cutoff)
    --channel: int = null
] {
    let data = $in
    
    mut result = []
    mut dc_estimate = 0.0
    
    for row in $data {
        if ($channel | is-not-empty) {
            let value = ($row.channels | get $channel)
            $dc_estimate = ($alpha * $dc_estimate) + ((1 - $alpha) * $value)
            let filtered = $value - $dc_estimate
            
            $result = ($result | append {
                timestamp: $row.timestamp
                channel: $channel
                value: $filtered
                dc: $dc_estimate
            })
        } else {
            # All channels - requires maintaining DC per channel
            let n_ch = ($data | first).channels | length
            mut channels = []
            
            for ch in 0..<($n_ch) {
                let value = ($row.channels | get $ch)
                # Note: This is a simplification; proper implementation needs per-channel state
                let filtered = $value  # Placeholder
                $channels = ($channels | append $filtered)
            }
            
            $result = ($result | append {
                timestamp: $row.timestamp
                channels: $channels
            })
        }
    }
    
    $result
}

# Notch filter approximation for power line interference
# Uses simple IIR bandstop approximation
export def notch-filter [
    freq: float = 60.0       # Notch frequency (50 or 60 Hz)
    --sampling-rate: int = 250
] {
    let data = $in
    
    # Simple delay-line notch: y[n] = x[n] - x[n-delay] + coeff*y[n-delay]
    # Where delay = sampling_rate / (2 * notch_freq)
    let delay = (($sampling_rate / ($freq * 2)) | into int)
    
    if ($data | length) <= $delay {
        log warning "Data too short for notch filter"
        return $data
    }
    
    mut result = []
    mut buffer = []
    
    for i in 0..<($data | length) {
        let row = ($data | get $i)
        let n_ch = $row.channels | length
        
        if $i < $delay {
            # Fill buffer
            $buffer = ($buffer | append $row)
            $result = ($result | append $row)
        } else {
            let delayed = ($buffer | get 0)
            $buffer = ($buffer | drop 1 | append $row)
            
            # Apply simple notch: current - delayed
            mut channels = []
            for ch in 0..<($n_ch) {
                let current = ($row.channels | get $ch)
                let past = ($delayed.channels | get $ch)
                let filtered = $current - $past
                $channels = ($channels | append $filtered)
            }
            
            $result = ($result | append {
                timestamp: $row.timestamp
                sample_num: $row.sample_num
                channels: $channels
                aux: $row.aux
            })
        }
    }
    
    $result
}

# =============================================================================
# Band Power Analysis (Simplified)
# =============================================================================

# Calculate relative band power from time-domain features
# Note: Full FFT requires external tools; this uses time-domain approximations
export def band-power [
    --band: string = "alpha"  # Band name: delta, theta, alpha, beta, gamma
    --sampling-rate: int = 250
] {
    let data = $in
    let band_info = (all-bands | get $band)
    
    if ($band_info | is-empty) {
        log error $"Unknown band: ($band)"
        return {}
    }
    
    let n_ch = ($data | first).channels | length
    mut channel_powers = []
    
    for ch in 0..<($n_ch) {
        let values = ($data | each {|row| $row.channels | get $ch})
        
        # Use variance as proxy for power (simplified)
        let power = ($values | math variance)
        
        $channel_powers = ($channel_powers | append {
            channel: $ch
            band: $band
            power: $power
            low_freq: $band_info.low
            high_freq: $band_info.high
        })
    }
    
    {
        band: $band
        band_name: $band_info.name
        channels: $channel_powers
        total_power: ($channel_powers | get power | math sum)
        avg_power: ($channel_powers | get power | math avg)
    }
}

# Calculate power for all bands
export def all-band-powers [
    --sampling-rate: int = 250
] {
    let data = $in
    let bands_list = [delta theta alpha beta gamma]
    
    mut results = {}
    
    for band in $bands_list {
        let power = ($data | band-power --band $band --sampling-rate $sampling_rate)
        $results = ($results | insert $band $power)
    }
    
    # Calculate relative powers (normalized to total)
    let total_power = ($results | values | each {|b| $b.avg_power} | math sum)
    
    mut relative = {}
    for band in $bands_list {
        let abs_power = ($results | get $band | get avg_power)
        let rel_power = if $total_power > 0 { $abs_power / $total_power } else { 0 }
        $relative = ($relative | insert $band $rel_power)
    }
    
    {
        absolute: $results
        relative: $relative
        total_power: $total_power
        sampling_rate: $sampling_rate
        samples_analyzed: ($data | length)
    }
}

# =============================================================================
# Feature Extraction
# =============================================================================

# Extract common EEG features from a data window
export def extract-features [
    --sampling-rate: int = 250
    --channel-names: list = null
] {
    let data = $in
    let n = $data | length
    let n_ch = ($data | first).channels | length
    let names = if ($channel_names | is-not-empty) {
        $channel_names
    } else {
        0..<($n_ch) | each {|i| $"Ch($i)"}
    }
    
    mut features = {}
    
    for ch in 0..<($n_ch) {
        let values = ($data | each {|row| $row.channels | get $ch})
        let ch_name = ($names | get $ch)
        
        let ch_features = {
            mean: ($values | math avg)
            std: ($values | math stddev)
            variance: ($values | math variance)
            min: ($values | math min)
            max: ($values | math max)
            rms: ($values | each {|x| $x * $x} | math avg | math sqrt)
            mav: ($values | each {|x| $x | math abs} | math avg)
            # Zero crossing rate (simplified)
            zcr: 0  # Would need sign change detection
        }
        
        $features = ($features | insert $ch_name $ch_features)
    }
    
    {
        timestamp: ($data | last).timestamp
        duration_sec: ($n | into float) / ($sampling_rate | into float)
        samples: $n
        sampling_rate: $sampling_rate
        channels: $features
    }
}

# Calculate signal quality metrics
export def signal-quality [
    --sampling-rate: int = 250
] {
    let data = $in
    let n_ch = ($data | first).channels | length
    
    mut quality = []
    
    for ch in 0..<($n_ch) {
        let values = ($data | each {|row| $row.channels | get $ch})
        
        let mean = ($values | math avg)
        let std = ($values | math stddev)
        let rms = ($values | each {|x| $x * $x} | math avg | math sqrt)
        
        # Check for flatline (very low std)
        let is_flatline = ($std < 0.01)
        
        # Check for saturation (values near extremes)
        let max_val = ($values | math abs | math max)
        let is_saturated = ($max_val > 10000)  # Assuming microvolts
        
        # Check for 50/60 Hz line noise (simple variance check)
        let notch_applied = ($data | notch-filter --sampling-rate $sampling_rate)
        let notch_values = ($notch_applied | each {|row| $row.channels | get $ch})
        let notch_var = ($notch_values | math variance)
        let line_noise_ratio = if $notch_var > 0 { $std / $notch_var } else { 1.0 }
        let has_line_noise = ($line_noise_ratio > 2.0)
        
        # Overall quality score (0-1)
        let quality_score = if $is_flatline or $is_saturated {
            0.0
        } else if $has_line_noise {
            0.5
        } else {
            1.0
        }
        
        $quality = ($quality | append {
            channel: $ch
            mean_uv: $mean
            std_uv: $std
            rms_uv: $rms
            is_flatline: $is_flatline
            is_saturated: $is_saturated
            has_line_noise: $has_line_noise
            quality_score: $quality_score
        })
    }
    
    {
        timestamp: ($data | last).timestamp
        overall_score: ($quality | get quality_score | math avg)
        channels: $quality
    }
}

# =============================================================================
# Utility Functions
# =============================================================================

# Normalize channels to zero mean
export def normalize [
    --per-channel: bool = true
] {
    let data = $in
    
    if $per_channel {
        let n_ch = ($data | first).channels | length
        
        # Calculate means per channel
        mut means = []
        for ch in 0..<($n_ch) {
            let values = ($data | each {|row| $row.channels | get $ch})
            $means = ($means | append ($values | math avg))
        }
        
        # Subtract means
        $data | each {|row|
            mut new_channels = []
            for ch in 0..<($n_ch) {
                let normalized = ($row.channels | get $ch) - ($means | get $ch)
                $new_channels = ($new_channels | append $normalized)
            }
            {
                timestamp: $row.timestamp
                sample_num: $row.sample_num
                channels: $new_channels
                aux: $row.aux
            }
        }
    } else {
        # Global normalization
        let global_mean = ($data | each {|row| $row.channels | math avg} | math avg)
        
        $data | each {|row|
            {
                timestamp: $row.timestamp
                sample_num: $row.sample_num
                channels: ($row.channels | each {|x| $x - $global_mean})
                aux: $row.aux
            }
        }
    }
}

# Apply gain to all channels
export def apply-gain [
    gain: float
] {
    let data = $in
    
    $data | each {|row|
        {
            timestamp: $row.timestamp
            sample_num: $row.sample_num
            channels: ($row.channels | each {|x| $x * $gain})
            aux: $row.aux
        }
    }
}

# Convert to microvolts (assuming data is in some other unit)
export def to-microvolts [
    --unit: string = "volts"  # Current unit: volts, millivolts, nanovolts
] {
    let data = $in
    let factor = match $unit {
        "volts" => 1_000_000
        "millivolts" => 1_000
        "nanovolts" => 0.001
        _ => 1
    }
    
    $data | apply-gain $factor
}
