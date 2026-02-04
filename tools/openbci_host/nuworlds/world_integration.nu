# world_integration.nu
# Integration with nuworlds environment
# BCI data as world sensors, entities for EEG channels, hypergraph edges as connections

use hypergraph.nu *
use stream_router.nu *

# World state container
export def World [] {
    {
        id: (random uuid),
        name: "bci_world",
        sensors: {},
        entities: {},
        connections: {},
        events: {},
        queries: {},
        spatial_index: {},
        time_index: {},
        metadata: {
            created_at: (date now),
            version: "1.0"
        }
    }
}

# Sensor definition
export def Sensor [
    id: string,
    sensor_type: string,
    config: record
] {
    {
        id: $id,
        type: $sensor_type,
        config: $config,
        data: [],
        last_reading: null,
        active: true,
        created_at: (date now)
    }
}

# Entity definition
export def Entity [
    id: string,
    entity_type: string,
    properties: record
] {
    {
        id: $id,
        type: $entity_type,
        properties: $properties,
        state: {},
        sensors: [],
        connections: [],
        created_at: (date now),
        last_updated: (date now)
    }
}

# Create a new world
export def "world create" [
    name: string = "bci_world"
] {
    World | upsert name $name
}

# Export BCI data as world sensor
export def "world add-sensor" [
    id: string,
    sensor_type: string,     # eeg, emg, eog, imu, etc.
    --channels: list = [],    # Channel names
    --sample-rate: int = 250,
    --location: record = {},  # Spatial location {x, y, z}
    --metadata: record = {}
] {
    let world = $in
    
    let sensor = (Sensor $id $sensor_type {
        channels: $channels,
        sample_rate: $sample_rate,
        location: $location,
        metadata: $metadata
    })
    
    $world | upsert sensors {||
        $world.sensors | insert $id $sensor
    }
}

# Create EEG channel entities
export def "world create-channel-entities" [
    channels: list,           # List of channel names
    --positions: record = {}  # Optional 10-20 positions
] {
    let world = $in
    
    mut new_world = $world
    
    for channel in $channels {
        let position = ($positions | get -i $channel | default {x: 0, y: 0, z: 0})
        
        let entity = (Entity $channel "eeg_channel" {
            label: $channel,
            position: $position,
            impedance: null,
            quality: null,
            reference: "average"
        })
        
        $new_world = ($new_world | upsert entities {||
            $new_world.entities | insert $channel $entity
        })
    }
    
    $new_world
}

# Create hypergraph edges as world connections
export def "world add-connection" [
    id: string,
    source: string,           # Source entity/sensor ID
    target: string,           # Target entity/sensor ID
    connection_type: string,  # data_flow, control, reference
    --properties: record = {},
    --bidirectional: bool = false
] {
    let world = $in
    
    let connection = {
        id: $id,
        source: $source,
        target: $target,
        type: $connection_type,
        properties: $properties,
        bidirectional: $bidirectional,
        active: true,
        data_transferred: 0,
        created_at: (date now)
    }
    
    mut new_world = $world
    
    # Add connection to world
    $new_world = ($new_world | upsert connections {||
        $world.connections | insert $id $connection
    })
    
    # Update entity connection lists
    if ($source in $new_world.entities) {
        $new_world = ($new_world | upsert entities.($source).connections {||
            ($new_world.entities | get $source | get connections) | append $id
        })
    }
    
    if ($target in $new_world.entities) {
        $new_world = ($new_world | upsert entities.($target).connections {||
            ($new_world.entities | get $target | get connections) | append $id
        })
    }
    
    $new_world
}

# Convert hypergraph to world connections
export def "world from-hypergraph" [hg: record] {
    let world = $in
    
    mut new_world = $world
    
    # Create entities from nodes
    for node_id in ($hg.nodes | columns) {
        let node = ($hg.nodes | get $node_id)
        
        let entity = (Entity $node_id $node.phase {
            phase: $node.phase,
            config: $node.config,
            status: $node.status
        })
        
        $new_world = ($new_world | upsert entities {||
            $new_world.entities | insert $node_id $entity
        })
    }
    
    # Create connections from edges
    for edge_id in ($hg.edges | columns) {
        let edge = ($hg.edges | get $edge_id)
        
        $new_world = ($new_world | world add-connection 
            $edge_id 
            $edge.source 
            $edge.target 
            "data_flow"
            --properties {
                stream: $edge.stream,
                buffer_size: $edge.config.buffer_size,
                backpressure: $edge.config.backpressure
            }
        )
    }
    
    $new_world
}

# Query world state
export def "world query" [
    query_string: string      # Query in world query language
] {
    let world = $in
    
    # Parse query string
    # Examples:
    #   "eeg.alpha > 0.5"
    #   "channel.Fp1.quality > 0.8"
    #   "entity.type == eeg_channel"
    #   "sensor.data[alpha] > threshold"
    
    let parts = ($query_string | split row " ")
    
    match $parts {
        [$entity, $op, $value] => {
            # Simple query: entity operator value
            match $op {
                ">" => {
                    $world.entities | transpose id data | where data.properties.?${entity} > ($value | into float)
                },
                "==" => {
                    $world.entities | transpose id data | where data.properties.?${entity} == $value
                },
                _ => {
                    print $"Unknown operator: ($op)"
                    []
                }
            }
        },
        [$type, ".", $field, $op, $value] => {
            # Typed query: type.field operator value
            match $type {
                "eeg" => {
                    # Query EEG band power
                    $world.sensors | transpose id data | where {
                        let sensor = $in.data
                        let band_value = ($sensor.data | last? | get -i $field | default 0)
                        match $op {
                            ">" => { $band_value > ($value | into float) },
                            "<" => { $band_value < ($value | into float) },
                            _ => false
                        }
                    }
                },
                _ => {
                    print $"Unknown type: ($type)"
                    []
                }
            }
        },
        _ => {
            # Complex query - would use a proper query parser
            print $"Complex queries not yet implemented: ($query_string)"
            []
        }
    }
}

# Event system
export def "world on" [
    event: string,            # Event name/pattern
    handler: closure,         # Event handler
    --priority: int = 0,     # Handler priority
    --once: bool = false     # Only trigger once
] {
    let world = $in
    
    let event_handler = {
        id: (random uuid),
        pattern: $event,
        handler: $handler,
        priority: $priority,
        once: $once,
        trigger_count: 0,
        created_at: (date now)
    }
    
    $world | upsert events {||
        if $event in $world.events {
            $world.events | upsert $event {||
                ($world.events | get $event) | append $event_handler
            }
        } else {
            $world.events | insert $event [$event_handler]
        }
    }
}

# Trigger an event
export def "world trigger" [
    event: string,
    --data: any = null
] {
    let world = $in
    
    print $"Triggering event: ($event)"
    
    # Find matching handlers
    let handlers = ($world.events | transpose name handlers | where {
        $event =~ $in.name or $in.name =~ $event
    } | get -i handlers | flatten)
    
    if $handlers == null {
        return $world
    }
    
    mut new_world = $world
    
    for handler in ($handlers | sort-by priority -r) {
        try {
            do $handler.handler $event $data
            
            # Update trigger count
            if $handler.once {
                # Remove one-time handlers
                $new_world = ($new_world | upsert events {||
                    $new_world.events | upsert $event {||
                        ($new_world.events | get $event) | where id != $handler.id
                    }
                })
            }
        } catch {|e|
            print $"Event handler error for '($event)': ($e.msg)"
        }
    }
    
    $new_world
}

# Update sensor data
export def "world update-sensor" [
    sensor_id: string,
    data: record
] {
    let world = $in
    
    if ($sensor_id not-in $world.sensors) {
        print $"Sensor '($sensor_id)' not found"
        return $world
    }
    
    let sensor = ($world.sensors | get $sensor_id)
    
    # Add to data buffer
    mut updated_sensor = $sensor
    $updated_sensor = ($updated_sensor | upsert data {||
        ($sensor.data | append $data) | last 1000  # Keep last 1000 samples
    })
    $updated_sensor = ($updated_sensor | upsert last_reading $data)
    
    $world | upsert sensors.($sensor_id) $updated_sensor
}

# Update entity state
export def "world update-entity" [
    entity_id: string,
    state: record
] {
    let world = $in
    
    if ($entity_id not-in $world.entities) {
        print $"Entity '($entity_id)' not found"
        return $world
    }
    
    $world 
    | upsert entities.($entity_id).state {||
        ($world.entities | get $entity_id | get state) | merge $state
    }
    | upsert entities.($entity_id).last_updated (date now)
}

# Get spatial neighbors
export def "world neighbors" [
    entity_id: string,
    --radius: float = 1.0
] {
    let world = $in
    
    if ($entity_id not-in $world.entities) {
        print $"Entity '($entity_id)' not found"
        return []
    }
    
    let entity = ($world.entities | get $entity_id)
    let pos = ($entity.properties.position | default {x: 0, y: 0, z: 0})
    
    # Find neighbors within radius
    $world.entities | transpose id data | where {|e|
        if $e.id == $entity_id { return false }
        let e_pos = ($e.data.properties.position? | default {x: 0, y: 0, z: 0})
        let dist = (($e_pos.x - $pos.x) ** 2 + ($e_pos.y - $pos.y) ** 2 + ($e_pos.z - $pos.z) ** 2 | math sqrt)
        $dist <= $radius
    }
}

# Export world to JSON
export def "world export" [] {
    $in | to json
}

# Import world from JSON
export def "world import" [json_data: string] {
    $json_data | from json
}

# Create standard BCI world with EEG channels
export def "world create-bci" [
    --channels: list = ["Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2"],
    --positions: record = {}
] {
    mut world = (world create "bci_environment")
    
    # Add EEG sensor
    $world = ($world | world add-sensor "eeg_primary" "eeg" 
        --channels $channels
        --sample-rate 250
        --location {x: 0, y: 0, z: 0}
        --metadata {device: "openbci", firmware: "v3"}
    )
    
    # Create channel entities with standard 10-20 positions
    let default_positions = {
        Fp1: {x: -0.5, y: 0.8, z: 0.3},
        Fp2: {x: 0.5, y: 0.8, z: 0.3},
        F3:  {x: -0.6, y: 0.3, z: 0.4},
        F4:  {x: 0.6, y: 0.3, z: 0.4},
        C3:  {x: -0.5, y: 0, z: 0.5},
        C4:  {x: 0.5, y: 0, z: 0.5},
        P3:  {x: -0.5, y: -0.4, z: 0.4},
        P4:  {x: 0.5, y: -0.4, z: 0.4},
        O1:  {x: -0.3, y: -0.8, z: 0.2},
        O2:  {x: 0.3, y: -0.8, z: 0.2},
        T3:  {x: -0.8, y: 0, z: 0},
        T4:  {x: 0.8, y: 0, z: 0}
    }
    
    let merged_positions = ($default_positions | merge $positions)
    $world = ($world | world create-channel-entities $channels --positions $merged_positions)
    
    # Connect channels to primary sensor
    for channel in $channels {
        $world = ($world | world add-connection 
            $"($channel)_to_sensor"
            $channel
            "eeg_primary"
            "data_flow"
            --properties {stream: "raw_eeg", multiplex: true}
        )
    }
    
    # Add common reference connection
    $world = ($world | world add-connection
        "average_reference"
        "eeg_primary"
        "reference_node"
        "reference"
        --bidirectional true
    )
    
    $world
}

# Monitor world state
export def "world monitor" [
    --interval: duration = 1sec
] {
    let world = $in
    
    print "Starting world monitor..."
    
    # Spawn monitoring job
    job spawn {
        loop {
            # Print world statistics
            print $"Entities: ($world.entities | length) | Sensors: ($world.sensors | length) | Connections: ($world.connections | length)"
            sleep $interval
        }
    }
    
    $world
}

# Snapshot world state
export def "world snapshot" [] {
    let world = $in
    
    {
        timestamp: (date now),
        entity_count: ($world.entities | length),
        sensor_count: ($world.sensors | length),
        connection_count: ($world.connections | length),
        entities: ($world.entities | transpose id data | take 10),
        active_sensors: ($world.sensors | transpose id data | where data.active == true | each {|s|
            {
                id: $s.id,
                type: $s.data.type,
                last_reading: $s.data.last_reading
            }
        })
    }
}
