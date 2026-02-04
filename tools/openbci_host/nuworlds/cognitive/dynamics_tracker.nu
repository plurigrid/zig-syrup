# dynamics_tracker.nu
# Track dynamical system evolution for cognitive architecture
# Tracks fixed points, limit cycles, strange attractors, Poincaré sections, return maps

# =============================================================================
# Dynamics State Management
# =============================================================================

export def DynamicsState [] {
    {
        trajectories: {},     # Stored trajectories
        fixed_points: {},     # Detected fixed points
        limit_cycles: {},     # Detected limit cycles
        attractors: {},       # Strange attractors
        poincare_sections: {},# Poincaré section data
        return_maps: {},      # Return maps
        stability: {},        # Stability analyses
        metadata: {
            created_at: (date now),
            version: "1.0",
            tracking_sessions: 0
        }
    }
}

export def "dynamics new" [] {
    DynamicsState
}

# =============================================================================
# Fixed Point Tracking
# =============================================================================

# Track and detect fixed points in dynamical system
export def "dynamics fixed-point" [
    trajectory: list,         # Time series data
    --convergence-threshold: float = 0.001,
    --window-size: int = 20,
    --system-id: string = "default"
] {
    let state = $in | default (DynamicsState)
    let n = $trajectory | length
    
    mut fixed_points = []
    mut visited_regions = {}
    
    # Scan for regions where state remains nearly constant
    for i in 0..<($n - $window_size) {
        let window = $trajectory | skip $i | take $window_size | each { |v| $v | into float }
        let mean_val = $window | math avg
        let max_deviation = $window | each { |v| ($v - $mean_val) | math abs } | math max
        
        if $max_deviation < $convergence_threshold {
            # Check if this is a new fixed point (not too close to existing)
            let region_key = ($mean_val * 100.0 | math floor)  # Quantize for comparison
            
            if $region_key not-in $visited_regions {
                $visited_regions = ($visited_regions | insert $region_key true)
                
                # Analyze stability
                let prev_window = if $i >= $window_size {
                    $trajectory | skip ($i - $window_size) | take $window_size | each { |v| $v | into float }
                } else {
                    []
                }
                
                let approach_rate = if ($prev_window | length) > 0 {
                    let prev_mean = $prev_window | math avg
                    let mean_diff = $mean_val - $prev_mean
                    if ($mean_diff | math abs) > 0.0001 {
                        $max_deviation / ($mean_diff | math abs)
                    } else {
                        0.0
                    }
                } else {
                    0.0
                }
                
                $fixed_points = ($fixed_points | append {
                    index: $i,
                    value: $mean_val,
                    deviation: $max_deviation,
                    stability: (if $approach_rate < 0.1 { "stable" } else { "slow_manifold" }),
                    approach_rate: $approach_rate,
                    window_start: $i,
                    window_end: ($i + $window_size)
                })
            }
        }
    }
    
    # Update state
    let new_state = $state | upsert fixed_points {||
        $state.fixed_points | upsert $system_id $fixed_points
    } | upsert metadata.tracking_sessions {||
        $state.metadata.tracking_sessions + 1
    }
    
    {
        state: $new_state,
        fixed_points: $fixed_points,
        n_detected: ($fixed_points | length),
        stable_count: ($fixed_points | where stability == "stable" | length)
    }
}

# =============================================================================
# Limit Cycle Detection
# =============================================================================

# Detect and characterize limit cycles
export def "dynamics limit-cycle" [
    trajectory: list,
    --embedding-dim: int = 2,
    --time-delay: int = 1,
    --tolerance: float = 0.1,
    --min-period: int = 10,
    --system-id: string = "default"
] {
    let state = $in | default (DynamicsState)
    let n = $trajectory | length
    
    # Create delay embedding for phase space
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
    
    let n_embed = $embedded | length
    
    # Find limit cycles by detecting returns to neighborhood
    mut limit_cycles = []
    mut visited = []
    
    for start_idx in 0..<($n_embed | math min 100) {  # Sample starting points
        if $start_idx in $visited {
            continue
        }
        
        let start_point = $embedded | get $start_idx
        
        # Search for return to neighborhood
        for i in ($start_idx + $min_period)..<$n_embed {
            let current = $embedded | get $i
            
            # Compute distance
            mut dist_sq = 0.0
            for d in 0..<$embedding_dim {
                let diff = ($current | get $d) - ($start_point | get $d)
                $dist_sq = $dist_sq + ($diff * $diff)
            }
            let dist = $dist_sq | math sqrt
            
            if $dist < $tolerance {
                # Found return - characterize cycle
                let period = $i - $start_idx
                
                # Compute cycle statistics
                let cycle_points = $embedded | skip $start_idx | take $period
                
                # Center of orbit
                mut center = []
                for d in 0..<$embedding_dim {
                    let coord = $cycle_points | each { |p| $p | get $d } | math avg
                    $center = ($center | append $coord)
                }
                
                # Amplitude
                mut amplitude = 0.0
                for p in $cycle_points {
                    mut dist_to_center = 0.0
                    for d in 0..<$embedding_dim {
                        let diff = ($p | get $d) - ($center | get $d)
                        $dist_to_center = $dist_to_center + ($diff * $diff)
                    }
                    let r = $dist_to_center | math sqrt
                    if $r > $amplitude {
                        $amplitude = $r
                    }
                }
                
                $limit_cycles = ($limit_cycles | append {
                    start_index: $start_idx,
                    period: $period,
                    center: $center,
                    amplitude: $amplitude,
                    tolerance: $tolerance,
                    stability: "unknown"  # Would need perturbation analysis
                })
                
                # Mark visited
                for v in $start_idx..<$i {
                    $visited = ($visited | append $v)
                }
                
                break
            }
        }
    }
    
    # Update state
    let new_state = $state | upsert limit_cycles {||
        $state.limit_cycles | upsert $system_id $limit_cycles
    }
    
    {
        state: $new_state,
        limit_cycles: $limit_cycles,
        n_detected: ($limit_cycles | length),
        periods: ($limit_cycles | get period)
    }
}

# =============================================================================
# Strange Attractor Tracking
# =============================================================================

# Detect and characterize strange attractors
export def "dynamics attractor" [
    trajectory: list,
    --embedding-dim: int = 3,
    --time-delay: int = 1,
    --correlation-horizon: int = 100,
    --system-id: string = "default"
] {
    let state = $in | default (DynamicsState)
    let n = $trajectory | length
    
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
    
    let n_embed = $embedded | length
    
    # Compute correlation dimension (Grassberger-Procaccia simplified)
    let radii = [0.01, 0.02, 0.05, 0.1, 0.2]
    mut correlation_integrals = []
    
    for r in $radii {
        mut count = 0
        let sample_size = ($n_embed | math min 200)
        
        for i in 0..<$sample_size {
            let pi = $embedded | get $i
            for j in ($i + 1)..<$sample_size {
                let pj = $embedded | get $j
                
                mut dist_sq = 0.0
                for d in 0..<$embedding_dim {
                    let diff = ($pi | get $d) - ($pj | get $d)
                    $dist_sq = $dist_sq + ($diff * $diff)
                }
                
                if ($dist_sq | math sqrt) < $r {
                    $count = $count + 1
                }
            }
        }
        
        let total_pairs = ($sample_size * ($sample_size - 1)) / 2
        let C = ($count | into float) / ($total_pairs | into float)
        $correlation_integrals = ($correlation_integrals | append { r: $r, C: $C })
    }
    
    # Estimate correlation dimension from scaling
    mut dimensions = []
    for i in 1..<($correlation_integrals | length) {
        let c1 = $correlation_integrals | get ($i - 1)
        let c2 = $correlation_integrals | get $i
        if $c1.C > 0 and $c2.C > 0 {
            let dlogC = ($c2.C | math log) - ($c1.C | math log)
            let dlogr = ($c2.r | math log) - ($c1.r | math log)
            if ($dlogr | math abs) > 0.001 {
                $dimensions = ($dimensions | append ($dlogC / $dlogr))
            }
        }
    }
    
    let correlation_dimension = if ($dimensions | length) > 0 {
        $dimensions | math avg
    } else {
        $embedding_dim | into float
    }
    
    # Determine if strange attractor (fractal dimension < embedding dim)
    let is_strange = $correlation_dimension < ($embedding_dim | into float) and $correlation_dimension > 1.5
    
    # Compute bounding box
    mut min_bounds = []
    mut max_bounds = []
    for d in 0..<$embedding_dim {
        let coords = $embedded | each { |p| $p | get $d }
        $min_bounds = ($min_bounds | append ($coords | math min | into float))
        $max_bounds = ($max_bounds | append ($coords | math max | into float))
    }
    
    let attractor = {
        embedding_dimension: $embedding_dim,
        correlation_dimension: $correlation_dimension,
        is_strange: $is_strange,
        n_points: $n_embed,
        bounds: {
            min: $min_bounds,
            max: $max_bounds
        },
        correlation_integrals: $correlation_integrals,
        dimension_estimates: $dimensions
    }
    
    # Update state
    let new_state = $state | upsert attractors {||
        $state.attractors | upsert $system_id $attractor
    }
    
    { state: $new_state, attractor: $attractor }
}

# =============================================================================
# Poincaré Section Analysis
# =============================================================================

# Compute Poincaré section for periodic orbit analysis
export def "dynamics poincare" [
    trajectory: list,
    --section-plane: list = [1, 0, 0],  # Normal vector to section plane
    --section-offset: float = 0.0,      # Plane offset
    --embedding-dim: int = 3,
    --time-delay: int = 1,
    --system-id: string = "default"
] {
    let state = $in | default (DynamicsState)
    let n = $trajectory | length
    
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
    
    # Find crossings of Poincaré section
    mut crossings = []
    let n_embed = $embedded | length
    
    for i in 1..<$n_embed {
        let p_prev = $embedded | get ($i - 1)
        let p_curr = $embedded | get $i
        
        # Compute dot product with plane normal
        mut dot_prev = 0.0
        mut dot_curr = 0.0
        for d in 0..<($section_plane | length | math min ($p_prev | length)) {
            $dot_prev = $dot_prev + (($section_plane | get $d) * ($p_prev | get $d))
            $dot_curr = $dot_curr + (($section_plane | get $d) * ($p_curr | get $d))
        }
        
        $dot_prev = $dot_prev - $section_offset
        $dot_curr = $dot_curr - $section_offset
        
        # Check for sign change (crossing)
        if ($dot_prev * $dot_curr < 0) and ($dot_curr > 0) {
            # Interpolate crossing point
            let t = ($dot_prev | math abs) / (($dot_prev | math abs) + ($dot_curr | math abs))
            
            mut crossing_point = []
            for d in 0..<($p_prev | length) {
                let interp = (($p_prev | get $d) * (1.0 - $t)) + (($p_curr | get $d) * $t)
                $crossing_point = ($crossing_point | append $interp)
            }
            
            $crossings = ($crossings | append {
                index: $i,
                point: $crossing_point,
                interpolation_factor: $t,
                direction: "upward"
            })
        }
    }
    
    # Analyze return times
    let return_times = if ($crossings | length) > 1 {
        1..<($crossings | length) | each { |i|
            ($crossings | get $i | get index) - ($crossings | get ($i - 1) | get index)
        }
    } else {
        []
    }
    
    let section = {
        plane_normal: $section_plane,
        plane_offset: $section_offset,
        crossings: $crossings,
        n_crossings: ($crossings | length),
        return_times: $return_times,
        mean_return_time: (if ($return_times | length) > 0 { $return_times | math avg } else { 0 }),
        return_time_variance: (if ($return_times | length) > 1 { 
            ($return_times | math stddev | into float) | $in * $in 
        } else { 0.0 })
    }
    
    # Update state
    let new_state = $state | upsert poincare_sections {||
        $state.poincare_sections | upsert $system_id $section
    }
    
    { state: $new_state, section: $section }
}

# =============================================================================
# Return Map Analysis
# =============================================================================

# Build return map for discrete dynamics analysis
export def "dynamics return-map" [
    trajectory: list,
    --delay: int = 1,
    --system-id: string = "default"
] {
    let state = $in | default (DynamicsState)
    let n = $trajectory | length
    
    if $n <= $delay {
        error make { msg: "Trajectory too short for return map" }
    }
    
    # Build return map: x_{n+1} vs x_n
    mut return_map = []
    for i in 0..<($n - $delay) {
        let x_n = $trajectory | get $i | into float
        let x_next = $trajectory | get ($i + $delay) | into float
        $return_map = ($return_map | append { x: $x_n, x_next: $x_next })
    }
    
    # Analyze map properties
    let x_vals = $return_map | get x
    let x_next_vals = $return_map | get x_next
    
    # Find fixed points (where x ≈ x_next)
    mut fixed_points = []
    for p in $return_map {
        if (($p.x_next - $p.x) | math abs) < 0.01 {
            $fixed_points = ($fixed_points | append $p)
        }
    }
    
    # Estimate local slopes (derivative approximation)
    mut slopes = []
    for i in 1..<($return_map | length) {
        let p1 = $return_map | get ($i - 1)
        let p2 = $return_map | get $i
        let dx = $p2.x - $p1.x
        if ($dx | math abs) > 0.0001 {
            let dy = $p2.x_next - $p1.x_next
            $slopes = ($slopes | append ($dy / $dx))
        }
    }
    
    let map_analysis = {
        points: $return_map,
        n_points: ($return_map | length),
        fixed_points: $fixed_points,
        n_fixed_points: ($fixed_points | length),
        range_x: { min: ($x_vals | math min | into float), max: ($x_vals | math max | into float) },
        range_x_next: { min: ($x_next_vals | math min | into float), max: ($x_next_vals | math max | into float) },
        slope_statistics: {
            mean: (if ($slopes | length) > 0 { $slopes | math avg } else { 0.0 }),
            std: (if ($slopes | length) > 1 { $slopes | math stddev | into float } else { 0.0 })
        },
        delay: $delay
    }
    
    # Update state
    let new_state = $state | upsert return_maps {||
        $state.return_maps | upsert $system_id $map_analysis
    }
    
    { state: $new_state, return_map: $map_analysis }
}

# =============================================================================
# Stability Analysis
# =============================================================================

# Comprehensive stability analysis of dynamical regimes
export def "dynamics stability" [
    trajectory: list,
    --analysis-window: int = 100,
    --system-id: string = "default"
] {
    let state = $in | default (DynamicsState)
    let n = $trajectory | length
    
    # Analyze in sliding windows
    mut regime_analysis = []
    let step = $analysis_window / 2
    
    for start in 0..<$step..($n - $analysis_window) {
        let window = $trajectory | skip $start | take $analysis_window | each { |v| $v | into float }
        
        # Basic statistics
        let mean = $window | math avg
        let variance = if ($window | length) > 1 { 
            ($window | math stddev | into float) | $in * $in 
        } else { 0.0 }
        
        # Trend analysis (linear fit via correlation)
        let indices = seq 0 ($window | length)
        let mean_idx = $indices | math avg
        let cov = ($indices | enumerate | each { |ie|
            let centered_idx = ($ie.index | into float) - $mean_idx
            let centered_val = ($window | get $ie.index) - $mean
            $centered_idx * $centered_val
        } | math sum)
        let var_idx = $indices | each { |i| 
            let c = ($i | into float) - $mean_idx
            $c * $c
        } | math sum
        let slope = if $var_idx > 0 { $cov / $var_idx } else { 0.0 }
        
        # Autocorrelation
        let autocorr = if ($window | length) > 1 and $variance > 0.0001 {
            let shifted = $window | skip 1
            let original = $window | last (($window | length) - 1)
            let cov = ($shifted | enumerate | each { |se|
                (($se.item) - $mean) * ((($original | get $se.index)) - $mean)
            } | math sum)
            $cov / ($variance * (($window | length) - 1 | into float))
        } else {
            0.0
        }
        
        # Classify regime
        let regime = if $variance < 0.001 {
            "stable_fixed_point"
        } else if $slope | math abs > 0.01 {
            "transient_drift"
        } else if $autocorr > 0.7 {
            "slow_dynamics"
        } else if $autocorr < 0.3 {
            "fast_fluctuations"
        } else {
            "periodic_or_quasiperiodic"
        }
        
        $regime_analysis = ($regime_analysis | append {
            window_start: $start,
            window_end: ($start + $analysis_window),
            mean: $mean,
            variance: $variance,
            slope: $slope,
            autocorrelation: $autocorr,
            regime: $regime
        })
    }
    
    # Overall classification
    let regime_counts = $regime_analysis | group-by regime | transpose regime count | each { |r|
        { regime: $r.regime, count: ($r.count | length) }
    } | sort-by count -r
    
    let dominant_regime = if ($regime_counts | length) > 0 {
        $regime_counts | get 0 | get regime
    } else {
        "unknown"
    }
    
    let stability_report = {
        window_analysis: $regime_analysis,
        dominant_regime: $dominant_regime,
        regime_distribution: $regime_counts,
        stability_score: (if $dominant_regime == "stable_fixed_point" { 1.0 } 
                         else if $dominant_regime == "periodic_or_quasiperiodic" { 0.7 }
                         else if $dominant_regime == "slow_dynamics" { 0.5 }
                         else { 0.3 }),
        is_stable: ($dominant_regime == "stable_fixed_point")
    }
    
    # Update state
    let new_state = $state | upsert stability {||
        $state.stability | upsert $system_id $stability_report
    }
    
    { state: $new_state, stability: $stability_report }
}

# =============================================================================
# Complete System Analysis
# =============================================================================

# Run complete dynamics analysis on trajectory
export def "dynamics analyze" [
    trajectory: list,
    --system-id: string = "default",
    --embedding-dim: int = 3
] {
    mut state = $in | default (DynamicsState)
    
    # Store trajectory
    $state = ($state | upsert trajectories {||
        $state.trajectories | upsert $system_id $trajectory
    })
    
    # Run all analyses
    let fp_result = $state | dynamics fixed-point --system-id $system_id
    $state = $fp_result.state
    
    let lc_result = $state | dynamics limit-cycle --embedding-dim $embedding_dim --system-id $system_id
    $state = $lc_result.state
    
    let att_result = $state | dynamics attractor --embedding-dim $embedding_dim --system-id $system_id
    $state = $att_result.state
    
    let stab_result = $state | dynamics stability --system-id $system_id
    $state = $stab_result.state
    
    let poincare_result = $state | dynamics poincare --embedding-dim $embedding_dim --system-id $system_id
    $state = $poincare_result.state
    
    let rm_result = $state | dynamics return-map --system-id $system_id
    $state = $rm_result.state
    
    # Compile summary
    let summary = {
        system_id: $system_id,
        trajectory_length: ($trajectory | length),
        fixed_points: {
            count: $fp_result.n_detected,
            stable: $fp_result.stable_count
        },
        limit_cycles: {
            count: $lc_result.n_detected,
            periods: $lc_result.periods
        },
        attractor: {
            is_strange: $att_result.attractor.is_strange,
            correlation_dimension: $att_result.attractor.correlation_dimension
        },
        stability: {
            dominant_regime: $stab_result.stability.dominant_regime,
            stability_score: $stab_result.stability.stability_score
        },
        poincare: {
            n_crossings: $poincare_result.section.n_crossings,
            mean_return_time: $poincare_result.section.mean_return_time
        },
        return_map: {
            n_fixed_points: $rm_result.return_map.n_fixed_points,
            slope_mean: $rm_result.return_map.slope_statistics.mean
        }
    }
    
    { state: $state, summary: $summary }
}

# =============================================================================
# Utility Functions
# =============================================================================

# Get dynamics summary
export def "dynamics summary" [] {
    let state = $in
    {
        n_trajectories: ($state.trajectories | length),
        systems_with_fixed_points: ($state.fixed_points | columns),
        systems_with_limit_cycles: ($state.limit_cycles | columns),
        strange_attractors: ($state.attractors | transpose id info | where { |a| $a.info.is_strange } | get id),
        poincare_sections: ($state.poincare_sections | columns),
        return_maps: ($state.return_maps | columns),
        tracking_sessions: $state.metadata.tracking_sessions
    }
}

# Export dynamics state
export def "dynamics export" [] {
    $in | to json
}

# Import dynamics state
export def "dynamics import" [json_data: string] {
    $json_data | from json
}

# Reset dynamics state
export def "dynamics reset" [] {
    DynamicsState
}
