# state_manager.nu
# BCI state tracking with mental state classification
# State transitions, history, and trigger system

# State definitions
export def MentalStates [] {
    ["focused", "relaxed", "drowsy", "excited", "stressed", "meditative", "unknown"]
}

# State transition record
export def StateTransition [
    from_state: string,
    to_state: string,
    confidence: float,
    trigger: string
] {
    {
        from: $from_state,
        to: $to_state,
        confidence: $confidence,
        trigger: $trigger,
        timestamp: (date now),
        duration_in_previous: null  # Will be set by manager
    }
}

# State manager
export def StateManager [] {
    {
        current_state: "unknown",
        current_confidence: 0.0,
        state_history: [],
        transition_history: [],
        state_timers: {},
        state_counts: {},
        triggers: {},
        state_start_time: (date now),
        total_observations: 0,
        metadata: {
            created_at: (date now),
            version: "1.0"
        }
    }
}

# Create new state manager
export def "state new" [] {
    StateManager
}

# Update current state
export def "state update" [
    new_state: string,
    --confidence: float = 0.0,
    --trigger: string = "classification"
] {
    let manager = $in
    
    if $new_state not-in (MentalStates) {
        print $"Warning: Unknown state '($new_state)', adding to valid states"
    }
    
    # If state unchanged, just update confidence
    if $new_state == $manager.current_state {
        $manager | upsert current_confidence $confidence
    } else {
        # State transition
        let now = (date now)
        let duration = $now - $manager.state_start_time
        
        let transition = (StateTransition 
            $manager.current_state 
            $new_state 
            $confidence 
            $trigger
            | upsert duration_in_previous $duration
        )
        
        mut new_manager = $manager
        
        # Update transition history
        $new_manager = ($new_manager | upsert transition_history {||
            ($manager.transition_history | append $transition) | last 1000
        })
        
        # Update state history
        $new_manager = ($new_manager | upsert state_history {||
            ($manager.state_history | append {
                state: $manager.current_state,
                start_time: $manager.state_start_time,
                end_time: $now,
                duration: $duration
            }) | last 1000
        })
        
        # Update current state
        $new_manager = ($new_manager | upsert current_state $new_state)
        $new_manager = ($new_manager | upsert current_confidence $confidence)
        $new_manager = ($new_manager | upsert state_start_time $now)
        
        # Update state counts
        $new_manager = ($new_manager | upsert state_counts {||
            let current_count = ($manager.state_counts | get -i $new_state | default 0)
            $manager.state_counts | upsert $new_state ($current_count + 1)
        })
        
        # Execute triggers for this state
        $new_manager = ($new_manager | execute-triggers $new_state $confidence)
        
        print $"State transition: ($transition.from) -> ($transition.to) [($confidence | into string | str substring ..4)]"
        
        $new_manager
    }
}

# Get current state
export def "state current" [] {
    let manager = $in
    {
        state: $manager.current_state,
        confidence: $manager.current_confidence,
        since: $manager.state_start_time,
        duration: ((date now) - $manager.state_start_time)
    }
}

# Get state history
export def "state history" [
    --last: duration = null,      # Show only last N duration
    --limit: int = 100           # Maximum entries to show
] {
    let manager = $in
    
    let history = if $last != null {
        let cutoff = (date now) - $last
        $manager.state_history | where start_time >= $cutoff
    } else {
        $manager.state_history | last $limit
    }
    
    $history | each {|entry|
        $entry | upsert duration_formatted (format-duration $entry.duration)
    }
}

# Get transition history
export def "state transitions" [
    --from: string = null,        # Filter by source state
    --to: string = null,          # Filter by target state
    --limit: int = 50
] {
    let manager = $in
    
    mut transitions = $manager.transition_history | last $limit
    
    if $from != null {
        $transitions = ($transitions | where from == $from)
    }
    
    if $to != null {
        $transitions = ($transitions | where to == $to)
    }
    
    $transitions | each {|t|
        $t | upsert duration_formatted (format-duration $t.duration_in_previous)
    }
}

# Add state trigger
export def "state trigger" [
    state: string,                # State to trigger on
    handler: closure,             # Handler to execute
    --enter: bool = true,         # Trigger on state enter
    --exit: bool = false,        # Trigger on state exit
    --confidence-threshold: float = 0.0,
    --once: bool = false         # Only trigger once
] {
    let manager = $in
    
    let trigger = {
        id: (random uuid),
        state: $state,
        handler: $handler,
        on_enter: $enter,
        on_exit: $exit,
        confidence_threshold: $confidence_threshold,
        once: $once,
        triggered_count: 0
    }
    
    $manager | upsert triggers {||
        if $state in $manager.triggers {
            $manager.triggers | upsert $state {||
                ($manager.triggers | get $state) | append $trigger
            }
        } else {
            $manager.triggers | insert $state [$trigger]
        }
    }
}

# Execute triggers for a state
def execute-triggers [state: string, confidence: float] {
    let manager = $in
    
    if ($state not-in $manager.triggers) {
        return $manager
    }
    
    let triggers = ($manager.triggers | get $state)
    mut new_manager = $manager
    
    for trigger in $triggers {
        if $confidence >= $trigger.confidence_threshold {
            try {
                do $trigger.handler $state $confidence
                
                # Update trigger count
                let new_count = ($trigger.triggered_count + 1)
                
                # Remove if once-only
                if $trigger.once {
                    $new_manager = ($new_manager | upsert triggers {||
                        $new_manager.triggers | upsert $state {||
                            ($new_manager.triggers | get $state) | where id != $trigger.id
                        }
                    })
                } else {
                    $new_manager = ($new_manager | upsert triggers {||
                        $new_manager.triggers | upsert $state {||
                            ($new_manager.triggers | get $state) | each {|t|
                                if $t.id == $trigger.id {
                                    $t | upsert triggered_count $new_count
                                } else {
                                    $t
                                }
                            }
                        }
                    })
                }
            } catch {|e|
                print $"Trigger error for state '($state)': ($e.msg)"
            }
        }
    }
    
    $new_manager
}

# Get state statistics
export def "state stats" [] {
    let manager = $in
    
    let total_time = (date now) - $manager.metadata.created_at
    
    # Calculate time spent in each state
    mut state_durations = {}
    for state in ($manager.state_counts | columns) {
        let time_in_state = ($manager.state_history 
            | where state == $state 
            | get -i duration 
            | default [0sec]
            | math sum)
        $state_durations = ($state_durations | insert $state $time_in_state)
    }
    
    # Add current state duration
    let current_duration = ((date now) - $manager.state_start_time)
    let current_total = ($state_durations | get -i $manager.current_state | default 0sec)
    $state_durations = ($state_durations | upsert $manager.current_state ($current_total + $current_duration))
    
    {
        current_state: $manager.current_state,
        current_confidence: $manager.current_confidence,
        total_observations: $manager.total_observations,
        total_transitions: ($manager.transition_history | length),
        unique_states: ($manager.state_counts | length),
        state_distribution: $manager.state_counts,
        state_durations: $state_durations,
        uptime: $total_time
    }
}

# Predict next likely state based on history
export def "state predict" [] {
    let manager = $in
    
    if ($manager.transition_history | length) < 5 {
        return { prediction: null, confidence: 0.0, reason: "insufficient_data" }
    }
    
    # Count transitions from current state
    let from_current = ($manager.transition_history | where from == $manager.current_state)
    
    if ($from_current | length) == 0 {
        return { prediction: null, confidence: 0.0, reason: "no_history_from_current" }
    }
    
    # Find most common next state
    let next_states = ($from_current | group-by to | transpose state entries | each {|s|
        { state: $s.state, count: ($s.entries | length) }
    } | sort-by count -r)
    
    let total = ($from_current | length)
    let top = $next_states.0
    
    {
        prediction: $top.state,
        confidence: (($top.count | into float) / $total),
        alternatives: ($next_states | skip 1 | take 2),
        based_on: $total
    }
}

# Detect state patterns
export def "state patterns" [
    --min-length: int = 3
] {
    let manager = $in
    
    if ($manager.state_history | length) < $min_length {
        return []
    }
    
    # Simple pattern detection: repeated sequences
    let states = ($manager.state_history | get state)
    
    # Find common 2-state and 3-state patterns
    mut patterns = {}
    
    for i in 0..(($states | length) - 2) {
        let pattern = $"($states | get $i)->($states | get ($i + 1))"
        $patterns = ($patterns | upsert $pattern { ($patterns | get -i $pattern | default 0) + 1 })
    }
    
    $patterns | transpose pattern count | sort-by count -r | take 10
}

# Export state data
export def "state export" [] {
    $in | to json
}

# Import state data
export def "state import" [json_data: string] {
    $json_data | from json
}

# Reset state manager
export def "state reset" [] {
    StateManager
}

# Helper: Format duration nicely
def format-duration [dur: duration] {
    let secs = ($dur | into int) / 1000000000
    
    if $secs < 60 {
        $"($secs | into int)s"
    } else if $secs < 3600 {
        $"($secs / 60 | into int)m ($secs mod 60 | into int)s"
    } else {
        $"($secs / 3600 | into int)h (($secs mod 3600) / 60 | into int)m"
    }
}

# Create state from EEG features
export def "state from-eeg" [
    features: record          # EEG features including band powers
] {
    let manager = $in
    
    # Extract relevant features
    let alpha = $features.alpha? | default 0
    let beta = $features.beta? | default 0
    let theta = $features.theta? | default 0
    
    # Simple heuristic classification
    let state_guess = if $theta > $alpha and $theta > $beta {
        "drowsy"
    } else if $alpha > $beta {
        "relaxed"
    } else if $beta > ($alpha * 2) {
        "focused"
    } else {
        "unknown"
    }
    
    let confidence = 0.7  # Would calculate properly
    
    $manager | state update $state_guess --confidence $confidence --trigger "eeg_features"
}

# Real-time state monitoring
export def "state monitor" [
    --interval: duration = 1sec
] {
    let manager = $in
    
    print "Starting state monitor..."
    print $"Current state: ($manager.current_state)"
    
    job spawn {
        loop {
            let current = $manager | state current
            print $"[($current.since | format date '%H:%M:%S')] ($current.state) [($current.confidence | into string | str substring ..4)] for ($current.duration | format-duration)"
            sleep $interval
        }
    }
    
    $manager
}

# State comparison between two managers
export def "state compare" [other: record] {
    let this = $in
    
    let this_stats = ($this | state stats)
    let other_stats = ($other | state stats)
    
    {
        current: {
            this: $this_stats.current_state,
            other: $other_stats.current_state,
            match: $this_stats.current_state == $other_stats.current_state
        },
        agreement: {
            # Calculate agreement percentage on common states
        },
        this_stats: $this_stats,
        other_stats: $other_stats
    }
}
