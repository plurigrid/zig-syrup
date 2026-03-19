# signal_worlds_bridge.nu
# Bridge between signal and world domains
# Bidirectional mapping: Signal features ↔ World parameters

use std log
use ../eeg_types.nu *
use ./signal_input.nu [SignalConfig]
use ./worlds_projection.nu [WorldProjectionConfig]

# =============================================================================
# Bridge Configuration
# =============================================================================

export def BridgeConfig [] {
    {
        # Sample rates
        signal_rate_hz: 250,      # OpenBCI sample rate
        world_update_rate_hz: 30,  # World state update rate
        
        # Feature extraction settings
        features: {
            bands: {
                enabled: true,
                names: ["delta", "theta", "alpha", "beta", "gamma"],
                window_sec: 1.0
            },
            hjorth: {
                enabled: true,
                window_sec: 2.0
            },
            entropy: {
                enabled: true,
                window_sec: 2.0,
                types: ["shannon", "sample"]
            },
            fractal: {
                enabled: false,
                window_sec: 4.0,
                types: ["hfd"]
            }
        },
        
        # World state encoding
        encoding: {
            state_vars: ["arousal", "valence", "focus", "relaxation", "cognitive_load", "fatigue"],
            normalization: "minmax",    # minmax, zscore, softmax
            quantization_bits: 8        # For compact encoding
        },
        
        # Synchronization settings
        sync: {
            buffer_ms: 100,             # Buffer time for synchronization
            max_latency_ms: 50,         # Maximum acceptable latency
            interpolation: "linear"     # linear, cubic, nearest
        },
        
        # Bidirectional mapping weights
        mapping_weights: {
            # Signal features → World states
            forward: {
                alpha_power: { relaxation: 0.6, focus: -0.2 },
                beta_power: { focus: 0.5, cognitive_load: 0.4 },
                theta_power: { fatigue: 0.4, cognitive_load: -0.1 },
                alpha_beta_ratio: { relaxation: 0.4 },
                beta_alpha_ratio: { focus: 0.3, cognitive_load: 0.2 },
                hjorth_activity: { arousal: 0.3 },
                hjorth_mobility: { fatigue: -0.3 },
                hjorth_complexity: { cognitive_load: 0.2 }
            },
            # World states → Signal features (for synthesis/prediction)
            reverse: {
                relaxation: { alpha_power: 0.5, theta_power: 0.2 },
                focus: { beta_power: 0.4, alpha_power: -0.2 },
                arousal: { beta_power: 0.3, gamma_power: 0.2 },
                cognitive_load: { beta_power: 0.3, theta_power: -0.1 },
                fatigue: { theta_power: 0.3, beta_power: -0.2 }
            }
        }
    }
}

# Bridge state
export def BridgeState [] {
    {
        config: (BridgeConfig),
        signal_buffer: [],
        feature_buffer: [],
        world_buffer: [],
        last_sync: null,
        signal_sample_count: 0,
        world_update_count: 0,
        dropped_samples: 0,
        latency_ms: 0.0
    }
}

# =============================================================================
# Signal to World Mapping (Forward)
# =============================================================================

# Map signal features to world parameters
export def "bridge signal-to-world" [
    signal_data: record      # Signal data with features
    --method: string = "weighted"  # Mapping method: weighted, neural, lookup
]: [ nothing -> record ] {
    let cfg = (BridgeConfig)
    let features = extract-signal-features $signal_data $cfg
    
    log info $"Mapping signal features to world state using method: ($method)"
    
    let mapping = match $method {
        "weighted" => (map-weighted-forward $features $cfg.mapping_weights.forward),
        "lookup" => (map-lookup-forward $features $cfg),
        _ => (map-weighted-forward $features $cfg.mapping_weights.forward)
    }
    
    # Normalize to valid ranges
    let world_state = normalize-world-state $mapping $cfg
    
    {
        direction: "signal-to-world",
        method: $method,
        source_features: $features,
        world_state: $world_state,
        confidence: (calculate-mapping-confidence $features),
        timestamp: (date now)
    }
}

# Extract comprehensive signal features
export def extract-signal-features [
    signal_data: record
    cfg: record
]: [ nothing -> record ] {
    let samples = if ($signal_data.samples? | is-not-empty) {
        $signal_data.samples
    } else if ($signal_data.buffer? | is-not-empty) {
        $signal_data.buffer
    } else {
        []
    }
    
    if ($samples | length) == 0 {
        return { error: "No samples available" }
    }
    
    let n_channels = ($samples | first).channels? | length | default 8
    
    # Calculate band powers (simplified)
    mut band_powers = {}
    let sample_rate = 250
    let window_samples = ($cfg.features.bands.window_sec * $sample_rate | into int)
    
    for band in $cfg.features.bands.names {
        let powers = 0..<$n_channels | each { |ch|
            let ch_values = $samples | last $window_samples | each { |s| $s.channels? | get $ch | default 0.0 }
            $ch_values | math variance
        }
        let avg_power = $powers | math avg
        $band_powers = ($band_powers | insert $band {
            power: $avg_power,
            relative: 0.0  # Will be calculated after all bands
        })
    }
    
    # Calculate relative powers
    let total_power = $band_powers | values | get power | math sum
    if $total_power > 0 {
        for band in $cfg.features.bands.names {
            let abs_power = $band_powers | get $band | get power
            let rel_power = $abs_power / $total_power
            $band_powers = ($band_powers | upsert $band {power: $abs_power, relative: $rel_power})
        }
    }
    
    # Calculate ratios
    let alpha_power = $band_powers.alpha?.power? | default 0.001
    let beta_power = $band_powers.beta?.power? | default 0.001
    let theta_power = $band_powers.theta?.power? | default 0.001
    
    # Hjorth parameters
    let hjorth = if $cfg.features.hjorth.enabled {
        calculate-hjorth-bridged $samples $n_channels
    } else {
        { activity: 1.0, mobility: 1.0, complexity: 1.0 }
    }
    
    # Entropy
    let entropy = if $cfg.features.entropy.enabled {
        calculate-entropy-bridged $samples
    } else {
        { shannon: 0.5, sample: 0.5 }
    }
    
    {
        bands: $band_powers,
        total_power: $total_power,
        ratios: {
            alpha_theta: ($alpha_power / $theta_power),
            alpha_beta: ($alpha_power / $beta_power),
            beta_alpha: ($beta_power / $alpha_power),
            theta_beta: ($theta_power / $beta_power)
        },
        hjorth: $hjorth,
        entropy: $entropy,
        sample_count: ($samples | length),
        channel_count: $n_channels
    }
}

# Weighted forward mapping
export def map-weighted-forward [
    features: record
    weights: record
]: [ nothing -> record ] {
    let weight_keys = $weights | columns
    let state_vars = ["arousal", "valence", "focus", "relaxation", "cognitive_load", "fatigue"]
    
    mut state = {}
    for var in $state_vars {
        $state = ($state | insert $var 0.5)  # Initialize to neutral
    }
    
    # Apply weighted contributions
    for feature_key in $weight_keys {
        let feature_weights = $weights | get $feature_key
        let feature_value = get-feature-value $features $feature_key
        
        for state_var in ($feature_weights | columns) {
            let weight = $feature_weights | get $state_var
            let contribution = $feature_value * $weight
            let current = $state | get $state_var
            $state = ($state | upsert $state_var ($current + $contribution))
        }
    }
    
    $state
}

# Lookup table forward mapping (simplified)
export def map-lookup-forward [
    features: record
    cfg: record
]: [ nothing -> record ] {
    # Simplified lookup based on dominant band
    let bands = $features.bands
    let max_band = $bands | columns | sort-by { |b| $bands | get $b | get power | default 0 } | last
    
    match $max_band {
        "delta" => { arousal: 0.2, valence: 0.0, focus: 0.1, relaxation: 0.8, cognitive_load: 0.1, fatigue: 0.7 },
        "theta" => { arousal: 0.3, valence: 0.1, focus: 0.3, relaxation: 0.6, cognitive_load: 0.3, fatigue: 0.5 },
        "alpha" => { arousal: 0.3, valence: 0.0, focus: 0.5, relaxation: 0.8, cognitive_load: 0.2, fatigue: 0.2 },
        "beta" => { arousal: 0.7, valence: 0.1, focus: 0.8, relaxation: 0.2, cognitive_load: 0.7, fatigue: 0.3 },
        "gamma" => { arousal: 0.9, valence: 0.2, focus: 0.9, relaxation: 0.1, cognitive_load: 0.9, fatigue: 0.4 },
        _ => { arousal: 0.5, valence: 0.0, focus: 0.5, relaxation: 0.5, cognitive_load: 0.5, fatigue: 0.5 }
    }
}

# Get feature value by key
export def get-feature-value [
    features: record
    key: string
]: [ nothing -> float ] {
    match $key {
        "alpha_power" => ($features.bands.alpha?.power? | default 0) / (($features.total_power | default 1) + 0.001),
        "beta_power" => ($features.bands.beta?.power? | default 0) / (($features.total_power | default 1) + 0.001),
        "theta_power" => ($features.bands.theta?.power? | default 0) / (($features.total_power | default 1) + 0.001),
        "alpha_beta_ratio" => $features.ratios.alpha_beta? | default 1.0,
        "beta_alpha_ratio" => $features.ratios.beta_alpha? | default 1.0,
        "hjorth_activity" => $features.hjorth.activity? | default 1.0,
        "hjorth_mobility" => $features.hjorth.mobility? | default 1.0,
        "hjorth_complexity" => $features.hjorth.complexity? | default 1.0,
        _ => 0.5
    }
}

# =============================================================================
# World to Signal Mapping (Reverse)
# =============================================================================

# Encode world state into signal space
export def "bridge world-to-signal" [
    world_state: record      # World state to encode
    --method: string = "weighted"  # Encoding method
]: [ nothing -> record ] {
    let cfg = (BridgeConfig)
    
    log info $"Encoding world state to signal features using method: ($method)"
    
    let encoded_features = match $method {
        "weighted" => (map-weighted-reverse $world_state $cfg.mapping_weights.reverse),
        "generative" => (map-generative-reverse $world_state $cfg),
        _ => (map-weighted-reverse $world_state $cfg.mapping_weights.reverse)
    }
    
    {
        direction: "world-to-signal",
        method: $method,
        source_state: $world_state,
        encoded_features: $encoded_features,
        reconstructable: true,
        timestamp: (date now)
    }
}

# Weighted reverse mapping
export def map-weighted-reverse [
    world_state: record
    weights: record
]: [ nothing -> record ] {
    let state_vars = $world_state | columns
    
    mut features = {
        alpha_power: 0.1,
        beta_power: 0.1,
        theta_power: 0.1,
        gamma_power: 0.05
    }
    
    for state_var in $state_vars {
        let state_value = $world_state | get $state_var
        let var_weights = $weights | get $state_var | default {}
        
        for feature in ($var_weights | columns) {
            let weight = $var_weights | get $feature
            let contribution = $state_value * $weight
            let current = $features | get $feature | default 0.1
            $features = ($features | upsert $feature ($current + $contribution))
        }
    }
    
    # Normalize
    let total = $features | values | math sum
    if $total > 0 {
        $features | columns | each { |k| 
            let v = $features | get $k
            {key: $k, val: ($v / $total)}
        } | reduce -f {} { |i, acc| $acc | insert $i.key $i.val }
    } else {
        $features
    }
}

# Generative reverse mapping (placeholder for ML-based synthesis)
export def map-generative-reverse [
    world_state: record
    cfg: record
]: [ nothing -> record ] {
    # Placeholder for generative model
    # In a full implementation, this would use a trained neural network
    # to generate realistic EEG features from world states
    
    let base = map-weighted-reverse $world_state $cfg.mapping_weights.reverse
    
    # Add some "creative" variation
    $base | columns | each { |k| 
        let v = $base | get $k
        let noise = (random float -0.05..0.05)
        {key: $k, val: (if ($v + $noise) > 0 { $v + $noise } else { 0.01 })}
    } | reduce -f {} { |i, acc| $acc | insert $i.key $i.val }
}

# =============================================================================
# Feature Extraction Helpers
# =============================================================================

# Calculate Hjorth parameters for bridge
export def calculate-hjorth-bridged [
    samples: list
    n_channels: int
]: [ nothing -> record ] {
    # Use first channel for simplicity
    let ch_values = $samples | each { |s| $s.channels? | get 0 | default 0.0 }
    
    let activity = $ch_values | math variance
    
    # First derivative
    let deriv1 = $ch_values | window 2 | each { |w| ($w | get 1) - ($w | get 0) }
    let var1 = if ($deriv1 | length) > 0 {
        $deriv1 | math variance
    } else { 0.0 }
    
    let mobility = if $activity > 0 {
        ($var1 / $activity | math sqrt)
    } else { 1.0 }
    
    # Second derivative
    let deriv2 = $deriv1 | window 2 | each { |w| ($w | get 1) - ($w | get 0) }
    let var2 = if ($deriv2 | length) > 0 {
        $deriv2 | math variance
    } else { 0.0 }
    
    let mobility2 = if $var1 > 0 {
        ($var2 / $var1 | math sqrt)
    } else { 1.0 }
    
    let complexity = if $mobility > 0 {
        $mobility2 / $mobility
    } else { 1.0 }
    
    {
        activity: (if $activity > 0 { $activity } else { 1.0 }),
        mobility: (if $mobility > 0 { $mobility } else { 1.0 }),
        complexity: (if $complexity > 0 { $complexity } else { 1.0 })
    }
}

# Calculate entropy for bridge
export def calculate-entropy-bridged [
    samples: list
]: [ nothing -> record ] {
    let ch_values = $samples | each { |s| $s.channels? | get 0 | default 0.0 }
    
    # Simple binning for Shannon entropy
    let min_val = $ch_values | math min
    let max_val = $ch_values | math max
    let range = $max_val - $min_val
    
    mut bins = [0 0 0 0 0 0 0 0]
    
    for val in $ch_values {
        let idx = if $range > 0 {
            let normalized = (($val - $min_val) / $range * 7) | into int
            if $normalized > 7 { 7 } else if $normalized < 0 { 0 } else { $normalized }
        } else { 0 }
        
        $bins = ($bins | enumerate | each { |b| 
            if $b.index == $idx { $b.item + 1 } else { $b.item }
        })
    }
    
    let total = $ch_values | length
    let probs = $bins | each { |c| if $total > 0 { $c / $total } else { 0.125 } }
    
    let shannon = -1.0 * ($probs | each { |p| 
        if $p > 0 { $p * ($p | math log 2) } else { 0.0 }
    } | math sum) | math abs
    
    # Normalize (max for 8 bins is log2(8) = 3)
    let normalized = $shannon / 3.0
    
    {
        shannon: (if $normalized > 1.0 { 1.0 } else { $normalized }),
        sample: 0.5  # Placeholder for sample entropy
    }
}

# =============================================================================
# Normalization and Utilities
# =============================================================================

# Normalize world state to valid ranges
export def normalize-world-state [
    state: record
    cfg: record
]: [ nothing -> record ] {
    let ranges = $cfg.encoding.state_vars
    
    mut normalized = {}
    for var in $ranges {
        let raw = $state | get $var | default 0.5
        # Clamp to [0, 1] for most variables, [-1, 1] for valence
        let clamped = if $var == "valence" {
            if $raw > 1.0 { 1.0 } else if $raw < -1.0 { -1.0 } else { $raw }
        } else {
            if $raw > 1.0 { 1.0 } else if $raw < 0.0 { 0.0 } else { $raw }
        }
        $normalized = ($normalized | insert $var $clamped)
    }
    
    $normalized
}

# Calculate mapping confidence
export def calculate-mapping-confidence [
    features: record
]: [ nothing -> float ] {
    # Confidence based on signal quality and feature richness
    let has_bands = ($features.bands? | is-not-empty)
    let has_hjorth = ($features.hjorth? | is-not-empty)
    let sample_count = $features.sample_count? | default 0
    
    let sample_confidence = if $sample_count > 250 {
        1.0
    } else if $sample_count > 100 {
        $sample_count / 250.0
    } else {
        0.3
    }
    
    let feature_confidence = if $has_bands and $has_hjorth {
        1.0
    } else if $has_bands {
        0.7
    } else {
        0.4
    }
    
    ($sample_confidence + $feature_confidence) / 2.0
}

# =============================================================================
# Synchronization
# =============================================================================

# Synchronize signal rate (250Hz) with world updates (30Hz)
export def "bridge sync" [
    signal_stream: list       # High-rate signal stream
    --downsample-to: int = 30 # Target rate in Hz
]: [ list -> list ] {
    let cfg = (BridgeConfig)
    let signal_rate = $cfg.signal_rate_hz
    let target_rate = $downsample_to
    
    let factor = ($signal_rate / $target_rate | into int)
    
    log info $"Synchronizing signal stream: ($signal_rate)Hz → ($target_rate)Hz (factor: $factor)"
    
    if $factor <= 1 {
        return $signal_stream
    }
    
    # Downsample by factor
    mut result = []
    mut i = 0
    while $i < ($signal_stream | length) {
        $result = ($result | append ($signal_stream | get $i))
        $i = $i + $factor
    }
    
    {
        original_rate: $signal_rate,
        target_rate: $target_rate,
        downsample_factor: $factor,
        original_samples: ($signal_stream | length),
        synced_samples: ($result | length),
        samples: $result
    }
}

# Interpolate world states to signal rate
export def "bridge interpolate" [
    world_states: list        # Low-rate world states
    --upsample-to: int = 250  # Target rate in Hz
    --method: string = "linear"  # linear, cubic
]: [ list -> list ] {
    let cfg = (BridgeConfig)
    let world_rate = $cfg.world_update_rate_hz
    let target_rate = $upsample_to
    
    let factor = ($target_rate / $world_rate | into int)
    
    log info $"Interpolating world states: ($world_rate)Hz → ($target_rate)Hz (factor: $factor)"
    
    if ($world_states | length) < 2 or $factor <= 1 {
        return $world_states
    }
    
    mut result = []
    
    for i in 0..<(($world_states | length) - 1) {
        let current = $world_states | get $i
        let next = $world_states | get ($i + 1)
        
        # Add current state
        $result = ($result | append $current)
        
        # Interpolate intermediate states
        for j in 1..<$factor {
            let t = ($j | into float) / ($factor | into float)
            let interpolated = interpolate-states $current $next $t $method
            $result = ($result | append $interpolated)
        }
    }
    
    # Add last state
    $result = ($result | append ($world_states | last))
    
    {
        original_rate: $world_rate,
        target_rate: $target_rate,
        upsample_factor: $factor,
        original_states: ($world_states | length),
        interpolated_states: ($result | length),
        states: $result
    }
}

# Interpolate between two world states
export def interpolate-states [
    state_a: record
    state_b: record
    t: float                  # Interpolation factor [0, 1]
    method: string
]: [ nothing -> record ] {
    let vars = $state_a | columns
    
    mut result = {}
    for var in $vars {
        let a = $state_a | get $var | default 0.0
        let b = $state_b | get $var | default 0.0
        
        let val = match $method {
            "linear" => { $a + $t * ($b - $a) },
            "cubic" => { 
                # Smooth step interpolation
                let t2 = $t * $t
                let t3 = $t2 * $t
                $a + ($b - $a) * (3.0 * $t2 - 2.0 * $t3)
            },
            _ => { $a + $t * ($b - $a) }
        }
        
        $result = ($result | insert $var $val)
    }
    
    $result | insert interpolated true | insert t $t
}

# =============================================================================
# Bidirectional Pipeline
# =============================================================================

# Run complete bidirectional bridge pipeline
export def "bridge pipeline" [
    input: record             # Input data (signal or world state)
    --direction: string       # "forward" (signal→world) or "reverse" (world→signal)
]: [ nothing -> record ] {
    log info $"Running bidirectional bridge pipeline: direction=($direction)"
    
    let result = match $direction {
        "forward" => {
            let world_mapping = (bridge signal-to-world $input)
            {
                input_type: "signal",
                output_type: "world",
                mapping: $world_mapping,
                synchronized: (bridge sync $input.samples?)
            }
        },
        "reverse" => {
            let signal_encoding = (bridge world-to-signal $input)
            {
                input_type: "world",
                output_type: "signal",
                encoding: $signal_encoding,
                interpolated: null  # Would interpolate if we had a time series
            }
        },
        _ => { error: $"Unknown direction: ($direction)" }
    }
    
    $result | insert timestamp (date now)
}

# =============================================================================
# Module Info
# =============================================================================

export def module-info [] {
    {
        name: "signal_worlds_bridge",
        version: "0.1.0",
        description: "Bidirectional bridge between signal and world domains",
        commands: [
            "bridge signal-to-world",
            "bridge world-to-signal",
            "bridge sync",
            "bridge interpolate",
            "bridge pipeline"
        ],
        signal_rate_hz: 250,
        world_rate_hz: 30,
        features: ["bands", "hjorth", "entropy"]
    }
}
