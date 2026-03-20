# phase_runner.nu
# Execute processing phases with DAG-based orchestration
# Supports parallel execution and phase health monitoring

use hypergraph.nu *

# Job registry for tracking background phase executions
export def JobRegistry [] {
    {
        jobs: {},
        phase_map: {},
        start_times: {},
        health_checks: {}
    }
}

# Phase execution configuration
export def PhaseConfig [] {
    {
        timeout: 30000,           # Timeout in milliseconds
        retries: 3,               # Number of retries on failure
        parallel: false,          # Whether to run in parallel with siblings
        health_check_interval: 5000,  # Health check interval in ms
        auto_restart: true,       # Auto-restart on failure
        restart_delay: 1000       # Delay before restart in ms
    }
}

# Run a single phase by name
export def "phase run" [
    name: string,              # Phase name to execute
    --input: any = null,      # Input data for the phase
    --config: record = {},    # Phase-specific configuration
    --hypergraph: record = {} # Optional hypergraph context
] {
    let phase_config = (PhaseConfig | merge $config)
    
    print $"Starting phase: ($name)"
    let start_time = (date now)
    
    mut attempt = 0
    mut result = null
    mut last_error = null
    
    while $attempt < $phase_config.retries {
        $attempt = $attempt + 1
        
        $result = try {
            # Execute the phase logic
            let executor = $phase_config.executor?
            if $executor != null {
                do $executor $input $phase_config
            } else {
                # Default executor - pass through with logging
                print $"Phase ($name) executing with input: ($input | describe)"
                $input
            }
        } catch {|e|
            $last_error = $e
            print $"Phase ($name) attempt ($attempt) failed: ($e.msg)"
            null
        }
        
        if $result != null {
            break
        }
        
        # Wait before retry
        if $attempt < $phase_config.retries {
            sleep ($phase_config.restart_delay | into duration --millisecond)
        }
    }
    
    if $result == null {
        error make {
            msg: $"Phase '($name)' failed after ($phase_config.retries) attempts: ($last_error.msg?)",
            label: "phase run"
        }
    }
    
    let duration = (date now) - $start_time
    print $"Phase ($name) completed in ($duration)"
    
    {
        phase: $name,
        result: $result,
        duration: $duration,
        attempts: $attempt,
        completed_at: (date now)
    }
}

# Execute a full pipeline from hypergraph configuration
export def "phase pipeline" [
    hg: record,               # Hypergraph configuration
    --input: any = null,      # Initial input data
    --parallel: bool = true,  # Enable parallel execution where possible
    --monitor: bool = true    # Enable health monitoring
] {
    print "Starting pipeline execution..."
    
    # Get topological execution order
    let execution_order = try {
        $hg | hypergraph topo-sort
    } catch {|e|
        error make {
            msg: $"Cannot execute pipeline: ($e.msg)",
            label: "phase pipeline"
        }
    }
    
    print $"Execution order: ($execution_order | str join ' -> ')"
    
    # Initialize job registry if parallel mode
    mut registry = if $parallel {
        JobRegistry
    } else {
        null
    }
    
    # Data flow storage
    mut data_flow = {}
    if $input != null {
        $data_flow = ($data_flow | insert "__input__" $input)
    }
    
    # Track completed phases
    mut completed = []
    mut failed = []
    
    # Group phases by dependency level for parallel execution
    let levels = if $parallel {
        compute-execution-levels $hg $execution_order
    } else {
        $execution_order | each { [$in] }
    }
    
    # Execute each level
    for level in $levels {
        print $"Executing level: ($level | str join ', ')"
        
        if $parallel and ($level | length) > 1 {
            # Execute phases in parallel
            let results = ($level | each {|phase_name|
                # Collect inputs
                let incoming = ($hg | hypergraph incoming $phase_name)
                mut phase_input = {}
                
                for edge in $incoming {
                    let source_data = $data_flow | get -i $edge.data.source
                    if $source_data != null {
                        $phase_input = ($phase_input | insert $edge.data.stream $source_data)
                    }
                }
                
                let node = ($hg.nodes | get $phase_name)
                let effective_input = if ($phase_input | is-empty) { $input } else { $phase_input }
                
                # Spawn job
                {
                    name: $phase_name,
                    job: (job spawn {
                        phase run $phase_name --input $effective_input --config $node.config
                    })
                }
            })
            
            # Wait for all jobs in level
            for item in $results {
                let job_result = (job recv $item.job)
                
                if ($job_result | describe) == "error" {
                    $failed = ($failed | append $item.name)
                    print $"Phase ($item.name) failed in parallel execution"
                } else {
                    $data_flow = ($data_flow | insert $item.name $job_result.result)
                    $completed = ($completed | append $item.name)
                }
            }
        } else {
            # Sequential execution
            for phase_name in $level {
                # Collect inputs from dependencies
                let incoming = ($hg | hypergraph incoming $phase_name)
                mut phase_input = {}
                
                for edge in $incoming {
                    let source_data = $data_flow | get -i $edge.data.source
                    if $source_data != null {
                        $phase_input = ($phase_input | insert $edge.data.stream $source_data)
                    }
                }
                
                let node = ($hg.nodes | get $phase_name)
                let effective_input = if ($phase_input | is-empty) { $input } else { $phase_input }
                
                let result = try {
                    phase run $phase_name --input $effective_input --config $node.config --hypergraph $hg
                } catch {|e|
                    print $"Phase ($phase_name) failed: ($e.msg)"
                    null
                }
                
                if $result == null {
                    $failed = ($failed | append $phase_name)
                    
                    # Check if we should continue
                    let continue_on_error = $node.config.continue_on_error? | default false
                    if not $continue_on_error {
                        break
                    }
                } else {
                    $data_flow = ($data_flow | insert $phase_name $result.result)
                    $completed = ($completed | append $phase_name)
                }
            }
        }
    }
    
    # Compile results
    {
        completed: $completed,
        failed: $failed,
        data_flow: $data_flow,
        final_output: ($data_flow | get -i ($completed | last)),
        execution_time: null,  # Would track total time
        status: (if ($failed | is-empty) { "success" } else { "partial_failure" })
    }
}

# Compute execution levels for parallel execution
# Returns array of arrays, where each inner array contains phases that can run in parallel
def compute-execution-levels [hg: record, order: list] {
    mut levels = []
    mut assigned = {}
    
    for phase in $order {
        # Get max level of all dependencies
        let incoming = ($hg | hypergraph incoming $phase)
        let dep_levels = ($incoming | each {|edge|
            $assigned | get -i $edge.data.source | default -1
        })
        
        let my_level = if ($dep_levels | is-empty) {
            0
        } else {
            ($dep_levels | math max) + 1
        }
        
        # Ensure level exists
        while ($levels | length) <= $my_level {
            $levels = ($levels | append [[]])
        }
        
        # Add phase to its level
        $levels = ($levels | enumerate | each {|lvl|
            if $lvl.index == $my_level {
                $lvl.item | append $phase
            } else {
                $lvl.item
            }
        })
        
        $assigned = ($assigned | insert $phase $my_level)
    }
    
    $levels
}

# Start health monitoring for a phase
export def "phase monitor" [
    name: string,
    --interval: duration = 5sec,
    --restart: bool = true
] {
    print $"Starting health monitor for phase: ($name)"
    
    job spawn {
        mut healthy = true
        mut consecutive_failures = 0
        
        while true {
            sleep $interval
            
            # Check phase health
            let check_result = try {
                # Health check logic would go here
                # For now, assume healthy if we can ping
                { status: "healthy", timestamp: (date now) }
            } catch {|e|
                { status: "unhealthy", error: $e.msg, timestamp: (date now) }
            }
            
            if $check_result.status == "unhealthy" {
                $consecutive_failures = $consecutive_failures + 1
                print $"Health check failed for ($name): ($check_result.error) [($consecutive_failures) consecutive]"
                
                if $consecutive_failures >= 3 and $restart {
                    print $"Restarting phase ($name)..."
                    # Restart logic would go here
                    $consecutive_failures = 0
                }
            } else {
                $consecutive_failures = 0
            }
        }
    }
}

# Stop a running phase
export def "phase stop" [name: string] {
    print $"Stopping phase: ($name)"
    # Would signal the phase to stop gracefully
    { phase: $name, action: "stopped", timestamp: (date now) }
}

# Restart a phase
export def "phase restart" [
    name: string,
    --input: any = null,
    --config: record = {}
] {
    print $"Restarting phase: ($name)"
    phase stop $name
    sleep 1sec
    phase run $name --input $input --config $config
}

# Get status of all phases in a pipeline
export def "phase status" [hg: record] {
    $hg | hypergraph list-nodes | each {|node|
        {
            name: $node.id,
            phase: $node.phase,
            status: $node.status,
            run_count: $node.run_count,
            error_count: $node.error_count,
            last_run: $node.last_run
        }
    }
}

# Wait for a phase to complete
export def "phase wait" [
    name: string,
    --timeout: duration = 60sec
] {
    print $"Waiting for phase ($name)..."
    let start = (date now)
    
    while ((date now) - $start) < $timeout {
        # Check if phase is complete
        # This would check shared state
        sleep 100ms
    }
    
    print $"Phase ($name) wait timeout"
    { phase: $name, status: "timeout" }
}

# Execute a batch of phases with dependency resolution
export def "phase batch" [
    phases: list,            # List of phase configurations
    --parallel: bool = true,
    --max-concurrency: int = 4
] {
    print $"Executing batch of ($phases | length) phases"
    
    # Build dependency graph
    mut hg = (hypergraph new)
    
    for phase in $phases {
        $hg = ($hg | hypergraph add-node $phase.name $phase.phase $phase.config)
    }
    
    # Add edges based on dependencies
    for phase in $phases {
        for dep in ($phase.dependencies? | default []) {
            $hg = ($hg | hypergraph add-edge $dep $phase.name {
                stream: $phase.input_stream? | default "data"
            })
        }
    }
    
    # Execute the pipeline
    phase pipeline $hg --parallel $parallel
}
