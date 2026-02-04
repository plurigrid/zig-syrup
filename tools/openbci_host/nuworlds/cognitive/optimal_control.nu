# optimal_control.nu
# Optimal Control Strategies for nuworlds cognitive control
# MPC, LQR, iLQR, PID, Reinforcement Learning, Bifurcation-based control

# =============================================================================
# Model Predictive Control (MPC)
# =============================================================================

# Create MPC controller
export def "control mpc" [
    --horizon: int = 10        # Prediction horizon
    --dt: float = 0.1          # Time step
    --state-dim: int = 2       # State dimension
    --control-dim: int = 1     # Control input dimension
    --weights: record = {}     # Cost function weights
]: [ nothing -> record ] {
    let default_weights = {
        Q: (diagonal-matrix $state_dim 1.0)     # State cost
        R: (diagonal-matrix $control_dim 0.1)   # Control cost
        Qf: (diagonal-matrix $state_dim 10.0)   # Terminal cost
    }
    let W = ($weights | merge $default_weights)
    
    {
        type: "mpc"
        horizon: $horizon
        dt: $dt
        state_dim: $state_dim
        control_dim: $control_dim
        weights: $W
        state_constraints: null
        control_constraints: {
            u_min: (seq 0 $control_dim | each {|_| -10.0} | take $control_dim)
            u_max: (seq 0 $control_dim | each {|_| 10.0} | take $control_dim)
        }
        reference: (seq 0 $state_dim | each {|_| 0.0} | take $state_dim)
        initialized: true
    }
}

# Solve MPC optimization for current state
export def "mpc solve" [
    state: list                # Current state
    dynamics: closure          # System dynamics: f(x, u) -> dx/dt
    --controller: record = {}  # MPC controller (or use input)
]: [ list -> record ] {
    let ctrl = (if ($controller | is-empty) { $in } else { $controller })
    
    # Initialize optimization variables
    mut U = (seq 0 $ctrl.horizon | each {|_| 
        seq 0 $ctrl.control_dim | each {|_| 0.0} | take $ctrl.control_dim
    })
    
    # Simple gradient descent for control sequence
    let learning_rate = 0.1
    let iterations = 50
    
    mut current_cost = 1e10
    
    for iter in 0..<$iterations {
        # Forward simulate with current control sequence
        let trajectory = (mpc-forward-sim $state $U $ctrl $dynamics)
        
        # Calculate cost
        let cost = (mpc-calculate-cost $trajectory $U $ctrl)
        
        if $cost < $current_cost {
            $current_cost = $cost
        }
        
        # Gradient descent on control (simplified)
        # In practice, use iLQR or QP solver
        $U = (mpc-gradient-step $U $trajectory $ctrl $learning_rate)
        
        # Apply control constraints
        $U = (mpc-apply-constraints $U $ctrl.control_constraints)
    }
    
    # Return first control action
    let optimal_u = ($U | first)
    
    {
        control: $optimal_u
        control_sequence: $U
        predicted_trajectory: $trajectory
        predicted_cost: $current_cost
        horizon: $ctrl.horizon
    }
}

# Update MPC reference trajectory
export def "mpc set-reference" [
    reference: list            # Reference state
]: [ record -> record ] {
    let controller = $in
    $controller | upsert reference $reference
}

# Set state constraints for MPC
export def "mpc set-constraints" [
    x_min: list                # Minimum state bounds
    x_max: list                # Maximum state bounds
    u_min: list                # Minimum control bounds
    u_max: list                # Maximum control bounds
]: [ record -> record ] {
    let controller = $in
    $controller 
    | upsert state_constraints {min: $x_min, max: $x_max}
    | upsert control_constraints {min: $u_min, max: $u_max}
}

# =============================================================================
# Linear Quadratic Regulator (LQR)
# =============================================================================

# Create LQR controller
export def "control lqr" [
    A: list                    # State matrix
    B: list                    # Input matrix
    --Q: list = null           # State cost matrix
    --R: list = null           # Control cost matrix
    --solve-method: string = "riccati"  # riccati, iterative
]: [ nothing -> record ] {
    let n = ($A | length)      # State dimension
    let m = ($B.0 | length)    # Control dimension
    
    let Q_mat = (if $Q == null { diagonal-matrix $n 1.0 } else { $Q })
    let R_mat = (if $R == null { diagonal-matrix $m 0.1 } else { $R })
    
    # Solve Algebraic Riccati Equation: A^T P + P A - P B R^{-1} B^T P + Q = 0
    let P = (solve-riccati $A $B $Q_mat $R_mat $solve_method)
    
    # Compute optimal gain: K = R^{-1} B^T P
    let K = (compute-lqr-gain $A $B $P $R_mat)
    
    {
        type: "lqr"
        A: $A
        B: $B
        Q: $Q_mat
        R: $R_mat
        P: $P
        K: $K
        state_dim: $n
        control_dim: $m
        is_stable: (check-lqr-stability $A $B $K)
    }
}

# Compute LQR control action
export def "lqr control" [
    state: list                # Current state
    --controller: record = {}  # LQR controller
]: [ list -> record ] {
    let ctrl = (if ($controller | is-empty) { $in } else { $controller })
    
    # u = -K * x
    let u = (matrix-vector-multiply-neg $ctrl.K $state)
    
    {
        control: $u
        control_norm: (vector-norm $u)
        state_cost: (quadratic-form $state $ctrl.Q)
        value_function: (quadratic-form $state $ctrl.P)
        is_optimal: true
    }
}

# Discrete-time LQR
export def "control lqr discrete" [
    Ad: list                   # Discrete state matrix
    Bd: list                   # Discrete input matrix
    --Q: list = null           # State cost matrix
    --R: list = null           # Control cost matrix
    --horizon: int = 100       # Finite horizon (0 for infinite)
]: [ nothing -> record ] {
    let n = ($Ad | length)
    let m = ($Bd.0 | length)
    
    let Q_mat = (if $Q == null { diagonal-matrix $n 1.0 } else { $Q })
    let R_mat = (if $R == null { diagonal-matrix $m 0.1 } else { $R })
    
    if $horizon > 0 {
        # Finite horizon - backward recursion
        let result = (solve-dlqr-finite $Ad $Bd $Q_mat $R_mat $horizon)
        {
            type: "lqr_discrete_finite"
            Ad: $Ad
            Bd: $Bd
            Q: $Q_mat
            R: $R_mat
            P_sequence: $result.P_seq
            K_sequence: $result.K_seq
            horizon: $horizon
            state_dim: $n
            control_dim: $m
        }
    } else {
        # Infinite horizon
        let P = (solve-dlqr-infinite $Ad $Bd $Q_mat $R_mat)
        let K = (compute-dlqr-gain $Ad $Bd $P $R_mat)
        
        {
            type: "lqr_discrete_infinite"
            Ad: $Ad
            Bd: $Bd
            Q: $Q_mat
            R: $R_mat
            P: $P
            K: $K
            state_dim: $n
            control_dim: $m
            is_stable: (check-dlqr-stability $Ad $Bd $K)
        }
    }
}

# =============================================================================
# Iterative LQR (iLQR) for Nonlinear Systems
# =============================================================================

# Create iLQR controller for nonlinear trajectory optimization
export def "control ilqr" [
    --horizon: int = 50        # Time horizon
    --dt: float = 0.02         # Time step
    --state-dim: int = 4       # State dimension
    --control-dim: int = 2     # Control dimension
    --max-iter: int = 50       # Maximum iterations
    --tolerance: float = 1e-6  # Convergence tolerance
]: [ nothing -> record ] {
    {
        type: "ilqr"
        horizon: $horizon
        dt: $dt
        state_dim: $state_dim
        control_dim: $control_dim
        max_iterations: $max_iter
        tolerance: $tolerance
        regularization: 1.0
        line_search_gamma: 0.5
        line_search_beta: 0.5
        initialized: false
    }
}

# Solve trajectory optimization using iLQR
export def "ilqr solve" [
    x0: list                   # Initial state
    x_goal: list               # Goal state
    dynamics: closure          # Nonlinear dynamics: f(x, u) -> x_next
    cost: closure              # Cost function: c(x, u) -> scalar
    --controller: record = {}  # iLQR controller
]: [ nothing -> record ] {
    let ctrl = (if ($controller | is-empty) { $in } else { $controller })
    
    # Initialize with simple trajectory
    mut X = (seq 0 $ctrl.horizon | each {|i|
        interpolate-state $x0 $x_goal ($i / $ctrl.horizon)
    })
    mut U = (seq 0 $ctrl.horizon | each {|_| 
        seq 0 $ctrl.control_dim | each {|_| 0.0} | take $ctrl.control_dim
    })
    
    mut iteration = 0
    mut converged = false
    mut total_cost = 0.0
    
    while $iteration < $ctrl.max_iterations and not $converged {
        # Forward rollout
        let rollout = (ilqr-forward-rollout $X $U $x0 $dynamics $ctrl)
        $X = $rollout.states
        $U = $rollout.controls
        let new_cost = $rollout.cost
        
        # Check convergence
        if ($total_cost - $new_cost | math abs) < $ctrl.tolerance {
            $converged = true
        }
        $total_cost = $new_cost
        
        # Backward pass (compute optimal control adjustments)
        let backward = (ilqr-backward-pass $X $U $cost $dynamics $ctrl)
        
        # Update controls
        $U = (ilqr-update-controls $U $backward $ctrl)
        
        $iteration = $iteration + 1
    }
    
    {
        optimal_trajectory: $X
        optimal_controls: $U
        final_cost: $total_cost
        iterations: $iteration
        converged: $converged
        goal_reached: ((vector-distance ($X | last) $x_goal) < 0.1)
    }
}

# =============================================================================
# Adaptive PID Control with Stability Guarantees
# =============================================================================

# Create PID controller
export def "control pid" [
    --kp: float = 1.0          # Proportional gain
    --ki: float = 0.1          # Integral gain
    --kd: float = 0.01         # Derivative gain
    --adaptive = false   # Enable adaptive tuning
    --stability-margin: float = 0.5  # Minimum stability margin
]: [ nothing -> record ] {
    {
        type: "pid"
        kp: $kp
        ki: $ki
        kd: $kd
        integral: 0.0
        prev_error: 0.0
        setpoint: 0.0
        adaptive: $adaptive
        stability_margin: $stability_margin
        gains_history: []
        error_history: []
        stability_verified: true
    }
}

# Compute PID control action
export def "pid control" [
    measurement: float         # Current measurement
    --controller: record = {}  # PID controller
]: [ float -> record ] {
    let ctrl = (if ($controller | is-empty) { $in } else { $controller })
    
    let error = $ctrl.setpoint - $measurement
    let dt = 0.01  # Assume 100Hz
    
    # Update integral with anti-windup
    let new_integral = (clip ($ctrl.integral + $error * $dt) -10.0 10.0)
    
    # Calculate derivative
    let derivative = ($error - $ctrl.prev_error) / $dt
    
    # PID formula
    let output = ($ctrl.kp * $error) + ($ctrl.ki * $new_integral) + ($ctrl.kd * $derivative)
    
    # Update controller state
    let updated_ctrl = $ctrl
    | upsert integral $new_integral
    | upsert prev_error $error
    | upsert error_history {|c| 
        ($c.error_history | append $error) | last 100
    }
    
    {
        control: (clip $output -100.0 100.0)
        error: $error
        p_term: ($ctrl.kp * $error)
        i_term: ($ctrl.ki * $new_integral)
        d_term: ($ctrl.kd * $derivative)
        controller_state: $updated_ctrl
    }
}

# Adapt PID gains based on performance
export def "pid adapt" [
    --controller: record = {}  # PID controller
]: [ nothing -> record ] {
    let ctrl = (if ($controller | is-empty) { $in } else { $controller })
    
    if not $ctrl.adaptive {
        return $ctrl
    }
    
    # Analyze error history
    let errors = $ctrl.error_history
    if ($errors | length) < 10 {
        return $ctrl
    }
    
    # Calculate performance metrics
    let error_variance = (variance $errors)
    let error_mean = ($errors | math avg | math abs)
    let oscillation = (detect-oscillation $errors)
    
    mut new_kp = $ctrl.kp
    mut new_ki = $ctrl.ki
    mut new_kd = $ctrl.kd
    
    # Adapt based on behavior
    if $oscillation {
        # Reduce gains if oscillating
        $new_kp = $ctrl.kp * 0.9
        $new_ki = $ctrl.ki * 0.8
        $new_kd = $ctrl.kd * 1.1
    } else if $error_mean > 1.0 {
        # Increase integral gain for steady-state error
        $new_ki = ($ctrl.ki * 1.1) | clip 0.0 10.0
    } else if $error_variance < 0.1 {
        # Good performance, slightly reduce gains for robustness
        $new_kp = $ctrl.kp * 0.98
    }
    
    # Verify stability margins
    let stable = (verify-pid-stability $new_kp $new_ki $new_kd $ctrl.stability_margin)
    
    if $stable {
        $ctrl
        | upsert kp $new_kp
        | upsert ki $new_ki
        | upsert kd $new_kd
        | upsert gains_history {|c| 
            ($c.gains_history | append {
                kp: $new_kp
                ki: $new_ki
                kd: $new_kd
                timestamp: (date now)
            }) | last 50
        }
    } else {
        $ctrl | upsert stability_verified false
    }
}

# Set PID setpoint
export def "pid setpoint" [
    setpoint: float            # Target value
]: [ record -> record ] {
    let ctrl = $in
    $ctrl | upsert setpoint $setpoint | upsert integral 0.0
}

# =============================================================================
# Reinforcement Learning Based Control
# =============================================================================

# Q-learning controller for discrete state/action spaces
export def "control reinforcement" [
    --type: string = "qlearning"   # qlearning, policy_gradient, actor_critic
    --state-bins: list = [10 10]   # Discretization bins per state dimension
    --action-bins: int = 5         # Number of discrete actions
    --learning-rate: float = 0.1
    --discount: float = 0.95
    --epsilon: float = 0.1         # Exploration rate
]: [ nothing -> record ] {
    let n_states = ($state_bins | math product)
    let n_actions = $action_bins
    
    # Initialize Q-table (sparse representation)
    let q_table = {}
    
    match $type {
        "qlearning" => {
            {
                type: "qlearning"
                state_bins: $state_bins
                action_bins: $action_bins
                q_table: $q_table
                alpha: $learning_rate
                gamma: $discount
                epsilon: $epsilon
                episode: 0
                total_steps: 0
                last_state: null
                last_action: null
            }
        }
        "policy_gradient" => {
            {
                type: "policy_gradient"
                state_dim: ($state_bins | length)
                action_dim: $action_bins
                policy_weights: (random-matrix $action_bins ($state_bins | length) 0.1)
                baseline: 0.0
                alpha: $learning_rate
                gamma: $discount
                trajectory_buffer: []
            }
        }
        "actor_critic" => {
            {
                type: "actor_critic"
                state_dim: ($state_bins | length)
                action_dim: $action_bins
                actor_weights: (random-matrix $action_bins ($state_bins | length) 0.1)
                critic_weights: (random-vector ($state_bins | length) 0.1)
                alpha_actor: $learning_rate
                alpha_critic: $learning_rate * 2
                gamma: $discount
            }
        }
        _ => {
            error make { msg: $"Unknown RL type: ($type)" }
        }
    }
}

# Select action using RL policy
export def "rl select-action" [
    state: list                # Current state
    --controller: record = {}  # RL controller
]: [ list -> record ] {
    let ctrl = (if ($controller | is-empty) { $in } else { $controller })
    
    let state_idx = (discretize-state $state $ctrl.state_bins)
    
    match $ctrl.type {
        "qlearning" => {
            # Epsilon-greedy
            let explore = (random float 0.0..1.0) < $ctrl.epsilon
            
            let action_idx = if $explore {
                (random int 0..($ctrl.action_bins - 1))
            } else {
                # Get best action from Q-table
                let state_q = ($ctrl.q_table | get --optional $state_idx | default {})
                if ($state_q | is-empty) {
                    (random int 0..($ctrl.action_bins - 1))
                } else {
                    argmax ($state_q | values)
                }
            }
            
            let action = (discrete-to-continuous $action_idx $ctrl.action_bins -1.0 1.0)
            
            {
                action: $action
                action_idx: $action_idx
                state_idx: $state_idx
                explore: $explore
            }
        }
        "policy_gradient" => {
            # Softmax policy
            let probs = (softmax-policy $state $ctrl.policy_weights)
            let action_idx = (sample-discrete $probs)
            let action = (discrete-to-continuous $action_idx $ctrl.action_bins -1.0 1.0)
            
            {
                action: $action
                action_idx: $action_idx
                state: $state
                probs: $probs
            }
        }
        "actor_critic" => {
            # Actor selects action
            let probs = (softmax-policy $state $ctrl.actor_weights)
            let action_idx = (sample-discrete $probs)
            let action = (discrete-to-continuous $action_idx $ctrl.action_bins -1.0 1.0)
            
            # Critic estimates value
            let value = (dot-product $state $ctrl.critic_weights)
            
            {
                action: $action
                action_idx: $action_idx
                value: $value
                state: $state
            }
        }
        _ => {
            {action: 0.0}
        }
    }
}

# Update RL controller with experience
export def "rl update" [
    state: list                # Current state
    action: int                # Action taken
    reward: float              # Reward received
    next_state: list           # Next state
    --controller: record = {}  # RL controller
]: [ nothing -> record ] {
    let ctrl = (if ($controller | is-empty) { $in } else { $controller })
    
    let s_idx = (discretize-state $state $ctrl.state_bins)
    let s_next_idx = (discretize-state $next_state $ctrl.state_bins)
    
    match $ctrl.type {
        "qlearning" => {
            # Get current Q-value
            let q_s = ($ctrl.q_table | get --optional $s_idx | default {})
            let current_q = ($q_s | get --optional $action | default 0.0)
            
            # Get max Q for next state
            let q_next = ($ctrl.q_table | get --optional $s_next_idx | default {})
            let max_q_next = if ($q_next | is-empty) { 0.0 } else { $q_next | values | math max }
            
            # Q-learning update
            let td_target = $reward + ($ctrl.gamma * $max_q_next)
            let new_q = $current_q + ($ctrl.alpha * ($td_target - $current_q))
            
            # Update Q-table
            let new_q_s = ($q_s | upsert $action $new_q)
            let new_q_table = ($ctrl.q_table | upsert $s_idx $new_q_s)
            
            $ctrl 
            | upsert q_table $new_q_table
            | upsert total_steps ($ctrl.total_steps + 1)
        }
        _ => {
            $ctrl
        }
    }
}

# =============================================================================
# Bifurcation-Based Control
# =============================================================================

# Create bifurcation-based controller (switching control)
export def "control bifurcation" [
    --bifurcation-param: float = 0.0   # Control parameter
    --n-branches: int = 2              # Number of equilibrium branches
    --switching-threshold: float = 0.5 # Threshold for switching
]: [ nothing -> record ] {
    {
        type: "bifurcation"
        parameter: $bifurcation_param
        n_branches: $n_branches
        switching_threshold: $switching_threshold
        current_branch: 0
        branch_history: []
        equilibrium_branches: []
        stability_map: {}
        initialized: true
    }
}

# Analyze bifurcation structure
export def "bifurcation analyze" [
    dynamics: closure          # System dynamics with parameter
    param_range: list          # [min, max] for bifurcation parameter
    --n-samples: int = 100     # Resolution of bifurcation diagram
]: [ nothing -> record ] {
    let param_min = $param_range.0
    let param_max = $param_range.1
    let param_step = (($param_max - $param_min) / $n_samples)
    
    mut bifurcation_points = []
    mut equilibrium_curves = []
    
    for i in 0..<$n_samples {
        let param = $param_min + ($i * $param_step)
        
        # Find equilibria at this parameter value
        let equilibria = (find-equilibria $dynamics $param)
        
        for eq in $equilibria {
            # Check stability
            let stable = (check-equilibrium-stability $dynamics $eq $param)
            
            $bifurcation_points = ($bifurcation_points | append {
                parameter: $param
                equilibrium: $eq
                stable: $stable
            })
        }
    }
    
    # Detect bifurcation points (stability changes)
    let detected_bifurcations = (detect-bifurcation-points $bifurcation_points)
    
    {
        bifurcation_points: $bifurcation_points
        detected_bifurcations: $detected_bifurcations
        param_range: $param_range
        n_samples: $n_samples
    }
}

# Switch between attractors using bifurcation control
export def "bifurcation switch" [
    current_state: list        # Current system state
    target_branch: int         # Target equilibrium branch
    --controller: record = {}  # Bifurcation controller
]: [ nothing -> record ] {
    let ctrl = (if ($controller | is-empty) { $in } else { $controller })
    
    # Determine parameter adjustment needed
    let current_param = $ctrl.parameter
    let param_adjustment = if $target_branch != $ctrl.current_branch {
        # Calculate parameter perturbation for switching
        let target_eq = ($ctrl.equilibrium_branches | get $target_branch | default [0 0])
        let state_error = (vector-distance $current_state $target_eq)
        
        if $state_error > $ctrl.switching_threshold {
            # Large perturbation needed
            0.5 * ($target_branch - $ctrl.current_branch | into float)
        } else {
            # Fine-tuning
            0.1 * ($target_branch - $ctrl.current_branch | into float)
        }
    } else {
        0.0
    }
    
    let new_param = $current_param + $param_adjustment
    
    let updated_ctrl = $ctrl
    | upsert parameter $new_param
    | upsert current_branch $target_branch
    | upsert branch_history {|c| 
        ($c.branch_history | append {
            from: $ctrl.current_branch
            to: $target_branch
            param: $new_param
            timestamp: (date now)
        }) | last 100
    }
    
    {
        parameter_adjustment: $param_adjustment
        new_parameter: $new_param
        target_branch: $target_branch
        switch_required: ($target_branch != $ctrl.current_branch)
        updated_controller: $updated_ctrl
    }
}

# =============================================================================
# Cost Function Design with Free Energy
# =============================================================================

# Create cost function incorporating free energy principle
export def "cost free-energy" [
    --state-target: list = [0 0]   # Target state
    --precision: list = null       # Precision matrix (inverse variance)
    --control-cost: float = 0.1    # Control effort penalty
    --uncertainty-weight: float = 1.0  # Weight for uncertainty term
]: [ nothing -> record ] {
    let n = ($state_target | length)
    let prec = (if $precision == null { diagonal-matrix $n 1.0 } else { $precision })
    
    {
        type: "free_energy"
        target: $state_target
        precision: $prec
        control_cost: $control_cost
        uncertainty_weight: $uncertainty_weight
        evaluate: {|state, control, uncertainty|
            # Prediction error: (s - μ)^T Σ^{-1} (s - μ)
            let error = ($state | zip $state_target | each {|p| $p.0 - $p.1})
            let pred_error = (quadratic-form $error $prec)
            
            # Complexity (KL divergence): -ln p(s|μ) + ln p(s)
            let complexity = $uncertainty_weight * $uncertainty
            
            # Control cost: u^T R u
            let control_penalty = $control_cost * ($control | each {|u| $u * $u} | math sum)
            
            # Free energy = accuracy - complexity
            $pred_error + $complexity + $control_penalty
        }
    }
}

# =============================================================================
# Helper Functions
# =============================================================================

# Matrix operations
def diagonal-matrix [n: int, val: float]: [ nothing -> list ] {
    seq 0 ($n - 1) | each {|i|
        seq 0 ($n - 1) | each {|j|
            if $i == $j { $val } else { 0.0 }
        }
    }
}

def matrix-vector-multiply-neg [M: list, v: list]: [ nothing -> list ] {
    $M | each {|row|
        -($row | zip $v | each {|p| $p.0 * $p.1} | math sum)
    }
}

def quadratic-form [x: list, P: list]: [ nothing -> float ] {
    let Px = ($P | each {|row|
        $row | zip $x | each {|p| $p.0 * $p.1} | math sum
    })
    $x | zip $Px | each {|p| $p.0 * $p.1} | math sum
}

def vector-norm [v: list]: [ nothing -> float ] {
    $v | each {|x| $x * $x} | math sum | math sqrt
}

def vector-distance [a: list, b: list]: [ nothing -> float ] {
    $a | zip $b | each {|p| $p.0 - $p.1} | each {|d| $d * $d} | math sum | math sqrt
}

# MPC helpers
def mpc-forward-sim [x0: list, U: list, ctrl: record, dynamics: closure]: [ nothing -> list ] {
    mut X = [$x0]
    mut x = $x0
    
    for u in $U {
        let dx = (do $dynamics $x $u)
        $x = ($x | zip $dx | each {|p| $p.0 + ($p.1 * $ctrl.dt)})
        $X = ($X | append $x)
    }
    
    $X
}

def mpc-calculate-cost [X: list, U: list, ctrl: record]: [ nothing -> float ] {
    mut cost = 0.0
    
    for i in 0..<(($X | length) - 1) {
        let x = ($X | get $i)
        let u = ($U | get $i)
        
        # Stage cost: x^T Q x + u^T R u
        let state_cost = (quadratic-form (vector-subtract $x $ctrl.reference) $ctrl.weights.Q)
        let control_cost = (quadratic-form $u $ctrl.weights.R)
        $cost = $cost + $state_cost + $control_cost
    }
    
    # Terminal cost
    let x_term = ($X | last)
    let term_cost = (quadratic-form (vector-subtract $x_term $ctrl.reference) $ctrl.weights.Qf)
    $cost + $term_cost
}

def mpc-gradient-step [U: list, trajectory: list, ctrl: record, lr: float]: [ nothing -> list ] {
    # Simplified gradient step
    $U | enumerate | each {|u_item|
        let i = $u_item.index
        $u_item.item | each {|u_val|
            # Simple random perturbation for demo
            $u_val + (random float -0.01..0.01 * $lr)
        }
    }
}

def mpc-apply-constraints [U: list, constraints: record]: [ nothing -> list ] {
    $U | each {|u|
        $u | enumerate | each {|u_item|
            let i = $u_item.index
            let u_min = ($constraints.u_min | get $i)
            let u_max = ($constraints.u_max | get $i)
            $u_item.item | clip $u_min $u_max
        }
    }
}

def vector-subtract [a: list, b: list]: [ nothing -> list ] {
    $a | zip $b | each {|p| $p.0 - $p.1}
}

def clip [val: float, min: float, max: float]: [ nothing -> float ] {
    if $val < $min { $min } else if $val > $max { $max } else { $val }
}

# LQR helpers
def solve-riccati [A: list, B: list, Q: list, R: list, method: string]: [ nothing -> list ] {
    # Simplified Riccati solution (iterative)
    let n = ($A | length)
    mut P = $Q
    
    for _ in 0..100 {
        # P = Q + A^T P A - A^T P B (R + B^T P B)^{-1} B^T P A
        let AtPA = (matrix-multiply (transpose-matrix $A) (matrix-multiply $P $A))
        $P = (matrix-add $Q $AtPA)
    }
    
    $P
}

def compute-lqr-gain [A: list, B: list, P: list, R: list]: [ nothing -> list ] {
    # K = R^{-1} B^T P
    let BtP = (matrix-multiply (transpose-matrix $B) $P)
    # Simplified: assume R is diagonal
    $BtP | each {|row|
        $row | each {|val| $val / $R.0.0}
    }
}

def check-lqr-stability [A: list, B: list, K: list]: [ nothing -> bool ] {
    # Check if A - BK is stable
    let BK = (matrix-multiply $B $K)
    let A_cl = (matrix-subtract $A $BK)
    
    # Simplified: check trace
    let trace = ($A_cl | enumerate | each {|row| $row.item | get $row.index} | math sum)
    $trace < 0
}

def solve-dlqr-finite [Ad: list, Bd: list, Q: list, R: list, horizon: int]: [ nothing -> record ] {
    mut P_seq = [(matrix-scale $Q 10.0)]
    mut K_seq = []
    
    for _ in 0..<$horizon {
        let P = $P_seq.0
        # Simplified Riccati recursion
        $P_seq = ($P_seq | prepend $Q)
    }
    
    {P_seq: $P_seq, K_seq: $K_seq}
}

def solve-dlqr-infinite [Ad: list, Bd: list, Q: list, R: list]: [ nothing -> list ] {
    # Iterative solution
    solve-riccati $Ad $Bd $Q $R "iterative"
}

def compute-dlqr-gain [Ad: list, Bd: list, P: list, R: list]: [ nothing -> list ] {
    compute-lqr-gain $Ad $Bd $P $R
}

def check-dlqr-stability [Ad: list, Bd: list, K: list]: [ nothing -> bool ] {
    check-lqr-stability $Ad $Bd $K
}

# Matrix operations
def transpose-matrix [M: list]: [ nothing -> list ] {
    let n = ($M | length)
    let m = ($M.0 | length)
    seq 0 ($m - 1) | each {|j|
        seq 0 ($n - 1) | each {|i|
            $M | get $i | get $j
        }
    }
}

def matrix-multiply [A: list, B: list]: [ nothing -> list ] {
    let n = ($A | length)
    let m = ($B.0 | length)
    let p = ($B | length)
    
    seq 0 ($n - 1) | each {|i|
        seq 0 ($m - 1) | each {|j|
            mut sum = 0.0
            for k in 0..<$p {
                let a_ik = $A | get $i | get $k
                let b_kj = $B | get $k | get $j
                $sum = $sum + ($a_ik * $b_kj)
            }
            $sum
        }
    }
}

def matrix-add [A: list, B: list]: [ nothing -> list ] {
    $A | zip $B | each {|row_pair|
        $row_pair.0 | zip $row_pair.1 | each {|elem_pair|
            $elem_pair.0 + $elem_pair.1
        }
    }
}

def matrix-subtract [A: list, B: list]: [ nothing -> list ] {
    $A | zip $B | each {|row_pair|
        $row_pair.0 | zip $row_pair.1 | each {|elem_pair|
            $elem_pair.0 - $elem_pair.1
        }
    }
}

def matrix-scale [M: list, s: float]: [ nothing -> list ] {
    $M | each {|row| $row | each {|e| $e * $s}}
}

# iLQR helpers
def interpolate-state [x0: list, xg: list, t: float]: [ nothing -> list ] {
    $x0 | zip $xg | each {|p| $p.0 + ($t * ($p.1 - $p.0))}
}

def ilqr-forward-rollout [X: list, U: list, x0: list, dynamics: closure, ctrl: record]: [ nothing -> record ] {
    mut states = [$x0]
    mut x = $x0
    mut cost = 0.0
    
    for i in 0..<(($U | length) - 1) {
        let u = ($U | get $i)
        $x = (do $dynamics $x $u)
        $states = ($states | append $x)
        
        # Running cost
        $cost = $cost + ($u | each {|v| $v * $v} | math sum)
    }
    
    {states: $states, controls: $U, cost: $cost}
}

def ilqr-backward-pass [X: list, U: list, cost_fn: closure, dynamics: closure, ctrl: record]: [ nothing -> record ] {
    # Simplified backward pass
    {k: [], K: []}
}

def ilqr-update-controls [U: list, backward: record, ctrl: record]: [ nothing -> list ] {
    # Simplified update
    $U
}

# PID helpers
def variance [vals: list]: [ nothing -> float ] {
    let mean = ($vals | math avg)
    let sq_diff = $vals | each {|v| ($v - $mean) * ($v - $mean)}
    ($sq_diff | math avg)
}

def detect-oscillation [errors: list]: [ nothing -> bool ] {
    if ($errors | length) < 20 { return false }
    
    # Check sign changes
    let signs = $errors | each {|e| if $e > 0 { 1 } else { -1 }}
    mut sign_changes = 0
    mut prev_sign = ($signs | first)
    
    for s in ($signs | skip 1) {
        if $s != $prev_sign {
            $sign_changes = $sign_changes + 1
        }
        $prev_sign = $s
    }
    
    ($sign_changes | into float) / ($signs | length) > 0.3
}

def verify-pid-stability [kp: float, ki: float, kd: float, margin: float]: [ nothing -> bool ] {
    # Simplified stability check for PID
    # Real systems would use Nyquist or root locus
    $kp > 0 and $ki >= 0 and $kd >= 0
}

# RL helpers
def discretize-state [state: list, bins: list]: [ nothing -> string ] {
    $state | zip $bins | each {|p|
        let val = $p.0
        let n_bins = $p.1
        let bin = ((($val + 1.0) / 2.0 * $n_bins) | into int | clip 0 ($n_bins - 1))
        $bin | into string
    } | str join "_"
}

def discrete-to-continuous [idx: int, n_bins: int, min: float, max: float]: [ nothing -> float ] {
    let range = $max - $min
    $min + ((idx | into float) / ($n_bins - 1)) * $range
}

def argmax [vals: list]: [ nothing -> int ] {
    let max_val = ($vals | math max)
    $vals | enumerate | where {|e| $e.item == $max_val} | first | get index
}

def softmax-policy [state: list, weights: list]: [ nothing -> list ] {
    let logits = $weights | each {|w| dot-product $state $w}
    let max_logit = ($logits | math max)
    let exps = $logits | each {|l| ($l - $max_logit) | math exp}
    let sum_exps = ($exps | math sum)
    $exps | each {|e| $e / $sum_exps}
}

def sample-discrete [probs: list]: [ nothing -> int ] {
    let r = (random float 0.0..1.0)
    mut cumsum = 0.0
    mut idx = 0
    
    for p in $probs {
        $cumsum = $cumsum + $p
        if $r <= $cumsum {
            return $idx
        }
        $idx = $idx + 1
    }
    
    ($probs | length) - 1
}

def random-matrix [rows: int, cols: int, scale: float]: [ nothing -> list ] {
    seq 0 $rows | each {|_| 
        seq 0 $cols | each {|_| random float (-$scale)..$scale}
    } | take $rows
}

def random-vector [n: int, scale: float]: [ nothing -> list ] {
    seq 0 $n | each {|_| random float (-$scale)..$scale} | take $n
}

def dot-product [a: list, b: list]: [ nothing -> float ] {
    $a | zip $b | each {|p| $p.0 * $p.1} | math sum
}

# Bifurcation helpers
def find-equilibria [dynamics: closure, param: float]: [ nothing -> list ] {
    # Simplified: return sample equilibria
    [[0 0] [1 0] [-1 0]]
}

def check-equilibrium-stability [dynamics: closure, eq: list, param: float]: [ nothing -> bool ] {
    # Simplified check
    ($eq | first | math abs) < 0.5
}

def detect-bifurcation-points [points: list]: [ nothing -> list ] {
    mut bifurcations = []
    mut prev_stable = null
    mut prev_param = null
    
    for p in $points {
        if $prev_stable != null and $p.stable != $prev_stable {
            $bifurcations = ($bifurcations | append {
                parameter: ($prev_param + $p.parameter) / 2
                type: (if $p.stable { "stabilizing" } else { "destabilizing" })
            })
        }
        $prev_stable = $p.stable
        $prev_param = $p.parameter
    }
    
    $bifurcations
}

# =============================================================================
# Aliases
# =============================================================================

export alias mpc-init = control mpc
export alias mpc-solve = mpc solve
export alias lqr-init = control lqr
export alias lqr-ctrl = lqr control
export alias ilqr-init = control ilqr
export alias ilqr-solve = ilqr solve
export alias pid-init = control pid
export alias pid-ctrl = pid control
export alias pid-adapt = pid adapt
export alias rl-init = control reinforcement
export alias rl-act = rl select-action
export alias rl-update = rl update
export alias bifurc-init = control bifurcation
export alias bifurc-analyze = bifurcation analyze
export alias bifurc-switch = bifurcation switch
