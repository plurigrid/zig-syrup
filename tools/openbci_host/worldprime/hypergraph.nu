# hypergraph.nu
# Core hypergraph data structure for BCI pipeline orchestration
# Nuworlds uses hypergraph structures for data flow between processing phases

# Node record type representing a processing phase
# id: unique identifier
# phase: phase type (acquisition, preprocessing, analysis, output)
# config: phase-specific configuration
# status: current node status (idle, running, error, completed)
# created_at: timestamp
export def Node [id: string, phase: string, config: record] {
    {
        id: $id,
        phase: $phase,
        config: $config,
        status: "idle",
        created_at: (date now),
        last_run: null,
        run_count: 0,
        error_count: 0
    }
}

# Edge record type representing data stream connections
# id: unique identifier
# source: source node id
# target: target node id  
# stream: stream name/type
# config: edge-specific configuration (buffer size, backpressure, etc)
export def Edge [id: string, source: string, target: string, stream: string, config: record] {
    {
        id: $id,
        source: $source,
        target: $target,
        stream: $stream,
        config: ($config | default {
            buffer_size: 1024,
            backpressure: "drop_oldest",  # drop_oldest, block, throttle
            multiplex: false
        }),
        active: true,
        messages_passed: 0,
        bytes_transferred: 0,
        created_at: (date now)
    }
}

# Create a new empty hypergraph
# Returns: record with nodes, edges, and metadata
export def "hypergraph new" [] {
    {
        id: (random uuid),
        nodes: {},
        edges: {},
        metadata: {
            created_at: (date now),
            version: "1.0",
            name: "unnamed_pipeline"
        },
        state: {
            running: false,
            current_phase: null,
            execution_order: [],
            last_error: null
        }
    }
}

# Add a processing phase node to the hypergraph
# Usage: $hg | hypergraph add-node <id> <phase> <config>
export def "hypergraph add-node" [
    id: string,           # Unique node identifier
    phase: string,        # Phase type: acquisition, preprocessing, analysis, output
    config: record        # Node configuration (type, parameters, etc)
] {
    let hg = $in
    let node = (Node $id $phase $config)
    
    # Check for duplicate node id
    if ($id in $hg.nodes) {
        error make {
            msg: $"Node '($id)' already exists in hypergraph",
            label: "hypergraph add-node"
        }
    }
    
    # Return updated hypergraph
    $hg | upsert nodes {|| 
        $hg.nodes | insert $id $node
    }
}

# Add a data stream edge between nodes
# Usage: $hg | hypergraph add-edge <source> <target> <config>
export def "hypergraph add-edge" [
    source: string,       # Source node id
    target: string,       # Target node id
    config: record        # Edge config including stream name
] {
    let hg = $in
    
    # Validate nodes exist
    if ($source not-in $hg.nodes) {
        error make {
            msg: $"Source node '($source)' does not exist",
            label: "hypergraph add-edge"
        }
    }
    if ($target not-in $hg.nodes) {
        error make {
            msg: $"Target node '($target)' does not exist",
            label: "hypergraph add-edge"
        }
    }
    
    let edge_id = $"($source)_to_($target)_($config.stream? | default 'data')"
    let stream_name = ($config.stream? | default "data")
    
    # Create edge with filtered config (remove stream from config, it's a top-level field)
    let edge_config = ($config | reject -i stream)
    let edge = (Edge $edge_id $source $target $stream_name $edge_config)
    
    # Return updated hypergraph
    $hg | upsert edges {||
        $hg.edges | insert $edge_id $edge
    }
}

# Get a node by id
export def "hypergraph get-node" [id: string] {
    let hg = $in
    $hg.nodes | get $id
}

# Get an edge by id
export def "hypergraph get-edge" [id: string] {
    let hg = $in
    $hg.edges | get $id
}

# List all nodes in the hypergraph
export def "hypergraph list-nodes" [] {
    let hg = $in
    $hg.nodes | transpose id data | flatten
}

# List all edges in the hypergraph
export def "hypergraph list-edges" [] {
    let hg = $in
    $hg.edges | transpose id data | flatten
}

# Get incoming edges for a node
export def "hypergraph incoming" [node_id: string] {
    let hg = $in
    $hg.edges | transpose id data | flatten | where data.target == $node_id
}

# Get outgoing edges for a node
export def "hypergraph outgoing" [node_id: string] {
    let hg = $in
    $hg.edges | transpose id data | flatten | where data.source == $node_id
}

# Get neighbors (connected nodes) for a node
export def "hypergraph neighbors" [node_id: string] {
    let hg = $in
    let outgoing = ($hg | hypergraph outgoing $node_id | get -i data.target)
    let incoming = ($hg | hypergraph incoming $node_id | get -i data.source)
    $outgoing | append $incoming | uniq
}

# Traverse the hypergraph starting from a node
# mode: bfs (breadth-first), dfs (depth-first)
export def "hypergraph traverse" [
    start_node?: string,  # Starting node (defaults to first node)
    --mode: string = "bfs"  # Traversal mode: bfs or dfs
] {
    let hg = $in
    
    # Default to first node if not specified
    let start = if ($start_node == null) {
        $hg.nodes | columns | first
    } else {
        $start_node
    }
    
    if ($start == null) {
        error make {
            msg: "No nodes in hypergraph",
            label: "hypergraph traverse"
        }
    }
    
    mut visited = [$start]
    mut result = [($hg.nodes | get $start)]
    mut queue = [$start]
    
    while ($queue | length) > 0 {
        let current = if $mode == "bfs" {
            let c = $queue.0
            $queue = ($queue | skip 1)
            $c
        } else {
            let c = ($queue | last)
            $queue = ($queue | drop 1)
            $c
        }
        
        # Get neighbors via outgoing edges
        let neighbors = ($hg | hypergraph outgoing $current | get -i data.target)
        
        for neighbor in $neighbors {
            if $neighbor not-in $visited {
                $visited = ($visited | append $neighbor)
                $result = ($result | append ($hg.nodes | get $neighbor))
                $queue = ($queue | append $neighbor)
            }
        }
    }
    
    $result
}

# Topological sort for DAG execution order
export def "hypergraph topo-sort" [] {
    let hg = $in
    
    mut in_degree = {}
    mut adjacency = {}
    
    # Initialize
    for node_id in ($hg.nodes | columns) {
        $in_degree = ($in_degree | insert $node_id 0)
        $adjacency = ($adjacency | insert $node_id [])
    }
    
    # Build adjacency list and calculate in-degrees
    for edge in ($hg.edges | columns) {
        let e = ($hg.edges | get $edge)
        $in_degree = ($in_degree | upsert $e.target { ($in_degree | get $e.target) + 1 })
        $adjacency = ($adjacency | upsert $e.source { ($adjacency | get $e.source) | append $e.target })
    }
    
    # Kahn's algorithm
    mut queue = ($in_degree | transpose node degree | where degree == 0 | get node)
    mut result = []
    
    while ($queue | length) > 0 {
        let node = $queue.0
        $queue = ($queue | skip 1)
        $result = ($result | append $node)
        
        for neighbor in ($adjacency | get $node) {
            $in_degree = ($in_degree | upsert $neighbor { ($in_degree | get $neighbor) - 1 })
            if (($in_degree | get $neighbor) == 0) {
                $queue = ($queue | append $neighbor)
            }
        }
    }
    
    # Check for cycles
    if ($result | length) != ($hg.nodes | length) {
        error make {
            msg: "Hypergraph contains cycles - cannot perform topological sort",
            label: "hypergraph topo-sort"
        }
    }
    
    $result
}

# Execute the hypergraph pipeline with data flow
export def "hypergraph execute" [
    --input: any = null,   # Initial input data
    --context: record = {}  # Execution context
] {
    let hg = $in
    
    # Get execution order
    let order = try {
        $hg | hypergraph topo-sort
    } catch {|e|
        error make {
            msg: $"Failed to determine execution order: ($e.msg)",
            label: "hypergraph execute"
        }
    }
    
    # Update hypergraph state
    mut hg_mut = ($hg | upsert state.running true)
    $hg_mut = ($hg_mut | upsert state.execution_order $order)
    
    # Data flow storage: node_id -> output_data
    mut data_flow = {}
    if $input != null {
        $data_flow = ($data_flow | insert "__input__" $input)
    }
    
    # Execute each node in order
    for node_id in $order {
        $hg_mut = ($hg_mut | upsert state.current_phase $node_id)
        
        let node = ($hg_mut.nodes | get $node_id)
        
        # Collect inputs from incoming edges
        let incoming = ($hg_mut | hypergraph incoming $node_id)
        mut node_input = {}
        
        for edge in $incoming {
            let source_output = $data_flow | get -i $edge.data.source
            if $source_output != null {
                $node_input = ($node_input | insert $edge.data.stream $source_output)
            }
        }
        
        # If no incoming data, use initial input for first node
        if (($node_input | is-empty)) and ($input != null) {
            $node_input = $input
        }
        
        # Execute the node
        print $"Executing node: ($node_id) [($node.phase)]"
        
        let result = try {
            # Get the executor from config or use default
            let executor = $node.config.executor?
            if $executor != null {
                # Execute the closure/function
                do $executor $node_input $node.config $context
            } else {
                # Default pass-through
                $node_input
            }
        } catch {|e|
            $hg_mut = ($hg_mut | upsert state.last_error $e.msg)
            $hg_mut = ($hg_mut | upsert nodes.($node_id).status "error")
            $hg_mut = ($hg_mut | upsert nodes.($node_id).error_count { ($node.error_count + 1) })
            
            if $node.config.continue_on_error? == true {
                print $"Warning: Node ($node_id) failed: ($e.msg)"
                null
            } else {
                $hg_mut = ($hg_mut | upsert state.running false)
                error make {
                    msg: $"Node '($node_id)' execution failed: ($e.msg)",
                    label: "hypergraph execute"
                }
            }
        }
        
        # Store output for downstream nodes
        if $result != null {
            $data_flow = ($data_flow | insert $node_id $result)
        }
        
        # Update node status
        $hg_mut = ($hg_mut | upsert nodes.($node_id).status "completed")
        $hg_mut = ($hg_mut | upsert nodes.($node_id).last_run (date now))
        $hg_mut = ($hg_mut | upsert nodes.($node_id).run_count { ($node.run_count + 1) })
        
        # Update edge stats
        for edge in ($hg_mut | hypergraph outgoing $node_id) {
            $hg_mut = ($hg_mut | upsert edges.($edge.id).messages_passed { ($edge.data.messages_passed + 1) })
        }
    }
    
    $hg_mut | upsert state.running false
}

# Visualize the hypergraph structure (returns mermaid diagram)
export def "hypergraph visualize" [] {
    let hg = $in
    
    mut diagram = "flowchart LR\n"
    
    # Add nodes
    for node_id in ($hg.nodes | columns) {
        let node = ($hg.nodes | get $node_id)
        let shape = match $node.phase {
            "acquisition" => "((($node_id)))",
            "preprocessing" => "[$node_id]",
            "analysis" => "{{$node_id}}",
            "output" => "[/$node_id/]",
            _ => "[$node_id]"
        }
        $diagram = $diagram + $"    ($node_id)($shape)\n"
    }
    
    # Add edges
    for edge_id in ($hg.edges | columns) {
        let edge = ($hg.edges | get $edge_id)
        $diagram = $diagram + $"    ($edge.source) -->|($edge.stream)| ($edge.target)\n"
    }
    
    $diagram
}

# Export hypergraph to JSON
export def "hypergraph export" [] {
    $in | to json
}

# Import hypergraph from JSON
export def "hypergraph import" [json_data: string] {
    $json_data | from json
}

# Clone a hypergraph (deep copy)
export def "hypergraph clone" [] {
    let hg = $in
    $hg | to json | from json
}

# Remove a node and its connected edges
export def "hypergraph remove-node" [id: string] {
    let hg = $in
    
    # Remove connected edges
    let edges_to_remove = ($hg.edges | transpose id data | flatten 
        | where data.source == $id or data.target == $id 
        | get id)
    
    mut new_hg = $hg
    for edge_id in $edges_to_remove {
        $new_hg = ($new_hg | upsert edges ($new_hg.edges | reject $edge_id))
    }
    
    # Remove node
    $new_hg | upsert nodes ($new_hg.nodes | reject $id)
}

# Get pipeline statistics
export def "hypergraph stats" [] {
    let hg = $in
    {
        node_count: ($hg.nodes | length),
        edge_count: ($hg.edges | length),
        phases: ($hg.nodes | transpose id data | get -i data.phase | uniq | length),
        running: $hg.state.running,
        total_executions: ($hg.nodes | transpose id data | get -i data.run_count | math sum),
        total_errors: ($hg.nodes | transpose id data | get -i data.error_count | math sum)
    }
}
