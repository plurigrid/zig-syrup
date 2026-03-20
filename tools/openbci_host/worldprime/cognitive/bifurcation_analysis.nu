# bifurcation_analysis.nu
# Dynamical system analysis for cognitive architecture
# Detects, classifies, predicts, and controls bifurcations

# =============================================================================
# Bifurcation State Management
# =============================================================================

export def BifurcationState [] {
    {
        systems: {},          # Tracked dynamical systems
        history: [],          # Bifurcation event history
        lyapunov: {},         # Lyapunov exponent tracking
        parameters: {},       # Parameter trajectories
        phase_portraits: {},  # Stored phase portraits
        metadata: {
            created_at: (date now),
            version: "1.0",
            detections: 0
        }
    }
}

export def "bifurcation new" [] {
    BifurcationState
}

# =============================================================================
# Bifurcation Detection
# =============================================================================

# Detect bifurcation points in dynamical system time series
export def "bifurcation detect" [
    trajectory: list,         # Time series of system state
    --parameter: list = [],   # Corresponding parameter values
    --window-size: int = 50,  # Analysis window
    --threshold: float = 2.0, # Detection sensitivity
    --system-id: string = "default"
] {
    let state = $in | default (BifurcationState)
    let n_points = $trajectory | length
    
    mut bifurcation_points = []
    mut indicators = []
    
    # Compute local stability indicators
    for i in $window_size..<($n_points - $window_size) {
        # Extract window before and after
        let before = $trajectory | skip ($i - $window_size) | take $window_size
        let after = $trajectory | skip $i | take $window_size
        
        # Compute variance ratio (increase indicates bifurcation)
        let var_before = if ($before | length) > 1 {
            let b = $before | each { |v| $v | into float }
            ($b | math stddev | into float) | $in * $in
        } else { 0.0 }
        
        let var_after = if ($after | length) > 1 {
            let a = $after | each { |v| $v | into float }
            ($a | math stddev | into float) | $in * $in
        } else { 0.0 }
        
        let var_ratio = if $var_before > 0.0001 {
            $var_after / $var_before
        } else {
            1.0
        }
        
        # Detect change in mean
        let mean_before = $before | each { |v| $v | into float } | math avg
        let mean_after = $after | each { |v| $v | into float } | math avg
        let mean_shift = ($mean_after - $mean_before) | math abs
        
        # Combined bifurcation indicator
        let indicator = ($var_ratio | math log) * $mean_shift
        $indicators = ($indicators | append { index: $i, indicator: $indicator, var_ratio: $var_ratio, mean_shift: $mean_shift })
        
        # Detect bifurcation
        if $indicator > $threshold {
            let param_val = if ($parameter | length) > 0 {
                $parameter | get $i
            } else {
                $i
            }
            
            $bifurcation_points = ($bifurcation_points | append {
                index: $i,
                parameter: $param_val,
                indicator: $indicator,
                var_ratio: $var_ratio,
                mean_shift: $mean_shift,
                timestamp: (date now)
            })
        }
    }
    
    # Update state
    let detection_record = {
        system_id: $system_id,
        n_points: $n_points,
        bifurcation_points: $bifurcation_points,
        threshold: $threshold,
        detected_at: (date now)
    }
    
    let new_state = $state | upsert history {||
        $state.history | append $detection_record
    } | upsert metadata.detections {||
        $state.metadata.detections + ($bifurcation_points | length)
    }
    
    {
        state: $new_state,
        bifurcation_points: $bifurcation_points,
        n_detected: ($bifurcation_points | length),
        indicators: $indicators
    }
}

# =============================================================================
# Bifurcation Classification
# =============================================================================

# Classify bifurcation types based on system behavior
export def "bifurcation classify" [
    trajectory: list,
    --bifurcation-point: int,     # Index of detected bifurcation
    --window-size: int = 30,
    --system-id: string = "default"
] {
    let state = $in | default (BifurcationState)
    
    let n = $trajectory | length
    if $bifurcation_point >= $n or $bifurcation_point < $window_size {
        error make { msg: "Invalid bifurcation point index" }
    }
    
    # Analyze pre-bifurcation behavior
    let pre = $trajectory | skip ($bifurcation_point - $window_size) | take $window_size
    let post = $trajectory | skip $bifurcation_point | take $window_size
    
    # Extract features for classification
    let pre_vals = $pre | each { |v| $v | into float }
    let post_vals = $post | each { |v| $v | into float }
    
    let pre_mean = $pre_vals | math avg
    let post_mean = $post_vals | math avg
    let pre_var = if ($pre_vals | length) > 1 { ($pre_vals | math stddev | into float) | $in * $in } else { 0.0 }
    let post_var = if ($post_vals | length) > 1 { ($post_vals | math stddev | into float) | $in * $in } else { 0.0 }
    
    # Count local extrema (indicates oscillations)
    mut pre_extrema = 0
    for i in 1..<($pre_vals | length | $in - 1) {
        let v = $pre_vals | get $i
        let v_prev = $pre_vals | get ($i - 1)
        let v_next = $pre_vals | get ($i + 1)
        if ($v > $v_prev and $v > $v_next) or ($v < $v_prev and $v < $v_next) {
            $pre_extrema = $pre_extrema + 1
        }
    }
    
    mut post_extrema = 0
    for i in 1..<($post_vals | length | $in - 1) {
        let v = $post_vals | get $i
        let v_prev = $post_vals | get ($i - 1)
        let v_next = $post_vals | get ($i + 1)
        if ($v > $v_prev and $v > $v_next) or ($v < $v_prev and $v < $v_next) {
            $post_extrema = $post_extrema + 1
        }
    }
    
    # Classification rules
    let classification = if $pre_var < 0.001 and $post_var > 0.1 {
        if $post_extrema > 3 {
            { type: "hopf", name: "Hopf bifurcation", description: "Fixed point to limit cycle" }
        } else {
            { type: "saddle_node", name: "Saddle-node bifurcation", description: "Creation/annihilation of fixed points" }
        }
    } else if $pre_var > 0.1 and $post_var < 0.001 {
        { type: "inverse_hopf", name: "Inverse Hopf", description: "Limit cycle to fixed point" }
    } else if ($pre_mean | math abs) < 0.1 and ($post_mean | math abs) > 0.5 {
        { type: "pitchfork", name: "Pitchfork bifurcation", description: "Symmetry breaking" }
    } else if $post_extrema > $pre_extrema * 2 {
        { type: "period_doubling", name: "Period-doubling bifurcation", description: "Period doubling route to chaos" }
    } else {
        { type: "unknown", name: "Unclassified", description: "Requires further analysis" }
    }
    
    let details = {
        pre_stability: {
            mean: $pre_mean,
            variance: $pre_var,
            extrema_count: $pre_extrema
        },
        post_stability: {
            mean: $post_mean,
            variance: $post_var,
            extrema_count: $post_extrema
        },
        change_metrics: {
            variance_ratio: (if $pre_var > 0.0001 { $post_var / $pre_var } else { 0.0 }),
            mean_shift: ($post_mean - $pre_mean),
            oscillation_change: ($post_extrema - $pre_extrema)
        }
    }
    
    let result = {
        bifurcation_point: $bifurcation_point,
        classification: $classification,
        confidence: (if $classification.type != "unknown" { 0.7 } else { 0.3 }),
        details: $details
    }
    
    # Update state
    let new_state = $state | upsert systems {||
        let sys = $state.systems | get --optional $system_id | default {}
        $state.systems | upsert $system_id ($sys | upsert last_classification $result)
    }
    
    { state: $new_state, result: $result }
}

# =============================================================================
# Bifurcation Prediction
# =============================================================================

# Predict upcoming bifurcations from early warning signals
export def "bifurcation predict" [
    trajectory: list,
    --prediction-horizon: int = 100,
    --early-warning-window: int = 50,
    --system-id: string = "default"
] {
    let state = $in | default (BifurcationState)
    let n = $trajectory | length
    
    if $n < $early_warning_window {
        return { prediction: null, reason: "insufficient_data", state: $state }
    }
    
    # Compute early warning indicators
    let recent = $trajectory | skip ($n - $early_warning_window) | take $early_warning_window
    let recent_vals = $recent | each { |v| $v | into float }
    
    # Critical slowing down: increasing autocorrelation
    mut autocorr_lag1 = 0.0
    let mean_recent = $recent_vals | math avg
    let var_recent = if ($recent_vals | length) > 1 { 
        ($recent_vals | math stddev | into float) | $in * $in 
    } else { 1.0 }
    
    if $var_recent > 0.0001 {
        mut cov_sum = 0.0
        for i in 1..<($recent_vals | length) {
            let cov = (($recent_vals | get $i) - $mean_recent) * (($recent_vals | get ($i - 1)) - $mean_recent)
            $cov_sum = $cov_sum + $cov
        }
        $autocorr_lag1 = $cov_sum / ($var_recent * ($recent_vals | length | $in - 1 | into float))
    }
    
    # Increasing variance (flickering)
    let half = $early_warning_window / 2
    let first_half = $recent_vals | take $half
    let second_half = $recent_vals | skip $half
    
    let var_first = if ($first_half | length) > 1 { 
        ($first_half | math stddev | into float) | $in * $in 
    } else { 0.0 }
    let var_second = if ($second_half | length) > 1 { 
        ($second_half | math stddev | into float) | $in * $in 
    } else { 0.0 }
    
    let variance_trend = if $var_first > 0.0001 {
        $var_second / $var_first
    } else {
        1.0
    }
    
    # Skewness/kurtosis changes
    # Simplified: measure asymmetry
    mut skew_proxy = 0.0
    for v in $recent_vals {
        $skew_proxy = $skew_proxy + (($v - $mean_recent) | math pow 3)
    }
    $skew_proxy = $skew_proxy / ($recent_vals | length | into float)
    $skew_proxy = $skew_proxy / (($var_recent | math sqrt) | math pow 3)
    
    # Combine indicators
    let warning_score = ($autocorr_lag1 | into float | $in * 0.4) + 
                        ([0.0, ($variance_trend - 1.0)] | math max | $in * 0.4) +
                        (($skew_proxy | math abs) * 0.2)
    
    # Prediction
    let prediction = if $warning_score > 0.5 {
        {
            imminent: true,
            estimated_time: (if $warning_score > 0.8 { "very soon" } else { "soon" }),
            warning_score: $warning_score,
            indicators: {
                autocorrelation: $autocorr_lag1,
                variance_trend: $variance_trend,
                skewness_proxy: $skew_proxy
            },
            recommended_action: "Monitor closely; prepare control intervention"
        }
    } else {
        {
            imminent: false,
            warning_score: $warning_score,
            indicators: {
                autocorrelation: $autocorr_lag1,
                variance_trend: $variance_trend,
                skewness_proxy: $skew_proxy
            }
        }
    }
    
    # Update state with prediction
    let new_state = $state | upsert systems {||
        let sys = $state.systems | get --optional $system_id | default {}
        let predictions = $sys | get --optional predictions | default []
        $state.systems | upsert $system_id ($sys | upsert predictions ($predictions | append {
            timestamp: (date now),
            prediction: $prediction
        } | last 10))
    }
    
    { state: $new_state, prediction: $prediction }
}

# =============================================================================
# Bifurcation Control
# =============================================================================

# Control parameters to avoid or achieve bifurcations
export def "bifurcation control" [
    --current-parameter: float,
    --target-state: string = "stable",  # "stable", "oscillating", "bifurcate"
    --sensitivity: float = 0.1,
    --system-id: string = "default"
] {
    let state = $in | default (BifurcationState)
    
    let sys = $state.systems | get --optional $system_id | default {}
    let last_bifurcation = $sys | get --optional last_classification
    
    # Determine control strategy based on target
    let strategy = match $target_state {
        "stable" => {
            # Move away from bifurcation boundary
            let adjustment = if $sensitivity > 0 {
                -0.1 * $current_parameter  # Decrease parameter
            } else {
                0.1 * $current_parameter   # Increase parameter
            }
            {
                action: "stabilize",
                parameter_adjustment: $adjustment,
                target_region: "subcritical",
                description: "Move deeper into stable regime"
            }
        },
        "oscillating" => {
            # Move toward Hopf bifurcation
            let adjustment = 0.05 * $current_parameter
            {
                action: "induce_oscillation",
                parameter_adjustment: $adjustment,
                target_region: "supercritical_hopf",
                description: "Approach Hopf bifurcation for limit cycle"
            }
        },
        "bifurcate" => {
            # Move toward bifurcation boundary
            let adjustment = 0.02 * $current_parameter
            {
                action: "induce_bifurcation",
                parameter_adjustment: $adjustment,
                target_region: "bifurcation_boundary",
                description: "Approach bifurcation for regime change"
            }
        },
        _ => {
            {
                action: "maintain",
                parameter_adjustment: 0.0,
                target_region: "current",
                description: "Maintain current parameter value"
            }
        }
    }
    
    let new_param = $current_parameter + $strategy.parameter_adjustment
    
    let control_plan = {
        current_parameter: $current_parameter,
        target_state: $target_state,
        strategy: $strategy,
        recommended_parameter: $new_param,
        feedback_gain: (1.0 / $sensitivity),
        update_rate: 0.1
    }
    
    # Update state
    let new_state = $state | upsert parameters {||
        let param_history = $state.parameters | get --optional $system_id | default []
        $state.parameters | upsert $system_id ($param_history | append {
            timestamp: (date now),
            parameter: $current_parameter,
            adjustment: $strategy.parameter_adjustment,
            new_parameter: $new_param,
            target: $target_state
        } | last 100)
    }
    
    { state: $new_state, control_plan: $control_plan }
}

# =============================================================================
# Lyapunov Exponents
# =============================================================================

# Compute or estimate Lyapunov exponents for chaos detection
export def "bifurcation lyapunov" [
    trajectory: list,
    --system-id: string = "default",
    --embedding-dim: int = 3,
    --time-delay: int = 1,
    --window-size: int = 100
] {
    let state = $in | default (BifurcationState)
    let n = $trajectory | length
    
    if $n < $window_size {
        return { error: "Insufficient data for Lyapunov estimation", state: $state }
    }
    
    # Estimate maximal Lyapunov exponent using Wolf algorithm (simplified)
    let data = $trajectory | each { |v| $v | into float }
    
    mut divergence_sum = 0.0
    mut n_divergences = 0
    
    for i in 0..<($n - $window_size - $time_delay) {
        # Find nearest neighbor in embedding space
        let point_i = $data | skip $i | take $embedding_dim
        
        mut min_dist = 1e10
        mut nearest_idx = -1
        
        for j in 0..<($n - $window_size) {
            if $j == $i or ($j - $i | math abs) < 10 {
                continue
            }
            
            let point_j = $data | skip $j | take $embedding_dim
            mut dist_sq = 0.0
            for k in 0..<($point_i | length | $in | math min ($point_j | length)) {
                let diff = ($point_i | get $k) - ($point_j | get $k)
                $dist_sq = $dist_sq + ($diff * $diff)
            }
            let dist = $dist_sq | math sqrt
            if $dist < $min_dist and $dist > 0.0001 {
                $min_dist = $dist
                $nearest_idx = $j
            }
        }
        
        if $nearest_idx >= 0 {
            # Track divergence
            let future_i = $i + $time_delay
            let future_j = $nearest_idx + $time_delay
            
            if $future_i < $n and $future_j < $n {
                let new_point_i = $data | get $future_i
                let new_point_j = $data | get $future_j
                let new_dist = ($new_point_i - $new_point_j) | math abs
                
                if $min_dist > 0.0001 and $new_dist > 0 {
                    let divergence = ($new_dist / $min_dist | math log)
                    $divergence_sum = $divergence_sum + $divergence
                    $n_divergences = $n_divergences + 1
                }
            }
        }
    }
    
    # Estimate maximal Lyapunov exponent
    let max_lyapunov = if $n_divergences > 0 {
        $divergence_sum / ($n_divergences | into float)
    } else {
        0.0
    }
    
    # Determine system type
    let system_type = if $max_lyapunov > 0.01 {
        "chaotic"
    } else if $max_lyapunov > -0.01 {
        "quasiperiodic_or_periodic"
    } else {
        "stable"
    }
    
    let lyapunov_info = {
        maximal_lyapunov: $max_lyapunov,
        system_type: $system_type,
        n_divergences_measured: $n_divergences,
        embedding_dimension: $embedding_dim,
        time_delay: $time_delay,
        estimated_at: (date now)
    }
    
    # Update state
    let new_state = $state | upsert lyapunov {||
        $state.lyapunov | upsert $system_id ($lyapunov_info)
    }
    
    { state: $new_state, lyapunov: $lyapunov_info }
}

# =============================================================================
# Phase Portrait Analysis
# =============================================================================

# Generate and analyze phase portrait
export def "bifurcation portrait" [
    trajectory: list,
    --embedding-dim: int = 2,
    --time-delay: int = 1,
    --system-id: string = "default"
] {
    let state = $in | default (BifurcationState)
    let n = $trajectory | length
    
    if $n < ($embedding_dim * $time_delay + 1) {
        error make { msg: "Insufficient data for phase portrait" }
    }
    
    # Create delay embedding
    mut embedded = []
    for i in 0..<($n - ($embedding_dim - 1) * $time_delay) {
        mut point = []
        for d in 0..<$embedding_dim {
            let idx = $i + ($d * $time_delay)
            let val = $trajectory | get $idx | into float
            $point = ($point | append $val)
        }
        $embedded = ($embedded | append $point)
    }
    
    # Analyze geometry
    let n_embedded = $embedded | length
    
    # Compute trajectory length
    mut trajectory_length = 0.0
    for i in 1..<$n_embedded {
        let p1 = $embedded | get ($i - 1)
        let p2 = $embedded | get $i
        mut dist = 0.0
        for d in 0..<$embedding_dim {
            let diff = ($p2 | get $d) - ($p1 | get $d)
            $dist = $dist + ($diff * $diff)
        }
        $trajectory_length = $trajectory_length + ($dist | math sqrt)
    }
    
    # Estimate attractor dimension (box-counting simplified)
    let box_count = 10
    let min_coord = $embedded | each { |p| $p | get 0 } | math min | into float
    let max_coord = $embedded | each { |p| $p | get 0 } | math max | into float
    let box_size = ($max_coord - $min_coord) / ($box_count | into float)
    
    mut occupied_boxes = {}
    for p in $embedded {
        let x = $p | get 0 | into float
        let box_x = (($x - $min_coord) / $box_size) | math floor
        $occupied_boxes = ($occupied_boxes | upsert $box_x true)
    }
    
    let box_count_estimate = $occupied_boxes | length
    let estimated_dim = ($box_count_estimate | into float | math log) / ($box_count | into float | math log)
    
    let portrait = {
        embedded_points: $embedded,
        n_points: $n_embedded,
        embedding_dimension: $embedding_dim,
        time_delay: $time_delay,
        trajectory_length: $trajectory_length,
        bounding_box: { min: $min_coord, max: $max_coord },
        estimated_fractal_dimension: $estimated_dim,
        box_count: $box_count_estimate
    }
    
    # Update state
    let new_state = $state | upsert phase_portraits {||
        $state.phase_portraits | upsert $system_id $portrait
    }
    
    { state: $new_state, portrait: $portrait }
}

# =============================================================================
# Utility Functions
# =============================================================================

# Get summary of all bifurcation analysis
export def "bifurcation summary" [] {
    let state = $in
    {
        n_systems: ($state.systems | length),
        total_detections: $state.metadata.detections,
        systems_analyzed: ($state.systems | columns),
        recent_history: ($state.history | last 5),
        lyapunov_tracked: ($state.lyapunov | columns),
        portraits_generated: ($state.phase_portraits | columns)
    }
}

# Export bifurcation state
export def "bifurcation export" [] {
    $in | to json
}

# Import bifurcation state
export def "bifurcation import" [json_data: string] {
    $json_data | from json
}

# Reset bifurcation state
export def "bifurcation reset" [] {
    BifurcationState
}
