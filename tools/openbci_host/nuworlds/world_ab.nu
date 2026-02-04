# world_ab.nu
# World A/B testing commands for managing world variants
# Supports a://, b://, c:// URI schemes for world variants

use config.nu *
use state_manager.nu *

# =============================================================================
# World State Storage
# =============================================================================

# Get worlds storage directory
export def worlds-dir []: [ nothing -> path ] {
    $nu.home-path | path join ".config" "nuworlds" "worlds"
}

# Ensure worlds directory exists
export def ensure-worlds-dir []: [ nothing -> nothing ] {
    mkdir (worlds-dir)
}

# =============================================================================
# World URI Parsing
# =============================================================================

# Parse world URI into components
export def parse-world-uri [uri: string]: [ nothing -> record ] {
    let pattern = '^(?<scheme>[abc])://(?<name>[^/]+)(?:/(?<path>.*))?$'
    
    if ($uri | find -r $pattern | is-empty) {
        error make { msg: $"Invalid world URI: ($uri). Expected format: [abc]://world-name" }
    }
    
    let match = ($uri | parse -r $pattern | get 0)
    
    {
        scheme: $match.scheme
        name: $match.name
        path: ($match | get -i path | default "")
        full: $uri
        variant: (match $match.scheme {
            "a" => "baseline"
            "b" => "variant"
            "c" => "experimental"
            _ => "unknown"
        })
    }
}

# Build world URI from components
export def build-world-uri [
    scheme: string      # a, b, or c
    name: string        # world name
    --path: string = "" # optional path
]: [ nothing -> string ] {
    if $path != "" {
        $"($scheme)://($name)/($path)"
    } else {
        $"($scheme)://($name)"
    }
}

# =============================================================================
# World Creation
# =============================================================================

# Create a new world variant
export def "world create" [
    uri: string                     # World URI (a://name, b://name, c://name)
    --param: record = {}            # World parameters (e.g., {physics.gravity: 9.8})
    --template: string = "default"  # Base template to use
    --from: string = ""             # Clone from existing world
]: [ nothing -> record ] {
    ensure-worlds-dir
    
    let parsed = (parse-world-uri $uri)
    let world_file = (worlds-dir | path join $"($parsed.scheme)_($parsed.name).nuon")
    
    # Check if world already exists
    if ($world_file | path exists) {
        error make { msg: $"World ($uri) already exists. Use 'world clone' to copy." }
    }
    
    # Build parameter tree
    mut params = {}
    for key in ($param | columns) {
        let val = ($param | get $key)
        # Handle nested keys like "physics.gravity"
        let key_parts = ($key | split ".")
        $params = ($params | merge (build-nested-record $key_parts $val))
    }
    
    # Create world record
    mut world = {
        uri: $uri
        scheme: $parsed.scheme
        name: $parsed.name
        variant: $parsed.variant
        template: $template
        params: $params
        created_at: (date now)
        updated_at: (date now)
        entities: {}
        sensors: {}
        connections: {}
        events: []
        state_hash: ""
        version: 0
        snapshots: []
    }
    
    # Clone from existing if specified
    if $from != "" {
        let from_parsed = (parse-world-uri $from)
        let from_file = (worlds-dir | path join $"($from_parsed.scheme)_($from_parsed.name).nuon")
        
        if not ($from_file | path exists) {
            error make { msg: $"Source world ($from) not found" }
        }
        
        let source_world = (open $from_file)
        $world = ($world | merge {
            entities: $source_world.entities
            sensors: $source_world.sensors
            connections: $source_world.connections
            cloned_from: $from
        })
    }
    
    # Calculate initial state hash
    $world = ($world | upsert state_hash (compute-state-hash $world))
    
    # Save world
    $world | save -f $world_file
    
    print $"✓ Created world ($uri) [($parsed.variant)]"
    if ($params | is-not-empty) {
        print $"  Parameters: ($params | table)"
    }
    
    $world
}

# Build nested record from key parts
export def build-nested-record [parts: list, value: any]: [ nothing -> record ] {
    if ($parts | length) == 1 {
        { ($parts | get 0): $value }
    } else {
        let first = ($parts | get 0)
        let rest = ($parts | skip 1)
        { $first: (build-nested-record $rest $value) }
    }
}

# Compute content hash of world state
export def compute-state-hash [world: record]: [ nothing -> string ] {
    let state = ($world | select entities sensors connections | to json)
    # Simple hash using built-in hash functionality
    $state | hash sha256 | str substring 0..16
}

# =============================================================================
# World Listing
# =============================================================================

# List all active worlds
export def "world list" [
    --scheme: string = ""    # Filter by scheme (a, b, c)
    --format: string = "table"  # Output format: table, json, uri
]: [ nothing -> table ] {
    ensure-worlds-dir
    
    let world_files = (ls (worlds-dir)/*.nuon | default [])
    
    if ($world_files | is-empty) {
        print "No worlds found. Create one with: world create a://name"
        return []
    }
    
    mut worlds = []
    
    for file in $world_files {
        let world = (open $file.name)
        $worlds = ($worlds | append {
            uri: $world.uri
            scheme: $world.scheme
            name: $world.name
            variant: $world.variant
            version: $world.version
            entities: ($world.entities | length)
            sensors: ($world.sensors | length)
            created_at: $world.created_at
            updated_at: $world.updated_at
            state_hash: $world.state_hash
        })
    }
    
    # Apply scheme filter
    if $scheme != "" {
        $worlds = ($worlds | where scheme == $scheme)
    }
    
    # Format output
    match $format {
        "uri" => { $worlds | get uri }
        "json" => { $worlds | to json }
        _ => { $worlds }
    }
}

# =============================================================================
# World Comparison
# =============================================================================

# Compare two worlds and show differences
export def "world compare" [
    uri_a: string    # First world URI
    uri_b: string    # Second world URI
    --deep: bool     # Deep comparison of all entities
]: [ nothing -> record ] {
    let world_a = (load-world $uri_a)
    let world_b = (load-world $uri_b)
    
    print $"Comparing ($uri_a) vs ($uri_b)..."
    
    mut diff = {
        uri_a: $uri_a
        uri_b: $uri_b
        identical: false
        params_diff: {}
        entities_diff: { added: [], removed: [], modified: [] }
        sensors_diff: { added: [], removed: [], modified: [] }
        connections_diff: { added: [], removed: [], modified: [] }
        summary: {}
    }
    
    # Compare parameters
    let params_a = ($world_a | get -i params | default {})
    let params_b = ($world_b | get -i params | default {})
    $diff.params_diff = (compare-records $params_a $params_b)
    
    # Compare entities
    $diff.entities_diff = (compare-collections $world_a.entities $world_b.entities $deep)
    
    # Compare sensors
    $diff.sensors_diff = (compare-collections $world_a.sensors $world_b.sensors $deep)
    
    # Compare connections
    $diff.connections_diff = (compare-collections $world_a.connections $world_b.connections $deep)
    
    # Check if identical
    $diff.identical = (
        ($diff.params_diff | is-empty) and
        ($diff.entities_diff.added | is-empty) and
        ($diff.entities_diff.removed | is-empty) and
        ($diff.entities_diff.modified | is-empty) and
        ($diff.sensors_diff.added | is-empty) and
        ($diff.sensors_diff.removed | is-empty) and
        ($diff.sensors_diff.modified | is-empty)
    )
    
    # Build summary
    $diff.summary = {
        entity_changes: ($diff.entities_diff.added | length) + ($diff.entities_diff.removed | length) + ($diff.entities_diff.modified | length)
        sensor_changes: ($diff.sensors_diff.added | length) + ($diff.sensors_diff.removed | length) + ($diff.sensors_diff.modified | length)
        connection_changes: ($diff.connections_diff.added | length) + ($diff.connections_diff.removed | length) + ($diff.connections_diff.modified | length)
        param_changes: ($diff.params_diff | length)
    }
    
    # Print summary
    if $diff.identical {
        print "✓ Worlds are identical"
    } else {
        print $"Parameter changes: ($diff.summary.param_changes)"
        print $"Entity changes: +($diff.entities_diff.added | length) -($diff.entities_diff.removed | length) ~($diff.entities_diff.modified | length)"
        print $"Sensor changes: +($diff.sensors_diff.added | length) -($diff.sensors_diff.removed | length) ~($diff.sensors_diff.modified | length)"
        print $"Connection changes: +($diff.connections_diff.added | length) -($diff.connections_diff.removed | length) ~($diff.connections_diff.modified | length)"
    }
    
    $diff
}

# Compare two records
export def compare-records [a: record, b: record]: [ nothing -> record ] {
    let keys_a = ($a | columns)
    let keys_b = ($b | columns)
    
    mut diff = {}
    
    # Find modified or in a only
    for key in $keys_a {
        let val_a = ($a | get $key)
        if $key in $keys_b {
            let val_b = ($b | get $key)
            if ($val_a | to json) != ($val_b | to json) {
                $diff = ($diff | insert $key { old: $val_a, new: $val_b })
            }
        } else {
            $diff = ($diff | insert $key { old: $val_a, new: null })
        }
    }
    
    # Find in b only
    for key in $keys_b {
        if $key not-in $keys_a {
            $diff = ($diff | insert $key { old: null, new: ($b | get $key) })
        }
    }
    
    $diff
}

# Compare two collections (entities, sensors, connections)
export def compare-collections [a: record, b: record, deep: bool]: [ nothing -> record ] {
    let keys_a = ($a | columns)
    let keys_b = ($b | columns)
    
    let added = ($keys_b | where {|k| $k not-in $keys_a})
    let removed = ($keys_a | where {|k| $k not-in $keys_b})
    
    mut modified = []
    
    if $deep {
        # Deep comparison for common keys
        let common = ($keys_a | where {|k| $k in $keys_b})
        for key in $common {
            let item_a = ($a | get $key)
            let item_b = ($b | get $key)
            if ($item_a | to json) != ($item_b | to json) {
                $modified = ($modified | append {
                    id: $key
                    diff: (compare-records $item_a $item_b)
                })
            }
        }
    }
    
    { added: $added, removed: $removed, modified: $modified }
}

# =============================================================================
# World Cloning
# =============================================================================

# Clone a world to a new URI
export def "world clone" [
    source_uri: string      # Source world URI
    target_uri: string      # Target world URI
    --snapshot: bool        # Create snapshot before cloning
]: [ nothing -> record ] {
    let source = (load-world $source_uri)
    let target_parsed = (parse-world-uri $target_uri)
    let target_file = (worlds-dir | path join $"($target_parsed.scheme)_($target_parsed.name).nuon")
    
    if ($target_file | path exists) {
        error make { msg: $"Target world ($target_uri) already exists" }
    }
    
    # Create snapshot if requested
    if $snapshot {
        world snapshot $source_uri
    }
    
    # Clone world
    mut target = $source
    $target = ($target | upsert uri $target_uri)
    $target = ($target | upsert scheme $target_parsed.scheme)
    $target = ($target | upsert name $target_parsed.name)
    $target = ($target | upsert variant $target_parsed.variant)
    $target = ($target | upsert cloned_from $source_uri)
    $target = ($target | upsert cloned_at (date now))
    $target = ($target | upsert version 0)
    $target = ($target | upsert created_at (date now))
    $target = ($target | upsert updated_at (date now))
    
    # Save cloned world
    $target | save -f $target_file
    
    print $"✓ Cloned ($source_uri) → ($target_uri)"
    $target
}

# =============================================================================
# World Snapshots
# =============================================================================

# Create a snapshot of world state
export def "world snapshot" [
    uri: string           # World URI
    --message: string = ""  # Optional snapshot message
]: [ nothing -> record ] {
    let world = (load-world $uri)
    let parsed = (parse-world-uri $uri)
    
    let snapshot = {
        version: $world.version
        timestamp: (date now)
        message: $message
        state_hash: $world.state_hash
        entity_count: ($world.entities | length)
        sensor_count: ($world.sensors | length)
    }
    
    # Add to world snapshots
    mut updated_world = $world
    $updated_world = ($updated_world | upsert snapshots {||
        ($world.snapshots | default []) | append $snapshot
    })
    $updated_world = ($updated_world | upsert version ($world.version + 1))
    
    # Save
    let world_file = (worlds-dir | path join $"($parsed.scheme)_($parsed.name).nuon")
    $updated_world | save -f $world_file
    
    print $"✓ Snapshot created for ($uri) [v($snapshot.version)]"
    $snapshot
}

# List snapshots for a world
export def "world snapshots" [
    uri: string          # World URI
]: [ nothing -> table ] {
    let world = (load-world $uri)
    $world | get -i snapshots | default []
}

# =============================================================================
# World Loading Helper
# =============================================================================

# Load world from URI
export def load-world [uri: string]: [ nothing -> record ] {
    let parsed = (parse-world-uri $uri)
    let world_file = (worlds-dir | path join $"($parsed.scheme)_($parsed.name).nuon")
    
    if not ($world_file | path exists) {
        error make { msg: $"World ($uri) not found" }
    }
    
    open $world_file
}

# Save world to storage
export def save-world [world: record]: [ nothing -> nothing ] {
    let parsed = (parse-world-uri $world.uri)
    let world_file = (worlds-dir | path join $"($parsed.scheme)_($parsed.name).nuon")
    
    $world | save -f $world_file
}

# =============================================================================
# World Deletion
# =============================================================================

# Delete a world
export def "world delete" [
    uri: string           # World URI to delete
    --force: bool         # Skip confirmation
]: [ nothing -> nothing ] {
    let parsed = (parse-world-uri $uri)
    let world_file = (worlds-dir | path join $"($parsed.scheme)_($parsed.name).nuon")
    
    if not ($world_file | path exists) {
        print $"World ($uri) not found"
        return
    }
    
    if not $force {
        print $"Are you sure you want to delete ($uri)? [y/N]"
        let confirm = (input)
        if ($confirm | downcase) != "y" {
            print "Cancelled"
            return
        }
    }
    
    rm $world_file
    print $"✓ Deleted ($uri)"
}

# =============================================================================
# World Info
# =============================================================================

# Show detailed world information
export def "world info" [
    uri: string           # World URI
]: [ nothing -> record ] {
    let world = (load-world $uri)
    
    let info = {
        uri: $world.uri
        scheme: $world.scheme
        name: $world.name
        variant: $world.variant
        template: $world.template
        version: $world.version
        created_at: $world.created_at
        updated_at: $world.updated_at
        entity_count: ($world.entities | length)
        sensor_count: ($world.sensors | length)
        connection_count: ($world.connections | length)
        event_count: ($world.events | length)
        snapshot_count: ($world.snapshots | length)
        state_hash: $world.state_hash
        cloned_from: ($world | get -i cloned_from | default "(original)")
        params: $world.params
    }
    
    print $"World: ($uri)"
    print $"  Variant: ($info.variant)"
    print $"  Template: ($info.template)"
    print $"  Version: ($info.version)"
    print $"  Entities: ($info.entity_count)"
    print $"  Sensors: ($info.sensor_count)"
    print $"  Connections: ($info.connection_count)"
    print $"  Snapshots: ($info.snapshot_count)"
    print $"  State Hash: ($info.state_hash)"
    
    $info
}
