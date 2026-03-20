# active_inference.nu
# Free Energy Principle implementation for Active Inference
# Perceptual inference and active inference for brain-computer interfaces
#
# This module implements the computational foundations of Active Inference
# based on Karl Friston's Free Energy Principle, connecting bifurcations
# to perception-action cycles via precision-weighted prediction errors.

use std log

# =============================================================================
# Generative Model Types and Constants
# =============================================================================

# Default generative model parameters
export const DEFAULT_PRIOR_PRECISION = 1.0
export const DEFAULT_LIKELICHOOD_PRECISION = 1.0
export const DEFAULT_LEARNING_RATE = 0.01
export const DEFAULT_TEMPERATURE = 1.0

# Active inference modes
export const INFERENCE_MODES = {
    perceptual: "State estimation via variational inference"
    active: "Action selection via expected free energy"
    learning: "Parameter learning via gradient descent"
    planning: "Policy selection via tree search"
}

# =============================================================================
# Generative Model Definition
# =============================================================================

# Define a generative model p(o,s) = p(o|s) * p(s)
# where o = observations, s = hidden states
export def "inference generative-model" [
    --prior-mean: list = []       # Prior mean over hidden states
    --prior-precision: float = $DEFAULT_PRIOR_PRECISION  # Prior precision (inverse variance)
    --likelihood-matrix: list = []  # p(o|s) likelihood mapping
    --likelihood-precision: float = $DEFAULT_LIKELICHOOD_PRECISION
    --n-states: int = 8           # Number of discrete hidden states
    --n-observations: int = 16    # Number of observation dimensions
]: [ nothing -> record ] {
    # Create default prior if not provided
    let prior_m = if ($prior_mean | is-empty) {
        seq 0 $n_states | each { random float 0..1 } | normalize-distribution
    } else {
        $prior_mean | normalize-distribution
    }
    
    # Create default likelihood if not provided
    let likelihood = if ($likelihood_matrix | is-empty) {
        # Random likelihood matrix (n_observations x n_states)
        seq 0 $n_observations | each {|_| 
            seq 0 $n_states | each { random float 0..1 } | normalize-distribution
        }
    } else {
        $likelihood_matrix
    }
    
    # Construct generative model
    {
        type: "generative_model"
        n_states: $n_states
        n_observations: $n_observations
        prior: {
            mean: $prior_m
            precision: $prior_precision
        }
        likelihood: $likelihood
        likelihood_precision: $likelihood_precision
        parameters: {
            A_matrix: $likelihood  # Sensory mapping
            B_tensors: []          # Transition matrices (for dynamic models)
            C_preferences: []      # Prior preferences over outcomes
            D_prior: $prior_m      # Initial state prior
        }
        created: (date now | format date "%Y-%m-%d %H:%M:%S")
    }
}

# Normalize a probability distribution (sum to 1)
def normalize-distribution []: [ list -> list ] {
    let probs = $in
    let sum_probs = ($probs | math sum)
    if $sum_probs > 0 {
        $probs | each {|p| $p / $sum_probs }
    } else {
        # Return uniform distribution if sum is zero
        let n = $probs | length
        seq 0 $n | each { 1.0 / ($n | into float) }
    }
}

# Softmax function for converting log probabilities to probabilities
export def softmax [
    --precision: float = 1.0  # Temperature/precision parameter
]: [ list -> list ] {
    let logits = $in
    let max_logit = ($logits | math max)
    let exp_shifted = ($logits | each {|x| ($x - $max_logit) * $precision | math exp })
    let sum_exp = ($exp_shifted | math sum)
    $exp_shifted | each {|e| $e / $sum_exp }
}

# =============================================================================
# Variational Free Energy Minimization
# =============================================================================

# Perform variational inference to minimize free energy
# F = E_q[ln q(s) - ln p(o,s)] = D_KL[q(s)||p(s|o)] - ln p(o)
export def "inference variational" [
    generative_model: record     # Generative model p(o,s)
    observations: list           # Observed data
    --max-iterations: int = 100  # Maximum inference iterations
    --tolerance: float = 0.0001  # Convergence tolerance
    --learning-rate: float = $DEFAULT_LEARNING_RATE
]: [ nothing -> record ] {
    let gm = $generative_model
    let n_states = $gm.n_states
    
    # Initialize variational distribution q(s) ~ N(mu, sigma)
    mut q_mean = $gm.prior.mean
    mut q_precision = $gm.prior.precision
    mut free_energies = []
    mut converged = false
    mut iteration = 0
    
    log info "Starting variational inference..."
    
    while ($iteration < $max_iterations) and (not $converged) {
        # Compute prediction error (sensory - expected)
        let predicted_obs = (expected-observations $q_mean $gm.likelihood)
        let prediction_error = ($observations | zip $predicted_obs | each {|p| $p.0 - $p.1 })
        
        # Compute precision-weighted prediction error
        let weighted_error = ($prediction_error | each {|e| $e * $gm.likelihood_precision })
        
        # Update variational mean (gradient descent on free energy)
        # dF/dmu = precision * prediction_error + prior_precision * (mu - prior)
        let prior_error = ($q_mean | zip $gm.prior.mean | each {|p| $p.0 - $p.1 })
        let gradient = ($weighted_error | zip $prior_error | each {|p| 
            $p.0 + $gm.prior.precision * $p.1
        })
        
        let new_q_mean = ($q_mean | zip $gradient | each {|p| 
            $p.0 - $learning_rate * $p.1
        } | normalize-distribution)
        
        # Compute free energy for convergence check
        let fe = (compute-free-energy $q_mean $gm $observations)
        $free_energies = ($free_energies | append $fe)
        
        # Check convergence
        if ($iteration > 0) {
            let delta = ($free_energies | last) - ($free_energies | get (($free_energies | length) - 2))
            if ($delta | math abs) < $tolerance {
                $converged = true
            }
        }
        
        $q_mean = $new_q_mean
        $iteration = $iteration + 1
    }
    
    log info $"Variational inference converged after ($iteration) iterations"
    
    {
        posterior: {
            mean: $q_mean
            precision: $q_precision
        }
        free_energy_history: $free_energies
        final_free_energy: ($free_energies | last)
        iterations: $iteration
        converged: $converged
        observations: $observations
        model: $gm
    }
}

# Compute expected observations from state beliefs
export def expected-observations [state_beliefs: list, likelihood_matrix: list]: [ nothing -> list ] {
    mut expected = []
    
    for obs_idx in 0..<($likelihood_matrix | length) {
        let likelihood_given_state = ($likelihood_matrix | get $obs_idx)
        let expected_val = ($likelihood_given_state | zip $state_beliefs 
            | each {|p| $p.0 * $p.1 } | math sum)
        $expected = ($expected | append $expected_val)
    }
    
    $expected
}

# Compute variational free energy F = E_q[ln q - ln p(o,s)]
def compute-free-energy [q_mean: list, gm: record, observations: list]: [ nothing -> float ] {
    # Energy term: -E_q[ln p(o,s)]
    let log_prior = ($q_mean | each {|s| if $s > 0 { $s | math ln } else { -1000 } } | math sum)
    
    let log_likelihood = compute-log-likelihood $q_mean $gm.likelihood $observations
    let energy = -($log_prior + $log_likelihood)
    
    # Entropy term: E_q[ln q]
    let entropy = ($q_mean | each {|s| if $s > 0 { -$s * ($s | math ln) } else { 0 } } | math sum)
    
    # Free energy = Energy - Entropy
    $energy - $entropy
}

# Compute log likelihood of observations given state beliefs
def compute-log-likelihood [state_beliefs: list, likelihood_matrix: list, observations: list]: [ nothing -> float ] {
    mut log_lik = 0.0
    
    for obs_idx in 0..<($observations | length) {
        let obs = ($observations | get $obs_idx)
        let likelihood_given_state = ($likelihood_matrix | get $obs_idx)
        let expected_obs = ($likelihood_given_state | zip $state_beliefs 
            | each {|p| $p.0 * $p.1 } | math sum)
        
        # Gaussian log likelihood
        let diff = $obs - $expected_obs
        $log_lik = $log_lik - 0.5 * $diff * $diff
    }
    
    $log_lik
}

# =============================================================================
# Predictive Coding Updates
# =============================================================================

# Predictive coding: hierarchical message passing with precision weighting
export def "inference predictive-coding" [
    observations: list           # Bottom-up sensory input
    prior_predictions: list      # Top-down predictions
    --precisions: record = {}    # Precision weights per level
    --learning-rate: float = 0.1
    --n-levels: int = 3          # Number of hierarchical levels
]: [ nothing -> record ] {
    let default_precisions = {
        level0: 1.0   # Sensory precision (high)
        level1: 0.5   # Intermediate precision
        level2: 0.1   # Prior precision (low)
    }
    let prec = $precisions | default $default_precisions
    
    mut levels = []
    mut current_input = $observations
    
    # Initialize hierarchical levels
    for level in 0..<$n_levels {
        let precision = ($prec | get -o $"level($level)" | default 0.5)
        let prediction = if $level < ($prior_predictions | length) {
            $prior_predictions | get $level
        } else {
            # Generate prediction for this level
            $current_input | each {|x| $x * 0.9 }  # Simple prediction function
        }
        
        # Compute prediction error at this level
        let epsilon = ($current_input | zip $prediction | each {|p| $p.0 - $p.1 })
        let weighted_error = ($epsilon | each {|e| $e * $precision })
        
        # Update representation (simplified)
        let representation = ($prediction | zip $weighted_error | each {|p| 
            $p.0 + $learning_rate * $p.1
        })
        
        $levels = ($levels | append {
            level: $level
            precision: $precision
            prediction: $prediction
            prediction_error: $epsilon
            weighted_error: $weighted_error
            representation: $representation
        })
        
        # Pass representation up as input to next level
        $current_input = $representation
    }
    
    {
        levels: $levels
        top_down_predictions: $prior_predictions
        bottom_up_errors: ($levels | each {|l| $l.prediction_error })
        final_representation: ($levels | last | get representation)
        total_prediction_error: ($levels | each {|l| 
            $l.prediction_error | each {|e| $e * $e } | math sum
        } | math sum)
    }
}

# Update precision weights based on prediction error history (meta-learning)
export def update-precision [
    current_precisions: record
    prediction_errors: list      # Recent prediction errors
    --adaptation_rate: float = 0.01
]: [ nothing -> record ] {
    mut new_precisions = {}
    
    for key in ($current_precisions | columns) {
        let current_prec = ($current_precisions | get $key)
        let avg_error = ($prediction_errors | math avg)
        
        # Increase precision if error is low, decrease if high
        let error_modulation = 1.0 / (1.0 + $avg_error)
        let new_prec = ($current_prec * (1.0 - $adaptation_rate)) + ($error_modulation * $adaptation_rate)
        
        $new_precisions = ($new_precisions | insert $key (if $new_prec > 0.01 { $new_prec } else { 0.01 }))
    }
    
    $new_precisions
}

# =============================================================================
# Policy Selection (Active Inference)
# =============================================================================

# Select actions/policies that minimize expected free energy
export def "inference policy-selection" [
    generative_model: record     # Generative model with transitions
    current_state_beliefs: list  # Current posterior over states
    available_policies: list     # List of policy (action sequence) candidates
    --horizon: int = 5           # Planning horizon (steps ahead)
    --temperature: float = $DEFAULT_TEMPERATURE
    --mode: string = "efe"       # "efe" (explore+exploit) or "kl" (exploit only)
]: [ nothing -> record ] {
    mut policy_values = []
    
    for policy in $available_policies {
        # Compute expected free energy for this policy
        let efe = (compute-expected-free-energy $generative_model $current_state_beliefs $policy $horizon $mode)
        
        $policy_values = ($policy_values | append {
            policy: $policy
            expected_free_energy: $efe
            value: (-$efe)  # Negative EFE is value
        })
    }
    
    # Softmax selection over policies
    let values = ($policy_values | each {|p| $p.value })
    let inv_temp = -1.0 / $temperature
    let policy_probs = ($values | softmax --precision $inv_temp)
    
    # Assign probabilities to policies
    let policies_with_probs = ($policy_values | enumerate | each {|entry| 
        let prob = ($policy_probs | get $entry.index)
        $entry.item | insert probability $prob
    })
    
    # Select best policy
    let best_policy = ($policies_with_probs | sort-by value | last)
    
    {
        policies: $policies_with_probs
        selected_policy: $best_policy
        selection_entropy: ($policy_probs | each {|p| if $p > 0 { -$p * ($p | math ln) } else { 0 } } | math sum)
        temperature: $temperature
        horizon: $horizon
        mode: $mode
    }
}

# Compute Expected Free Energy G(π) for a given policy
export def "inference expected-free-energy" [
    generative_model: record
    initial-state: list
    policy: list                 # Action sequence
    --horizon: int = 5
    --mode: string = "efe"       # "efe" or "kl"
]: [ nothing -> float ] {
    compute-expected-free-energy $generative_model $initial_state $policy $horizon $mode
}

# Internal function to compute EFE
export def compute-expected-free-energy [gm: record, initial_state: list, policy: list, horizon: int, mode: string]: [ nothing -> float ] {
    mut total_efe = 0.0
    mut state_beliefs = $initial_state
    
    for tau in 0..<$horizon {
        # Get action at this time step
        let action = if $tau < ($policy | length) {
            $policy | get $tau
        } else {
            0  # Default/no-op action
        }
        
        # Predict next state given action (using B tensor if available)
        let next_state = (predict-next-state $state_beliefs $action $gm)
        
        # Predict expected observations
        let expected_obs = (expected-observations $next_state $gm.likelihood)
        
        # Compute EFE components
        # 1. Expected ambiguity (entropy of p(o|s))
        let ambiguity = (compute-ambiguity $gm $next_state)
        
        # 2. Risk (KL divergence between predicted and preferred outcomes)
        let risk = (compute-risk $expected_obs $gm)
        
        # 3. Information gain (expected reduction in uncertainty)
        let info_gain = if $mode == "efe" {
            (compute-information-gain $state_beliefs $next_state)
        } else {
            0.0
        }
        
        # Total EFE for this time step
        let step_efe = $ambiguity + $risk - $info_gain
        $total_efe = $total_efe + $step_efe
        
        $state_beliefs = $next_state
    }
    
    $total_efe
}

# Predict next state given current state and action
def predict-next-state [current_state: list, action: int, gm: record]: [ nothing -> list ] {
    if ($gm.parameters.B_tensors | is-not-empty) and ($action < ($gm.parameters.B_tensors | length)) {
        # Use transition matrix for this action
        let B = ($gm.parameters.B_tensors | get $action)
        # s' = B * s (matrix multiplication)
        matrix-vector-mul $B $current_state | normalize-distribution
    } else {
        # Default: small diffusion
        $current_state | each {|s| $s * 0.95 + 0.05 / ($current_state | length) }
    }
}

# Simple matrix-vector multiplication
def matrix-vector-mul [matrix: list, vector: list]: [ nothing -> list ] {
    $matrix | each {|row| 
        $row | zip $vector | each {|p| $p.0 * $p.1 } | math sum
    }
}

# Compute expected ambiguity (entropy of likelihood)
def compute-ambiguity [gm: record, state: list]: [ nothing -> float ] {
    # Simplified: variance of observations given state
    0.5 / $gm.likelihood_precision
}

# Compute risk as KL divergence between predicted and preferred outcomes
def compute-risk [predicted_obs: list, gm: record]: [ nothing -> float ] {
    let preferences = if ($gm.parameters.C_preferences | is-empty) {
        # Uniform preferences if not specified
        $predicted_obs | each { 1.0 / ($predicted_obs | length) }
    } else {
        $gm.parameters.C_preferences
    }
    
    # KL divergence D_KL[predicted || preferred]
    mut kl = 0.0
    for i in 0..<($predicted_obs | length) {
        let p = $predicted_obs | get $i
        let q = $preferences | get $i
        if $p > 0 {
            kl = $kl + $p * (($p | math ln) - ($q | math ln))
        }
    }
    $kl
}

# Compute expected information gain
def compute-information-gain [old_state: list, new_state: list]: [ nothing -> float ] {
    # Simplified: reduction in entropy
    let old_entropy = ($old_state | each {|s| if $s > 0 { -$s * ($s | math ln) } else { 0 } } | math sum)
    let new_entropy = ($new_state | each {|s| if $s > 0 { -$s * ($s | math ln) } else { 0 } } | math sum)
    $old_entropy - $new_entropy
}

# =============================================================================
# Perceptual and Active Inference Pipelines
# =============================================================================

# Complete perceptual inference pipeline
export def perceptual-inference [
    observations: list           # Sensory observations
    --n-states: int = 8          # Number of hidden states
    --max-iterations: int = 100
    --return-full: bool = false  # Return full inference record
]: [ nothing -> record ] {
    # Create generative model
    let gm = (inference generative-model --n-states $n_states --n-observations ($observations | length))
    
    # Run variational inference
    let result = (inference variational $gm $observations --max-iterations $max_iterations)
    
    if $return_full {
        $result
    } else {
        {
            posterior: $result.posterior
            free_energy: $result.final_free_energy
            converged: $result.converged
            confidence: ($result.posterior.precision | math min 10.0)
        }
    }
}

# Complete active inference pipeline (perception + action)
export def active-inference-step [
    observations: list
    current-state: list
    available-actions: list
    --n-policies: int = 4        # Number of policy candidates to generate
    --horizon: int = 3
]: [ nothing -> record ] {
    # Step 1: Perceptual inference (update beliefs)
    let percept = (perceptual-inference $observations --return-full)
    let current_beliefs = $percept.posterior.mean
    
    # Step 2: Generate candidate policies
    let policies = (generate-policies $available_actions $n_policies $horizon)
    
    # Step 3: Policy selection
    let gm = (inference generative-model)
    let policy_result = (inference policy-selection $gm $current_beliefs $policies --horizon $horizon)
    
    {
        perception: $percept
        action_selection: $policy_result
        selected_action: $policy_result.selected_policy.policy.0  # First action of best policy
        expected_outcome: (predict-next-state $current_beliefs ($policy_result.selected_policy.policy.0) $gm)
        free_energy: $percept.free_energy
    }
}

# Generate random policy candidates
def generate-policies [actions: list, n_policies: int, horizon: int]: [ nothing -> list ] {
    mut policies = []
    
    for i in 0..<$n_policies {
        mut policy = []
        for tau in 0..<$horizon {
            let action_idx = (random int 0..<($actions | length))
            let action = ($actions | get $action_idx)
            $policy = ($policy | append $action)
        }
        $policies = ($policies | append [$policy])
    }
    
    $policies
}

# =============================================================================
# Precision and Attention Mechanisms
# =============================================================================

# Precision-weighted prediction error computation
export def precision-weighted-pe [
    prediction_errors: list      # Raw prediction errors
    sensory-precision: float     # Precision of sensory input
    --precision-map: list = []   # Channel-specific precisions
]: [ nothing -> record ] {
    let n_channels = $prediction_errors | length
    
    # Create precision map if not provided
    let precisions = if ($precision_map | is-empty) {
        seq 0 $n_channels | each {|_| $sensory_precision }
    } else {
        $precision_map
    }
    
    # Apply precision weighting
    let weighted_errors = ($prediction_errors | zip $precisions | each {|p| 
        $p.0 * $p.1  # error * precision
    })
    
    # Compute total precision-weighted error
    let total_pwpe = ($weighted_errors | each {|e| $e * $e } | math sum | math sqrt)
    
    {
        raw_errors: $prediction_errors
        precisions: $precisions
        weighted_errors: $weighted_errors
        total_pwpe: $total_pwpe
        effective_precision: ($precisions | math avg)
        attention_focus: ($precisions | enumerate | sort-by item | last | get index)  # Highest precision channel
    }
}

# Dynamic precision updating (attention modulation)
export def update-attention [
    current_precisions: list
    prediction_errors: list
    --adaptation_rate: float = 0.1
    --min-precision: float = 0.1
    --max-precision: float = 10.0
]: [ nothing -> list ] {
    mut new_precisions = []
    
    for i in 0..<($current_precisions | length) {
        let current_prec = ($current_precisions | get $i)
        let error = ($prediction_errors | get $i | math abs)
        
        # Precision increases when error is predictable, decreases when surprising
        # This implements "precision engineering" or attention
        let prediction_of_error = 0.5  # Expected error level
        let surprise = ($error - $prediction_of_error) | math abs
        
        # Update precision: reduce precision for surprising input (sensory attenuation)
        let new_prec = $current_prec * (1.0 - $adaptation_rate) + (1.0 / (1.0 + $surprise)) * $adaptation_rate
        let clamped_prec = ($new_prec | math max $min_precision | math min $max_precision)
        
        $new_precisions = ($new_precisions | append $clamped_prec)
    }
    
    $new_precisions
}
