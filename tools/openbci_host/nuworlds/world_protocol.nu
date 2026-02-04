# world_protocol.nu
# Protocol handlers for a:// b:// c:// world URIs
# Registers URI schemes and provides content-addressed caching

use world_ab.nu *

# =============================================================================
# Protocol Registration
# =============================================================================

# Register world URI schemes in nushell
export def "world-protocol register" []: [ nothing -> nothing ] {
    print "Registering world protocol handlers..."
    
    # Register custom commands that act as protocol handlers
    # In nushell, we use command prefixes instead of true URI schemes
    
    # Ensure directories exist
    ensure-protocol-dirs
    
    print "✓ Protocol handlers registered"
    print "  Use: open a://world-name"
    print "  Use: open b://world-name  "
    print "  Use: open c://world-name  "
}

# Get protocol cache directory
export def protocol-cache-dir []: [ nothing -> path ] {
    $nu.home-path | path join ".config" "nuworlds" "cache"
}

# Ensure protocol directories exist
export def ensure-protocol-dirs []: [ nothing -> nothing ] {
    mkdir (protocol-cache-dir)
    mkdir ($nu.home-path | path join ".config" "nuworlds" "protocols")
}

# =============================================================================
# URI Opening
# =============================================================================

# Open a world by URI (main protocol handler)
export def "open world" [
    uri: string              # World URI (a://, b://, c://)
    --mode: string = "read"  # Open mode: read, write, sync
]: [ nothing -> record ] {
    let parsed = (parse-world-uri-safe $uri)
    
    match $parsed.scheme {
        "a" => { open-world-variant $uri "baseline" $mode }
        "b" => { open-world-variant $uri "variant" $mode }
        "c" => { open-world-variant $uri "experimental" $mode }
        _ => { error make { msg: $"Unknown scheme: ($parsed.scheme)" } }
    }
}

# Open specific variant
export def open-world-variant [
    uri: string,
    variant_type: string,
    mode: string
]: [ nothing -> record ] {
    let world = (load-world $uri)
    
    # Log access
    log-protocol-access $uri $mode
    
    # Update access cache
    update-access-cache $uri
    
    print $"Opened ($uri) [($variant_type)] in ($mode) mode"
    print $"  Entities: ($world.entities | length)"
    print $"  Sensors: ($world.sensors | length)"
    
    $world
}

# Safe URI parsing with error handling
export def parse-world-uri-safe [uri: string]: [ nothing -> record ] {
    let pattern = '^(?<scheme>[abc])://(?<name>[^/]+)(?:/(?<path>.*))?$'
    
    if ($uri | find -r $pattern | is-empty) {
        error make { 
            msg: $"Invalid world URI: ($uri)"
            help: "Expected format: a://world-name, b://world-name, or c://world-name"
        }
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

# =============================================================================
# Convenience Commands
# =============================================================================

# Quick open a:// URIs
export def "open a" [
    path: string             # Path after a://
    --mode: string = "read"  # Open mode
]: [ nothing -> record ] {
    open world $"a://($path)" --mode $mode
}

# Quick open b:// URIs
export def "open b" [
    path: string             # Path after b://
    --mode: string = "read"  # Open mode
]: [ nothing -> record ] {
    open world $"b://($path)" --mode $mode
}

# Quick open c:// URIs
export def "open c" [
    path: string             # Path after c://
    --mode: string = "read"  # Open mode
]: [ nothing -> record ] {
    open world $"c://($path)" --mode $mode
}

# =============================================================================
# Protocol Cache
# =============================================================================

# Content-addressed cache lookup
export def "world-cache get" [
    hash: string             # Content hash
]: [ nothing -> any ] {
    let cache_file = (protocol-cache-dir | path join $"($hash).nuon")
    
    if ($cache_file | path exists) {
        open $cache_file
    } else {
        null
    }
}

# Store in content-addressed cache
export def "world-cache put" [
    data: any                # Data to cache
]: [ nothing -> string ] {
    let hash = ($data | to json | hash sha256)
    let cache_file = (protocol-cache-dir | path join $"($hash).nuon")
    
    $data | save -f $cache_file
    
    $hash
}

# Check if content is in cache
export def "world-cache has" [
    hash: string             # Content hash
]: [ nothing -> bool ] {
    let cache_file = (protocol-cache-dir | path join $"($hash).nuon")
    $cache_file | path exists
}

# Get cache info
export def "world-cache info" []: [ nothing -> record ] {
    let cache_dir = (protocol-cache-dir)
    let entries = (ls $cache_dir/*.nuon | default [])
    
    let total_size = ($entries | get -i size | default 0b | math sum)
    
    {
        cache_dir: $cache_dir
        entries: ($entries | length)
        total_size: $total_size
        entries_list: ($entries | each { |e| { hash: ($e.name | path basename | str replace ".nuon" ""), size: $e.size } })
    }
}

# Clear cache
export def "world-cache clear" [
    --older-than: duration = 0sec  # Only clear entries older than
]: [ nothing -> nothing ] {
    let cache_dir = (protocol-cache-dir)
    let entries = (ls $cache_dir/*.nuon | default [])
    
    mut cleared = 0
    
    for entry in $entries {
        let should_clear = (if $older_than > 0sec {
            let age = ((date now) - $entry.modified)
            $age > $older_than
        } else { true })
        
        if $should_clear {
            rm $entry.name
            $cleared = $cleared + 1
        }
    }
    
    print $"Cleared ($cleared) cache entries"
}

# =============================================================================
# Access Logging
# =============================================================================

# Log protocol access
export def log-protocol-access [
    uri: string,
    mode: string
]: [ nothing -> nothing ] {
    let log_file = ($nu.home-path | path join ".config" "nuworlds" "protocol_access.log")
    
    let entry = {
        timestamp: (date now)
        uri: $uri
        mode: $mode
        hash: (compute-uri-hash $uri)
    }
    
    # Append to log
    let current_log = (if ($log_file | path exists) { open $log_file } else { [] })
    ($current_log | append $entry) | save -f $log_file
}

# Compute URI hash for tracking
export def compute-uri-hash [uri: string]: [ nothing -> string ] {
    $uri | hash sha256 | str substring 0..16
}

# Update access cache for a URI
export def update-access-cache [uri: string]: [ nothing -> nothing ] {
    let cache_file = ($nu.home-path | path join ".config" "nuworlds" "access_cache.nuon")
    
    let entry = {
        last_access: (date now)
        access_count: 1
    }
    
    mut cache = (if ($cache_file | path exists) { open $cache_file } else { {} })
    
    if ($uri in $cache) {
        let prev = ($cache | get $uri)
        $cache = ($cache | upsert $uri {
            last_access: (date now)
            access_count: ($prev.access_count + 1)
        })
    } else {
        $cache = ($cache | insert $uri $entry)
    }
    
    $cache | save -f $cache_file
}

# Get access stats
export def "world-protocol access-stats" [
    --uri: string = ""       # Filter by URI
]: [ nothing -> table ] {
    let cache_file = ($nu.home-path | path join ".config" "nuworlds" "access_cache.nuon")
    
    if not ($cache_file | path exists) {
        print "No access stats available"
        return []
    }
    
    let cache = (open $cache_file)
    
    let stats = ($cache | transpose uri data | each { |row|
        {
            uri: $row.uri
            last_access: $row.data.last_access
            access_count: $row.data.access_count
        }
    } | sort-by access_count -r)
    
    if $uri != "" {
        $stats | where uri =~ $uri
    } else {
        $stats
    }
}

# =============================================================================
# Protocol Discovery
# =============================================================================

# List available world URIs
export def "world-protocol list" [
    --scheme: string = ""    # Filter by scheme (a, b, c)
]: [ nothing -> table ] {
    let worlds = (world list --format json | from json)
    
    if $scheme != "" {
        $worlds | where scheme == $scheme
    } else {
        $worlds
    }
}

# Search worlds by name or content
export def "world-protocol search" [
    query: string            # Search query
    --type: string = "name"  # Search type: name, entity, hash
]: [ nothing -> table ] {
    let worlds = (world list --format json | from json)
    
    match $type {
        "name" => { $worlds | where name =~ $query }
        "hash" => { $worlds | where state_hash =~ $query }
        _ => { $worlds | where name =~ $query }
    }
}

# Resolve URI to file path
export def "world-protocol resolve" [
    uri: string              # World URI
]: [ nothing -> path ] {
    let parsed = (parse-world-uri-safe $uri)
    worlds-dir | path join $"($parsed.scheme)_($parsed.name).nuon"
}

# Get URI info
export def "world-protocol info" [
    uri: string              # World URI
]: [ nothing -> record ] {
    let parsed = (parse-world-uri-safe $uri)
    let world = (load-world $uri)
    let file_path = (world-protocol resolve $uri)
    let file_info = (ls $file_path | get 0)
    
    {
        uri: $uri
        scheme: $parsed.scheme
        name: $parsed.name
        variant: $parsed.variant
        path: $file_path
        size: $file_info.size
        modified: $file_info.modified
        state_hash: $world.state_hash
        version: $world.version
    }
}

# =============================================================================
# Protocol Aliases
# =============================================================================

# Create alias for a world URI
export def "world-protocol alias" [
    uri: string              # Source URI
    alias_name: string       # Alias name
]: [ nothing -> nothing ] {
    let aliases_file = ($nu.home-path | path join ".config" "nuworlds" "aliases.nuon")
    
    mut aliases = (if ($aliases_file | path exists) { open $aliases_file } else { {} })
    
    $aliases = ($aliases | insert $alias_name $uri)
    $aliases | save -f $aliases_file
    
    print $"Created alias '($alias_name)' → ($uri)"
}

# List aliases
export def "world-protocol aliases" []: [ nothing -> record ] {
    let aliases_file = ($nu.home-path | path join ".config" "nuworlds" "aliases.nuon")
    
    if ($aliases_file | path exists) {
        open $aliases_file
    } else {
        {}
    }
}

# Resolve alias
export def "world-protocol resolve-alias" [
    alias_name: string       # Alias to resolve
]: [ nothing -> string ] {
    let aliases_file = ($nu.home-path | path join ".config" "nuworlds" "aliases.nuon")
    
    if not ($aliases_file | path exists) {
        error make { msg: $"Alias '($alias_name)' not found" }
    }
    
    let aliases = (open $aliases_file)
    
    if ($alias_name not-in $aliases) {
        error make { msg: $"Alias '($alias_name)' not found" }
    }
    
    $aliases | get $alias_name
}

# =============================================================================
# Batch Operations
# =============================================================================

# Open multiple URIs at once
export def "world-protocol batch-open" [
    uris: list               # List of URIs
    --mode: string = "read"  # Open mode
]: [ nothing -> table ] {
    $uris | each { |uri| 
        try {
            let world = (open world $uri --mode $mode)
            {
                uri: $uri
                status: "success"
                entities: ($world.entities | length)
                sensors: ($world.sensors | length)
            }
        } catch { |e|
            {
                uri: $uri
                status: "error"
                error: $e.msg
            }
        }
    }
}

# Sync multiple worlds
export def "world-protocol sync" [
    source: string           # Source URI
    targets: list            # Target URIs
    --strategy: string = "clone"  # Sync strategy
]: [ nothing -> table ] {
    let source_world = (load-world $source)
    
    $targets | each { |target|
        try {
            match $strategy {
                "clone" => {
                    world clone $source $target --force
                }
                _ => { error make { msg: $"Unknown sync strategy: ($strategy)" } }
            }
            
            {
                target: $target
                status: "synced"
                source_hash: $source_world.state_hash
            }
        } catch { |e|
            {
                target: $target
                status: "error"
                error: $e.msg
            }
        }
    }
}

# =============================================================================
# Protocol Diagnostics
# =============================================================================

# Run diagnostics on protocol handlers
export def "world-protocol diagnose" []: [ nothing -> record ] {
    print "Running protocol diagnostics..."
    
    mut results = {
        checks: []
        passed: 0
        failed: 0
    }
    
    # Check 1: Directories exist
    print "  Checking directories..."
    let dirs_ok = ((worlds-dir | path exists) and (protocol-cache-dir | path exists))
    $results.checks = ($results.checks | append {
        name: "directories"
        status: (if $dirs_ok { "pass" } else { "fail" })
    })
    if $dirs_ok { $results.passed = $results.passed + 1 } else { $results.failed = $results.failed + 1 }
    
    # Check 2: Can parse URIs
    print "  Checking URI parsing..."
    let parse_ok = (try {
        let parsed = (parse-world-uri-safe "a://test-world")
        $parsed.scheme == "a" and $parsed.name == "test-world"
    } catch { false })
    $results.checks = ($results.checks | append {
        name: "uri_parsing"
        status: (if $parse_ok { "pass" } else { "fail" })
    })
    if $parse_ok { $results.passed = $results.passed + 1 } else { $results.failed = $results.failed + 1 }
    
    # Check 3: Cache functional
    print "  Checking cache..."
    let cache_ok = (try {
        let test_data = { test: true, timestamp: (date now) }
        let hash = (world-cache put $test_data)
        let retrieved = (world-cache get $hash)
        ($retrieved | to json) == ($test_data | to json)
    } catch { false })
    $results.checks = ($results.checks | append {
        name: "cache"
        status: (if $cache_ok { "pass" } else { "fail" })
    })
    if $cache_ok { $results.passed = $results.passed + 1 } else { $results.failed = $results.failed + 1 }
    
    print ""
    print $"Diagnostics complete: ($results.passed)/($results.passed + $results.failed) passed"
    
    $results
}
