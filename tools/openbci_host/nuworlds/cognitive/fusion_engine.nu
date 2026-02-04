# fusion_engine.nu
# Multi-world sensor fusion using multiple algorithms
# Implements Bayesian, Dempster-Shafer, Kalman, and Consensus fusion

use std log

# =============================================================================
# Fusion Engine Configuration
# =============================================================================

export def FusionConfig [] {
    {
        # Fusion method weights for ensemble
        weights: {
            bayesian: 0.25,
            dempster_shafer: 0.25,
            kalman: 0.25,
            consensus: 0.25
        },
        
        # Bayesian fusion parameters
        bayesian: {
            prior_type: "uniform",      # uniform, informed, adaptive
            update_rule: "sequential",  # sequential, batch
            confidence_threshold: 0.3
        },
        
        # Dempster-Shafer parameters
        dempster_shafer: {
            frame_of_discernment: ["arousal", "valence", "focus", "relaxation", "cognitive_load"],
            conflict_resolution: "yager",  # yager, murphy, discount
            mass_threshold: 0.1
        },
        
        # Kalman filter parameters
        kalman: {
            process_noise: 0.01,
            measurement_noise: 0.1,
            initial_uncertainty: 1.0,
            adaptive_q: true            # Adaptive process noise
        },
        
        # Consensus fusion parameters
        consensus: {
            convergence_threshold: 0.01,
            max_iterations: 100,
            weight_by_confidence: true
        },
        
        # Output configuration
        output: {
            include_individual: false,   # Include individual world estimates
            include_uncertainty: true,   # Include uncertainty bounds
            confidence_threshold: 0.5    # Minimum confidence for valid output
        }
    }
}

# Fusion engine state
export def FusionState [] {
    {
        config: (FusionConfig),
        kalman_state: null,          # Kalman filter state
        history: [],                 # Fusion history
        iteration: 0,
        last_fusion: null
    }
}

# =============================================================================
# Main Fusion Commands
# =============================================================================

# Bayesian fusion across world estimates
export def "fusion bayesian" [
    world_estimates: record     # World state estimates from multiple worlds
    --prior: record = null      # Prior distribution (null = uniform)
    --confidences: record = null # Confidence for each world
]: [ nothing -> record ] {
    let cfg = (FusionConfig).bayesian
    let worlds = $world_estimates.worlds? | default {}
    let world_ids = $worlds | columns
    
    log info $"Running Bayesian fusion with ($world_ids | length) worlds"
    
    if ($world_ids | length) == 0 {
        return { error: "No world estimates provided" }
    }
    
    # Initialize prior (uniform if not provided)
    let prior = if ($prior | is-not-empty) {
        $prior
    } else {
        let n = $world_ids | length
        $world_ids | each { |w| {world: $w, probability: (1.0 / $n)} } | reduce -f {} { |item, acc| $acc | insert $item.world $item.probability }
    }
    
    # Get likelihoods from world confidences
    let likelihoods = if ($confidences | is-not-empty) {
        $confidences
    } else {
        $world_ids | each { |w| {world: $w, confidence: ($worlds | get $w | get confidence | default 0.5)} } | reduce -f {} { |item, acc| $acc | insert $item.world $item.confidence }
    }
    
    # Calculate posterior (normalized product of prior and likelihood)
    let total_confidence = $likelihoods | values | math sum
    
    mut posterior = {}
    for w in $world_ids {
        let prior_prob = $prior | get $w | default (1.0 / ($world_ids | length))
        let likelihood = $likelihoods | get $w | default 0.5
        let posterior_prob = $prior_prob * $likelihood
        $posterior = ($posterior | insert $w $posterior_prob)
    }
    
    # Normalize posterior
    let posterior_sum = $posterior | values | math sum
    $posterior = ($posterior | columns | each { |w| 
        {world: $w, prob: (($posterior | get $w) / $posterior_sum)}
    } | reduce -f {} { |item, acc| $acc | insert $item.world $item.prob })
    
    # Weighted fusion of state estimates
    let fused_state = fuse-states-weighted $worlds $posterior
    
    {
        method: "bayesian",
        prior: $prior,
        likelihoods: $likelihoods,
        posterior: $posterior,
        state: $fused_state,
        confidence: ($posterior | values | math max),
        entropy: (calculate-entropy $posterior),
        timestamp: (date now)
    }
}

# Dempster-Shafer evidence theory fusion
export def "fusion dempster-shafer" [
    world_estimates: record     # World state estimates
    --fod: list = null          # Frame of discernment
]: [ nothing -> record ] {
    let cfg = (FusionConfig).dempster_shafer
    let worlds = $world_estimates.worlds? | default {}
    let world_ids = $worlds | columns
    
    let frame = if ($fod | is-not-empty) { $fod } else { $cfg.frame_of_discernment }
    
    log info $"Running Dempster-Shafer fusion with frame: ($frame | str join ', ')"
    
    if ($world_ids | length) == 0 {
        return { error: "No world estimates provided" }
    }
    
    # Create basic probability assignments (BPAs) for each world
    mut bpas = {}
    
    for w in $world_ids {
        let world = $worlds | get $w
        let state = $world.projection.state
        
        # Create BPA from state values (normalized)
        let total = $state | values | each { |v| $v | math abs } | math sum
        
        mut masses = {}
        for hypothesis in $frame {
            let value = $state | get $hypothesis | default 0.5
            let mass = if $total > 0 {
                ($value | math abs) / $total
            } else { 1.0 / ($frame | length) }
            $masses = ($masses | insert $hypothesis $mass)
        }
        
        # Add uncertainty mass
        let uncertainty = 1.0 - ($masses | values | math sum)
        $masses = ($masses | insert "uncertainty" ($uncertainty | math abs))
        
        $bpas = ($bpas | insert $w $masses)
    }
    
    # Combine BPAs using Dempster's rule
    let combined = dempster-combine $bpas $world_ids
    
    # Calculate belief and plausibility
    let belief_plausibility = calculate-belief-plausibility $combined $frame
    
    # Convert to fused state estimate
    let fused_state = $frame | each { |h| 
        let value = $combined | get $h | default 0.0
        {hypothesis: $h, value: $value}
    } | reduce -f {} { |item, acc| $acc | insert $item.hypothesis $item.value }
    
    {
        method: "dempster-shafer",
        bpas: $bpas,
        combined: $combined,
        belief: $belief_plausibility.belief,
        plausibility: $belief_plausibility.plausibility,
        state: $fused_state,
        confidence: (1.0 - ($combined.uncertainty? | default 0.0)),
        uncertainty: ($combined.uncertainty? | default 0.0),
        timestamp: (date now)
    }
}

# Kalman filter for state estimation
export def "fusion kalman" [
    world_estimates: record     # World state estimates
    --previous-state: record = null  # Previous fused state for prediction
    --dt: float = 0.033         # Time step (30Hz = 33ms)
]: [ nothing -> record ] {
    let cfg = (FusionConfig).kalman
    let worlds = $world_estimates.worlds? | default {}
    let world_ids = $worlds | columns
    
    log info $"Running Kalman filter fusion with ($world_ids | length) worlds"
    
    if ($world_ids | length) == 0 {
        return { error: "No world estimates provided" }
    }
    
    # Extract measurements from all worlds
    let measurements = extract-measurements $worlds
    let state_vars = $measurements | columns
    
    # Initialize or predict state
    mut state = if ($previous_state | is-not-empty) {
        kalman-predict $previous_state $cfg $dt
    } else {
        kalman-init $measurements $cfg
    }
    
    # Update with measurements
    for var in $state_vars {
        let measurement = $measurements | get $var
        let world_values = $world_ids | each { |w| 
            let val = $worlds | get $w | get projection.state | get $var | default 0.5
            let conf = $worlds | get $w | get confidence | default 0.5
            {value: $val, confidence: $conf}
        }
        
        # Weighted average measurement
        let weighted_sum = $world_values | each { |wv| $wv.value * $wv.confidence } | math sum
        let weight_sum = $world_values | each { |wv| $wv.confidence } | math sum
        let z = if $weight_sum > 0 { $weighted_sum / $weight_sum } else { 0.5 }
        
        # Measurement noise (inverse of confidence)
        let r = $cfg.measurement_noise / ($weight_sum + 0.001)
        
        # Kalman gain
        let k = $state.variance.$var / ($state.variance.$var + $r)
        
        # Update estimate
        let new_estimate = $state.estimate.$var + $k * ($z - $state.estimate.$var)
        let new_variance = (1.0 - $k) * $state.variance.$var
        
        $state.estimate = ($state.estimate | upsert $var $new_estimate)
        $state.variance = ($state.variance | upsert $var $new_variance)
    }
    
    {
        method: "kalman",
        state: $state.estimate,
        variance: $state.variance,
        gain: $state.gain,
        confidence: (1.0 - ($state.variance | values | math avg)),
        timestamp: (date now)
    }
}

# Consensus-based distributed fusion
export def "fusion consensus" [
    world_estimates: record     # World state estimates
    --max-iter: int = null      # Maximum iterations
    --threshold: float = null   # Convergence threshold
]: [ nothing -> record ] {
    let cfg = (FusionConfig).consensus
    let worlds = $world_estimates.worlds? | default {}
    let world_ids = $worlds | columns
    
    let max_iterations = if ($max_iter | is-not-empty) { $max_iter } else { $cfg.max_iterations }
    let conv_threshold = if ($threshold | is-not-empty) { $threshold } else { $cfg.convergence_threshold }
    
    log info $"Running consensus fusion with ($world_ids | length) worlds"
    
    if ($world_ids | length) == 0 {
        return { error: "No world estimates provided" }
    }
    
    # Get state variables
    let first_world = $worlds | get ($world_ids | first)
    let state_vars = $first_world.projection.state | columns
    
    # Initialize node states
    mut node_states = {}
    for w in $world_ids {
        let state = $worlds | get $w | get projection.state
        let confidence = $worlds | get $w | get confidence
        $node_states = ($node_states | insert $w {
            state: $state,
            weight: $confidence,
            iteration: 0
        })
    }
    
    # Consensus iterations
    mut iteration = 0
    mut converged = false
    mut convergence_history = []
    
    while $iteration < $max_iterations and not $converged {
        mut new_states = {}
        mut max_diff = 0.0
        
        for w in $world_ids {
            # Average with neighbors (all other worlds in this case)
            let current = $node_states | get $w
            mut new_state = {}
            
            for var in $state_vars {
                # Weighted average with all other worlds
                let current_val = $current.state | get $var
                mut weighted_sum = $current_val * $current.weight
                mut total_weight = $current.weight
                
                for other_w in $world_ids {
                    if $other_w != $w {
                        let other = $node_states | get $other_w
                        let other_val = $other.state | get $var
                        $weighted_sum = $weighted_sum + ($other_val * $other.weight)
                        $total_weight = $total_weight + $other.weight
                    }
                }
                
                let new_val = if $total_weight > 0 { $weighted_sum / $total_weight } else { $current_val }
                $new_state = ($new_state | insert $var $new_val)
                
                let diff = ($new_val - $current_val) | math abs
                if $diff > $max_diff {
                    $max_diff = $diff
                }
            }
            
            $new_states = ($new_states | insert $w {
                state: $new_state,
                weight: $current.weight,
                iteration: $iteration
            })
        }
        
        $node_states = $new_states
        $iteration = $iteration + 1
        
        $convergence_history = ($convergence_history | append {
            iteration: $iteration,
            max_difference: $max_diff
        })
        
        if $max_diff < $conv_threshold {
            $converged = true
        }
    }
    
    # Final fused state (average of all converged states)
    let fused_state = average-states ($node_states | values | each { |n| $n.state })
    
    # Calculate consensus confidence based on convergence
    let consensus_confidence = if $converged {
        0.9 + 0.1 * (1.0 - ($iteration | into float) / $max_iterations)
    } else {
        0.5 * (1.0 - ($iteration | into float) / $max_iterations)
    }
    
    {
        method: "consensus",
        iterations: $iteration,
        converged: $converged,
        final_difference: (if ($convergence_history | length) > 0 { ($convergence_history | last).max_difference } else { 0 }),
        convergence_history: (if ($convergence_history | length) > 10 { $convergence_history | last 10 } else { $convergence_history }),
        node_states: $node_states,
        state: $fused_state,
        confidence: $consensus_confidence,
        timestamp: (date now)
    }
}

# Run all fusion methods and combine results
export def "fusion ensemble" [
    world_estimates: record     # World state estimates
    --weights: record = null    # Method weights
]: [ nothing -> record ] {
    let cfg = (FusionConfig)
    let method_weights = if ($weights | is-not-empty) { $weights } else { $cfg.weights }
    
    log info "Running ensemble fusion with all methods"
    
    # Run each fusion method
    let bayesian_result = (fusion bayesian $world_estimates)
    let ds_result = (fusion dempster-shafer $world_estimates)
    let kalman_result = (fusion kalman $world_estimates)
    let consensus_result = (fusion consensus $world_estimates)
    
    # Collect all results
    let all_results = {
        bayesian: $bayesian_result,
        dempster_shafer: $ds_result,
        kalman: $kalman_result,
        consensus: $consensus_result
    }
    
    # Weighted combination of states
    let state_vars = $bayesian_result.state | columns
    
    mut fused_state = {}
    for var in $state_vars {
        let b_val = $bayesian_result.state | get $var | default 0.5
        let ds_val = $ds_result.state | get $var | default 0.5
        let k_val = $kalman_result.state | get $var | default 0.5
        let c_val = $consensus_result.state | get $var | default 0.5
        
        let b_conf = $bayesian_result.confidence
        let ds_conf = $ds_result.confidence
        let k_conf = $kalman_result.confidence
        let c_conf = $consensus_result.confidence
        
        let weighted_val = (
            $b_val * $method_weights.bayesian * $b_conf +
            $ds_val * $method_weights.dempster_shafer * $ds_conf +
            $k_val * $method_weights.kalman * $k_conf +
            $c_val * $method_weights.consensus * $c_conf
        ) / (
            $method_weights.bayesian * $b_conf +
            $method_weights.dempster_shafer * $ds_conf +
            $method_weights.kalman * $k_conf +
            $method_weights.consensus * $c_conf + 0.001
        )
        
        $fused_state = ($fused_state | insert $var $weighted_val)
    }
    
    # Calculate overall confidence
    let overall_confidence = (
        $bayesian_result.confidence * $method_weights.bayesian +
        $ds_result.confidence * $method_weights.dempster_shafer +
        $kalman_result.confidence * $method_weights.kalman +
        $consensus_result.confidence * $method_weights.consensus
    )
    
    {
        method: "ensemble",
        individual_results: $all_results,
        weights: $method_weights,
        state: $fused_state,
        confidence: $overall_confidence,
        uncertainty: (1.0 - $overall_confidence),
        agreement_score: (calculate-agreement $all_results $state_vars),
        timestamp: (date now)
    }
}

# =============================================================================
# Helper Functions
# =============================================================================

# Weighted fusion of state estimates
export def fuse-states-weighted [
    worlds: record
    weights: record
]: [ nothing -> record ] {
    let world_ids = $worlds | columns
    let first_world = $worlds | get ($world_ids | first)
    let state_vars = $first_world.projection.state | columns
    
    mut fused = {}
    for var in $state_vars {
        mut weighted_sum = 0.0
        mut total_weight = 0.0
        
        for w in $world_ids {
            let state_val = $worlds | get $w | get projection.state | get $var | default 0.5
            let weight = $weights | get $w | default (1.0 / ($world_ids | length))
            
            $weighted_sum = $weighted_sum + ($state_val * $weight)
            $total_weight = $total_weight + $weight
        }
        
        let fused_val = if $total_weight > 0 { $weighted_sum / $total_weight } else { 0.5 }
        $fused = ($fused | insert $var $fused_val)
    }
    
    $fused
}

# Calculate entropy of a probability distribution
export def calculate-entropy [
    distribution: record
]: [ nothing -> float ] {
    let probs = $distribution | values | filter { |p| $p > 0 }
    
    if ($probs | length) == 0 {
        return 0.0
    }
    
    let entropy = -1.0 * ($probs | each { |p| $p * ($p | math log 2) } | math sum)
    $entropy | math abs
}

# Dempster's rule of combination
export def dempster-combine [
    bpas: record
    world_ids: list
]: [ nothing -> record ] {
    let masses_list = $world_ids | each { |w| $bpas | get $w }
    
    # Start with first BPA
    mut combined = $masses_list | first
    
    # Combine sequentially
    for masses in ($masses_list | skip 1) {
        let m1 = $combined
        let m2 = $masses
        
        let keys1 = $m1 | columns
        let keys2 = $m2 | columns
        
        mut new_combined = {}
        mut conflict = 0.0
        
        # Calculate combination
        for k1 in $keys1 {
            for k2 in $keys2 {
                let v1 = $m1 | get $k1
                let v2 = $m2 | get $k2
                
                if $k1 == $k2 {
                    let current = $new_combined | get $k1 | default 0.0
                    $new_combined = ($new_combined | upsert $k1 ($current + $v1 * $v2))
                } else if $k1 == "uncertainty" {
                    let current = $new_combined | get $k2 | default 0.0
                    $new_combined = ($new_combined | upsert $k2 ($current + $v1 * $v2))
                } else if $k2 == "uncertainty" {
                    let current = $new_combined | get $k1 | default 0.0
                    $new_combined = ($new_combined | upsert $k1 ($current + $v1 * $v2))
                } else {
                    $conflict = $conflict + ($v1 * $v2)
                }
            }
        }
        
        # Normalize (Dempster's rule)
        let norm_factor = 1.0 - $conflict
        if $norm_factor > 0.001 {
            $new_combined = ($new_combined | columns | each { |k| 
                {key: $k, val: (($new_combined | get $k) / $norm_factor)}
            } | reduce -f {} { |item, acc| $acc | insert $item.key $item.val })
        }
        
        $combined = $new_combined
    }
    
    $combined
}

# Calculate belief and plausibility
export def calculate-belief-plausibility [
    combined: record
    frame: list
]: [ nothing -> record ] {
    let uncertainty = $combined.uncertainty? | default 0.0
    
    mut belief = {}
    mut plausibility = {}
    
    for h in $frame {
        let mass = $combined | get $h | default 0.0
        $belief = ($belief | insert $h $mass)
        $plausibility = ($plausibility | insert $h ($mass + $uncertainty))
    }
    
    { belief: $belief, plausibility: $plausibility }
}

# Extract measurements from worlds
export def extract-measurements [
    worlds: record
]: [ nothing -> record ] {
    let world_ids = $worlds | columns
    let first_world = $worlds | get ($world_ids | first)
    let state_vars = $first_world.projection.state | columns
    
    mut measurements = {}
    for var in $state_vars {
        let values = $world_ids | each { |w| 
            $worlds | get $w | get projection.state | get $var | default 0.5
        }
        $measurements = ($measurements | insert $var ($values | math avg))
    }
    
    $measurements
}

# Initialize Kalman filter
export def kalman-init [
    measurements: record
    cfg: record
]: [ nothing -> record ] {
    {
        estimate: $measurements,
        variance: ($measurements | columns | each { |k| {key: $k, val: $cfg.initial_uncertainty} } | reduce -f {} { |i, acc| $acc | insert $i.key $i.val }),
        gain: ($measurements | columns | each { |k| {key: $k, val: 0.5} } | reduce -f {} { |i, acc| $acc | insert $i.key $i.val })
    }
}

# Kalman prediction step
export def kalman-predict [
    state: record
    cfg: record
    dt: float
]: [ nothing -> record ] {
    # Simple prediction: state stays same, variance grows
    let new_variance = $state.variance | columns | each { |k| 
        let v = $state.variance | get $k
        let q = if $cfg.adaptive_q { $cfg.process_noise * (1.0 + $v) } else { $cfg.process_noise }
        {key: $k, val: ($v + $q)}
    } | reduce -f {} { |i, acc| $acc | insert $i.key $i.val }
    
    $state | upsert variance $new_variance
}

# Average multiple states
export def average-states [
    states: list
]: [ nothing -> record ] {
    if ($states | length) == 0 {
        return {}
    }
    
    let first = $states | first
    let vars = $first | columns
    
    mut avg = {}
    for var in $vars {
        let values = $states | each { |s| $s | get $var | default 0.5 }
        $avg = ($avg | insert $var ($values | math avg))
    }
    
    $avg
}

# Calculate agreement score between fusion methods
export def calculate-agreement [
    results: record
    state_vars: list
]: [ nothing -> float ] {
    let methods = $results | columns
    
    if ($methods | length) < 2 {
        return 1.0
    }
    
    mut total_variance = 0.0
    for var in $state_vars {
        let values = $methods | each { |m| 
            let state = $results | get $m | get state
            $state | get $var | default 0.5
        }
        let var_val = $values | math variance
        $total_variance = $total_variance + $var_val
    }
    
    let avg_variance = $total_variance / ($state_vars | length)
    1.0 - (avg_variance | math sqrt)  # Convert to agreement score
}

# =============================================================================
# Module Info
# =============================================================================

export def module-info [] {
    {
        name: "fusion_engine",
        version: "0.1.0",
        description: "Multi-world sensor fusion using Bayesian, Dempster-Shafer, Kalman, and Consensus methods",
        commands: [
            "fusion bayesian",
            "fusion dempster-shafer",
            "fusion kalman",
            "fusion consensus",
            "fusion ensemble"
        ],
        methods: ["bayesian", "dempster-shafer", "kalman", "consensus", "ensemble"]
    }
}
