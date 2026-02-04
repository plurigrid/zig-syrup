# ab_orchestrator.nu
# Full A/B test orchestration for world variants
# Coordinates multi-variant testing with statistical analysis

use world_ab.nu *
use multiplayer.nu *
use immer_ops.nu *
use ewig_history.nu *

# =============================================================================
# Test Storage
# =============================================================================

# Get tests storage directory
export def tests-dir []: [ nothing -> path ] {
    $nu.home-path | path join ".config" "nuworlds" "tests"
}

# Ensure tests directory exists
export def ensure-tests-dir []: [ nothing -> nothing ] {
    mkdir (tests-dir)
}

# =============================================================================
# Test Initialization
# =============================================================================

# Initialize a new A/B test
export def "ab-test init" [
    name: string                              # Test name
    --variants: list = [a b c]                # Variant schemes
    --players-per-variant: int = 1            # Players per variant
    --config: record = {}                     # Test configuration
]: [ nothing -> string ] {
    ensure-tests-dir
    
    let test_file = (tests-dir | path join $"($name).nuon")
    
    if ($test_file | path exists) {
        error make { msg: $"Test '($name)' already exists" }
    }
    
    # Validate variants
    for v in $variants {
        if $v not-in [a b c] {
            error make { msg: $"Invalid variant: ($v). Must be a, b, or c." }
        }
    }
    
    let test_id = (random uuid | str substring 0..8)
    let total_players = ($variants | length) * $players_per_variant
    
    # Create test record
    let test = {
        id: $test_id
        name: $name
        status: "initialized"
        created_at: (date now)
        started_at: null
        ended_at: null
        config: ({
            variants: $variants
            players_per_variant: $players_per_variant
            total_players: $total_players
            duration: null
            confidence_level: 0.95
            min_sample_size: 100
        } | merge $config)
        worlds: {}           # uri -> world info
        sessions: []         # Session IDs
        results: {
            variant_metrics: {}
            events: []
        }
        analysis: {
            winner: null
            confidence: 0.0
            p_values: {}
        }
    }
    
    # Create world for each variant
    for variant in $variants {
        let uri = $"($variant)://($name)-($variant)"
        
        # Create world (will error if exists)
        world create $uri --param { test: $name, variant: $variant }
        
        # Track in test
        let world_info = {
            uri: $uri
            variant: $variant
            players_assigned: 0
            metrics: {
                events: 0
                errors: 0
                session_duration: 0sec
            }
        }
    }
    
    # Save test
    $test | save -f $test_file
    
    print $"✓ Initialized A/B test: ($name)"
    print $"  ID: ($test_id)"
    print $"  Variants: ($variants | str join ', ')"
    print $"  Players per variant: ($players_per_variant)"
    print $"  Total players: ($total_players)"
    
    $test_id
}

# =============================================================================
# Test Execution
# =============================================================================

# Run the A/B test
export def "ab-test run" [
    name: string                              # Test name
    --duration: duration = 5min               # Test duration
    --auto-assign: bool = true                # Auto-assign players
]: [ nothing -> nothing ] {
    ensure-tests-dir
    let test_file = (tests-dir | path join $"($name).nuon")
    
    if not ($test_file | path exists) {
        error make { msg: $"Test '($name)' not found" }
    }
    
    let test = (open $test_file)
    
    if $test.status == "running" {
        print "Test already running"
        return
    }
    
    print $"Starting A/B test: ($name)"
    print $"  Duration: ($duration)\n"
    
    # Create multiplayer session
    let session_id = (mp session new --players $test.config.total_players --name $name --duration $duration)
    
    mut updated_test = $test
    $updated_test = ($updated_test | upsert sessions ($test.sessions | append $session_id))
    $updated_test = ($updated_test | upsert config.duration $duration)
    $updated_test = ($updated_test | upsert status "running")
    $updated_test = ($updated_test | upsert started_at (date now))
    
    # Auto-assign players if requested
    if $auto_assign {
        mut player_idx = 0
        for variant in $test.config.variants {
            let world_uri = $"($variant)://($name)-($variant)"
            
            for i in 1..$test.config.players_per_variant {
                let player_id = $"player-($player_idx)"
                mp session assign $session_id $player_id $world_uri
                $player_idx = $player_idx + 1
            }
        }
    }
    
    # Start session
    mp session start $session_id
    
    # Save test state
    $updated_test | save -f $test_file
    
    print $"\n✓ Test ($name) is running"
    print $"  Session: ($session_id)"
    print $"  Use 'ab-test monitor ($name)' to watch progress"
}

# =============================================================================
# Test Monitoring
# =============================================================================

# Live monitoring dashboard for test
export def "ab-test monitor" [
    name: string                              # Test name
    --refresh: duration = 2sec                # Refresh interval
]: [ nothing -> nothing ] {
    ensure-tests-dir
    let test_file = (tests-dir | path join $"($name).nuon")
    
    if not ($test_file | path exists) {
        error make { msg: $"Test '($name)' not found" }
    }
    
    print $"Monitoring A/B test: ($name)"
    print "Press Ctrl+C to stop\n"
    
    loop {
        # Clear screen
        print "\x1b[2J\x1b[H"
        
        let test = (open $test_file)
        
        # Header
        print $"A/B Test: ($test.name) [($test.status)]"
        
        let elapsed = (if $test.started_at != null {
            (date now) - $test.started_at
        } else { 0sec })
        
        let remaining = (if $test.config.duration != null {
            let total = $test.config.duration
            if $elapsed < $total {
                $total - $elapsed
            } else { 0sec }
        } else { null })
        
        print $"Elapsed: ($elapsed) | Remaining: ($remaining | default 'N/A')"
        print ("-" | str repeat 60)
        
        # Variant metrics
        for variant in $test.config.variants {
            let uri = $"($variant)://($name)-($variant)"
            let world_info = ($test.worlds | get -i $uri | default {})
            let metrics = ($world_info | get -i metrics | default {})
            
            print $"($variant):// - Events: ($metrics | get -i events | default 0) | Errors: ($metrics | get -i errors | default 0)"
        }
        
        print ""
        
        # Session info
        for session_id in $test.sessions {
            let session_info = (try { mp session info $session_id } catch { null })
            if $session_info != null {
                print $"Session ($session_id): ($session_info.status)"
            }
        }
        
        if $test.status == "ended" {
            print "\nTest ended."
            break
        }
        
        sleep $refresh
    }
}

# =============================================================================
# Test Results
# =============================================================================

# Get statistical analysis of test results
export def "ab-test results" [
    name: string                              # Test name
    --confidence: float = 0.95                # Confidence level
]: [ nothing -> record ] {
    ensure-tests-dir
    let test_file = (tests-dir | path join $"($name).nuon")
    
    if not ($test_file | path exists) {
        error make { msg: $"Test '($name)' not found" }
    }
    
    let test = (open $test_file)
    
    print $"Results for A/B test: ($name)"
    print ("-" | str repeat 60)
    
    # Collect metrics per variant
    mut variant_data = {}
    for variant in $test.config.variants {
        let uri = $"($variant)://($name)-($variant)"
        
        # Get world history stats
        let history_stats = (try {
            ewig stats $uri
        } catch { null })
        
        # Get session metrics
        let session_metrics = (try {
            mp session metrics ($test.sessions | get 0) --variant $variant
        } catch { null })
        
        $variant_data = ($variant_data | insert $variant {
            events: ($history_stats | get -i total_events | default 0)
            event_rate: ($history_stats | get -i avg_events_per_minute | default 0)
            players: ($session_metrics | get -i $variant | get -i player_count | default 0)
        })
    }
    
    # Calculate statistics
    let baseline = ($test.config.variants | get 0)
    let baseline_data = ($variant_data | get $baseline)
    
    mut comparison = {}
    for variant in $test.config.variants {
        if $variant != $baseline {
            let v_data = ($variant_data | get $variant)
            let event_lift = (if $baseline_data.events > 0 {
                (($v_data.events - $baseline_data.events) / $baseline_data.events * 100)
            } else { 0 })
            
            $comparison = ($comparison | insert $variant {
                vs_baseline: $baseline
                event_lift: $event_lift
                events: $v_data.events
                confidence: (calculate-confidence $v_data.events $baseline_data.events)
            })
        }
    }
    
    # Display results
    print "\nVariant Performance:"
    for variant in $test.config.variants {
        let data = ($variant_data | get $variant)
        let lift = (if $variant != $baseline {
            let comp = ($comparison | get $variant)
            $" ({(if $comp.event_lift > 0 { "+" } else { "" })}($comp.event_lift | math round -p 1)%)"
        } else { " (baseline)" })
        
        print $"  ($variant): ($data.events) events, ($data.event_rate | math round -p 2)/min ($lift)"
    }
    
    let results = {
        test_name: $name
        variants: $variant_data
        baseline: $baseline
        comparisons: $comparison
        confidence_level: $confidence
        total_events: ($variant_data | transpose k v | each { |r| $r.v.events } | math sum)
    }
    
    # Save results back to test
    mut updated_test = $test
    $updated_test = ($updated_test | upsert results.variant_metrics $variant_data)
    $updated_test | save -f $test_file
    
    $results
}

# Calculate confidence score (simplified)
export def calculate-confidence [a: float, b: float]: [ nothing -> float ] {
    if $b == 0 { return 0.0 }
    
    let diff = ($a - $b | math abs)
    let avg = (($a + $b) / 2)
    
    # Simple heuristic: larger relative difference = higher confidence
    let relative_diff = ($diff / $avg)
    
    # Scale to 0-1 range with diminishing returns
    (1 - (2.71828 ** (-2 * $relative_diff)))
}

# =============================================================================
# Winner Determination
# =============================================================================

# Determine winning variant
export def "ab-test winner" [
    name: string                              # Test name
    --metric: string = "events"               # Metric to compare
    --min-confidence: float = 0.8             # Minimum confidence threshold
]: [ nothing -> record ] {
    let results = (ab-test results $name)
    
    print $"\nDetermining winner for ($name)..."
    
    let baseline = $results.baseline
    let baseline_data = ($results.variants | get $baseline)
    
    mut best_variant = $baseline
    mut best_value = (if $metric == "events" { $baseline_data.events } else { 0 })
    mut best_confidence = 1.0
    
    # Find best variant
    for variant in ($results.variants | columns) {
        if $variant == $baseline { continue }
        
        let v_data = ($results.variants | get $variant)
        let value = (if $metric == "events" { $v_data.events } else { 0 })
        
        let comparison = ($results.comparisons | get -i $variant | default { confidence: 0 })
        
        if $value > $best_value and $comparison.confidence >= $min_confidence {
            $best_variant = $variant
            $best_value = $value
            $best_confidence = $comparison.confidence
        }
    }
    
    let winner = {
        variant: $best_variant
        metric: $metric
        value: $best_value
        confidence: $best_confidence
        is_significant: ($best_confidence >= $min_confidence)
        lift: (if $best_variant != $baseline {
            let baseline_value = (if $metric == "events" { $baseline_data.events } else { 0 })
            (($best_value - $baseline_value) / $baseline_value * 100)
        } else { 0 })
    }
    
    if $winner.is_significant {
        print $"\n✓ Winner: ($best_variant)://"
        print $"  ($metric): ($winner.value)"
        print $"  Confidence: ($winner.confidence | math round -p 2)"
        print $"  Lift: ($winner.lift | math round -p 2)%"
    } else {
        print "\n⚠ No clear winner"
        print $"  Best variant: ($best_variant) with ($winner.confidence | math round -p 2) confidence"
        print $"  (Threshold: ($min_confidence))"
    }
    
    # Save winner to test
    let test_file = (tests-dir | path join $"($name).nuon")
    let test = (open $test_file)
    mut updated_test = $test
    $updated_test = ($updated_test | upsert analysis.winner $best_variant)
    $updated_test = ($updated_test | upsert analysis.confidence $best_confidence)
    $updated_test | save -f $test_file
    
    $winner
}

# =============================================================================
# Winner Promotion
# =============================================================================

# Promote winning variant to production
export def "ab-test promote" [
    name: string                              # Test name
    variant: string                           # Variant to promote
    --target: string = "prod://default"       # Production target URI
    --snapshot: bool = true                   # Create snapshot before promotion
]: [ nothing -> record ] {
    ensure-tests-dir
    let test_file = (tests-dir | path join $"($name).nuon")
    
    if not ($test_file | path exists) {
        error make { msg: $"Test '($name)' not found" }
    }
    
    let test = (open $test_file)
    
    if $variant not-in $test.config.variants {
        error make { msg: $"Variant ($variant) not in test" }
    }
    
    let source_uri = $"($variant)://($name)-($variant)"
    
    print $"Promoting ($variant) to ($target)..."
    
    # Clone winning variant to production
    let promoted = (world clone $source_uri $target --snapshot=$snapshot)
    
    # Update test status
    mut updated_test = $test
    $updated_test = ($updated_test | upsert status "promoted")
    $updated_test = ($updated_test | upsert promoted_variant $variant)
    $updated_test = ($updated_test | upsert promoted_to $target)
    $updated_test = ($updated_test | upsert promoted_at (date now))
    
    # Add promotion event
    let event = {
        type: "promotion"
        timestamp: (date now)
        variant: $variant
        from: $source_uri
        to: $target
    }
    $updated_test = ($updated_test | upsert results.events {|| $test.results.events | append $event })
    
    $updated_test | save -f $test_file
    
    print $"\n✓ Promoted ($variant) → ($target)"
    print $"  State hash: ($promoted.state_hash)"
    
    {
        test: $name
        variant: $variant
        source: $source_uri
        target: $target
        timestamp: (date now)
    }
}

# =============================================================================
# Test Lifecycle
# =============================================================================

# Stop a running test
export def "ab-test stop" [
    name: string                              # Test name
]: [ nothing -> record ] {
    ensure-tests-dir
    let test_file = (tests-dir | path join $"($name).nuon")
    
    if not ($test_file | path exists) {
        error make { msg: $"Test '($name)' not found" }
    }
    
    let test = (open $test_file)
    
    # End all sessions
    for session_id in $test.sessions {
        try {
            mp session end $session_id
        } catch { |e| print $"Warning: could not end session ($session_id): ($e.msg)" }
    }
    
    mut updated_test = $test
    $updated_test = ($updated_test | upsert status "ended")
    $updated_test = ($updated_test | upsert ended_at (date now))
    $updated_test | save -f $test_file
    
    print $"✓ Stopped test ($name)"
    
    # Return final results
    ab-test results $name
}

# List all tests
export def "ab-test list" [
    --status: string = ""                    # Filter by status
]: [ nothing -> table ] {
    ensure-tests-dir
    
    let test_files = (ls (tests-dir)/*.nuon | default [])
    
    if ($test_files | is-empty) {
        print "No tests found"
        return []
    }
    
    mut tests = []
    
    for file in $test_files {
        let test = (open $file.name)
        
        $tests = ($tests | append {
            name: $test.name
            id: $test.id
            status: $test.status
            variants: ($test.config.variants | str join ',')
            players: $test.config.total_players
            created: $test.created_at
            winner: ($test.analysis | get -i winner | default '-')
        })
    }
    
    if $status != "" {
        $tests | where status == $status
    } else {
        $tests
    }
}

# Get test info
export def "ab-test info" [
    name: string                              # Test name
]: [ nothing -> record ] {
    ensure-tests-dir
    let test_file = (tests-dir | path join $"($name).nuon")
    
    if not ($test_file | path exists) {
        error make { msg: $"Test '($name)' not found" }
    }
    
    let test = (open $test_file)
    
    print $"A/B Test: ($test.name)"
    print $"  ID: ($test.id)"
    print $"  Status: ($test.status)"
    print $"  Variants: ($test.config.variants | str join ', ')"
    print $"  Players: ($test.config.total_players)"
    print $"  Created: ($test.created_at)"
    
    if $test.started_at != null {
        print $"  Started: ($test.started_at)"
    }
    if $test.ended_at != null {
        print $"  Ended: ($test.ended_at)"
    }
    if $test.analysis.winner != null {
        print $"  Winner: ($test.analysis.winner) (confidence: ($test.analysis.confidence | math round -p 2))"
    }
    
    $test
}

# Delete a test
export def "ab-test delete" [
    name: string                              # Test name
    --force: bool                             # Skip confirmation
    --cleanup-worlds: bool = true             # Delete associated worlds
]: [ nothing -> nothing ] {
    ensure-tests-dir
    let test_file = (tests-dir | path join $"($name).nuon")
    
    if not ($test_file | path exists) {
        print $"Test '($name)' not found"
        return
    }
    
    let test = (open $test_file)
    
    if not $force {
        print $"Delete test '($name)'? [y/N]"
        let confirm = (input)
        if ($confirm | downcase) != "y" {
            print "Cancelled"
            return
        }
    }
    
    # Cleanup worlds if requested
    if $cleanup_worlds {
        for variant in $test.config.variants {
            let uri = $"($variant)://($name)-($variant)"
            try {
                world delete $uri --force
            } catch { |e| print $"Warning: could not delete ($uri)" }
        }
    }
    
    rm $test_file
    print $"✓ Deleted test ($name)"
}

# =============================================================================
# Test Export
# =============================================================================

# Export test results
export def "ab-test export" [
    name: string                              # Test name
    --format: string = "json"                 # Export format: json, csv, markdown
    --output: path = ""                       # Output file
]: [ nothing -> string ] {
    ensure-tests-dir
    let test_file = (tests-dir | path join $"($name).nuon")
    
    if not ($test_file | path exists) {
        error make { msg: $"Test '($name)' not found" }
    }
    
    let test = (open $test_file)
    
    let output_file = (if $output == "" {
        $"($name)_results.($format)"
    } else { $output })
    
    let content = (match $format {
        "json" => { $test | to json }
        "nuon" => { $test | to nuon }
        "markdown" => { generate-markdown-report $test }
        _ => { error make { msg: $"Unknown format: ($format)" } }
    })
    
    $content | save -f $output_file
    print $"✓ Exported to ($output_file)"
    
    $content
}

# Generate markdown report
export def generate-markdown-report [test: record]: [ nothing -> string ] {
    $"# A/B Test Report: ($test.name)

## Summary
- **Test ID**: ($test.id)
- **Status**: ($test.status)
- **Created**: ($test.created_at)
- **Variants**: ($test.config.variants | str join ', ')
- **Total Players**: ($test.config.total_players)

## Configuration
- **Confidence Level**: ($test.config.confidence_level)
- **Min Sample Size**: ($test.config.min_sample_size)

## Results

### Variant Metrics
($test.results.variant_metrics | transpose variant data | each { |row|
    $"#### ($row.variant)
- Events: ($row.data | get -i events | default 0)
- Event Rate: ($row.data | get -i event_rate | default 0 | math round -p 2)/min
- Players: ($row.data | get -i players | default 0)
"
} | str join "\n")

## Analysis
($if $test.analysis.winner != null {
    $"### Winner: ($test.analysis.winner)
- **Confidence**: ($test.analysis.confidence | math round -p 4)
"
} else {
    "### No winner determined yet"
})

## Events
($test.results.events | each { |e| $"- ($e.timestamp): ($e.type)" } | str join "\n")

---
*Generated: (date now)*
"
}
