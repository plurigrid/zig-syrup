# free_energy_calculator.nu
# Variational Free Energy Computation for Active Inference
# Calculates surprise, KL divergence, and tracks free energy minimization
# Analyzes the complexity-accuracy tradeoff in brain dynamics

use std log

# =============================================================================
# Types and Constants
# =============================================================================

export const LN_2PI = 1.8378770664093453  # ln(2π)
export const DEFAULT_PRECISION = 1.0
export const HISTORY_WINDOW = 100

# =============================================================================
# Surprise Calculation (Negative Log Model Evidence)
# =============================================================================

# Calculate surprise: -ln p(o) = negative log model evidence
# This is the quantity the brain (approximately) minimizes
export def calculate-surprise [
    observations: list           # Observed data
    predicted_observations: list # Model predictions
    --observation-precision: float = $DEFAULT_PRECISION
    --method: string = "gaussian"  # gaussian, categorical, mixture
]: [ nothing -> float ] {
    match $method {
        "gaussian" => (gaussian-surprise $observations $predicted_observations $observation_precision)
        "categorical" => (categorical-surprise $observations $predicted_observations)
        "poisson" => (poisson-surprise $observations $predicted_observations)
        _ => (gaussian-surprise $observations $predicted_observations $observation_precision)
    }
}

# Gaussian surprise: -ln N(o; μ, σ²)
def gaussian-surprise [obs: list, pred: list, precision: float]: [ nothing -> float ] {
    let variance = 1.0 / $precision
    let n = $obs | length
    
    mut sum_sq_error = 0.0
    for i in 0..<$n {
        let error = ($obs | get $i) - ($pred | get $i)
        $sum_sq_error = $sum_sq_error + $error * $error
    }
    
    let mse = $sum_sq_error / ($n | into float)
    
    # -ln N(o|μ,σ²) = 0.5 * [ln(2πσ²) + (o-μ)²/σ²]
    0.5 * ($LN_2PI + ($variance | math ln) + $mse / $variance)
}

# Categorical surprise (cross-entropy)
def categorical-surprise [obs: list, pred: list]: [ nothing -> float ] {
    # obs: one-hot or probability distribution
    # pred: predicted probability distribution
    mut cross_entropy = 0.0
    
    for i in 0..<($obs | length) {
        let p_obs = $obs | get $i
        let p_pred_val = $pred | get $i
        let p_pred = if $p_pred_val > 0.0001 { $p_pred_val } else { 0.0001 }  # Avoid log(0)
        
        if $p_obs > 0 {
            $cross_entropy = $cross_entropy - $p_obs * ($p_pred | math ln)
        }
    }
    
    $cross_entropy
}

# Poisson surprise for count data
def poisson-surprise [obs: list, pred: list]: [ nothing -> float ] {
    mut surprise = 0.0
    
    for i in 0..<($obs | length) {
        let o = $obs | get $i
        let lambda_raw = $pred | get $i
        let lambda = if $lambda_raw > 0.0001 { $lambda_raw } else { 0.0001 }
        
        # -ln Poisson(o|λ) = λ - o*ln(λ) + ln(o!)
        # Using Stirling's approximation for ln(o!): o*ln(o) - o + 0.5*ln(2πo)
        let log_factorial = if $o > 0 {
            $o * ($o | math ln) - $o + 0.5 * ($LN_2PI + ($o | math ln))
        } else {
            0
        }
        
        $surprise = $surprise + $lambda - $o * ($lambda | math ln) + $log_factorial
    }
    
    $surprise / ($obs | length | into float)
}

# =============================================================================
# KL Divergence Calculations
# =============================================================================

# Calculate KL divergence between recognition density q(s) and generative density p(s)
# D_KL[q(s) || p(s)] = E_q[ln q(s) - ln p(s)]
export def kl-divergence [
    q_distribution: record       # Recognition density {mean: [], precision: float} or {probabilities: []}
    p_distribution: record       # Generative/prior density
    --distribution_type: string = "gaussian"  # gaussian, categorical, diagonal_gaussian
]: [ nothing -> float ] {
    match $distribution_type {
        "gaussian" => (kl-gaussian $q_distribution $p_distribution)
        "categorical" => (kl-categorical $q_distribution $p_distribution)
        "diagonal_gaussian" => (kl-diagonal-gaussian $q_distribution $p_distribution)
        _ => (kl-gaussian $q_distribution $p_distribution)
    }
}

# KL divergence between two Gaussians
# D_KL[N(μ₁, σ₁²) || N(μ₂, σ₂²)] = 0.5 * [ln(σ₂²/σ₁²) + σ₁²/σ₂² + (μ₁-μ₂)²/σ₂² - 1]
def kl-gaussian [q: record, p: record]: [ nothing -> float ] {
    let q_mean = $q.mean
    let q_prec = $q.precision
    let q_var = 1.0 / $q_prec
    
    let p_mean = $p.mean
    let p_prec = $p.precision
    let p_var = 1.0 / $p_prec
    
    # For multivariate: trace(Σ₂⁻¹Σ₁) + (μ₂-μ₁)ᵀΣ₂⁻¹(μ₂-μ₁) - k + ln(|Σ₂|/|Σ₁|)
    let mean_diff_sq = ($q_mean | zip $p_mean | each {|pair| 
        let diff = $pair.0 - $pair.1
        $diff * $diff
    } | math sum)
    
    0.5 * (($p_var / $q_var | math ln) + $q_var / $p_var + $mean_diff_sq * $p_prec - 1.0)
}

# KL divergence for diagonal Gaussians (independent dimensions)
def kl-diagonal-gaussian [q: record, p: record]: [ nothing -> float ] {
    let q_means = $q.mean
    let q_precs = $q.precisions  # Per-dimension precisions
    let p_means = $p.mean
    let p_precs = $p.precisions
    
    mut total_kl = 0.0
    let n_dims = $q_means | length
    
    for i in 0..<$n_dims {
        let q_mean = $q_means | get $i
        let q_prec = $q_precs | get $i
        let q_var = 1.0 / $q_prec
        
        let p_mean = $p_means | get $i
        let p_prec = $p_precs | get $i
        let p_var = 1.0 / $p_prec
        
        let mean_diff_sq = ($q_mean - $p_mean) ** 2
        let dim_kl = 0.5 * (($p_var / $q_var | math ln) + $q_var / $p_var + $mean_diff_sq * $p_prec - 1.0)
        
        $total_kl = $total_kl + $dim_kl
    }
    
    $total_kl
}

# KL divergence between categorical distributions
def kl-categorical [q: record, p: record]: [ nothing -> float ] {
    let q_probs = $q.probabilities
    let p_probs = $p.probabilities
    
    mut kl = 0.0
    for i in 0..<($q_probs | length) {
        let q_i = $q_probs | get $i
        let p_i = $p_probs | get $i | if $in > 0.0001 { $in } else { 0.0001 }
        
        if $q_i > 0 {
            $kl = $kl + $q_i * (($q_i | math ln) - ($p_i | math ln))
        }
    }
    
    $kl
}

# Monte Carlo estimate of KL divergence using samples
def kl-monte-carlo [q_samples: list, log_q_fn: closure, log_p_fn: closure]: [ nothing -> float ] {
    mut kl_estimate = 0.0
    let n_samples = $q_samples | length
    
    for sample in $q_samples {
        let log_q = (do $log_q_fn $sample)
        let log_p = (do $log_p_fn $sample)
        $kl_estimate = $kl_estimate + $log_q - $log_p
    }
    
    $kl_estimate / ($n_samples | into float)
}

# =============================================================================
# Variational Free Energy
# =============================================================================

# Calculate variational free energy F = D_KL[q(s) || p(s)] - E_q[ln p(o|s)]
# Or equivalently: F = E_q[ln q(s) - ln p(o,s)]
export def calculate-free-energy [
    observations: list
    recognition_density: record  # q(s)
    generative_model: record     # Contains p(s) and p(o|s)
    --compute_components = false  # Return F, accuracy, and complexity separately
]: [ nothing -> record ] {
    # Get prior from generative model
    let prior = $generative_model.prior
    
    # Get predicted observations from generative model
    let predicted_obs = if ($generative_model | get -o predicted_observations | is-not-empty) {
        $generative_model.predicted_observations
    } else {
        # Compute from recognition density and likelihood
        expected-observations $recognition_density.mean $generative_model.likelihood
    }
    
    # 1. Accuracy term: E_q[ln p(o|s)]
    let accuracy = (calculate-accuracy $observations $predicted_obs $generative_model)
    
    # 2. Complexity term: D_KL[q(s) || p(s)]
    let complexity = (kl-divergence $recognition_density $prior --distribution_type "gaussian")
    
    # 3. Free energy: F = -accuracy + complexity = complexity - (-accuracy)
    let free_energy = $complexity - $accuracy
    
    if $compute_components {
        {
            free_energy: $free_energy
            accuracy: $accuracy
            complexity: $complexity
            negative_evidence_bound: (-$free_energy)  # ELBO = -F
        }
    } else {
        {free_energy: $free_energy}
    }
}

# Calculate expected log likelihood (accuracy term)
def calculate-accuracy [obs: list, pred: list, gm: record]: [ nothing -> float ] {
    let precision = $gm.likelihood_precision
    let variance = 1.0 / $precision
    
    mut log_likelihood = 0.0
    let n = $obs | length
    
    for i in 0..<$n {
        let error = ($obs | get $i) - ($pred | get $i)
        # ln N(o|pred, var) = -0.5 * ln(2πvar) - 0.5 * error²/var
        $log_likelihood = $log_likelihood - 0.5 * ($LN_2PI + ($variance | math ln)) - 0.5 * $error * $error / $variance
    }
    
    $log_likelihood / ($n | into float)
}

# Expected observations from state beliefs
def expected-observations [state_beliefs: list, likelihood_matrix: list]: [ nothing -> list ] {
    mut expected = []
    
    for obs_idx in 0..<($likelihood_matrix | length) {
        let likelihood_given_state = ($likelihood_matrix | get $obs_idx)
        let expected_val = ($likelihood_given_state | zip $state_beliefs 
            | each {|p| $p.0 * $p.1 } | math sum)
        $expected = ($expected | append $expected_val)
    }
    
    $expected
}

# =============================================================================
# Free Energy Minimization Tracking
# =============================================================================

# Track free energy minimization over time
export def track-free-energy [
    time_series_data: list       # List of {observations: [], recognition: {}}
    generative_model: record
    --window_size: int = 10      # Window for running statistics
]: [ nothing -> record ] {
    let n_samples = $time_series_data | length
    mut free_energy_history = []
    mut accuracy_history = []
    mut complexity_history = []
    
    for sample in $time_series_data {
        let obs = $sample.observations
        let recognition = $sample.recognition
        
        let fe_result = (calculate-free-energy $obs $recognition $generative_model --compute_components true)
        
        $free_energy_history = ($free_energy_history | append $fe_result.free_energy)
        $accuracy_history = ($accuracy_history | append $fe_result.accuracy)
        $complexity_history = ($complexity_history | append $fe_result.complexity)
    }
    
    # Compute running statistics
    let running_stats = (compute-running-stats $free_energy_history $window_size)
    
    # Detect convergence
    let convergence = (detect-convergence $free_energy_history)
    
    {
        free_energy_history: $free_energy_history
        accuracy_history: $accuracy_history
        complexity_history: $complexity_history
        final_free_energy: ($free_energy_history | last)
        min_free_energy: ($free_energy_history | math min)
        mean_free_energy: ($free_energy_history | math avg)
        running_statistics: $running_stats
        convergence: $convergence
    }
}

# Compute running statistics over a window
def compute-running-stats [values: list, window: int]: [ nothing -> record ] {
    let n = $values | length
    mut means = []
    mut variances = []
    
    for i in $window..<$n {
        let window_data = $values | range ($i - $window)..<$i
        let mean = $window_data | math avg
        let var = $window_data | each {|x| ($x - $mean) ** 2 } | math avg
        
        $means = ($means | append $mean)
        $variances = ($variances | append $var)
    }
    
    {
        running_means: $means
        running_variances: $variances
        window_size: $window
    }
}

# Detect convergence in free energy minimization
def detect-convergence [free_energies: list]: [ nothing -> record ] {
    let n = $free_energies | length
    if $n < 10 {
        return {converged: false iterations: $n}
    }
    
    # Check if free energy has stabilized
    let last_10 = $free_energies | range ($n - 10)..<$n
    let mean_last = $last_10 | math avg
    let var_last = $last_10 | each {|x| ($x - $mean_last) ** 2 } | math avg
    
    # Check monotonic decrease (within tolerance)
    let first_half = $free_energies | range 0..<($n / 2 | into int)
    let second_half = $free_energies | range ($n / 2 | into int)..<$n
    let mean_first = $first_half | math avg
    let mean_second = $second_half | math avg
    
    let is_decreasing = $mean_second < $mean_first
    let is_stable = $var_last < 0.01 * ($mean_last | math abs)
    
    {
        converged: ($is_decreasing and $is_stable)
        iterations: $n
        variance_last_10: $var_last
        mean_first_half: $mean_first
        mean_second_half: $mean_second
        improvement: ($mean_first - $mean_second)
    }
}

# =============================================================================
# Complexity-Accuracy Tradeoff Analysis
# =============================================================================

# Analyze the complexity-accuracy tradeoff in free energy minimization
export def complexity-accuracy-tradeoff [
    free_energy_trace: record    # Result from track-free-energy
]: [ nothing -> record ] {
    let complexity = $free_energy_trace.complexity_history
    let accuracy = $free_energy_trace.accuracy_history
    let free_energy = $free_energy_trace.free_energy_history
    
    let n = $complexity | length
    
    # Compute correlation between complexity and accuracy
    let mean_c = $complexity | math avg
    let mean_a = $accuracy | math avg
    
    mut cov_ca = 0.0
    mut var_c = 0.0
    mut var_a = 0.0
    
    for i in 0..<$n {
        let c = $complexity | get $i
        let a = $accuracy | get $i
        let dc = $c - $mean_c
        let da = $a - $mean_a
        
        $cov_ca = $cov_ca + $dc * $da
        $var_c = $var_c + $dc * $dc
        $var_a = $var_a + $da * $da
    }
    
    $cov_ca = $cov_ca / ($n | into float)
    $var_c = $var_c / ($n | into float)
    $var_a = $var_a / ($n | into float)
    
    let correlation = if ($var_c > 0) and ($var_a > 0) {
        $cov_ca / (($var_c * $var_a) | math sqrt)
    } else {
        0.0
    }
    
    # Compute efficiency: accuracy per unit complexity
    let final_complexity = $complexity | last
    let final_accuracy = $accuracy | last
    let efficiency = if $final_complexity > 0 {
        $final_accuracy / $final_complexity
    } else {
        0.0
    }
    
    # Pareto frontier: find points that maximize accuracy - complexity tradeoff
    let pareto_points = (find-pareto-frontier $complexity $accuracy)
    
    {
        correlation: $correlation
        efficiency: $efficiency
        final_complexity: $final_complexity
        final_accuracy: $final_accuracy
        complexity_range: {min: ($complexity | math min) max: ($complexity | math max)}
        accuracy_range: {min: ($accuracy | math min) max: ($accuracy | math max)}
        pareto_optimal_points: $pareto_points
        tradeoff_balance: (if $final_complexity < $final_accuracy { "accuracy_biased" } else { "complexity_biased" })
    }
}

# Find Pareto optimal points (maximize both accuracy and minimize complexity)
def find-pareto-frontier [complexity: list, accuracy: list]: [ nothing -> list ] {
    let n = $complexity | length
    mut pareto = []
    
    for i in 0..<$n {
        let c_i = $complexity | get $i
        let a_i = $accuracy | get $i
        
        # Check if dominated by any other point
        mut dominated = false
        for j in 0..<$n {
            if $i != $j {
                let c_j = $complexity | get $j
                let a_j = $accuracy | get $j
                
                # Point j dominates i if it has lower complexity AND higher accuracy
                if ($c_j < $c_i) and ($a_j > $a_i) {
                    $dominated = true
                    break
                }
            }
        }
        
        if not $dominated {
            $pareto = ($pareto | append {index: $i complexity: $c_i accuracy: $a_i})
        }
    }
    
    $pareto
}

# =============================================================================
# Free Energy Components Analysis
# =============================================================================

# Decompose free energy into interpretable components
export def decompose-free-energy [
    generative_model: record
    recognition_density: record
    observations: list
]: [ nothing -> record ] {
    # Get components
    let fe = (calculate-free-energy $observations $recognition_density $generative_model --compute_components true)
    
    # Decompose complexity further
    let prior = $generative_model.prior
    let kl_breakdown = (decompose-kl $recognition_density $prior)
    
    # Decompose accuracy further  
    let pred_obs = expected-observations $recognition_density.mean $generative_model.likelihood
    let accuracy_breakdown = (decompose-accuracy $observations $pred_obs)
    
    {
        total_free_energy: $fe.free_energy
        complexity: {
            total: $fe.complexity
            mean_mismatch: $kl_breakdown.mean_mismatch
            variance_mismatch: $kl_breakdown.variance_mismatch
            entropy_component: $kl_breakdown.entropy
        }
        accuracy: {
            total: $fe.accuracy
            prediction_error: $accuracy_breakdown.mse
            precision_weighted_error: $accuracy_breakdown.precision_weighted
            per_observation: $accuracy_breakdown.per_observation
        }
        evidence_bound: (-$fe.free_energy)
    }
}

# Decompose KL divergence into components
def decompose-kl [q: record, p: record]: [ nothing -> record ] {
    let q_mean = $q.mean
    let q_var = 1.0 / $q.precision
    let p_mean = $p.mean
    let p_var = 1.0 / $p.precision
    
    # Mean mismatch contribution
    let mean_diff_sq = ($q_mean | zip $p_mean | each {|pair| 
        let diff = $pair.0 - $pair.1
        $diff * $diff
    } | math sum)
    let mean_mismatch = 0.5 * $mean_diff_sq / $p_var
    
    # Variance mismatch contribution
    let variance_mismatch = 0.5 * (($p_var / $q_var | math ln) + $q_var / $p_var - 1.0)
    
    # Entropy of q(s) - always negative contribution to KL
    let entropy = 0.5 * ($q_var | math ln) + 0.5 * $LN_2PI + 0.5
    
    {
        mean_mismatch: $mean_mismatch
        variance_mismatch: $variance_mismatch
        entropy: $entropy
        total: ($mean_mismatch + $variance_mismatch)
    }
}

# Decompose accuracy into components
def decompose-accuracy [obs: list, pred: list]: [ nothing -> record ] {
    let n = $obs | length
    
    mut per_obs = []
    mut sum_sq_error = 0.0
    
    for i in 0..<$n {
        let error = ($obs | get $i) - ($pred | get $i)
        let sq_error = $error * $error
        $sum_sq_error = $sum_sq_error + $sq_error
        $per_obs = ($per_obs | append {index: $i error: $error squared_error: $sq_error})
    }
    
    let mse = $sum_sq_error / ($n | into float)
    let rmse = $mse | math sqrt
    
    {
        mse: $mse
        rmse: $rmse
        precision_weighted: (-0.5 * $mse)  # Assuming unit precision
        per_observation: $per_obs
    }
}

# =============================================================================
# Free Energy Rate of Change
# =============================================================================

# Calculate rate of change of free energy (how quickly inference proceeds)
export def free-energy-rate [
    free_energy_history: list
    --time_step: float = 1.0     # Time between samples
]: [ nothing -> record ] {
    let n = $free_energy_history | length
    if $n < 2 {
        return {rate: 0 acceleration: 0}
    }
    
    # First derivative (rate of change)
    mut rates = []
    for i in 1..<$n {
        let fe_current = $free_energy_history | get $i
        let fe_previous = $free_energy_history | get ($i - 1)
        let rate = ($fe_current - $fe_previous) / $time_step
        $rates = ($rates | append $rate)
    }
    
    # Second derivative (acceleration)
    mut accelerations = []
    for i in 1..<($rates | length) {
        let rate_current = $rates | get $i
        let rate_previous = $rates | get ($i - 1)
        let accel = ($rate_current - $rate_previous) / $time_step
        $accelerations = ($accelerations | append $accel)
    }
    
    {
        rates: $rates
        mean_rate: ($rates | math avg)
        min_rate: ($rates | math min)  # Most negative = fastest decrease
        max_rate: ($rates | math max)
        accelerations: $accelerations
        mean_acceleration: ($accelerations | math avg)
        is_converging: (($rates | last) > -0.01)  # Near zero rate means converged
    }
}

# =============================================================================
# EEG Free Energy Analysis
# =============================================================================

# Analyze free energy dynamics from EEG data
export def analyze-eeg-free-energy [
    eeg-data: list
    --channel: int = 0
    --window-samples: int = 250  # 1 second at 250Hz
]: [ nothing -> record ] {
    # Extract channel data
    let signal = $eeg_data | each {|s| $s.channels | get $channel }
    
    let n_samples = $signal | length
    mut window_results = []
    
    # Analyze in windows
    for start in (seq 0 $window_samples ($n_samples - $window_samples)) {
        let end = $start + $window_samples
        let window_data = $signal | range $start..<$end
        
        # Compute prediction (simple autoregressive)
        let mean_val = $window_data | math avg
        let predictions = $window_data | each {|_| $mean_val }
        
        # Create simple recognition density (Gaussian over window)
        let variance = $window_data | each {|x| ($x - $mean_val) ** 2 } | math avg
        let precision = if $variance > 0 { 1.0 / $variance } else { 1.0 }
        
        let recognition = {
            mean: [$mean_val]
            precision: $precision
        }
        
        let prior = {
            mean: [0.0]
            precision: 0.01  # Broad prior
        }
        
        let gm = {
            prior: $prior
            likelihood: [[1.0]]
            likelihood_precision: 1.0
            predicted_observations: $predictions
        }
        
        let fe = (calculate-free-energy $window_data $recognition $gm --compute_components true)
        
        $window_results = ($window_results | append {
            window_start: $start
            window_end: $end
            free_energy: $fe.free_energy
            accuracy: $fe.accuracy
            complexity: $fe.complexity
            signal_variance: $variance
        })
    }
    
    {
        channel: $channel
        window_results: $window_results
        temporal_dynamics: {
            mean_free_energy: ($window_results | each {|w| $w.free_energy } | math avg)
            std_free_energy: ($window_results | each {|w| $w.free_energy } | math stddev)
            min_free_energy: ($window_results | each {|w| $w.free_energy } | math min)
            max_free_energy: ($window_results | each {|w| $w.free_energy } | math max)
        }
        rate_of_change: (free-energy-rate ($window_results | each {|w| $w.free_energy }))
    }
}
