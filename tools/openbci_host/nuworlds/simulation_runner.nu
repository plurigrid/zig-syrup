# simulation_runner.nu
# Deterministic simulation runner for world variants
# Supports tick-based simulation, determinism verification, and replay

use world_ab.nu *
use immer_ops.nu *
use ewig_history.nu *

# =============================================================================
# Simulation State
# =============================================================================

# Get simulations storage directory
export def simulations-dir []: [ nothing -> path ] {
    $nu.home-path | path join ".config" "nuworlds" "simulations"
}

# Ensure simulations directory exists
export def ensure-simulations-dir []: [ nothing -> nothing ] {
    mkdir (simulations-dir)
}

# Create new simulation state
export def SimulationState [] {
    {
        tick: 0
        seed: 0
        world: {}
        rng_state: {}
        event_log: []
        deterministic: true
        start_time: (date now)
    }
}

# =============================================================================
# Simulation Execution
# =============================================================================

# Run deterministic simulation
export def "sim run" [
    world_uri: string           # World URI to simulate
    --ticks: int = 1000         # Number of ticks to run
    --seed: int = 42            # Random seed for determinism
    --tick-rate: duration = 16ms   # Real-time tick duration (0 for unlimited)
    --events: list = []         # Initial events to inject
    --snapshot-every: int = 0   # Create snapshot every N ticks (0 = never)
    --output: string = ""       # Output file for results
]: [ nothing -> record ] {
    ensure-simulations-dir
    
    # Load world
    let world = (load-world $world_uri)
    
    # Initialize simulation state
    mut state = (SimulationState)
    $state.seed = $seed
    $state.world = $world
    
    print $"Starting simulation: ($world_uri)"
    print $"  Ticks: ($ticks)"
    print $"  Seed: ($seed)"
    print $"  Entities: ($world.entities | length)"
    print ""
    
    # Initialize RNG with seed
    mut rng = (init-rng $seed)
    
    # Inject initial events
    for event in $events {
        $state.event_log = ($state.event_log | append {
            tick: 0
            type: "injected"
            data: $event
        })
    }
    
    # Main simulation loop
    mut last_progress = 0
    
    for tick in 1..$ticks {
        $state.tick = $tick
        
        # Generate tick events based on world state and RNG
        let tick_events = (generate-tick-events $state $rng)
        
        # Apply events
        for event in $tick_events {
            $state.world = (apply-sim-event $state.world $event)
            $state.event_log = ($state.event_log | append {
                tick: $tick
                type: $event.type
                data: $event
            })
        }
        
        # Update RNG state
        $rng = (advance-rng $rng)
        
        # Create snapshot if requested
        if $snapshot_every > 0 and ($tick mod $snapshot_every) == 0 {
            $state.world = ($state.world | upsert snapshots {||
                ($state.world | get -i snapshots | default []) | append {
                    tick: $tick
                    timestamp: (date now)
                    state_hash: (compute-state-hash $state.world)
                }
            })
        }
        
        # Progress indicator
        let progress = (($tick * 100) / $ticks | math floor)
        if $progress > $last_progress and ($progress mod 10) == 0 {
            print $"  ($progress)% complete..."
            $last_progress = $progress
        }
        
        # Real-time pacing
        if $tick_rate > 0sec {
            sleep $tick_rate
        }
    }
    
    # Finalize
    let end_time = (date now)
    let duration = ($end_time - $state.start_time)
    
    let result = {
        world_uri: $world_uri
        ticks: $ticks
        seed: $seed
        duration: $duration
        events_processed: ($state.event_log | length)
        final_state_hash: (compute-state-hash $state.world)
        entity_count: ($state.world.entities | length)
        deterministic: $state.deterministic
        tick_rate: (if $tick_rate > 0sec {
            ($ticks / (($duration | into int) / 1_000_000_000))
        } else { null })
    }
    
    print ""
    print "Simulation complete:"
    print $"  Duration: ($duration)"
    print $"  Events: ($result.events_processed)"
    print $"  Final hash: ($result.final_state_hash)"
    
    # Save if output specified
    if $output != "" {
        let sim_data = {
            metadata: $result
            final_state: $state.world
            event_log: $state.event_log
        }
        
        let output_path = (simulations-dir | path join $output)
        $sim_data | save -f $output_path
        print $"  Saved to: ($output_path)"
    }
    
    $result
}

# Initialize RNG state
export def init-rng [seed: int]: [ nothing -> record ] {
    # Simple LCG RNG state
    {
        seed: $seed
        state: $seed
        a: 1664525
        c: 1013904223
        m: 4294967296
    }
}

# Advance RNG
export def advance-rng [rng: record]: [ nothing -> record ] {
    let new_state = (($rng.a * $rng.state + $rng.c) mod $rng.m)
    $rng | upsert state $new_state
}

# Generate random float from RNG
export def rng-float [rng: record]: [ nothing -> float ] {
    ($rng.state / $rng.m)
}

# Generate events for a tick
export def generate-tick-events [state: record, rng: record]: [ nothing -> list ] {
    mut events = []
    
    # Entity update events
    for entity_id in ($state.world.entities | columns) {
        let entity = ($state.world.entities | get $entity_id)
        
        # Simulate entity behavior based on type
        let update = (match ($entity | get -i type | default "unknown") {
            "eeg_channel" => {
                # Simulate EEG data variation
                let noise = (rng-float $rng) * 10 - 5
                { type: "entity_update", entity_id: $entity_id, noise: $noise }
            }
            "sensor" => {
                # Simulate sensor reading
                if ((rng-float $rng) > 0.95) {
                    { type: "sensor_trigger", sensor_id: $entity_id }
                } else { null }
            }
            _ => { null }
        })
        
        if $update != null {
            $events = ($events | append $update)
        }
    }
    
    $events
}

# Apply simulation event to world
export def apply-sim-event [world: record, event: record]: [ nothing -> record ] {
    match $event.type {
        "entity_update" => {
            $world | upsert entities.($event.entity_id).state.last_update {
                tick: $event.tick?,
                noise: $event.noise?
            }
        }
        "sensor_trigger" => {
            $world | upsert sensors.($event.sensor_id).last_trigger (date now)
        }
        _ => { $world }
    }
}

# =============================================================================
# Determinism Verification
# =============================================================================

# Verify determinism by running same simulation twice
export def "sim verify" [
    world_a: string             # First world URI
    world_b: string = ""        # Second world URI (empty = use same as A)
    --ticks: int = 100          # Ticks to run
    --seed: int = 42            # Seed to use
]: [ nothing -> record ] {
    let uri_b = (if $world_b == "" { $world_a } else { $world_b })
    
    print $"Verifying determinism: ($world_a) vs ($uri_b)"
    print $"  Running both simulations with seed ($seed)..."
    print ""
    
    # Run first simulation
    print "  Run A..."
    let result_a = (sim run $world_a --ticks $ticks --seed $seed --tick-rate 0sec)
    
    # Run second simulation
    print "  Run B..."
    let result_b = (sim run $uri_b --ticks $ticks --seed $seed --tick-rate 0sec)
    
    # Compare
    let deterministic = ($result_a.final_state_hash == $result_b.final_state_hash)
    
    print ""
    print "Verification Results:"
    print $"  Run A hash: ($result_a.final_state_hash)"
    print $"  Run B hash: ($result_b.final_state_hash)"
    
    if $deterministic {
        print "  ✓ DETERMINISTIC - State hashes match"
    } else {
        print "  ✗ NON-DETERMINISTIC - State hashes differ!"
    }
    
    {
        deterministic: $deterministic
        world_a: $world_a
        world_b: $uri_b
        seed: $seed
        ticks: $ticks
        hash_a: $result_a.final_state_hash
        hash_b: $result_b.final_state_hash
        events_a: $result_a.events_processed
        events_b: $result_b.events_processed
    }
}

# =============================================================================
# Replay
# =============================================================================

# Replay simulation from log file
export def "sim replay" [
    log_file: path              # Simulation log file
    --speed: float = 1.0        # Replay speed
    --verify: bool = false      # Verify against stored hash
]: [ nothing -> record ] {
    if not ($log_file | path exists) {
        error make { msg: $"Log file not found: ($log_file)" }
    }
    
    let sim_data = (open $log_file)
    let metadata = $sim_data.metadata
    let event_log = $sim_data.event_log
    
    print $"Replaying simulation from ($log_file)"
    print $"  Original world: ($metadata.world_uri)"
    print $"  Ticks: ($metadata.ticks)"
    print $"  Events: ($metadata.events_processed)"
    print $"  Speed: ($speed)x"
    print ""
    
    # Load initial world state
    mut world = (load-world $metadata.world_uri)
    
    # Replay events
    mut last_tick = 0
    
    for event in $event_log {
        # Time between events
        if $event.tick > $last_tick {
            let tick_delta = ($event.tick - $last_tick)
            let sleep_time = ($tick_delta * 16 / $speed)  # Assume 16ms per tick
            sleep ($sleep_time * 1ms)
            $last_tick = $event.tick
        }
        
        # Apply event
        $world = (apply-sim-event $world $event.data)
        
        # Progress display
        if ($event.tick mod 100) == 0 {
            print $"  Tick ($event.tick)..."
        }
    }
    
    # Verify if requested
    let final_hash = (compute-state-hash $world)
    let verified = (if $verify {
        let matches = ($final_hash == $metadata.final_state_hash)
        print ""
        print $"Verification: (if $matches { "✓ PASS" } else { "✗ FAIL" })"
        print $"  Expected: ($metadata.final_state_hash)"
        print $"  Got: ($final_hash)"
        $matches
    } else { null })
    
    {
        replayed: true
        original_hash: $metadata.final_state_hash
        replay_hash: $final_hash
        verified: $verified
        events_replayed: ($event_log | length)
    }
}

# =============================================================================
# Benchmarking
# =============================================================================

# Benchmark simulation performance
export def "sim benchmark" [
    world_uri: string           # World URI to benchmark
    --ticks: int = 10000        # Ticks for benchmark
    --warmup: int = 1000        # Warmup ticks
    --runs: int = 3             # Number of runs
]: [ nothing -> record ] {
    print $"Benchmarking simulation for ($world_uri)"
    print $"  Configuration: ($ticks) ticks, ($runs) runs, ($warmup) warmup"
    print ""
    
    # Warmup
    if $warmup > 0 {
        print "  Warmup..."
        sim run $world_uri --ticks $warmup --seed 42 --tick-rate 0sec | ignore
    }
    
    mut results = []
    
    for run in 1..$runs {
        print $"  Run ($run)/($runs)..."
        
        let start = (date now)
        let result = (sim run $world_uri --ticks $ticks --seed (42 + $run) --tick-rate 0sec)
        let elapsed = ((date now) - $start)
        
        let tps = ($ticks / (($elapsed | into int) / 1_000_000_000))
        
        $results = ($results | append {
            run: $run
            ticks: $ticks
            duration: $elapsed
            ticks_per_second: $tps
            hash: $result.final_state_hash
        })
    }
    
    # Calculate statistics
    let durations = ($results | get duration | each { |d| $d | into int })
    let tps_values = ($results | get ticks_per_second)
    
    let stats = {
        world_uri: $world_uri
        runs: $runs
        ticks_per_run: $ticks
        avg_duration_ms: ($durations | math avg) / 1_000_000
        min_duration_ms: ($durations | math min) / 1_000_000
        max_duration_ms: ($durations | math max) / 1_000_000
        avg_tps: ($tps_values | math avg)
        min_tps: ($tps_values | math min)
        max_tps: ($tps_values | math max)
        stddev_tps: (calculate-stddev $tps_values)
        results: $results
    }
    
    print ""
    print "Benchmark Results:"
    print $"  Average TPS: ($stats.avg_tps | math round -p 2)"
    print $"  Min/Max TPS: ($stats.min_tps | math round -p 2) / ($stats.max_tps | math round -p 2)"
    print $"  StdDev: ($stats.stddev_tps | math round -p 2)"
    print $"  Avg Duration: ($stats.avg_duration_ms | math round -p 2) ms"
    
    $stats
}

# Calculate standard deviation
export def calculate-stddev [values: list]: [ nothing -> float ] {
    let mean = ($values | math avg)
    let squared_diffs = ($values | each { |v| ($v - $mean) ** 2 })
    let variance = ($squared_diffs | math avg)
    $variance | math sqrt
}

# =============================================================================
# Simulation Comparison
# =============================================================================

# Compare two simulation runs
export def "sim compare" [
    log_a: path                 # First simulation log
    log_b: path                 # Second simulation log
    --detailed: bool            # Show detailed differences
]: [ nothing -> record ] {
    if not ($log_a | path exists) {
        error make { msg: $"Log file not found: ($log_a)" }
    }
    if not ($log_b | path exists) {
        error make { msg: $"Log file not found: ($log_b)" }
    }
    
    let sim_a = (open $log_a)
    let sim_b = (open $log_b)
    
    print $"Comparing simulations:"
    print $"  A: ($log_a | path basename)"
    print $"  B: ($log_b | path basename)"
    print ""
    
    # Compare metadata
    let meta_a = $sim_a.metadata
    let meta_b = $sim_b.metadata
    
    let same_seed = ($meta_a.seed == $meta_b.seed)
    let same_ticks = ($meta_a.ticks == $meta_b.ticks)
    let same_hash = ($meta_a.final_state_hash == $meta_b.final_state_hash)
    
    print "Metadata Comparison:"
    print $"  Same seed: ($same_seed) (A: ($meta_a.seed), B: ($meta_b.seed))"
    print $"  Same ticks: ($same_ticks) (A: ($meta_a.ticks), B: ($meta_b.ticks))"
    print $"  Same final hash: ($same_hash)"
    print ""
    
    # Compare event counts
    let events_a = ($sim_a.event_log | length)
    let events_b = ($sim_b.event_log | length)
    
    print "Event Comparison:"
    print $"  Events A: ($events_a)"
    print $"  Events B: ($events_b)"
    print $"  Difference: ($events_b - $events_a)"
    
    if $detailed and not $same_hash {
        print ""
        print "Finding first divergence..."
        
        let min_events = (if $events_a < $events_b { $events_a } else { $events_b })
        mut divergence = null
        
        for i in 0..<$min_events {
            let event_a = ($sim_a.event_log | get $i)
            let event_b = ($sim_b.event_log | get $i)
            
            if ($event_a | to json) != ($event_b | to json) {
                $divergence = {
                    index: $i
                    tick_a: $event_a.tick
                    tick_b: $event_b.tick
                    event_a: $event_a
                    event_b: $event_b
                }
                break
            }
        }
        
        if $divergence != null {
            print $"  First divergence at event ($divergence.index)"
            print $"  Tick A: ($divergence.tick_a), Tick B: ($divergence.tick_b)"
        } else {
            print "  Events are identical up to min length"
        }
    }
    
    {
        identical: $same_hash
        same_seed: $same_seed
        same_ticks: $same_ticks
        events_a: $events_a
        events_b: $events_b
        hash_a: $meta_a.final_state_hash
        hash_b: $meta_b.final_state_hash
    }
}

# =============================================================================
# Stress Testing
# =============================================================================

# Stress test with many entities
export def "sim stress" [
    world_uri: string           # Base world URI
    --entities: int = 1000      # Number of entities to spawn
    --ticks: int = 100          # Ticks to run
]: [ nothing -> record ] {
    print $"Stress testing with ($entities) entities"
    
    # Load and clone world for stress test
    let stress_uri = $"($world_uri)-stress"
    world clone $world_uri $stress_uri --force
    
    let world = (load-world $stress_uri)
    
    # Spawn entities
    mut updated_world = $world
    for i in 0..<$entities {
        let entity_id = $"stress_entity_($i)"
        $updated_world = ($updated_world | upsert entities {||
            $updated_world.entities | insert $entity_id {
                id: $entity_id
                type: "stress_test"
                state: { spawned_at: (date now), index: $i }
            }
        })
    }
    
    # Save updated world
    let parsed = (parse-world-uri-safe $stress_uri)
    let world_file = (worlds-dir | path join $"($parsed.scheme)_($parsed.name).nuon")
    $updated_world | save -f $world_file
    
    print $"  Spawned ($entities) entities"
    
    # Run simulation
    let result = (sim run $stress_uri --ticks $ticks --seed 42 --tick-rate 0sec)
    
    # Cleanup
    world delete $stress_uri --force
    
    print ""
    print "Stress Test Results:"
    print $"  Entities: ($entities)"
    print $"  Ticks: ($ticks)"
    print $"  Duration: ($result.duration)"
    print $"  TPS: ($result.tick_rate | math round -p 2)"
    
    $result
}

# Safe URI parsing helper
export def parse-world-uri-safe [uri: string]: [ nothing -> record ] {
    let pattern = '^(?<scheme>[abc])://(?<name>[^/]+)(?:/(?<path>.*))?$'
    
    if ($uri | find -r $pattern | is-empty) {
        error make { msg: $"Invalid world URI: ($uri)" }
    }
    
    let match = ($uri | parse -r $pattern | get 0)
    
    {
        scheme: $match.scheme
        name: $match.name
        path: ($match | get -i path | default "")
        full: $uri
    }
}

# =============================================================================
# Simulation List
# =============================================================================

# List saved simulations
export def "sim list" []: [ nothing -> table ] {
    ensure-simulations-dir
    
    let files = (ls (simulations-dir)/*.nuon | default [])
    
    if ($files | is-empty) {
        print "No saved simulations"
        return []
    }
    
    $files | each { |file|
        let data = (open $file.name)
        {
            file: ($file.name | path basename)
            world: $data.metadata.world_uri
            ticks: $data.metadata.ticks
            seed: $data.metadata.seed
            events: $data.metadata.events_processed
            hash: $data.metadata.final_state_hash
            size: $file.size
        }
    }
}

# Delete simulation
export def "sim delete" [
    name: string                # Simulation file name
]: [ nothing -> nothing ] {
    let file = (simulations-dir | path join $name)
    
    if ($file | path exists) {
        rm $file
        print $"Deleted ($name)"
    } else {
        print $"Simulation ($name) not found"
    }
}
