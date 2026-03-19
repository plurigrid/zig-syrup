# persistent_homology.nu
# Topological Data Analysis (TDA) using Persistent Homology
# Tracks topological features (connected components, loops, voids) across scales
# 
# This module implements Vietoris-Rips complex construction and barcode
# computation for analyzing the topology of brain state spaces.

use std log

# =============================================================================
# Types and Constants
# =============================================================================

export const DEFAULT_MAX_SCALE = 2.0
export const DEFAULT_NUM_SCALES = 20
export const INFINITY_VALUE = 1e308

# Betti numbers: β0 = components, β1 = loops, β2 = voids
export const BETTI_NAMES = {
    0: "connected_components"
    1: "loops"
    2: "voids"
    3: "hypervoids"
}

# =============================================================================
# Point Cloud and Distance Functions
# =============================================================================

# Euclidean distance between two points
export def euclidean-distance [a: list, b: list]: [ nothing -> float ] {
    $a | zip $b | each {|p| ($p.0 - $p.1) | math abs | $in * $in } | math sum | math sqrt
}

# Compute pairwise distance matrix for point cloud
export def distance-matrix [points: list]: [ nothing -> list ] {
    let n = $points | length
    mut matrix = []
    
    for i in 0..<$n {
        mut row = []
        for j in 0..<$n {
            if $i == $j {
                $row = ($row | append 0.0)
            } else {
                let dist = (euclidean-distance ($points | get $i) ($points | get $j))
                $row = ($row | append $dist)
            }
        }
        $matrix = ($matrix | append [$row])
    }
    
    $matrix
}

# Normalize point cloud to unit hypercube
export def normalize-point-cloud [points: list]: [ nothing -> list ] {
    let n_dims = ($points | first | length)
    
    # Find min/max per dimension
    mut mins = []
    mut maxs = []
    
    for dim in 0..<$n_dims {
        let values = ($points | each {|p| $p | get $dim })
        $mins = ($mins | append ($values | math min))
        $maxs = ($maxs | append ($values | math max))
    }
    
    # Normalize
    $points | each {|p| 
        $p | enumerate | each {|entry| 
            let dim = $entry.index
            let min = ($mins | get $dim)
            let max = ($maxs | get $dim)
            let range = $max - $min
            if $range > 0 {
                ($entry.item - $min) / $range
            } else {
                0.5
            }
        }
    }
}

# =============================================================================
# Vietoris-Rips Complex Construction
# =============================================================================

# Build Rips complex at a given scale (epsilon)
# Returns simplices (edges, triangles, etc.) where all pairwise distances <= epsilon
export def "homology rips" [
    point_cloud: list           # List of points (each point is a list of coordinates)
    --scale: float = 0.5        # Rips scale epsilon
    --max-dim: int = 2          # Maximum simplex dimension (0=points, 1=edges, 2=triangles)
]: [ nothing -> record ] {
    let n_points = $point_cloud | length
    
    # Compute distance matrix
    let dist_matrix = (distance-matrix $point_cloud)
    
    # Build 0-simplices (points)
    let vertices = seq 0 $n_points | each {|i| [$i] }
    
    # Build 1-simplices (edges) - pairs within scale
    mut edges = []
    for i in 0..<$n_points {
        for j in ($i + 1)..<$n_points {
            let dist = ($dist_matrix | get $i | get $j)
            if $dist <= $scale {
                $edges = ($edges | append [[$i $j]])
            }
        }
    }
    
    # Build 2-simplices (triangles) - triples where all edges exist
    mut triangles = []
    if $max_dim >= 2 {
        for i in 0..<$n_points {
            for j in ($i + 1)..<$n_points {
                for k in ($j + 1)..<$n_points {
                    let d_ij = ($dist_matrix | get $i | get $j)
                    let d_ik = ($dist_matrix | get $i | get $k)
                    let d_jk = ($dist_matrix | get $j | get $k)
                    
                    if ($d_ij <= $scale) and ($d_ik <= $scale) and ($d_jk <= $scale) {
                        $triangles = ($triangles | append [[$i $j $k]])
                    }
                }
            }
        }
    }
    
    # Build 3-simplices (tetrahedra)
    mut tetrahedra = []
    if $max_dim >= 3 {
        for i in 0..<$n_points {
            for j in ($i + 1)..<$n_points {
                for k in ($j + 1)..<$n_points {
                    for l in ($k + 1)..<$n_points {
                        let d_ij = ($dist_matrix | get $i | get $j)
                        let d_ik = ($dist_matrix | get $i | get $k)
                        let d_il = ($dist_matrix | get $i | get $l)
                        let d_jk = ($dist_matrix | get $j | get $k)
                        let d_jl = ($dist_matrix | get $j | get $l)
                        let d_kl = ($dist_matrix | get $k | get $l)
                        
                        if (($d_ij <= $scale) and ($d_ik <= $scale) and ($d_il <= $scale) and ($d_jk <= $scale) and ($d_jl <= $scale) and ($d_kl <= $scale)) {
                            $tetrahedra = ($tetrahedra | append [[$i $j $k $l]])
                        }
                    }
                }
            }
        }
    }
    
    {
        scale: $scale
        n_points: $n_points
        simplices: {
            0: $vertices
            1: $edges
            2: $triangles
            3: $tetrahedra
        }
        counts: {
            vertices: ($vertices | length)
            edges: ($edges | length)
            triangles: ($triangles | length)
            tetrahedra: ($tetrahedra | length)
        }
        euler_characteristic: (($vertices | length) - ($edges | length) + ($triangles | length) - ($tetrahedra | length))
    }
}

# Build Rips filtration (sequence of complexes at increasing scales)
export def build-rips-filtration [
    point_cloud: list
    --min-scale: float = 0.0
    --max-scale: float = $DEFAULT_MAX_SCALE
    --num-scales: int = $DEFAULT_NUM_SCALES
    --max-dim: int = 2
]: [ nothing -> list ] {
    let scale_step = ($max_scale - $min_scale) / ($num_scales | into float)
    
    mut filtration = []
    for i in 0..<$num_scales {
        let scale = $min_scale + ($i | into float) * $scale_step
        let complex = (homology rips $point_cloud --scale $scale --max-dim $max_dim)
        $filtration = ($filtration | append $complex)
    }
    
    $filtration
}

# =============================================================================
# Persistent Homology Computation
# =============================================================================

# Compute persistent homology barcodes across filtration
export def "homology persistent" [
    point_cloud: list
    --min-scale: float = 0.0
    --max-scale: float = $DEFAULT_MAX_SCALE  
    --num-scales: int = $DEFAULT_NUM_SCALES
    --max-homology-dim: int = 2
]: [ nothing -> record ] {
    log info "Computing persistent homology..."
    
    # Build filtration
    let filtration = (build-rips-filtration $point_cloud --min-scale $min_scale --max-scale $max_scale --num-scales $num_scales --max-dim ($max_homology_dim + 1))
    
    # Track features across scales
    mut betti_curves = []
    mut persistence_diagrams = {}
    
    for dim in 0..=$max_homology_dim {
        $persistence_diagrams = ($persistence_diagrams | insert ($dim | into string) [])
    }
    
    # Compute Betti numbers at each scale
    for complex in $filtration {
        let bettis = (compute-betti-numbers $complex)
        $betti_curves = ($betti_curves | append {
            scale: $complex.scale
            betti: $bettis
        })
    }
    
    # Compute persistence intervals (birth/death times of features)
    # Simplified: track when features appear/disappear
    let persistence_barcodes = (compute-persistence-barcodes $filtration $max_homology_dim)
    
    # Build persistence diagrams
    for dim in 0..=$max_homology_dim {
        let barcode = ($persistence_barcodes | get ($dim | into string))
        let diagram = ($barcode | each {|interval| 
            {birth: $interval.birth death: $interval.death persistence: ($interval.death - $interval.birth)}
        })
        $persistence_diagrams = ($persistence_diagrams | insert ($dim | into string) $diagram)
    }
    
    {
        point_cloud_size: ($point_cloud | length)
        filtration_scales: ($filtration | each {|f| $f.scale })
        betti_curves: $betti_curves
        persistence_barcodes: $persistence_barcodes
        persistence_diagrams: $persistence_diagrams
        max_scale: $max_scale
        max_homology_dim: $max_homology_dim
    }
}

# Compute Betti numbers for a complex (simplified)
export def "homology betti" [
    rips_complex: record        # Rips complex from homology rips
]: [ nothing -> record ] {
    compute-betti-numbers $rips_complex
}

# Internal: compute Betti numbers
export def compute-betti-numbers [complex: record]: [ nothing -> record ] {
    # Simplified Betti number computation
    # β0 ≈ number of connected components (vertices - edges in spanning forest)
    # β1 ≈ number of loops (edges - vertices + components)
    # β2 ≈ number of voids (triangles - edges + vertices)
    
    let n0 = $complex.counts.vertices
    let n1 = $complex.counts.edges  
    let n2 = $complex.counts.triangles
    let n3 = $complex.counts.tetrahedra
    
    # Euler characteristic: χ = n0 - n1 + n2 - n3
    let chi = $n0 - $n1 + $n2 - $n3
    
    # Approximate β0 (connected components)
    # When scale is small, many components; when large, fewer
    let beta0 = if $n1 > 0 {
        ($n0 - $n1 + 1) | if $in > 1 { $in } else { 1 }
    } else {
        $n0
    }
    
    # Approximate β1 (loops/1-dimensional holes)
    let beta1 = ($n1 - $n0 + $beta0) | if $in > 0 { $in } else { 0 }
    
    # Approximate β2 (voids/2-dimensional holes)  
    let beta2 = ($n2 - $n1 + $n0 - $beta0) | if $in > 0 { $in } else { 0 }
    
    {
        0: $beta0
        1: $beta1
        2: $beta2
        euler_characteristic: $chi
        scale: $complex.scale
    }
}

# Compute persistence barcodes (birth/death times of topological features)
export def compute-persistence-barcodes [filtration: list, max_dim: int]: [ nothing -> record ] {
    mut barcodes = {}
    
    for dim in 0..=$max_dim {
        let dim_str = $dim | into string
        mut barcode = []
        
        # Track features across scales
        # Simplified: assume features born at first scale persist until they merge/annihilate
        mut active_features = []
        
        for complex in $filtration {
            let bettis = (compute-betti-numbers $complex)
            let current_betti = ($bettis | get ($dim | into string) | default 0)
            let scale = $complex.scale
            
            # Track new births and deaths
            let n_active = $active_features | length
            
            if $current_betti > $n_active {
                # New features born
                let new_features = $current_betti - $n_active
                for _ in 0..<$new_features {
                    $active_features = ($active_features | append {birth: $scale death: null})
                }
            } else if $current_betti < $n_active {
                # Features died
                let dead_features = $n_active - $current_betti
                for _ in 0..<$dead_features {
                    if ($active_features | length) > 0 {
                        let idx = ($active_features | length) - 1
                        let updated = ($active_features | get $idx | insert death $scale)
                        $barcode = ($barcode | append $updated)
                        $active_features = ($active_features | drop 1)
                    }
                }
            }
        }
        
        # Features still active at end get death = infinity
        let max_scale = ($filtration | last | get scale)
        for feature in $active_features {
            $barcode = ($barcode | append {birth: $feature.birth death: $INFINITY_VALUE})
        }
        
        $barcodes = ($barcodes | insert $dim_str $barcode)
    }
    
    $barcodes
}

# =============================================================================
# Persistence Diagrams
# =============================================================================

# Create persistence diagram from persistence computation
export def "homology diagram" [
    persistence_result: record   # Result from homology persistent
    --dimension: int = 0         # Homology dimension to plot
    --include-stats = true
]: [ nothing -> record ] {
    let dim_str = $dimension | into string
    let diagram = ($persistence_result.persistence_diagrams | get $dim_str | default [])
    
    let max_scale = $persistence_result.max_scale
    
    # Calculate statistics
    let persistences = ($diagram | each {|p| $p.persistence })
    let stats = if ($persistences | is-empty) {
        {count: 0 mean: 0 max: 0 min: 0 std: 0}
    } else {
        {
            count: ($diagram | length)
            mean: ($persistences | math avg)
            max: ($persistences | math max)
            min: ($persistences | math min)
            std: ($persistences | math stddev | default 0)
        }
    }
    
    # Find significant features (high persistence)
    let mean_persistence = $stats.mean
    let significant = ($diagram | where {|p| $p.persistence > $mean_persistence * 2 })
    
    let result = {
        dimension: $dimension
        points: $diagram
        diagonal: {x: [0 $max_scale] y: [0 $max_scale]}  # y=x line for reference
        statistics: $stats
        significant_features: $significant
        n_significant: ($significant | length)
    }
    
    if $include_stats {
        $result
    } else {
        $result | reject statistics
    }
}

# Compute bottleneck distance between two persistence diagrams (simplified)
export def bottleneck-distance [diagram1: list, diagram2: list]: [ nothing -> float ] {
    # Simplified: use mean difference in persistence values
    let pers1 = ($diagram1 | each {|p| $p.persistence })
    let pers2 = ($diagram2 | each {|p| $p.persistence })
    
    if ($pers1 | is-empty) or ($pers2 | is-empty) {
        return 0.0
    }
    
    let mean1 = $pers1 | math avg
    let mean2 = $pers2 | math avg
    
    ($mean1 - $mean2) | math abs
}

# =============================================================================
# Dynamic TDA: Topological Features Across Time
# =============================================================================

# Track topological features across time for dynamic brain state analysis
export def track-topological-dynamics [
    time_series: list           # List of point clouds over time
    --window_size: int = 10     # Analysis window size
    --step_size: int = 5        # Step between consecutive analyses
    --max-scale: float = 1.0
]: [ nothing -> record ] {
    let n_frames = $time_series | length
    mut results = []
    
    for start in (seq 0 $step_size ($n_frames - $window_size)) {
        let end = $start + $window_size
        let window_points = ($time_series | range $start..<$end) | flatten
        
        # Compute persistent homology for this window
        let ph = (homology persistent $window_points --max-scale $max_scale --num-scales 10)
        
        # Extract summary statistics
        let summary = {
            frame_start: $start
            frame_end: $end
            center_frame: (($start + $end) / 2 | math floor)
            betti_0: ($ph.betti_curves | last | get betti | get "0")
            betti_1: ($ph.betti_curves | last | get betti | get "1")
            betti_2: ($ph.betti_curves | last | get betti | get "2")
            total_persistence: ($ph.persistence_diagrams | values | flatten | each {|p| $p.persistence } | math sum)
            n_significant_features: ($ph.persistence_diagrams | values | flatten | where {|p| $p.persistence > 0.5 } | length)
        }
        
        $results = ($results | append $summary)
    }
    
    # Detect topological change points
    let change_points = (detect-topological-changes $results)
    
    {
        window_results: $results
        change_points: $change_points
        temporal_statistics: {
            mean_betti_0: ($results | each {|r| $r.betti_0 } | math avg)
            mean_betti_1: ($results | each {|r| $r.betti_1 } | math avg)
            mean_betti_2: ($results | each {|r| $r.betti_2 } | math avg)
            std_betti_0: ($results | each {|r| $r.betti_0 } | math stddev)
            std_betti_1: ($results | each {|r| $r.betti_1 } | math stddev)
            std_betti_2: ($results | each {|r| $r.betti_2 } | math stddev)
        }
    }
}

# Detect topological change points in temporal analysis
def detect-topological-changes [window-results: list]: [ nothing -> list ] {
    mut changes = []
    mut prev_betti = null
    
    for result in $window_results {
        let current_betti = {b0: $result.betti_0 b1: $result.betti_1 b2: $result.betti_2}
        
        if $prev_betti != null {
            let delta = ($current_betti.b0 - $prev_betti.b0) | math abs
            let delta1 = ($current_betti.b1 - $prev_betti.b1) | math abs
            let delta2 = ($current_betti.b2 - $prev_betti.b2) | math abs
            
            let total_change = $delta + $delta1 + $delta2
            
            if $total_change > 2 {
                $changes = ($changes | append {
                    frame: $result.center_frame
                    betti_change: $total_change
                    from: $prev_betti
                    to: $current_betti
                })
            }
        }
        
        $prev_betti = $current_betti
    }
    
    $changes
}

# =============================================================================
# EEG-Specific TDA Functions
# =============================================================================

# Convert EEG data to point cloud for TDA analysis
export def eeg-to-point-cloud [
    eeg-data: list              # List of EEG samples
    --embedding-dim: int = 3    # Embedding dimension (delay embedding)
    --delay: int = 5            # Delay for time-delay embedding
    --use-channels: list = []   # Which channels to include (empty = all)
]: [ nothing -> list ] {
    let n_samples = $eeg_data | length
    let channels = if ($use_channels | is-empty) {
        # Extract channel names from first sample
        $eeg_data | first | get channels
    } else {
        $use_channels
    }
    
    mut point_cloud = []
    
    # Time-delay embedding: x(t) = [x(t), x(t+τ), x(t+2τ), ...]
    let max_idx = $n_samples - ($embedding_dim * $delay)
    
    for i in 0..<$max_idx {
        mut point = []
        for d in 0..<$embedding_dim {
            let idx = $i + ($d * $delay)
            let sample = $eeg_data | get $idx
            # Use average across channels for single scalar
            let value = if ($sample | describe) =~ "record" {
                ($sample.channels | math avg)
            } else {
                $sample
            }
            $point = ($point | append $value)
        }
        $point_cloud = ($point_cloud | append [$point])
    }
    
    $point_cloud
}

# Analyze brain state topology from EEG
export def analyze-brain-topology [
    eeg-data: list
    --window-sec: float = 2.0
    --sampling-rate: int = 250
    --max-scale: float = 100.0  # Scaled for microvolt range
]: [ nothing -> record ] {
    let window_samples = ($window_sec * ($sampling_rate | into float)) | into int
    
    # Convert to point cloud
    let point_cloud = (eeg-to-point-cloud $eeg_data --embedding-dim 3 --delay 5)
    
    # Limit to window size
    let pc_window = ($point_cloud | range 0..<$window_samples)
    
    # Compute persistent homology
    let ph = (homology persistent $pc_window --max-scale $max_scale --num-scales 15 --max-homology-dim 2)
    
    # Interpret results for brain state
    let final_bettis = ($ph.betti_curves | last | get betti)
    
    let interpretation = {
        connectivity: if ($final_bettis | get "0") < 3 { "highly_connected" } else { "modular" }
        loop_complexity: ($final_bettis | get "1")
        void_structure: ($final_bettis | get "2")
        topological_complexity: (($final_bettis | get "0") + ($final_bettis | get "1") + ($final_bettis | get "2"))
    }
    
    {
        point_cloud_size: ($pc_window | length)
        persistent_homology: $ph
        betti_numbers: $final_bettis
        interpretation: $interpretation
        significant_cycles: ($ph.persistence_diagrams | get "1" | where {|p| $p.persistence > $max_scale * 0.3 } | length)
    }
}
