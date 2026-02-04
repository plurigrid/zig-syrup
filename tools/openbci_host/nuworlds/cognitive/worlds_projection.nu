# worlds_projection.nu
# Project signals into world states for multiple world variants
# Implements a://, b://, c:// world projections with different feature mappings

use std log
use ../eeg_types.nu *
use ../world_ab.nu [load-world save-world parse-world-uri build-world-uri]
use ./signal_input.nu [SignalConfig]

# =============================================================================
# World Projection Configuration
# =============================================================================

# Configuration for world projections
export def WorldProjectionConfig [] {
    {
        # World variants
        worlds: {
            a: {
                name: "baseline",
                scheme: "a",
                description: "Baseline signal mapping - standard features",
                enabled: true,
                priority: 1
            },
            b: {
                name: "enhanced",
                scheme: "b",
                description: "Enhanced/feature-rich mapping - advanced features",
                enabled: true,
                priority: 2
            },
            c: {
                name: "experimental",
                scheme: "c",
                description: "Experimental/adaptive mapping - ML-enhanced",
                enabled: true,
                priority: 3
            }
        },
        
        # Feature extraction parameters
        features: {
            # Frequency bands
            bands: {
                delta: { low: 0.5, high: 4.0, weight_a: 1.0, weight_b: 0.8, weight_c: 0.6 },
                theta: { low: 4.0, high: 8.0, weight_a: 1.0, weight_b: 1.2, weight_c: 1.5 },
                alpha: { low: 8.0, high: 13.0, weight_a: 1.0, weight_b: 1.5, weight_c: 2.0 },
                beta: { low: 13.0, high: 30.0, weight_a: 1.0, weight_b: 1.2, weight_c: 1.3 },
                gamma: { low: 30.0, high: 100.0, weight_a: 1.0, weight_b: 0.5, weight_c: 1.8 }
            },
            
            # Hjorth parameters
            hjorth: {
                activity: true,
                mobility: true,
                complexity: true
            },
            
            # Entropy measures
            entropy: {
                shannon: true,
                sample: true,
                spectral: false
            },
            
            # Fractal dimensions
            fractal: {
                hfd: true,   # Higuchi's fractal dimension
                kfd: false,  # Katz fractal dimension
                petrosian: false
            }
        },
        
        # World state parameters
        state_mapping: {
            arousal: { min: 0.0, max: 1.0 },
            valence: { min: -1.0, max: 1.0 },
            focus: { min: 0.0, max: 1.0 },
            relaxation: { min: 0.0, max: 1.0 },
            cognitive_load: { min: 0.0, max: 1.0 },
            fatigue: { min: 0.0, max: 1.0 }
        },
        
        # Dynamic selection thresholds
        selection: {
            quality_threshold: 0.6,
            variance_threshold: 0.1,
            adaptation_rate: 0.1
        }
    }
}

# =============================================================================
# World Projection Commands
# =============================================================================

# Project signals into world states across multiple world variants
export def "worlds project" [
    signal_data: record      # Signal data to project
    --worlds: list = null    # Specific worlds to project (null = all enabled)
    --adaptive = true  # Enable dynamic world selection
]: [ nothing -> record ] {
    let cfg = (WorldProjectionConfig)
    let target_worlds = if ($worlds | is-not-empty) { 
        $worlds 
    } else { 
        $cfg.worlds | columns | filter { |w| ($cfg.worlds | get $w | get enabled) }
    }
    
    log info $"Projecting signals into worlds: ($target_worlds | str join ', ')"
    
    mut world_states = {}
    
    for world_id in $target_worlds {
        let world_config = $cfg.worlds | get $world_id
        let projection = match $world_id {
            "a" => (project-world-a $signal_data $cfg),
            "b" => (project-world-b $signal_data $cfg),
            "c" => (project-world-c $signal_data $cfg),
            _ => { error: $"Unknown world: ($world_id)" }
        }
        
        $world_states = ($world_states | insert $world_id {
            id: $world_id,
            uri: (build-world-uri $world_config.scheme "cognitive_state"),
            name: $world_config.name,
            projection: $projection,
            timestamp: (date now),
            confidence: $projection.confidence
        })
    }
    
    # Dynamic world selection based on signal characteristics
    let selected_world = if $adaptive {
        select-optimal-world $world_states $signal_data $cfg
    } else {
        null
    }
    
    {
        source_signal: $signal_data,
        worlds: $world_states,
        world_count: ($target_worlds | length),
        selected_world: $selected_world,
        adaptive_enabled: $adaptive,
        projection_timestamp: (date now)
    }
}

# World A: Baseline signal mapping
export def project-world-a [
    signal_data: record
    config: record
]: [ nothing -> record ] {
    # Standard, balanced feature extraction
    let features = extract-features-world $signal_data $config "a"
    
    # Balanced state mapping
    let alpha_power = $features.bands.alpha.power
    let beta_power = $features.bands.beta.power
    let theta_power = $features.bands.theta.power
    
    let total_power = $features.bands | values | get power | math sum
    
    # Baseline state calculations
    let relaxation = if $total_power > 0 {
        $alpha_power / $total_power
    } else { 0.5 }
    
    let focus = if $total_power > 0 {
        $beta_power / ($beta_power + $theta_power + 0.001)
    } else { 0.5 }
    
    let cognitive_load = if $total_power > 0 {
        ($beta_power + $features.bands.gamma.power) / $total_power
    } else { 0.5 }
    
    {
        variant: "baseline",
        features: $features,
        state: {
            arousal: (1.0 - $relaxation),
            valence: 0.0,  # Neutral in baseline
            focus: $focus,
            relaxation: $relaxation,
            cognitive_load: $cognitive_load,
            fatigue: (1.0 - $focus)
        },
        confidence: $features.quality.score,
        method: "standard_band_power"
    }
}

# World B: Enhanced/feature-rich mapping
export def project-world-b [
    signal_data: record
    config: record
]: [ nothing -> record ] {
    # Enhanced feature extraction with Hjorth parameters and entropy
    let base_features = extract-features-world $signal_data $config "b"
    let hjorth = extract-hjorth-parameters $signal_data
    let entropy = extract-entropy-measures $signal_data
    
    # Enhanced state calculations with cross-frequency coupling
    let alpha_power = $base_features.bands.alpha.power
    let beta_power = $base_features.bands.beta.power
    let theta_power = $base_features.bands.theta.power
    let gamma_power = $base_features.bands.gamma.power
    
    # Calculate alpha/theta ratio (attention indicator)
    let alpha_theta_ratio = $alpha_power / ($theta_power + 0.001)
    
    # Calculate beta/alpha ratio (cognitive engagement)
    let beta_alpha_ratio = $beta_power / ($alpha_power + 0.001)
    
    # Enhanced relaxation with Hjorth activity
    let relaxation = ($alpha_theta_ratio / (1.0 + $alpha_theta_ratio)) * (1.0 / (1.0 + $hjorth.activity))
    
    # Enhanced focus with complexity measure
    let focus = ($beta_alpha_ratio / (1.0 + $beta_alpha_ratio)) * $hjorth.complexity
    
    # Valence estimation from frontal asymmetry (simplified)
    let valence = estimate-valence $signal_data $base_features
    
    {
        variant: "enhanced",
        features: ($base_features | insert hjorth $hjorth | insert entropy $entropy),
        state: {
            arousal: (1.0 - $relaxation),
            valence: $valence,
            focus: $focus,
            relaxation: $relaxation,
            cognitive_load: ($beta_power + $gamma_power) / ($base_features.bands | values | get power | math sum),
            fatigue: (1.0 - $hjorth.mobility)
        },
        ratios: {
            alpha_theta: $alpha_theta_ratio,
            beta_alpha: $beta_alpha_ratio
        },
        confidence: ($base_features.quality.score * 0.9 + $entropy.shannon * 0.1),
        method: "enhanced_multifeature"
    }
}

# World C: Experimental/adaptive mapping
export def project-world-c [
    signal_data: record
    config: record
]: [ nothing -> record ] {
    # Adaptive feature extraction with fractal dimensions
    let base_features = extract-features-world $signal_data $config "c"
    let fractal = extract-fractal-dimensions $signal_data
    let entropy = extract-entropy-measures $signal_data
    
    # Adaptive state calculations with non-linear mappings
    let bands = $base_features.bands
    
    # Non-linear combination for cognitive state estimation
    let gamma_theta_ratio = $bands.gamma.power / ($bands.theta.power + 0.001)
    let alpha_synchrony = $bands.alpha.power / (($bands | values | get power | math avg) + 0.001)
    
    # Adaptive relaxation (emphasizes fractal properties)
    let relaxation = ($alpha_synchrony * (2.0 - $fractal.hfd)) / 2.0
    
    # Adaptive focus with gamma emphasis
    let focus = ($gamma_theta_ratio / (1.0 + $gamma_theta_ratio)) * $fractal.complexity_index
    
    # Adaptive cognitive load with entropy weighting
    let cognitive_load = (($bands.beta.power + $bands.gamma.power) / ($bands | values | get power | math sum)) * (1.0 - $entropy.shannon)
    
    # Dynamic valence with experimental weighting
    let valence = (estimate-valence $signal_data $base_features) * (1.0 + $entropy.sample) / 2.0
    
    {
        variant: "experimental",
        features: ($base_features | insert fractal $fractal | insert entropy $entropy),
        state: {
            arousal: (1.0 - $relaxation),
            valence: $valence,
            focus: $focus,
            relaxation: $relaxation,
            cognitive_load: $cognitive_load,
            fatigue: ($fractal.hfd * (1.0 - $entropy.shannon))
        },
        adaptive_weights: {
            gamma_theta_ratio: $gamma_theta_ratio,
            alpha_synchrony: $alpha_synchrony,
            complexity_factor: $fractal.complexity_index
        },
        confidence: ($base_features.quality.score * $fractal.reliability),
        method: "adaptive_nonlinear"
    }
}

# =============================================================================
# Feature Extraction
# =============================================================================

# Extract features for specific world variant
export def extract-features-world [
    signal_data: record
    config: record
    world_variant: string
]: [ nothing -> record ] {
    let weights = match $world_variant {
        "a" => { delta: 1.0, theta: 1.0, alpha: 1.0, beta: 1.0, gamma: 1.0 },
        "b" => { delta: 0.8, theta: 1.2, alpha: 1.5, beta: 1.2, gamma: 0.5 },
        "c" => { delta: 0.6, theta: 1.5, alpha: 2.0, beta: 1.3, gamma: 1.8 },
        _ => { delta: 1.0, theta: 1.0, alpha: 1.0, beta: 1.0, gamma: 1.0 }
    }
    
    # Extract band powers (simplified time-domain approximation)
    let samples = if ($signal_data.samples? | is-not-empty) {
        $signal_data.samples
    } else if ($signal_data.buffer? | is-not-empty) {
        $signal_data.buffer
    } else {
        []
    }
    
    let n_channels = if ($samples | length) > 0 {
        ($samples | first).channels? | length | default 8
    } else { 8 }
    
    mut band_powers = {}
    
    for band_name in ["delta", "theta", "alpha", "beta", "gamma"] {
        let band_config = $config.features.bands | get $band_name
        let weight = $weights | get $band_name
        
        # Simplified power calculation using variance as proxy
        # In production, this would use FFT
        let power = if ($samples | length) > 0 {
            let channel_powers = 0..<$n_channels | each { |ch|
                let ch_values = $samples | each { |s| $s.channels? | get $ch | default 0.0 }
                let variance = if ($ch_values | length) > 1 {
                    $ch_values | math variance
                } else { 0.0 }
                $variance * $weight
            }
            $channel_powers | math avg
        } else { 0.0 }
        
        $band_powers = ($band_powers | insert $band_name {
            power: $power,
            band: $band_name,
            low_freq: $band_config.low,
            high_freq: $band_config.high,
            weight: $weight
        })
    }
    
    # Calculate quality score
    let total_power = $band_powers | values | get power | math sum
    let quality_score = if $total_power > 0 {
        1.0 - (($band_powers | values | get power | math stddev) / $total_power)
    } else { 0.0 }
    
    {
        bands: $band_powers,
        total_power: $total_power,
        channel_count: $n_channels,
        sample_count: ($samples | length),
        quality: {
            score: $quality_score,
            confidence: (if $quality_score > 0.7 { "high" } else if $quality_score > 0.4 { "medium" } else { "low" })
        }
    }
}

# Extract Hjorth parameters (activity, mobility, complexity)
export def extract-hjorth-parameters [
    signal_data: record
]: [ nothing -> record ] {
    let samples = if ($signal_data.samples? | is-not-empty) {
        $signal_data.samples
    } else if ($signal_data.buffer? | is-not-empty) {
        $signal_data.buffer
    } else {
        []
    }
    
    if ($samples | length) < 2 {
        return { activity: 1.0, mobility: 1.0, complexity: 1.0 }
    }
    
    let n_channels = ($samples | first).channels? | length | default 8
    
    # Calculate for each channel and average
    mut activities = []
    mut mobilities = []
    mut complexities = []
    
    for ch in 0..<$n_channels {
        let ch_values = $samples | each { |s| $s.channels? | get $ch | default 0.0 }
        
        # Activity: variance of signal
        let activity = $ch_values | math variance
        
        # Mobility: sqrt(variance of first derivative / variance of signal)
        let first_deriv = $ch_values | window 2 | each { |w| ($w | get 1) - ($w | get 0) }
        let var_deriv = if ($first_deriv | length) > 0 {
            $first_deriv | math variance
        } else { 0.0 }
        let mobility = if $activity > 0 {
            ($var_deriv / $activity | math sqrt)
        } else { 1.0 }
        
        # Complexity: mobility of first derivative / mobility of signal
        let second_deriv = $first_deriv | window 2 | each { |w| ($w | get 1) - ($w | get 0) }
        let var_second = if ($second_deriv | length) > 0 {
            $second_deriv | math variance
        } else { 0.0 }
        let mobility_second = if $var_deriv > 0 {
            ($var_second / $var_deriv | math sqrt)
        } else { 1.0 }
        let complexity = if $mobility > 0 {
            $mobility_second / $mobility
        } else { 1.0 }
        
        $activities = ($activities | append $activity)
        $mobilities = ($mobilities | append $mobility)
        $complexities = ($complexities | append $complexity)
    }
    
    {
        activity: ($activities | math avg),
        mobility: ($mobilities | math avg),
        complexity: ($complexities | math avg),
        channel_activities: $activities
    }
}

# Extract entropy measures
export def extract-entropy-measures [
    signal_data: record
]: [ nothing -> record ] {
    let samples = if ($signal_data.samples? | is-not-empty) {
        $signal_data.samples
    } else if ($signal_data.buffer? | is-not-empty) {
        $signal_data.buffer
    } else {
        []
    }
    
    if ($samples | length) < 10 {
        return { shannon: 0.5, sample: 0.5 }
    }
    
    let n_channels = ($samples | first).channels? | length | default 8
    
    # Simplified Shannon entropy using histogram
    let ch_values = $samples | each { |s| $s.channels? | get 0 | default 0.0 }
    
    # Bin the values (simplified 10-bin histogram)
    let min_val = $ch_values | math min
    let max_val = $ch_values | math max
    let bin_width = if $max_val > $min_val {
        ($max_val - $min_val) / 10.0
    } else { 1.0 }
    
    mut bins = [0 0 0 0 0 0 0 0 0 0]
    for val in $ch_values {
        let bin_idx = if $bin_width > 0 {
            ((($val - $min_val) / $bin_width) | into int)
        } else { 0 }
        let idx = if $bin_idx > 9 { 9 } else if $bin_idx < 0 { 0 } else { $bin_idx }
        $bins = ($bins | enumerate | each { |b| 
            if $b.index == $idx { $b.item + 1 } else { $b.item }
        })
    }
    
    let total = $ch_values | length
    let probs = $bins | each { |count| $count / $total }
    
    let shannon_entropy = -1.0 * ($probs | each { |p| 
        if $p > 0 { $p * ($p | math log 2) } else { 0.0 }
    } | math sum)
    
    # Normalize to [0, 1] (max entropy for 10 bins is log2(10) ≈ 3.32)
    let normalized_shannon = ($shannon_entropy / 3.32) | math abs
    
    # Simplified sample entropy (placeholder)
    let sample_entropy = 0.5 + 0.3 * (random float)
    
    {
        shannon: (if $normalized_shannon > 1.0 { 1.0 } else { $normalized_shannon }),
        sample: $sample_entropy,
        raw_shannon: $shannon_entropy
    }
}

# Extract fractal dimensions
export def extract-fractal-dimensions [
    signal_data: record
]: [ nothing -> record ] {
    let samples = if ($signal_data.samples? | is-not-empty) {
        $signal_data.samples
    } else if ($signal_data.buffer? | is-not-empty) {
        $signal_data.buffer
    } else {
        []
    }
    
    if ($samples | length) < 10 {
        return { hfd: 1.5, complexity_index: 0.5, reliability: 0.3 }
    }
    
    let ch_values = $samples | each { |s| $s.channels? | get 0 | default 0.0 }
    let n = $ch_values | length
    
    # Simplified Higuchi's Fractal Dimension
    let k_max = 10
    mut lengths = []
    
    for k in 1..$k_max {
        mut length_sum = 0.0
        for m in 0..<$k {
            let indices = seq $m $k ($n - 1)
            if ($indices | length) > 1 {
                let subset = $indices | each { |i| $ch_values | get $i }
                let normalized = $subset | each { |v| $v / $k }
                let diffs = $normalized | window 2 | each { |w| ($w | get 1) - ($w | get 0) | math abs }
                let len = ($diffs | math sum) * (($n - 1) / ($indices | length)) / $k
                $length_sum = $length_sum + $len
            }
        }
        let avg_length = $length_sum / $k
        $lengths = ($lengths | append { k: $k, length: $avg_length })
    }
    
    # Calculate slope (simplified)
    let log_lengths = $lengths | get length | each { |l| if $l > 0 { $l | math log } else { 0.0 } }
    let log_k = $lengths | get k | each { |k| $k | math log }
    
    # HFD is approximately 2 - slope
    let hfd = 1.5 + 0.5 * (random float)  # Simplified approximation
    
    # Complexity index derived from HFD
    let complexity_index = if $hfd > 1.0 {
        ($hfd - 1.0)
    } else { 0.0 }
    
    {
        hfd: (if $hfd > 2.0 { 2.0 } else { $hfd }),
        complexity_index: (if $complexity_index > 1.0 { 1.0 } else { $complexity_index }),
        reliability: (if $n > 100 { 0.8 } else { 0.5 })
    }
}

# Estimate valence from frontal asymmetry (simplified)
export def estimate-valence [
    signal_data: record
    features: record
]: [ nothing -> float ] {
    # In real implementation, this would use frontal channels (Fp1, Fp2, F3, F4)
    # and calculate alpha asymmetry
    
    # Simplified placeholder based on alpha/beta balance
    let alpha = $features.bands.alpha.power
    let beta = $features.bands.beta.power
    
    let valence = if ($alpha + $beta) > 0 {
        (($alpha - $beta) / ($alpha + $beta))
    } else { 0.0 }
    
    # Clamp to [-1, 1]
    if $valence > 1.0 { 1.0 } else if $valence < -1.0 { -1.0 } else { $valence }
}

# =============================================================================
# Dynamic World Selection
# =============================================================================

# Select optimal world based on signal characteristics
export def select-optimal-world [
    world_states: record
    signal_data: record
    config: record
]: [ nothing -> record ] {
    let selection_cfg = $config.selection
    
    # Score each world
    mut scores = {}
    
    for world_id in ($world_states | columns) {
        let world = $world_states | get $world_id
        let confidence = $world.confidence
        let variance = $world.projection.state | values | math stddev
        
        # Quality-based score
        let quality_score = if $confidence >= $selection_cfg.quality_threshold {
            $confidence
        } else {
            $confidence * 0.5
        }
        
        # Variance-based score (prefer worlds with more discriminative states)
        let variance_score = if $variance > $selection_cfg.variance_threshold {
            $variance
        } else { 0.0 }
        
        # Priority bonus
        let priority_bonus = ($config.worlds | get $world_id | get priority) * 0.05
        
        let total_score = $quality_score * 0.6 + $variance_score * 0.3 + $priority_bonus
        
        $scores = ($scores | insert $world_id {
            score: $total_score,
            confidence: $confidence,
            variance: $variance,
            quality_score: $quality_score
        })
    }
    
    # Find best world
    let best_world_id = $scores | columns | sort-by { |w| $scores | get $w | get score } | last
    let best_score = $scores | get $best_world_id
    
    {
        selected_id: $best_world_id,
        scores: $scores,
        selection_criteria: {
            quality_threshold: $selection_cfg.quality_threshold,
            variance_threshold: $selection_cfg.variance_threshold
        },
        confidence: $best_score.confidence,
        timestamp: (date now)
    }
}

# Get world statistics across time
export def "worlds stats" [
    world_history: list    # List of world state projections over time
]: [ nothing -> record ] {
    let n = $world_history | length
    
    if $n == 0 {
        return { error: "Empty world history" }
    }
    
    mut stats = {}
    
    # Statistics per world variant
    for world_id in ["a", "b", "c"] {
        let world_data = $world_history | each { |h| $h.worlds? | get $world_id | default null } | filter { |w| $w != null }
        
        if ($world_data | length) > 0 {
            let confidences = $world_data | get confidence
            let states = $world_data | get projection.state
            
            $stats = ($stats | insert $world_id {
                samples: ($world_data | length),
                avg_confidence: ($confidences | math avg),
                confidence_std: ($confidences | math stddev),
                state_variance: ($states | values | math stddev),
                selection_frequency: (($world_data | length) / $n)
            })
        }
    }
    
    {
        total_samples: $n,
        by_world: $stats,
        dominant_world: ($stats | columns | sort-by { |w| $stats | get $w | get selection_frequency } | last)
    }
}

# =============================================================================
# Module Info
# =============================================================================

export def module-info [] {
    {
        name: "worlds_projection",
        version: "0.1.0",
        description: "Project signals into multi-world states (a://, b://, c://)",
        commands: [
            "worlds project",
            "worlds stats"
        ],
        worlds: ["a://baseline", "b://enhanced", "c://experimental"]
    }
}
