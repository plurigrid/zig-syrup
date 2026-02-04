# multiscale_pyramid.nu
# Multi-Scale Pyramid for Hierarchical Analysis of Brain Dynamics
# Implements Gaussian/Laplacian pyramids for multi-resolution analysis
# and temporal pyramids for multi-timescale dynamics

use std log

# =============================================================================
# Types and Constants
# =============================================================================

export const DEFAULT_PYRAMID_LEVELS = 4
export const DEFAULT_REDUCTION_FACTOR = 2.0
export const DEFAULT_SIGMA = 1.0

export const PYRAMID_TYPES = {
    gaussian: "Gaussian pyramid for coarse-to-fine analysis"
    laplacian: "Laplacian pyramid for bandpass decomposition"
    temporal: "Temporal pyramid for multi-timescale dynamics"
    wavelet: "Wavelet-like pyramid for time-frequency analysis"
}

# =============================================================================
# Gaussian Pyramid
# =============================================================================

# Build Gaussian pyramid by repeated smoothing and subsampling
export def "pyramid build" [
    data: list                    # Input data (1D signal or 2D image)
    --levels: int = $DEFAULT_PYRAMID_LEVELS
    --reduction-factor: float = $DEFAULT_REDUCTION_FACTOR
    --sigma: float = $DEFAULT_SIGMA
    --pyramid-type: string = "gaussian"  # gaussian, laplacian, temporal
]: [ nothing -> record ] {
    match $pyramid_type {
        "gaussian" => (build-gaussian-pyramid $data $levels $reduction_factor $sigma)
        "laplacian" => (build-laplacian-pyramid $data $levels $reduction_factor $sigma)
        "temporal" => (build-temporal-pyramid $data $levels $reduction_factor)
        "wavelet" => (build-wavelet-pyramid $data $levels)
        _ => { error make { msg: $"Unknown pyramid type: ($pyramid_type)" } }
    }
}

# Build Gaussian pyramid
export def build-gaussian-pyramid [data: list, levels: int, reduction: float, sigma: float]: [ nothing -> record ] {
    mut pyramid = []
    mut current = $data
    
    # Level 0: original data
    $pyramid = ($pyramid | append {
        level: 0
        data: $current
        scale: 1.0
        size: ($current | length)
    })
    
    # Build higher levels
    for level in 1..<$levels {
        # Apply Gaussian smoothing
        let smoothed = (gaussian-smooth $current $sigma)
        
        # Downsample
        let downsampled = (downsample $smoothed $reduction)
        
        let scale = ($reduction | into float) ** ($level | into float)
        
        $pyramid = ($pyramid | append {
            level: $level
            data: $downsampled
            scale: $scale
            size: ($downsampled | length)
            reduction_factor: $reduction
        })
        
        $current = $downsampled
    }
    
    {
        type: "gaussian"
        levels: $levels
        reduction_factor: $reduction
        sigma: $sigma
        pyramid: $pyramid
        original_size: ($data | length)
    }
}

# Gaussian smoothing using simple binomial approximation
def gaussian-smooth [data: list, sigma: float]: [ nothing -> list ] {
    # Simple 3-point moving average as Gaussian approximation
    let kernel_size = (($sigma * 3) | into int | $in | math max | $in | math min)
    let kernel = (generate-gaussian-kernel $kernel_size $sigma)
    
    convolve-1d $data $kernel
}

# Generate 1D Gaussian kernel
def generate-gaussian-kernel [size: int, sigma: float]: [ nothing -> list ] {
    let center = $size / 2.0
    mut kernel = []
    
    for i in 0..<$size {
        let x = ($i | into float) - $center
        let value = ($x * $x / (-2.0 * $sigma * $sigma)) | math exp
        $kernel = ($kernel | append $value)
    }
    
    # Normalize
    let sum = $kernel | math sum
    $kernel | each {|k| $k / $sum }
}

# 1D convolution with zero padding
def convolve-1d [signal: list, kernel: list]: [ nothing -> list ] {
    let n = $signal | length
    let k = $kernel | length
    let pad = ($k / 2 | into int)
    
    mut result = []
    
    for i in 0..<$n {
        mut sum = 0.0
        for j in 0..<$k {
            let signal_idx = ($i | into int) + ($j | into int) - $pad
            let k_val = $kernel | get $j
            
            let s_val = if $signal_idx >= 0 and $signal_idx < $n {
                $signal | get $signal_idx
            } else {
                0.0  # Zero padding
            }
            
            $sum = $sum + $s_val * $k_val
        }
        $result = ($result | append $sum)
    }
    
    $result
}

# Downsample by averaging
export def downsample [data: list, factor: float]: [ nothing -> list ] {
    let n = $data | length
    let step = ($factor | into int | if $in > 2 { $in } else { 2 })
    
    mut result = []
    mut i = 0
    
    while $i < $n {
        let end = ($i + $step) | if $in < $n { $in } else { $n }
        let window = $data | range $i..<$end
        let avg = $window | math avg
        $result = ($result | append $avg)
        $i = $i + $step
    }
    
    $result
}

# Upsample by interpolation
def upsample [data: list, factor: int]: [ nothing -> list ] {
    let n = $data | length
    mut result = []
    
    for i in 0..<$n {
        let val = $data | get $i
        $result = ($result | append $val)
        
        # Insert interpolated values
        if $i < ($n - 1) {
            let next_val = $data | get ($i + 1)
            for j in 1..<$factor {
                let t = ($j | into float) / ($factor | into float)
                let interp = $val * (1.0 - $t) + $next_val * $t
                $result = ($result | append $interp)
            }
        }
    }
    
    $result
}

# =============================================================================
# Laplacian Pyramid
# =============================================================================

# Build Laplacian pyramid (bandpass decomposition)
export def build-laplacian-pyramid [data: list, levels: int, reduction: float, sigma: float]: [ nothing -> record ] {
    # First build Gaussian pyramid
    let gaussian = (build-gaussian-pyramid $data $levels $reduction $sigma)
    
    mut laplacian = []
    
    # Laplacian levels are differences between Gaussian levels
    for i in 0..<($levels - 1) {
        let current = $gaussian.pyramid | get $i | get data
        let next_g = $gaussian.pyramid | get ($i + 1) | get data
        
        # Upsample next level to match current
        let factor = ($reduction | into int)
        let upsampled_next = (upsample $next_g $factor)
        
        # Pad or truncate to match sizes
        let target_size = $current | length
        let sized_next = if ($upsampled_next | length) > $target_size {
            $upsampled_next | range 0..<$target_size
        } else if ($upsampled_next | length) < $target_size {
            $upsampled_next | append (seq 0 ($target_size - ($upsampled_next | length)) | each { 0 })
        } else {
            $upsampled_next
        }
        
        # Laplacian = current - upsampled(next)
        let lap_level = ($current | zip $sized_next | each {|p| $p.0 - $p.1 })
        
        $laplacian = ($laplacian | append {
            level: $i
            data: $lap_level
            scale: ($gaussian.pyramid | get $i | get scale)
            frequency_band: (level-to-frequency-band $i $levels)
        })
    }
    
    # Last level is same as Gaussian
    let last_level = $levels - 1
    $laplacian = ($laplacian | append {
        level: $last_level
        data: ($gaussian.pyramid | get $last_level | get data)
        scale: ($gaussian.pyramid | get $last_level | get scale)
        frequency_band: "lowpass"
    })
    
    {
        type: "laplacian"
        levels: $levels
        reduction_factor: $reduction
        sigma: $sigma
        pyramid: $laplacian
        gaussian_base: $gaussian
        original_size: ($data | length)
        is_reconstructible: true
    }
}

# Map pyramid level to frequency band
def level-to-frequency-band [level: int, total_levels: int]: [ nothing -> string ] {
    let ratio = ($level | into float) / (($total_levels - 1) | into float)
    
    if $ratio < 0.25 {
        "high_frequency"
    } else if $ratio < 0.5 {
        "mid_high_frequency"
    } else if $ratio < 0.75 {
        "mid_low_frequency"
    } else {
        "low_frequency"
    }
}

# Reconstruct from Laplacian pyramid
export def reconstruct-from-laplacian [laplacian_pyramid: record]: [ nothing -> list ] {
    let levels = $laplacian_pyramid.pyramid
    let n_levels = $levels | length
    
    # Start from coarsest level
    mut result = $levels | last | get data
    
    # Add finer details
    for i in (($n_levels - 2)..=0) {
        let level_data = $levels | get $i | get data
        let factor = ($laplacian_pyramid.reduction_factor | into int)
        
        # Upsample current result
        let upsampled = (upsample $result $factor)
        
        # Match sizes
        let target_size = $level_data | length
        let sized_result = if ($upsampled | length) > $target_size {
            $upsampled | range 0..<$target_size
        } else {
            $upsampled
        }
        
        # Add detail
        $result = ($level_data | zip $sized_result | each {|p| $p.0 + $p.1 })
    }
    
    $result
}

# =============================================================================
# Temporal Pyramid
# =============================================================================

# Build temporal pyramid for multi-timescale analysis
export def build-temporal-pyramid [data: list, levels: int, reduction: float]: [ nothing -> record ] {
    mut pyramid = []
    
    # Level 0: original temporal resolution
    $pyramid = ($pyramid | append {
        level: 0
        data: $data
        timescale: "fine"
        window_size: 1
        sampling_rate_factor: 1.0
    })
    
    # Build coarser temporal scales
    for level in 1..<$levels {
        let window_size = ($reduction | into int) ** ($level | into float)
        let prev_data = $pyramid | get ($level - 1) | get data
        
        # Apply temporal smoothing
        let smoothed = (temporal-smooth $prev_data ($window_size | into int))
        
        # Downsample
        let downsampled = (downsample $smoothed $reduction)
        
        let timescale = if $level == 1 {
            "medium"
        } else if $level == 2 {
            "coarse"
        } else {
            "very_coarse"
        }
        
        $pyramid = ($pyramid | append {
            level: $level
            data: $downsampled
            timescale: $timescale
            window_size: $window_size
            sampling_rate_factor: (1.0 / $window_size)
        })
    }
    
    {
        type: "temporal"
        levels: $levels
        reduction_factor: $reduction
        pyramid: $pyramid
        original_samples: ($data | length)
        timescales: ($pyramid | each {|p| $p.timescale })
    }
}

# Temporal smoothing using moving average
def temporal-smooth [data: list, window: int]: [ nothing -> list ] {
    let n = $data | length
    let half_window = ($window / 2 | into int)
    
    mut result = []
    
    for i in 0..<$n {
        let start = ($i | into int) - $half_window | if $in > 0 { $in } else { 0 }
        let end = ($i | into int) + $half_window + 1 | if $in < $n { $in } else { $n }
        
        let window_data = $data | range $start..<$end
        let avg = $window_data | math avg
        
        $result = ($result | append $avg)
    }
    
    $result
}

# =============================================================================
# Wavelet-like Pyramid
# =============================================================================

# Build wavelet-like pyramid using quadrature mirror filters
export def build-wavelet-pyramid [data: list, levels: int]: [ nothing -> record ] {
    mut pyramid = []
    mut current = $data
    
    for level in 0..<$levels {
        # Apply low-pass and high-pass filters
        let lowpass = (apply-lowpass $current)
        let highpass = (apply-highpass $current)
        
        # Downsample both
        let approx = (downsample $lowpass 2)
        let detail = (downsample $highpass 2)
        
        $pyramid = ($pyramid | append {
            level: $level
            approximation: $approx
            detail: $detail
            detail_coefficients: $detail
            scale: (2 ** ($level | into float))
        })
        
        # Continue with approximation for next level
        $current = $approx
    }
    
    {
        type: "wavelet"
        levels: $levels
        pyramid: $pyramid
        original_size: ($data | length)
        final_approximation: $current
    }
}

# Simple low-pass filter (moving average)
def apply-lowpass [data: list]: [ nothing -> list ] {
    convolve-1d $data [0.5 0.5]
}

# Simple high-pass filter (difference)
def apply-highpass [data: list]: [ nothing -> list ] {
    convolve-1d $data [0.5 -0.5]
}

# =============================================================================
# Pyramid Analysis
# =============================================================================

# Analyze features at each pyramid level
export def "pyramid analyze" [
    pyramid: record             # Pyramid from pyramid build
    --feature_fn: closure  # Custom feature extraction function
]: [ nothing -> record ] {
    let levels = $pyramid.pyramid
    mut analyses = []
    
    for level in $levels {
        # Extract data based on pyramid type
        let data = if ($level | get -o data | is-not-empty) {
            $level | get data
        } else if ($level | get -o approximation | is-not-empty) {
            $level | get approximation
        } else {
            []
        }
        
        # Compute standard features
        let std_features = (compute-level-features $data)
        
        # Apply custom feature function if provided
        let custom_features = if ($feature_fn | describe) != "nothing" {
            do $feature_fn $data $level
        } else {
            {}
        }
        
        $analyses = ($analyses | append ({
            level: ($level | get level)
            scale: ($level | get -o scale | default 1.0)
        } | merge $std_features | merge $custom_features))
    }
    
    {
        pyramid_type: $pyramid.type
        level_analyses: $analyses
        cross_scale_statistics: (compute-cross-scale-stats $analyses)
    }
}

# Compute standard features for a pyramid level
export def compute-level-features [data: list]: [ nothing -> record ] {
    if ($data | is-empty) {
        return {
            mean: 0
            variance: 0
            energy: 0
            entropy: 0
        }
    }
    
    let mean = $data | math avg
    let variance = $data | each {|x| ($x - $mean) ** 2 } | math avg
    let energy = $data | each {|x| $x * $x } | math sum
    
    # Simple entropy estimate
    let normalized = $data | normalize-distribution-safe
    let entropy = ($normalized | each {|p| if $p > 0.001 { -$p * ($p | math ln) } else { 0 } } | math sum)
    
    {
        mean: $mean
        variance: $variance
        std: ($variance | math sqrt)
        energy: $energy
        entropy: $entropy
        min: ($data | math min)
        max: ($data | math max)
        dynamic_range: (($data | math max) - ($data | math min))
    }
}

# Safe normalization for distribution
def normalize-distribution-safe [data: list]: [ nothing -> list ] {
    let sum = $data | each {|x| $x | math abs } | math sum
    if $sum > 0 {
        $data | each {|x| ($x | math abs) / $sum }
    } else {
        let n = $data | length
        seq 0 $n | each { 1.0 / ($n | into float) }
    }
}

# Compute cross-scale statistics
export def compute-cross-scale-stats [analyses: list]: [ nothing -> record ] {
    let energies = $analyses | each {|a| $a | get -o energy | default 0 }
    let variances = $analyses | each {|a| $a | get -o variance | default 0 }
    
    {
        energy_distribution: $energies
        variance_distribution: $variances
        total_energy: ($energies | math sum)
        energy_ratio_high_low: if ($energies | first) > 0 { 
            ($energies | last) / ($energies | first) 
        } else { 0 }
        dominant_scale: ($energies | enumerate | sort-by item | last | get index)
    }
}

# =============================================================================
# Cross-Scale Fusion
# =============================================================================

# Fuse information across pyramid levels
export def "pyramid fusion" [
    pyramid: record
    --fusion-mode: string = "weighted"  # weighted, max, attention
    --weights: list = []               # Custom weights per level
]: [ nothing -> record ] {
    let levels = $pyramid.pyramid
    let n_levels = $levels | length
    
    # Determine fusion weights
    let fusion_weights = if ($weights | is-empty) {
        match $fusion_mode {
            "weighted" => (compute-gaussian-weights $n_levels)
            "max" => (seq 0 $n_levels | each { 1.0 / ($n_levels | into float) })
            "attention" => (compute-attention-weights $levels)
            _ => (seq 0 $n_levels | each { 1.0 })
        }
    } else {
        $weights
    }
    
    # Collect data from all levels (upsampled to original size)
    let original_size = $pyramid.original_size
    mut upsampled_levels = []
    
    for level in $levels {
        let data = if ($level | get -o data | is-not-empty) {
            $level | get data
        } else if ($level | get -o approximation | is-not-empty) {
            $level | get approximation
        } else {
            []
        }
        
        let level_idx = $level | get level
        let scale = ($pyramid | get -o reduction_factor | default 2.0) ** ($level_idx | into float)
        let upsample_factor = ($scale | into int | math max 1)
        
        let upsampled = (upsample-to-size $data $original_size)
        $upsampled_levels = ($upsampled_levels | append $upsampled)
    }
    
    # Apply weighted fusion
    mut fused = []
    for i in 0..<$original_size {
        mut weighted_sum = 0.0
        mut weight_sum = 0.0
        
        for level_idx in 0..<($upsampled_levels | length) {
            let level_data = $upsampled_levels | get $level_idx
            if $i < ($level_data | length) {
                let val = $level_data | get $i
                let w = $fusion_weights | get $level_idx
                $weighted_sum = $weighted_sum + $val * $w
                $weight_sum = $weight_sum + $w
            }
        }
        
        let fused_val = if $weight_sum > 0 { $weighted_sum / $weight_sum } else { 0 }
        $fused = ($fused | append $fused_val)
    }
    
    {
        fused_signal: $fused
        fusion_mode: $fusion_mode
        weights: $fusion_weights
        pyramid_levels_used: $n_levels
        reconstruction_error: (compute-reconstruction-error $pyramid $fused)
    }
}

# Upsample data to target size
def upsample-to-size [data: list, target_size: int]: [ nothing -> list ] {
    let current_size = $data | length
    if $current_size >= $target_size {
        return ($data | range 0..<$target_size)
    }
    
    let factor = (($target_size | into float) / ($current_size | into float)) | into int | math max
    upsample $data $factor | range 0..<$target_size
}

# Compute Gaussian weights (center-weighted)
def compute-gaussian-weights [n: int]: [ nothing -> list ] {
    let center = ($n - 1) / 2.0
    let sigma = $n / 4.0
    
    seq 0 $n | each {|i| 
        let x = ($i | into float) - $center
        ($x * $x / (-2.0 * $sigma * $sigma)) | math exp
    }
}

# Compute attention weights based on level energy
export def compute-attention-weights [levels: list]: [ nothing -> list ] {
    let energies = $levels | each {|level| 
        let data = if ($level | get -o data | is-not-empty) {
            $level | get data
        } else if ($level | get -o approximation | is-not-empty) {
            $level | get approximation
        } else {
            []
        }
        
        if ($data | is-empty) { 0 } else { 
            $data | each {|x| $x * $x } | math avg 
        }
    }
    
    # Softmax over energies
    let max_energy = $energies | math max
    let exp_energies = $energies | each {|e| ($e - $max_energy / 2) | math exp }
    let sum_exp = $exp_energies | math sum
    
    $exp_energies | each {|e| $e / $sum_exp }
}

# Compute reconstruction error
export def compute-reconstruction-error [pyramid: record, reconstructed: list]: [ nothing -> float ] {
    if ($pyramid.type == "laplacian") {
        let original = (reconstruct-from-laplacian $pyramid)
        let n = ($original | length) | math min ($reconstructed | length)
        let errors = (seq 0 $n | each {|i| 
            let o = $original | get $i
            let r = $reconstructed | get $i
            ($o - $r) | math abs
        })
        $errors | math avg
    } else {
        0.0
    }
}

# =============================================================================
# EEG-Specific Pyramid Functions
# =============================================================================

# Build multi-scale pyramid for EEG analysis
export def eeg-pyramid [
    eeg-data: list
    --levels: int = 4
    --pyramid-type: string = "temporal"
    --channel: int = null        # Specific channel, or null for average
]: [ nothing -> record ] {
    # Extract signal
    let signal = if $channel != null {
        $eeg_data | each {|s| $s.channels | get $channel }
    } else {
        # Average across channels
        $eeg_data | each {|s| $s.channels | math avg }
    }
    
    # Build pyramid
    let pyramid = (pyramid build $signal --levels $levels --pyramid-type $pyramid_type)
    
    # Analyze for EEG-specific features
    let analysis = (pyramid analyze $pyramid --feature-fn {|data level| 
        {
            band_power_proxy: ($data | each {|x| $x * $x } | math avg)
            zero_crossings: (count-zero-crossings $data)
        }
    })
    
    {
        pyramid: $pyramid
        analysis: $analysis
        channel: ($channel | default -1)
        sampling_rates: ($pyramid.pyramid | each {|p| 
            $p | get -o sampling_rate_factor | default 1.0
        })
    }
}

# Count zero crossings in signal
export def count-zero-crossings [data: list]: [ nothing -> int ] {
    mut count = 0
    mut prev = $data | first
    
    for x in ($data | skip 1) {
        if ($prev < 0 and $x >= 0) or ($prev >= 0 and $x < 0) {
            $count = $count + 1
        }
        $prev = $x
    }
    
    $count
}

# Analyze scale-space representation of brain dynamics
export def analyze-scale-space [
    eeg-pyramid: record
    --frequency-bands: record = {}  # {delta: [0.5 4], theta: [4 8], ...}
]: [ nothing -> record ] {
    let analyses = $eeg-pyramid.analysis.level_analyses
    
    # Map levels to frequency content
    let sampling_rates = $eeg-pyramid.sampling_rates
    let nyquist_frequencies = ($sampling_rates | each {|r| $r * 125 })  # Assuming 250Hz base
    
    {
        pyramid_analysis: $eeg-pyramid
        frequency_mapping: ($nyquist_frequencies | enumerate | each {|entry| 
            {level: $entry.index max_frequency_hz: $entry.item}
        })
        dominant_timescales: ($analyses | enumerate | sort-by {|a| $a.item.energy } | last 2 | each {|a| 
            {level: $a.index energy: $a.item.energy}
        })
        cross_scale_complexity: ($analyses | each {|a| $a | get -o entropy | default 0 } | math avg)
    }
}
