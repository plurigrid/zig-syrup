# ewig_history.nu
# Eternal history queries for append-only world event logs
# Ewig = eternal/everlasting in German

use world_ab.nu *

# =============================================================================
# History Storage
# =============================================================================

# Get history storage directory
export def history-dir []: [ nothing -> path ] {
    $nu.home-path | path join ".config" "nuworlds" "history"
}

# Ensure history directory exists
export def ensure-history-dir []: [ nothing -> nothing ] {
    mkdir (history-dir)
}

# Get log file for a world
export def world-log-file [uri: string]: [ nothing -> path ] {
    let parsed = (parse-world-uri $uri)
    history-dir | path join $"($parsed.scheme)_($parsed.name).log.nuon"
}

# =============================================================================
# Log Operations
# =============================================================================

# Show append-only log for a world
export def "ewig log" [
    uri: string              # World URI
    --limit: int = 100       # Max events to show
    --follow: bool           # Follow log in real-time
    --format: string = "table"   # Output format
]: [ nothing -> table ] {
    ensure-history-dir
    let log_file = (world-log-file $uri)
    
    if not ($log_file | path exists) {
        # Return empty log if file doesn't exist
        print $"No history found for ($uri)"
        return []
    }
    
    let log = (open $log_file)
    
    if $follow {
        # Real-time following (simplified)
        print $"Following log for ($uri)..."
        print "Press Ctrl+C to stop\n"
        
        mut last_count = ($log | length)
        loop {
            sleep 1sec
            let current_log = (open $log_file)
            let current_count = ($current_log | length)
            
            if $current_count > $last_count {
                let new_events = ($current_log | range $last_count..)
                for event in $new_events {
                    print $"[($event.timestamp | format date "%H:%M:%S")] ($event.type): ($event | get -i description | default "")"
                }
                $last_count = $current_count
            }
        }
    }
    
    let limited_log = ($log | last $limit)
    
    match $format {
        "json" => { $limited_log | to json }
        "compact" => { $limited_log | each { |e| $"($e.timestamp) ($e.type)" } }
        _ => { $limited_log }
    }
}

# Append event to world log
export def "ewig append" [
    uri: string              # World URI
    event_type: string       # Event type
    --data: record = {}      # Event data
    --description: string = ""   # Event description
]: [ nothing -> record ] {
    ensure-history-dir
    let log_file = (world-log-file $uri)
    
    let event = {
        timestamp: (date now)
        type: $event_type
        description: $description
        data: $data
        seq: (if ($log_file | path exists) { (open $log_file | length) } else { 0 })
        hash: ""  # Will be computed
    }
    
    # Compute event hash (includes previous hash for chain)
    let prev_hash = (if ($log_file | path exists) {
        let log = (open $log_file)
        if ($log | is-empty) { "0" } else { $log | last | get hash }
    } else { "0" })
    
    let event_with_prev = ($event | insert prev_hash $prev_hash)
    let hash = ($event_with_prev | to json | hash sha256 | str substring 0..16)
    let final_event = ($event_with_prev | upsert hash $hash)
    
    # Append to log
    mut log = (if ($log_file | path exists) { open $log_file } else { [] })
    $log = ($log | append $final_event)
    $log | save -f $log_file
    
    $final_event
}

# =============================================================================
# Time-based Queries
# =============================================================================

# Get world state at specific timestamp
export def "ewig at" [
    uri: string              # World URI
    timestamp: string        # Timestamp (ISO format or relative)
]: [ nothing -> record ] {
    ensure-history-dir
    let log_file = (world-log-file $uri)
    
    if not ($log_file | path exists) {
        error make { msg: $"No history found for ($uri)" }
    }
    
    let log = (open $log_file)
    
    # Parse target timestamp
    let target = (parse-timestamp $timestamp)
    
    # Find events up to timestamp
    let relevant_events = ($log | where { |e| ($e.timestamp | into datetime) <= $target })
    
    if ($relevant_events | is-empty) {
        print $"No events found before ($timestamp)"
        return {}
    }
    
    # Reconstruct state from events
    let state = (reconstruct-state $relevant_events)
    
    print $"State at ($timestamp):"
    print $"  Events: ($relevant_events | length)"
    print $"  Last event: ($relevant_events | last | get type)"
    
    $state
}

# Parse various timestamp formats
export def parse-timestamp [ts: string]: [ nothing -> datetime ] {
    # Try ISO format first
    try {
        $ts | into datetime
    } catch {
        # Try relative formats
        match $ts {
            "now" => { date now }
            _ if ($ts | str ends-with "ago") => {
                # Parse "5min ago", "1hour ago", etc.
                let parts = ($ts | str replace " ago" "" | split " ")
                let value = ($parts | get 0 | into int)
                let unit = ($parts | get 1)
                
                let duration = (match $unit {
                    "sec" | "secs" | "second" | "seconds" | "s" => { $value * 1sec }
                    "min" | "mins" | "minute" | "minutes" | "m" => { $value * 1min }
                    "hour" | "hours" | "h" => { $value * 1hr }
                    "day" | "days" | "d" => { $value * 1day }
                    _ => { error make { msg: $"Unknown time unit: ($unit)" } }
                })
                
                (date now) - $duration
            }
            _ => { error make { msg: $"Cannot parse timestamp: ($ts)" } }
        }
    }
}

# Reconstruct state from events
export def reconstruct-state [events: list]: [ nothing -> record ] {
    mut state = {
        entities: {}
        sensors: {}
        connections: {}
        metadata: {}
    }
    
    for event in $events {
        $state = (apply-event $state $event)
    }
    
    $state
}

# Apply single event to state
export def apply-event [state: record, event: record]: [ nothing -> record ] {
    match $event.type {
        "entity_created" => {
            $state | upsert entities {||
                $state.entities | insert $event.data.entity_id $event.data.entity
            }
        }
        "entity_updated" => {
            $state | upsert entities.($event.data.entity_id) {||
                ($state.entities | get $event.data.entity_id) | merge $event.data.updates
            }
        }
        "entity_deleted" => {
            $state | reject entities.($event.data.entity_id)
        }
        "sensor_created" => {
            $state | upsert sensors {||
                $state.sensors | insert $event.data.sensor_id $event.data.sensor
            }
        }
        "sensor_data" => {
            $state | upsert sensors.($event.data.sensor_id).data {||
                ($state.sensors | get $event.data.sensor_id | get -i data | default []) | append $event.data.reading
            }
        }
        "connection_created" => {
            $state | upsert connections {||
                $state.connections | insert $event.data.connection_id $event.data.connection
            }
        }
        _ => { $state }
    }
}

# =============================================================================
# Range Queries
# =============================================================================

# Get state range between two timestamps
export def "ewig range" [
    uri: string              # World URI
    start: string            # Start timestamp
    end: string              # End timestamp
    --granularity: string = "event"   # Sampling: event, second, minute, hour
]: [ nothing -> list ] {
    ensure-history-dir
    let log_file = (world-log-file $uri)
    
    if not ($log_file | path exists) {
        error make { msg: $"No history found for ($uri)" }
    }
    
    let log = (open $log_file)
    let start_ts = (parse-timestamp $start)
    let end_ts = (parse-timestamp $end)
    
    # Filter events in range
    let range_events = ($log | where { |e|
        let ts = ($e.timestamp | into datetime)
        $ts >= $start_ts and $ts <= $end_ts
    })
    
    print $"Events in range ($start) to ($end): ($range_events | length)"
    
    match $granularity {
        "event" => { $range_events }
        _ => { sample-events $range_events $granularity }
    }
}

# Sample events by time granularity
export def sample-events [events: list, granularity: string]: [ nothing -> list ] {
    # Group events by time bucket
    mut buckets = {}
    
    for event in $events {
        let bucket = (bucket-timestamp $event.timestamp $granularity)
        $buckets = ($buckets | upsert $bucket {||
            ($buckets | get -i $bucket | default []) | append $event
        })
    }
    
    # Return one representative per bucket
    $buckets | transpose bucket events | each { |row|
        ($row.events | last)
    }
}

# Get bucket key for timestamp
export def bucket-timestamp [ts: datetime, granularity: string]: [ nothing -> string ] {
    match $granularity {
        "second" => { $ts | format date "%Y-%m-%d %H:%M:%S" }
        "minute" => { $ts | format date "%Y-%m-%d %H:%M" }
        "hour" => { $ts | format date "%Y-%m-%d %H" }
        _ => { $ts | format date "%Y-%m-%d %H:%M:%S" }
    }
}

# =============================================================================
# Replay Operations
# =============================================================================

# Replay events from log
export def "ewig replay" [
    uri: string              # World URI
    from: string             # Start event index or timestamp
    to: string               # End event index or timestamp
    --speed: float = 1.0     # Replay speed multiplier
    --callback: any = null   # Callback for each event
]: [ nothing -> record ] {
    ensure-history-dir
    let log_file = (world-log-file $uri)
    
    if not ($log_file | path exists) {
        error make { msg: $"No history found for ($uri)" }
    }
    
    let log = (open $log_file)
    
    # Parse from/to indices
    let from_idx = (if ($from | parse -r '^\d+$' | is-not-empty) {
        $from | into int
    } else {
        # Find by timestamp
        let ts = (parse-timestamp $from)
        $log | where { |e| ($e.timestamp | into datetime) >= $ts } | first | get seq
    })
    
    let to_idx = (if ($to | parse -r '^\d+$' | is-not-empty) {
        $to | into int
    } else {
        let ts = (parse-timestamp $to)
        $log | where { |e| ($e.timestamp | into datetime) <= $ts } | last | get seq
    })
    
    let events = ($log | where { |e| $e.seq >= $from_idx and $e.seq <= $to_idx })
    
    print $"Replaying ($events | length) events from ($uri)..."
    print $"  From event ($from_idx) to ($to_idx)"
    print $"  Speed: {$speed}x\n"
    
    mut state = {
        entities: {}
        sensors: {}
        connections: {}
    }
    
    for event in $events {
        let sleep_time = (if $event.seq > $from_idx {
            # Calculate time since last event
            let prev = ($log | where seq == ($event.seq - 1) | first)
            let delta = (($event.timestamp | into datetime) - ($prev.timestamp | into datetime))
            ($delta | into int) / 1_000_000_000 / $speed
        } else { 0 })
        
        if $sleep_time > 0 {
            sleep ($sleep_time * 1sec)
        }
        
        $state = (apply-event $state $event)
        
        print $"[($event.seq)] ($event.timestamp | format date "%H:%M:%S.%3f") ($event.type)"
        
        # Call callback if provided
        if $callback != null {
            do $callback $event $state
        }
    }
    
    print $"\n✓ Replay complete"
    print $"  Final state: ($state.entities | length) entities, ($state.sensors | length) sensors"
    
    {
        events_replayed: ($events | length)
        final_state: $state
        duration: ($events | last | get timestamp | into datetime) - ($events | first | get timestamp | into datetime)
    }
}

# =============================================================================
# Branching and Merging
# =============================================================================

# Branch history at specific event
export def "ewig branch" [
    uri: string              # World URI
    at_event: int            # Event sequence number to branch at
    new_uri: string          # New world URI for branch
]: [ nothing -> record ] {
    ensure-history-dir
    let log_file = (world-log-file $uri)
    
    if not ($log_file | path exists) {
        error make { msg: $"No history found for ($uri)" }
    }
    
    let log = (open $log_file)
    
    if $at_event < 0 or $at_event >= ($log | length) {
        error make { msg: $"Invalid event index ($at_event)" }
    }
    
    # Get events up to branch point
    let branch_events = ($log | where seq <= $at_event)
    
    # Create new world with branched history
    use world_ab.nu world create
    let new_world = (world create $new_uri --from $uri)
    
    # Copy history to new log file
    let new_log_file = (world-log-file $new_uri)
    $branch_events | save -f $new_log_file
    
    # Add branch event
    let branch_event = {
        timestamp: (date now)
        type: "branch"
        description: $"Branched from ($uri) at event ($at_event)"
        data: {
            parent_uri: $uri
            at_event: $at_event
            new_uri: $new_uri
        }
        seq: ($branch_events | length)
        hash: ""
        prev_hash: ($branch_events | last | get hash)
    }
    let branch_hash = ($branch_event | to json | hash sha256 | str substring 0..16)
    let final_branch_event = ($branch_event | upsert hash $branch_hash)
    
    let new_log = ($branch_events | append $final_branch_event)
    $new_log | save -f $new_log_file
    
    print $"✓ Branched ($uri) at event ($at_event) → ($new_uri)"
    print $"  Events in branch: ($branch_events | length)"
    
    {
        parent: $uri
        branch: $new_uri
        at_event: $at_event
        events: ($branch_events | length)
    }
}

# Merge two divergent histories
export def "ewig merge" [
    uri_a: string            # First world URI
    uri_b: string            # Second world URI
    --strategy: string = "append"   # Merge strategy: append, interleave, custom
    --into: string = ""      # Target URI for merge result
]: [ nothing -> record ] {
    ensure-history-dir
    let log_a = (world-log-file $uri_a)
    let log_b = (world-log-file $uri_b)
    
    if not ($log_a | path exists) {
        error make { msg: $"No history found for ($uri_a)" }
    }
    if not ($log_b | path exists) {
        error make { msg: $"No history found for ($uri_b)" }
    }
    
    let events_a = (open $log_a)
    let events_b = (open $log_b)
    
    print $"Merging ($uri_a) [($events_a | length) events] with ($uri_b) [($events_b | length) events]"
    
    # Find common ancestor (simplified - assumes shared prefix)
    let common_len = (find-common-prefix $events_a $events_b)
    
    print $"  Common ancestor: event ($common_len)"
    
    # Apply merge strategy
    let merged = (match $strategy {
        "append" => {
            # Append B's unique events after A's
            let unique_b = ($events_b | where seq >= $common_len)
            $events_a | append $unique_b
        }
        "interleave" => {
            # Interleave by timestamp
            let unique_a = ($events_a | where seq >= $common_len)
            let unique_b = ($events_b | where seq >= $common_len)
            interleave-events $unique_a $unique_b
        }
        _ => { $events_a }
    })
    
    # Renumber sequences
    mut renumbered = []
    for i in 0..<($merged | length) {
        let event = ($merged | get $i | upsert seq $i)
        $renumbered = ($renumbered | append $event)
    }
    
    # Save merged result
    let target_uri = (if $into == "" { $"($uri_a)_merged" } else { $into })
    let target_log = (world-log-file $target_uri)
    $renumbered | save -f $target_log
    
    print $"✓ Merged history saved to ($target_uri)"
    print $"  Total events: ($renumbered | length)"
    
    {
        uri_a: $uri_a
        uri_b: $uri_b
        target: $target_uri
        common_ancestor: $common_len
        events_a: ($events_a | length)
        events_b: ($events_b | length)
        merged_events: ($renumbered | length)
        strategy: $strategy
    }
}

# Find common prefix length between two event logs
export def find-common-prefix [a: list, b: list]: [ nothing -> int ] {
    mut i = 0
    let min_len = (if ($a | length) < ($b | length) { $a | length } else { $b | length })
    
    while $i < $min_len {
        let event_a = ($a | get $i)
        let event_b = ($b | get $i)
        
        # Compare by hash for equality
        if $event_a.hash != $event_b.hash {
            break
        }
        $i = $i + 1
    }
    
    $i
}

# Interleave two event lists by timestamp
export def interleave-events [a: list, b: list]: [ nothing -> list ] {
    let combined = ($a | append $b)
    $combined | sort-by timestamp
}

# =============================================================================
# History Statistics
# =============================================================================

# Show statistics for world history
export def "ewig stats" [
    uri: string              # World URI
]: [ nothing -> record ] {
    ensure-history-dir
    let log_file = (world-log-file $uri)
    
    if not ($log_file | path exists) {
        error make { msg: $"No history found for ($uri)" }
    }
    
    let log = (open $log_file)
    
    if ($log | is-empty) {
        print "History is empty"
        return {}
    }
    
    let start_time = ($log | first | get timestamp | into datetime)
    let end_time = ($log | last | get timestamp | into datetime)
    let duration = ($end_time - $start_time)
    
    # Count event types
    let type_counts = ($log | group-by type | transpose type events | each { |row|
        { type: $row.type, count: ($row.events | length) }
    } | sort-by count -r)
    
    let stats = {
        total_events: ($log | length)
        start_time: $start_time
        end_time: $end_time
        duration: $duration
        event_types: ($type_counts | length)
        type_breakdown: $type_counts
        avg_events_per_minute: (($log | length) / (($duration | into int) / 1_000_000_000 / 60))
    }
    
    print $"History Statistics for ($uri):"
    print $"  Total events: ($stats.total_events)"
    print $"  Duration: ($duration)"
    print $"  Event types: ($stats.event_types)"
    print $"  Avg rate: ($stats.avg_events_per_minute | math round -p 2) events/min"
    print "\nEvent breakdown:"
    for t in $type_counts {
        print $"  ($t.type): ($t.count)"
    }
    
    $stats
}

# =============================================================================
# History Integrity
# =============================================================================

# Verify history integrity (hash chain)
export def "ewig verify" [
    uri: string              # World URI
]: [ nothing -> record ] {
    ensure-history-dir
    let log_file = (world-log-file $uri)
    
    if not ($log_file | path exists) {
        error make { msg: $"No history found for ($uri)" }
    }
    
    let log = (open $log_file)
    
    mut broken = []
    
    for i in 1..<($log | length) {
        let current = ($log | get $i)
        let prev = ($log | get ($i - 1))
        
        if $current.prev_hash != $prev.hash {
            $broken = ($broken | append {
                at_event: $i
                expected: $prev.hash
                found: $current.prev_hash
            })
        }
    }
    
    let result = {
        valid: ($broken | is-empty)
        total_events: ($log | length)
        broken_links: ($broken | length)
        errors: $broken
    }
    
    if $result.valid {
        print "✓ History integrity verified"
        print $"  ($result.total_events) events in chain"
    } else {
        print $"✗ ($result.broken_links) broken links found"
        for err in $broken {
            print $"  Event ($err.at_event): hash mismatch"
        }
    }
    
    $result
}
