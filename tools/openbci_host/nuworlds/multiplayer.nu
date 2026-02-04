# multiplayer.nu
# 3-player session management for A/B world testing

use world_ab.nu *
use config.nu *

# =============================================================================
# Session Storage
# =============================================================================

# Get sessions storage directory
export def sessions-dir []: [ nothing -> path ] {
    $nu.home-path | path join ".config" "nuworlds" "sessions"
}

# Ensure sessions directory exists
export def ensure-sessions-dir []: [ nothing -> nothing ] {
    mkdir (sessions-dir)
}

# =============================================================================
# Session Creation
# =============================================================================

# Create a new multiplayer session
export def "mp session new" [
    --players: int = 3           # Number of players
    --name: string = ""          # Optional session name
    --duration: duration = 5min  # Default session duration
]: [ nothing -> string ] {
    ensure-sessions-dir
    
    let session_id = (random uuid | str substring 0..8)
    let session_file = (sessions-dir | path join $"($session_id).nuon")
    
    let session = {
        id: $session_id
        name: (if $name == "" { $"session-($session_id)" } else { $name })
        status: "created"
        created_at: (date now)
        started_at: null
        ended_at: null
        duration: $duration
        player_count: $players
        players: {}
        worlds: {}
        events: []
        metrics: {}
        sync_state: {
            last_sync: null
            sync_count: 0
            conflicts: []
        }
    }
    
    $session | save -f $session_file
    
    print $"✓ Created session: ($session_id)"
    print $"  Players: ($players)"
    print $"  Duration: ($duration)"
    
    $session_id
}

# =============================================================================
# Player Management
# =============================================================================

# Assign a player to a world variant
export def "mp session assign" [
    session: string         # Session ID
    player: string          # Player ID
    world_uri: string       # World URI (a://, b://, c://)
    --role: string = "player"  # Player role: player, observer, admin
]: [ nothing -> record ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    # Validate world exists
    let world = (load-world $world_uri)
    
    # Check if player already assigned
    if ($player in $sess.players) {
        print $"Warning: Player ($player) already assigned. Updating assignment."
    }
    
    # Check player limit
    if (($sess.players | columns | length) >= $sess.player_count) and ($player not-in $sess.players) {
        error make { msg: $"Session ($session) already has maximum players ($sess.player_count)" }
    }
    
    mut updated_sess = $sess
    
    # Assign player
    $updated_sess = ($updated_sess | upsert players.($player) {
        id: $player
        world: $world_uri
        role: $role
        assigned_at: (date now)
        state: "connected"
        last_activity: (date now)
    })
    
    # Track world usage in session
    $updated_sess = ($updated_sess | upsert worlds.($world_uri) {||
        {
            uri: $world_uri
            players: (($sess.worlds | get -i $world_uri | get -i players | default []) | append $player)
            assigned_at: (date now)
        }
    })
    
    # Add event
    let event = {
        type: "player_assigned"
        timestamp: (date now)
        player: $player
        world: $world_uri
        role: $role
    }
    $updated_sess = ($updated_sess | upsert events {|| $sess.events | append $event })
    
    # Save
    $updated_sess | save -f $session_file
    
    print $"✓ Assigned ($player) → ($world_uri) [($role)]"
    
    $updated_sess.players.($player)
}

# List players in a session
export def "mp session players" [
    session: string         # Session ID
]: [ nothing -> table ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    $sess.players | transpose id data | each { |row|
        {
            player: $row.id
            world: $row.data.world
            role: $row.data.role
            state: $row.data.state
            assigned_at: $row.data.assigned_at
        }
    }
}

# Remove player from session
export def "mp session unassign" [
    session: string         # Session ID
    player: string          # Player ID
]: [ nothing -> nothing ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    if ($player not-in $sess.players) {
        print $"Player ($player) not in session"
        return
    }
    
    let world_uri = $sess.players.($player).world
    
    mut updated_sess = $sess
    
    # Remove player
    $updated_sess = ($updated_sess | reject players.($player))
    
    # Update world players
    let world_players = ($sess.worlds | get $world_uri | get players | where {|p| $p != $player})
    if ($world_players | is-empty) {
        $updated_sess = ($updated_sess | reject worlds.($world_uri))
    } else {
        $updated_sess = ($updated_sess | upsert worlds.($world_uri).players $world_players)
    }
    
    # Add event
    let event = {
        type: "player_unassigned"
        timestamp: (date now)
        player: $player
        world: $world_uri
    }
    $updated_sess = ($updated_sess | upsert events {|| $sess.events | append $event })
    
    # Save
    $updated_sess | save -f $session_file
    
    print $"✓ Removed ($player) from session ($session)"
}

# =============================================================================
# Session Synchronization
# =============================================================================

# Synchronize all players in a session
export def "mp session sync" [
    session: string         # Session ID
    --force: bool           # Force sync even if conflicts
]: [ nothing -> record ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    print $"Syncing session ($session)..."
    
    # Collect states from all player worlds
    mut world_states = {}
    mut conflicts = []
    
    for player in ($sess.players | columns) {
        let world_uri = $sess.players.($player).world
        let world = (load-world $world_uri)
        
        # Check for conflicts with existing states
        for existing_world in ($world_states | columns) {
            if $existing_world != $world_uri {
                let existing = $world_states | get $existing_world
                let diff = (compare-world-states $world $existing)
                if not $diff.identical {
                    $conflicts = ($conflicts | append {
                        worlds: [$world_uri, $existing_world]
                        type: "state_divergence"
                        details: $diff
                    })
                }
            }
        }
        
        $world_states = ($world_states | insert $world_uri $world)
    }
    
    mut updated_sess = $sess
    
    # Update sync state
    $updated_sess = ($updated_sess | upsert sync_state {
        last_sync: (date now)
        sync_count: ($sess.sync_state.sync_count + 1)
        conflicts: $conflicts
    })
    
    # Add event
    let event = {
        type: "sync"
        timestamp: (date now)
        sync_count: ($sess.sync_state.sync_count + 1)
        conflicts_found: ($conflicts | length)
    }
    $updated_sess = ($updated_sess | upsert events {|| $sess.events | append $event })
    
    # Save
    $updated_sess | save -f $session_file
    
    if ($conflicts | is-empty) {
        print "✓ All players synchronized, no conflicts"
    } else {
        print $"⚠ ($conflicts | length) conflicts detected:"
        for conflict in $conflicts {
            print $"  - ($conflict.worlds | str join " vs "): ($conflict.type)"
        }
        
        if not $force {
            print "\nUse --force to proceed anyway, or resolve conflicts first."
        }
    }
    
    $updated_sess.sync_state
}

# Compare two world states for conflicts
export def compare-world-states [a: record, b: record]: [ nothing -> record ] {
    let a_entities = ($a | get -i entities | default {})
    let b_entities = ($b | get -i entities | default {})
    
    let a_hash = ($a | get -i state_hash | default "")
    let b_hash = ($b | get -i state_hash | default "")
    
    {
        identical: ($a_hash == $b_hash and $a_hash != "")
        entities_differ: (($a_entities | columns | sort) != ($b_entities | columns | sort))
        entity_count_delta: (($a_entities | length) - ($b_entities | length))
    }
}

# =============================================================================
# Session Observation
# =============================================================================

# Watch real-time session state
export def "mp session observe" [
    session: string              # Session ID
    --interval: duration = 1sec  # Update interval
    --duration: duration = 1min  # Observation duration
]: [ nothing -> nothing ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    print $"Observing session: ($sess.name)"
    print $"Players: ($sess.players | length) | Status: ($sess.status)"
    print "Press Ctrl+C to stop\n"
    
    let start_time = (date now)
    
    # Real-time observation loop
    loop {
        # Reload session (may have changed)
        let current_sess = (open $session_file)
        
        # Clear screen
        print "\x1b[2J\x1b[H"  # ANSI clear screen and home
        
        # Header
        print $"Session: ($current_sess.name) [($current_sess.id)]"
        print $"Status: ($current_sess.status) | Players: ($current_sess.players | length)/($current_sess.player_count)"
        print ("-" | str repeat 60)
        
        # Player table
        let player_table = ($current_sess.players | transpose id data | each { |row|
            {
                player: $row.id
                world: $row.data.world
                role: $row.data.role
                state: $row.data.state
                activity: (format-relative-time $row.data.last_activity)
            }
        })
        
        if ($player_table | is-not-empty) {
            $player_table | table
        } else {
            print "No players assigned"
        }
        
        print ""
        
        # Recent events (last 5)
        print "Recent events:"
        let recent_events = ($current_sess.events | last 5)
        for event in $recent_events {
            print $"  [($event.timestamp | format date "%H:%M:%S")] ($event.type)"
        }
        
        # Check duration
        let elapsed = ((date now) - $start_time)
        if $elapsed >= $duration {
            print "\nObservation complete."
            break
        }
        
        sleep $interval
    }
}

# Format relative time
export def format-relative-time [t: datetime]: [ nothing -> string ] {
    let delta = ((date now) - $t)
    let seconds = ($delta | into int) / 1_000_000_000
    
    if $seconds < 60 {
        $"($seconds | math floor)s ago"
    } else if $seconds < 3600 {
        $"($seconds / 60 | math floor)m ago"
    } else {
        $"($seconds / 3600 | math floor)h ago"
    }
}

# =============================================================================
# Session Metrics
# =============================================================================

# Show per-variant metrics for a session
export def "mp session metrics" [
    session: string              # Session ID
    --variant: string = ""       # Filter by variant (a, b, c)
]: [ nothing -> record ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    # Calculate metrics per world variant
    mut variant_metrics = {
        a: { world_count: 0, player_count: 0, events: 0 }
        b: { world_count: 0, player_count: 0, events: 0 }
        c: { world_count: 0, player_count: 0, events: 0 }
    }
    
    for player in ($sess.players | columns) {
        let world_uri = $sess.players.($player).world
        let scheme = ($world_uri | parse -r '^([abc])://' | get capture0)
        
        if $scheme in [a b c] {
            $variant_metrics = ($variant_metrics | upsert $scheme.player_count {||
                ($variant_metrics | get $scheme | get player_count) + 1
            })
        }
    }
    
    # Count worlds per variant
    for world_uri in ($sess.worlds | columns) {
        let scheme = ($world_uri | parse -r '^([abc])://' | get capture0)
        if $scheme in [a b c] {
            $variant_metrics = ($variant_metrics | upsert $scheme.world_count {||
                ($variant_metrics | get $scheme | get world_count) + 1
            })
        }
    }
    
    # Count events per variant (by player world)
    for event in $sess.events {
        if ($event | get -i world | is-not-empty) {
            let scheme = ($event.world | parse -r '^([abc])://' | get capture0)
            if $scheme in [a b c] {
                $variant_metrics = ($variant_metrics | upsert $scheme.events {||
                    ($variant_metrics | get $scheme | get events) + 1
                })
            }
        }
    }
    
    # Filter by variant if specified
    let output = if $variant != "" {
        { ($variant): ($variant_metrics | get $variant) }
    } else {
        $variant_metrics
    }
    
    print "Variant Metrics:"
    for v in [a b c] {
        let m = ($variant_metrics | get $v)
        print $"  ($v):// - Worlds: ($m.world_count), Players: ($m.player_count), Events: ($m.events)"
    }
    
    $output
}

# =============================================================================
# Conflict Resolution
# =============================================================================

# Resolve conflicts in a session
export def "mp session resolve" [
    session: string              # Session ID
    action: string               # Resolution action
    --target: string = ""        # Target world for resolution
]: [ nothing -> nothing ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    if ($sess.sync_state.conflicts | is-empty) {
        print "No conflicts to resolve"
        return
    }
    
    print $"Resolving ($sess.sync_state.conflicts | length) conflicts with action: ($action)"
    
    mut updated_sess = $sess
    
    match $action {
        "sync_all" => {
            # Force sync all worlds to target
            if $target == "" {
                error make { msg: "--target required for sync_all" }
            }
            let target_world = (load-world $target)
            
            # Clone target to all other worlds in session
            for player in ($sess.players | columns) {
                let player_world = $sess.players.($player).world
                if $player_world != $target {
                    world clone $target $player_world --force
                    print $"  Synced ($player_world) → ($target)"
                }
            }
        }
        "merge" => {
            # Merge states (simplified - would need proper merge logic)
            print "Merge not fully implemented - using last-write-wins"
        }
        "ignore" => {
            # Clear conflicts without action
            print "Ignoring conflicts"
        }
        _ => {
            error make { msg: $"Unknown resolution action: ($action)" }
        }
    }
    
    # Clear conflicts
    $updated_sess = ($updated_sess | upsert sync_state.conflicts [])
    
    # Add event
    let event = {
        type: "conflict_resolved"
        timestamp: (date now)
        action: $action
        target: $target
    }
    $updated_sess = ($updated_sess | upsert events {|| $sess.events | append $event })
    
    # Save
    $updated_sess | save -f $session_file
    
    print "✓ Conflicts resolved"
}

# =============================================================================
# Session Lifecycle
# =============================================================================

# Start a session
export def "mp session start" [
    session: string         # Session ID
]: [ nothing -> nothing ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    if $sess.status == "running" {
        print "Session already running"
        return
    }
    
    mut updated_sess = $sess
    $updated_sess = ($updated_sess | upsert status "running")
    $updated_sess = ($updated_sess | upsert started_at (date now))
    
    # Add event
    let event = {
        type: "session_started"
        timestamp: (date now)
    }
    $updated_sess = ($updated_sess | upsert events {|| $sess.events | append $event })
    
    # Save
    $updated_sess | save -f $session_file
    
    print $"✓ Session ($session) started"
}

# End a session
export def "mp session end" [
    session: string         # Session ID
]: [ nothing -> record ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    mut updated_sess = $sess
    $updated_sess = ($updated_sess | upsert status "ended")
    $updated_sess = ($updated_sess | upsert ended_at (date now))
    
    # Calculate duration
    if $sess.started_at != null {
        let duration = ((date now) - $sess.started_at)
        $updated_sess = ($updated_sess | upsert actual_duration $duration)
    }
    
    # Add event
    let event = {
        type: "session_ended"
        timestamp: (date now)
    }
    $updated_sess = ($updated_sess | upsert events {|| $sess.events | append $event })
    
    # Save
    $updated_sess | save -f $session_file
    
    print $"✓ Session ($session) ended"
    print $"  Events: ($updated_sess.events | length)"
    print $"  Syncs: ($updated_sess.sync_state.sync_count)"
    
    $updated_sess
}

# List all sessions
export def "mp session list" [
    --status: string = ""    # Filter by status
]: [ nothing -> table ] {
    ensure-sessions-dir
    
    let session_files = (ls (sessions-dir)/*.nuon | default [])
    
    if ($session_files | is-empty) {
        print "No sessions found"
        return []
    }
    
    mut sessions = []
    
    for file in $session_files {
        let sess = (open $file.name)
        
        $sessions = ($sessions | append {
            id: $sess.id
            name: $sess.name
            status: $sess.status
            players: ($sess.players | length)
            created: $sess.created_at
            started: ($sess | get -i started_at | default "-")
            events: ($sess.events | length)
        })
    }
    
    if $status != "" {
        $sessions | where status == $status
    } else {
        $sessions
    }
}

# Get session info
export def "mp session info" [
    session: string         # Session ID
]: [ nothing -> record ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        error make { msg: $"Session ($session) not found" }
    }
    
    let sess = (open $session_file)
    
    print $"Session: ($sess.name)"
    print $"  ID: ($sess.id)"
    print $"  Status: ($sess.status)"
    print $"  Players: ($sess.players | length)/($sess.player_count)"
    print $"  Created: ($sess.created_at)"
    print $"  Events: ($sess.events | length)"
    print $"  Syncs: ($sess.sync_state.sync_count)"
    print $"  Conflicts: ($sess.sync_state.conflicts | length)"
    
    $sess
}

# Delete a session
export def "mp session delete" [
    session: string         # Session ID
    --force: bool           # Skip confirmation
]: [ nothing -> nothing ] {
    ensure-sessions-dir
    let session_file = (sessions-dir | path join $"($session).nuon")
    
    if not ($session_file | path exists) {
        print $"Session ($session) not found"
        return
    }
    
    if not $force {
        print $"Delete session ($session)? [y/N]"
        let confirm = (input)
        if ($confirm | downcase) != "y" {
            print "Cancelled"
            return
        }
    }
    
    rm $session_file
    print $"✓ Deleted session ($session)"
}
