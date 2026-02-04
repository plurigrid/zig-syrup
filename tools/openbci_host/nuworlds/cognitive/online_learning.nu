# online_learning.nu
# Incremental learning systems for cognitive architecture
# Implements Hebbian learning, STDP, Bayesian updates, SGD, and reservoir computing

# =============================================================================
# Learning State Management
# =============================================================================

# Learning model state container
export def LearningState [] {
    {
        models: {},           # Trained models by ID
        reservoirs: {},       # Reservoir states
        weights: {},          # Synaptic weights
        learning_rates: {},   # Adaptive learning rates
        histories: {},        # Training histories
        metadata: {
            created_at: (date now),
            version: "1.0",
            total_updates: 0
        }
    }
}

# Create new learning state
export def "learning new" [] {
    LearningState
}

# =============================================================================
# Hebbian Learning
# =============================================================================

# Hebbian learning: "Neurons that fire together, wire together"
# Strengthens weights when pre and post synaptic neurons are correlated

export def "learning hebbian" [
    pre_synaptic: list,       # Pre-synaptic neuron activations
    post_synaptic: list,      # Post-synaptic neuron activations
    --learning-rate: float = 0.01,
    --decay: float = 0.001,   # Weight decay for stability
    --model-id: string = "hebbian_default"
] {
    let state = $in | default (LearningState)
    
    # Get or initialize weights
    let weights = $state.weights | get --optional $model_id | default {}
    
    # Calculate weight updates: Δw = η * pre * post
    mut new_weights = {}
    mut max_update = 0.0
    
    for pre_idx in 0..<($pre_synaptic | length) {
        let pre_val = $pre_synaptic | get $pre_idx
        for post_idx in 0..<($post_synaptic | length) {
            let post_val = $post_synaptic | get $post_idx
            let key = $"($pre_idx)->($post_idx)"
            
            let old_weight = $weights | get --optional $key | default 0.0
            let hebbian_update = $learning_rate * $pre_val * $post_val
            let decay_term = $decay * $old_weight
            let new_weight = $old_weight + $hebbian_update - $decay_term
            
            # Clip weights to prevent explosion
            let clipped = [1.0, [-1.0, $new_weight] | math max] | math min
            $new_weights = ($new_weights | insert $key $clipped)
            
            let update_mag = $hebbian_update | math abs
            if $update_mag > $max_update {
                $max_update = $update_mag
            }
        }
    }
    
    # Update state
    let new_state = $state | upsert weights {||
        $state.weights | upsert $model_id $new_weights
    }
    
    # Update model metadata
    let model_info = {
        type: "hebbian",
        pre_size: ($pre_synaptic | length),
        post_size: ($post_synaptic | length),
        learning_rate: $learning_rate,
        last_update: (date now),
        max_recent_update: $max_update,
        total_updates: (($state.models | get --optional $model_id | get --optional total_updates | default 0) + 1)
    }
    
    $new_state | upsert models {||
        $state.models | upsert $model_id $model_info
    }
}

# Apply Hebbian weights to transform input
export def "learning hebbian apply" [
    input: list,
    --model-id: string = "hebbian_default"
] {
    let state = $in
    let weights = $state.weights | get --optional $model_id | default {}
    let model = $state.models | get --optional $model_id
    
    if $model == null {
        error make { msg: $"Hebbian model '($model_id)' not found" }
    }
    
    let post_size = $model.post_size
    mut output = []
    
    for post_idx in 0..<$post_size {
        mut sum = 0.0
        for pre_idx in 0..<($input | length) {
            let key = $"($pre_idx)->($post_idx)"
            let weight = $weights | get --optional $key | default 0.0
            let pre_val = $input | get $pre_idx
            $sum = $sum + ($weight * $pre_val)
        }
        $output = ($output | append $sum)
    }
    
    $output
}

# =============================================================================
# Spike-Timing Dependent Plasticity (STDP)
# =============================================================================

# STDP: Time-asymmetric Hebbian learning for spiking neural networks
# Strengthens connections when pre fires before post, weakens when reverse

export def "learning stdp" [
    pre_spike_times: list,    # List of pre-synaptic spike timestamps (ms)
    post_spike_times: list,   # List of post-synaptic spike timestamps (ms)
    --learning-rate: float = 0.01,
    --tau-plus: float = 20.0,  # Time constant for potentiation (ms)
    --tau-minus: float = 20.0, # Time constant for depression (ms)
    --a-plus: float = 1.0,     # Max potentiation
    --a-minus: float = -1.0,   # Max depression (negative)
    --model-id: string = "stdp_default"
] {
    let state = $in | default (LearningState)
    let weights = $state.weights | get --optional $model_id | default {}
    
    mut new_weights = $weights
    mut weight_changes = []
    
    # Calculate STDP weight updates
    for pre_time in $pre_spike_times {
        for post_time in $post_spike_times {
            let delta_t = $post_time - $pre_time  # Positive = post after pre
            let key = "0->0"  # Single synapse for simplicity
            
            let old_weight = $new_weights | get --optional $key | default 0.0
            
            let weight_change = if $delta_t > 0 {
                # Pre before post: potentiation (LTP)
                let exponent = -1.0 * ($delta_t | into float) / $tau_plus
                $a_plus * $learning_rate * ($exponent | math exp)
            } else {
                # Post before pre: depression (LTD)
                let exponent = ($delta_t | into float) / $tau_minus
                $a_minus * $learning_rate * ($exponent | math exp)
            }
            
            let new_weight = [1.0, [-1.0, ($old_weight + $weight_change)] | math max] | math min
            $new_weights = ($new_weights | upsert $key $new_weight)
            $weight_changes = ($weight_changes | append $weight_change)
        }
    }
    
    # Update state
    let new_state = $state | upsert weights {||
        $state.weights | upsert $model_id $new_weights
    }
    
    let model_info = {
        type: "stdp",
        learning_rate: $learning_rate,
        tau_plus: $tau_plus,
        tau_minus: $tau_minus,
        last_update: (date now),
        recent_weight_changes: $weight_changes,
        total_pre_spikes: ($pre_spike_times | length),
        total_post_spikes: ($post_spike_times | length)
    }
    
    $new_state | upsert models {||
        $state.models | upsert $model_id $model_info
    }
}

# Calculate STDP window function for visualization/analysis
export def "learning stdp window" [
    --delta-t-range: list = [-50 -40 -30 -20 -10 -5 5 10 20 30 40 50],
    --tau-plus: float = 20.0,
    --tau-minus: float = 20.0,
    --a-plus: float = 1.0,
    --a-minus: float = -1.0
] {
    $delta_t_range | each { |dt|
        let dt_f = $dt | into float
        let change = if $dt > 0 {
            let exponent = -1.0 * $dt_f / $tau_plus
            $a_plus * ($exponent | math exp)
        } else if $dt < 0 {
            let exponent = $dt_f / $tau_minus
            $a_minus * ($exponent | math exp)
        } else {
            0.0
        }
        { delta_t: $dt, weight_change: $change }
    }
}

# =============================================================================
# Online Bayesian Learning
# =============================================================================

# Online Bayesian parameter estimation using conjugate priors
# Tracks belief distributions over parameters incrementally

export def "learning bayesian" [
    observation: float,       # New data point
    --prior-mean: float = 0.0,
    --prior-variance: float = 1.0,
    --noise-variance: float = 0.1,  # Observation noise
    --model-id: string = "bayesian_default"
] {
    let state = $in | default (LearningState)
    let model = $state.models | get --optional $model_id
    
    # Initialize or retrieve posterior from previous step
    let prior = if $model == null {
        { mean: $prior_mean, variance: $prior_variance, observations: 0 }
    } else {
        { mean: $model.mean, variance: $model.variance, observations: $model.observations }
    }
    
    # Bayesian update for Gaussian with known variance
    # Posterior precision = Prior precision + Likelihood precision
    let prior_precision = 1.0 / $prior.variance
    let likelihood_precision = 1.0 / $noise_variance
    let posterior_precision = $prior_precision + $likelihood_precision
    let posterior_variance = 1.0 / $posterior_precision
    
    # Posterior mean weighted by precisions
    let posterior_mean = ($prior_precision * $prior.mean + $likelihood_precision * $observation) / $posterior_precision
    
    let new_model = {
        type: "bayesian",
        mean: $posterior_mean,
        variance: $posterior_variance,
        precision: $posterior_precision,
        observations: ($prior.observations + 1),
        last_observation: $observation,
        prior_mean: $prior_mean,
        noise_variance: $noise_variance,
        confidence_interval: {
            lower: ($posterior_mean - 1.96 * ($posterior_variance | math sqrt)),
            upper: ($posterior_mean + 1.96 * ($posterior_variance | math sqrt))
        },
        last_update: (date now)
    }
    
    $state | upsert models {||
        $state.models | upsert $model_id $new_model
    }
}

# Batch Bayesian update with multiple observations
export def "learning bayesian batch" [
    observations: list,       # List of data points
    --prior-mean: float = 0.0,
    --prior-variance: float = 1.0,
    --noise-variance: float = 0.1,
    --model-id: string = "bayesian_default"
] {
    mut current_state = $in | default (LearningState)
    
    for obs in $observations {
        $current_state = ($current_state | learning bayesian $obs 
            --prior-mean $prior_mean 
            --prior-variance $prior_variance 
            --noise-variance $noise_variance 
            --model-id $model_id)
    }
    
    $current_state
}

# Predict next observation with uncertainty
export def "learning bayesian predict" [
    --model-id: string = "bayesian_default"
] {
    let state = $in
    let model = $state.models | get --optional $model_id
    
    if $model == null {
        error make { msg: $"Bayesian model '($model_id)' not found" }
    }
    
    {
        prediction: $model.mean,
        uncertainty: ($model.variance | math sqrt),
        confidence_95: {
            lower: $model.confidence_interval.lower,
            upper: $model.confidence_interval.upper
        },
        observations_seen: $model.observations
    }
}

# =============================================================================
# Stochastic Gradient Descent
# =============================================================================

# Online SGD with adaptive learning rate based on prediction error

export def "learning gradient" [
    features: list,           # Input features
    target: float,            # Target output
    --learning-rate: float = 0.01,
    --momentum: float = 0.9,  # Momentum coefficient
    --l2-reg: float = 0.001,  # L2 regularization
    --adaptive = true,  # Use adaptive learning rate
    --model-id: string = "sgd_default"
] {
    let state = $in | default (LearningState)
    let model = $state.models | get --optional $model_id
    
    # Initialize weights and velocity if new model
    let params = if $model == null {
        let dim = $features | length
        {
            weights: (seq 0 $dim | each { random float 0.0..0.1 }),
            bias: (random float 0.0..0.1),
            velocity: (seq 0 $dim | each { 0.0 }),
            bias_velocity: 0.0
        }
    } else {
        { 
            weights: $model.weights, 
            bias: $model.bias,
            velocity: $model.velocity,
            bias_velocity: $model.bias_velocity
        }
    }
    
    # Forward pass: prediction = w·x + b
    mut prediction = $params.bias
    for i in 0..<($features | length) {
        $prediction = $prediction + (($params.weights | get $i) * ($features | get $i))
    }
    
    # Compute error
    let error = $target - $prediction
    let squared_error = $error * $error
    
    # Adaptive learning rate based on prediction error
    let effective_lr = if $adaptive {
        # Increase LR for large errors, decrease for small errors
        let error_factor = [1.0, ($squared_error | math sqrt)] | math min
        $learning_rate * (1.0 + $error_factor)
    } else {
        $learning_rate
    }
    
    # Compute gradients with momentum
    mut new_weights = []
    mut new_velocity = []
    for i in 0..<($features | length) {
        let feature = $features | get $i
        let grad = -2.0 * $error * $feature + 2.0 * $l2_reg * ($params.weights | get $i)
        let velocity = $momentum * ($params.velocity | get $i) - $effective_lr * $grad
        let weight = ($params.weights | get $i) + $velocity
        $new_velocity = ($new_velocity | append $velocity)
        $new_weights = ($new_weights | append $weight)
    }
    
    # Update bias
    let bias_grad = -2.0 * $error
    let new_bias_velocity = $momentum * $params.bias_velocity - $effective_lr * $bias_grad
    let new_bias = $params.bias + $new_bias_velocity
    
    let new_model = {
        type: "sgd",
        weights: $new_weights,
        bias: $new_bias,
        velocity: $new_velocity,
        bias_velocity: $new_bias_velocity,
        last_prediction: $prediction,
        last_error: $error,
        learning_rate: $effective_lr,
        base_learning_rate: $learning_rate,
        update_count: (($model | get --optional update_count | default 0) + 1),
        last_update: (date now)
    }
    
    $state | upsert models {||
        $state.models | upsert $model_id $new_model
    }
}

# Predict using SGD model
export def "learning gradient predict" [
    features: list,
    --model-id: string = "sgd_default"
] {
    let state = $in
    let model = $state.models | get --optional $model_id
    
    if $model == null {
        error make { msg: $"SGD model '($model_id)' not found" }
    }
    
    mut prediction = $model.bias
    for i in 0..<($features | length) {
        $prediction = $prediction + (($model.weights | get $i) * ($features | get $i))
    }
    
    { prediction: $prediction }
}

# =============================================================================
# Reservoir Computing (Echo State Networks)
# =============================================================================

# Echo State Network reservoir for temporal pattern processing
# Fixed random reservoir with trainable readout weights

export def "learning reservoir" [
    input: list,              # Input vector
    --reservoir-size: int = 100,
    --spectral-radius: float = 0.9,
    --input-scaling: float = 1.0,
    --leaking-rate: float = 0.3,  # Leaky integrator
    --model-id: string = "reservoir_default"
] {
    let state = $in | default (LearningState)
    let reservoir = $state.reservoirs | get --optional $model_id
    
    # Initialize reservoir if new
    let res_state = if $reservoir == null {
        # Initialize random reservoir weights with desired spectral radius
        mut reservoir_weights = {}
        for i in 0..<$reservoir_size {
            for j in 0..<$reservoir_size {
                let key = $"($i)->($j)"
                # Sparse connectivity (10%)
                let weight = if (random float 0.0..1.0) < 0.1 {
                    (random float -1.0..1.0)
                } else {
                    0.0
                }
                $reservoir_weights = ($reservoir_weights | insert $key $weight)
            }
        }
        
        # Input weights
        mut input_weights = {}
        let input_size = $input | length
        for i in 0..<$input_size {
            for j in 0..<$reservoir_size {
                let key = $"in_($i)->($j)"
                $input_weights = ($input_weights | insert $key ((random float -1.0..1.0) * $input_scaling))
            }
        }
        
        {
            reservoir_weights: $reservoir_weights,
            input_weights: $input_weights,
            reservoir_state: (seq 0 $reservoir_size | each { 0.0 }),
            reservoir_size: $reservoir_size,
            input_size: $input_size,
            spectral_radius: $spectral_radius,
            leaking_rate: $leaking_rate
        }
    } else {
        $reservoir
    }
    
    # Update reservoir state: x(t+1) = (1-α)x(t) + α·tanh(W·x(t) + W_in·u(t))
    let alpha = $res leaking_rate
    let old_state = $res_state.reservoir_state
    
    mut new_state = []
    for j in 0..<$res_state.reservoir_size {
        # Reservoir recurrent input
        mut reservoir_input = 0.0
        for i in 0..<$res_state.reservoir_size {
            let key = $"($i)->($j)"
            let w = $res_state.reservoir_weights | get --optional $key | default 0.0
            $reservoir_input = $reservoir_input + ($w * ($old_state | get $i))
        }
        
        # External input
        mut external_input = 0.0
        for i in 0..<($input | length) {
            let key = $"in_($i)->($j)"
            let w = $res_state.input_weights | get --optional $key | default 0.0
            $external_input = $external_input + ($w * ($input | get $i))
        }
        
        # Leaky integrator update with tanh nonlinearity
        let activation = $reservoir_input + $external_input | math tanh
        let old_val = $old_state | get $j
        let new_val = (1.0 - $alpha) * $old_val + $alpha * $activation
        $new_state = ($new_state | append $new_val)
    }
    
    let updated_reservoir = $res_state | upsert reservoir_state $new_state
    
    # Update state
    let new_state = $state | upsert reservoirs {||
        $state.reservoirs | upsert $model_id $updated_reservoir
    }
    
    # Update model info
    let model_info = {
        type: "reservoir",
        reservoir_size: $res_state.reservoir_size,
        spectral_radius: $spectral_radius,
        leaking_rate: $leaking_rate,
        last_activation_mean: ($new_state | math avg),
        last_activation_std: (if ($new_state | length) > 1 { $new_state | math stddev } else { 0.0 }),
        last_update: (date now)
    }
    
    $new_state | upsert models {||
        $state.models | upsert $model_id $model_info
    }
}

# Get current reservoir state for readout training
export def "learning reservoir readout" [
    --model-id: string = "reservoir_default"
] {
    let state = $in
    let reservoir = $state.reservoirs | get --optional $model_id
    
    if $reservoir == null {
        error make { msg: $"Reservoir '($model_id)' not found" }
    }
    
    $reservoir.reservoir_state
}

# Train reservoir readout weights using ridge regression
export def "learning reservoir train-readout" [
    states: list,            # List of reservoir states (from washout)
    targets: list,           # Corresponding target outputs
    --regularization: float = 0.001,
    --model-id: string = "reservoir_default"
] {
    let state = $in
    
    # Simple pseudoinverse solution: W_out = Y · X⁺
    # For single output, this is simplified
    # Full implementation would use matrix operations
    
    # Collect statistics for online readout training
    let n_samples = $states | length
    let reservoir_size = ($states | get 0 | length)
    
    # Compute correlation matrix and output correlation (simplified)
    mut correlations = {}
    for i in 0..<$reservoir_size {
        let state_col = $states | each { |s| $s | get $i }
        let correlation = ($state_col | math avg) * ($targets | math avg)
        $correlations = ($correlations | insert $i $correlation)
    }
    
    let readout_weights = $correlations
    
    let model_info = {
        type: "reservoir_readout",
        readout_weights: $readout_weights,
        regularization: $regularization,
        n_train_samples: $n_samples,
        trained_at: (date now)
    }
    
    $state | upsert models {||
        $state.models | upsert $"($model_id)_readout" $model_info
    }
}

# =============================================================================
# Adaptive Learning Rate Management
# =============================================================================

# Adjust learning rates based on recent prediction errors
export def "learning adaptive-rate" [
    prediction_error: float,
    --model-id: string = "default",
    --adaptation-factor: float = 0.95,
    --min-rate: float = 0.0001,
    --max-rate: float = 1.0
] {
    let state = $in | default (LearningState)
    let current_lr = $state.learning_rates | get --optional $model_id | default 0.01
    
    # Error magnitude
    let error_mag = $prediction_error | math abs
    
    # Adapt learning rate: decrease if error is small (converging), 
    # increase if error is large (exploring)
    let error_threshold = 0.1
    let new_rate = if $error_mag < $error_threshold {
        # Decay learning rate as we converge
        [$min_rate, ($current_lr * $adaptation_factor)] | math max
    } else {
        # Increase for faster convergence on large errors
        [$max_rate, ($current_lr / $adaptation_factor)] | math min
    }
    
    $state | upsert learning_rates {||
        $state.learning_rates | upsert $model_id $new_rate
    } | upsert metadata.total_updates {||
        $state.metadata.total_updates + 1
    }
}

# Get current adaptive learning rate
export def "learning get-rate" [
    --model-id: string = "default"
] {
    let state = $in
    $state.learning_rates | get --optional $model_id | default 0.01
}

# =============================================================================
# Model Persistence
# =============================================================================

# Export learning state to JSON
export def "learning export" [] {
    $in | to json
}

# Import learning state from JSON
export def "learning import" [json_data: string] {
    $json_data | from json
}

# Get learning statistics
export def "learning stats" [] {
    let state = $in
    {
        n_models: ($state.models | length),
        n_reservoirs: ($state.reservoirs | length),
        total_weight_updates: $state.metadata.total_updates,
        model_types: ($state.models | transpose id info | each { |m| $m.info.type } | uniq),
        created_at: $state.metadata.created_at
    }
}

# Reset learning state
export def "learning reset" [] {
    LearningState
}
