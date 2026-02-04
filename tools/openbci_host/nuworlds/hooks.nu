#!/usr/bin/env nu
# hooks.nu - Event hooks for nuworlds
# Trigger custom actions on detected events

use themes.nu *
use utils.nu *

const HOOKS_DIR = ($nu.home-path | path join ".config" "nuworlds" "hooks")

# =============================================================================
# Hook Types
# =============================================================================

# Available hook types with their descriptions
const HOOK_TYPES = {
    on_blink: {
        description: "Triggered when eye blink is detected"
        parameters: ["timestamp" "channel" "amplitude"]
        default_threshold: 100.0
    }
    on_focus: {
        description: "Triggered when focus state is entered"
        parameters: ["timestamp" "alpha_beta_ratio" "duration"]
        default_threshold: 0.8
    }
    on_relax: {
        description: "Triggered when relaxation is detected"
        parameters: ["timestamp" "theta_alpha_ratio" "duration"]
        default_threshold: 1.2
    }
    on_artifact: {
        description: "Triggered on motion artifact detection"
        parameters: ["timestamp" "type" "channels" "severity"]
        default_threshold: 500.0
    }
    on_alpha_burst: {
        description: "Triggered on alpha wave burst"
        parameters: ["timestamp" "amplitude" "duration"]
        default_threshold: 50.0
    }
    on_jaw_clench: {
        description: "Triggered on jaw clench detection"
        parameters: ["timestamp" "intensity" "channels"]
        default_threshold: 200.0
    }
}

# =============================================================================
# Hook Management
# =============================================================================

# List all registered hooks
export def "hook list" []: [ nothing -> table ] {
    ensure-hooks-dir
    
    let hook_files = (ls ($HOOKS_DIR | path join "*.nuon") | default [])
    
    if ($hook_files | is-empty) {
        print "No hooks registered. Use 'hook register <type> <action>' to create hooks."
        return []
    }
    
    mut hooks = []
    for file in $hook_files {
        let hook = (open $file.name)
        $hooks = ($hooks | append {
            id: ($file.name | path basename | str replace ".nuon" "")
            type: $hook.type
            enabled: $hook.enabled
            threshold: $hook.threshold
            action: ($hook.action | str substring 0..40)
            triggers: ($hook.trigger_count | default 0)
        })
    }
    
    $hooks
}

# Show available hook types
export def "hook types" []: [ nothing -> table ] {
    $HOOK_TYPES | transpose type info | each { |row|
        {
            type: $row.type
            description: $row.info.description
            threshold: $row.info.default_threshold
        }
    }
}

# Register a new hook
export def "hook register" [
    type: string              # Hook type (see 'hook types')
    action: string            # Action to execute (nushell command or script)
    --threshold: float        # Custom threshold (uses default if not specified)
    --id: string = ""         # Custom hook ID (auto-generated if not specified)
    --disabled                # Create hook in disabled state
]: [ nothing -> record ] {
    ensure-hooks-dir
    
    # Validate hook type
    if $type not-in $HOOK_TYPES {
        error make { 
            msg: $"Unknown hook type: ($type). Valid types: ($HOOK_TYPES | columns | str join ', ')"
        }
    }
    
    let hook_id = if $id == "" {
        $"($type)_(date now | format date "%Y%m%d_%H%M%S")"
    } else {
        $id
    }
    
    let hook_def = ($HOOK_TYPES | get $type)
    let hook_threshold = $threshold | default $hook_def.default_threshold
    
    let hook = {
        id: $hook_id
        type: $type
        description: $hook_def.description
        enabled: (not $disabled)
        threshold: $hook_threshold
        parameters: $hook_def.parameters
        action: $action
        created_at: (date now)
        trigger_count: 0
        last_triggered: null
        log_triggers: true
    }
    
    let hook_file = ($HOOK_DIR | path join $"($hook_id).nuon")
    $hook | save -f $hook_file
    
    let status = if $disabled { "registered (disabled)" } else { "registered" }
    print $"✓ Hook ($status): ($hook_id)"
    print $"  Type: ($type)"
    print $"  Threshold: ($hook_threshold)"
    print $"  Action: ($action | str substring 0..50)..."
    
    $hook
}

# Enable a disabled hook
export def "hook enable" [id: string]: [ nothing -> nothing ] {
    let hook_file = ($HOOKS_DIR | path join $"($id).nuon")
    
    if not ($hook_file | path exists) {
        error make { msg: $"Hook not found: ($id)" }
    }
    
    let hook = (open $hook_file)
    $hook | upsert enabled true | save -f $hook_file
    
    print $"✓ Hook enabled: ($id)"
}

# Disable a hook
export def "hook disable" [id: string]: [ nothing -> nothing ] {
    let hook_file = ($HOOKS_DIR | path join $"($id).nuon")
    
    if not ($hook_file | path exists) {
        error make { msg: $"Hook not found: ($id)" }
    }
    
    let hook = (open $hook_file)
    $hook | upsert enabled false | save -f $hook_file
    
    print $"✓ Hook disabled: ($id)"
}

# Delete a hook
export def "hook delete" [
    id: string
    --force                   # Skip confirmation
]: [ nothing -> nothing ] {
    let hook_file = ($HOOKS_DIR | path join $"($id).nuon")
    
    if not ($hook_file | path exists) {
        print $"Hook not found: ($id)"
        return
    }
    
    if not $force {
        print $"Delete hook ($id)? [y/N]"
        let confirm = (input)
        if ($confirm | downcase) != "y" {
            print "Cancelled"
            return
        }
    }
    
    rm $hook_file
    print $"✓ Hook deleted: ($id)"
}

# Show hook details
export def "hook info" [id: string]: [ nothing -> record ] {
    let hook_file = ($HOOKS_DIR | path join $"($id).nuon")
    
    if not ($hook_file | path exists) {
        error make { msg: $"Hook not found: ($id)" }
    }
    
    let hook = (open $hook_file)
    
    print $"Hook: ($hook.id)"
    print $"  Type: ($hook.type)"
    print $"  Description: ($hook.description)"
    print $"  Status: (if $hook.enabled { "enabled" } else { "disabled" })"
    print $"  Threshold: ($hook.threshold)"
    print $"  Parameters: ($hook.parameters | str join ', ')"
    print $"  Action: ($hook.action)"
    print $"  Created: ($hook.created_at)"
    print $"  Trigger count: ($hook.trigger_count | default 0)"
    if $hook.last_triggered != null {
        print $"  Last triggered: ($hook.last_triggered)"
    }
    
    $hook
}

# Test a hook (manually trigger)
export def "hook test" [
    id: string
    --parameter (-p): record = {}  # Override parameters
]: [ nothing -> nothing ] {
    let hook_file = ($HOOKS_DIR | path join $"($id).nuon")
    
    if not ($hook_file | path exists) {
        error make { msg: $"Hook not found: ($id)" }
    }
    
    let hook = (open $hook_file)
    
    print $"Testing hook: ($id)"
    print $"  Type: ($hook.type)"
    print $"  Action: ($hook.action | str substring 0..50)...\n"
    
    # Build parameter record
    mut params = {
        timestamp: (date now | format date "%Y-%m-%d %H:%M:%S")
    }
    
    # Add default values for parameters
    for param in $hook.parameters {
        if $param == "timestamp" { continue }
        $params = ($params | insert $param (random float 0..100))
    }
    
    # Override with user parameters
    $params = ($params | merge $parameter)
    
    print "Parameters:"
    $params | table
    
    # Execute action
    print "\nExecuting action..."
    try {
        nu -c $hook.action
        print "✓ Hook executed successfully"
    } catch { |e|
        print $"✗ Hook execution failed: ($e.msg)"
    }
}

# =============================================================================
# Built-in Hook Functions
# =============================================================================

# Trigger on eye blink
export def "hook on-blink" [
    action: string            # Action to execute: can be a command or callback
    --threshold: float = 100  # Amplitude threshold in µV
    --channels: list = [0 1]  # Frontal channels to monitor
    --duration: duration = 200ms  # Debounce duration
]: [ nothing -> record ] {
    hook register on_blink $action --threshold $threshold
}

# Trigger on focus state enter
export def "hook on-focus" [
    action: string            # Action to execute
    --threshold: float = 0.8  # Alpha/beta ratio threshold (lower = more focused)
    --min-duration: duration = 3sec  # Minimum focus duration to trigger
]: [ nothing -> record ] {
    hook register on_focus $action --threshold $threshold
}

# Trigger on relaxation detection  
export def "hook on-relax" [
    action: string            # Action to execute
    --threshold: float = 1.2  # Theta/alpha ratio threshold
    --min-duration: duration = 5sec
]: [ nothing -> record ] {
    hook register on_relax $action --threshold $threshold
}

# Trigger on motion artifact
export def "hook on-artifact" [
    action: string            # Action to execute
    --threshold: float = 500  # Amplitude threshold in µV
    --types: list = ["motion" "blink" "jaw"]  # Artifact types to detect
]: [ nothing -> record ] {
    hook register on_artifact $action --threshold $threshold
}

# =============================================================================
# Hook Monitor (Background Process)
# =============================================================================

# Start monitoring hooks and triggering actions
export def "hook monitor" [
    --duration: duration = 5min   # Monitor duration
    --source: string = "simulated"  # Data source: simulated, device, file
]: [ nothing -> nothing ] {
    
    # Load all enabled hooks
    let hooks = (hook list | where enabled == true)
    
    if ($hooks | is-empty) {
        print "No enabled hooks found. Register hooks with 'hook register' first."
        return
    }
    
    print $"🎣 Monitoring ($hooks | length) hook(s) for ($duration)...\n"
    print "Press Ctrl+C to stop\n"
    
    print "Active hooks:"
    for hook in $hooks {
        print $"  • ($hook.id) [($hook.type)] threshold=($hook.threshold)"
    }
    
    print "\nMonitoring...\n"
    
    let start_time = (date now)
    mut trigger_log = []
    
    # Main monitoring loop
    loop {
        # Check duration
        if ((date now) - $start_time) >= $duration {
            print "\nMonitor duration reached."
            break
        }
        
        # Get data sample (simulated or real)
        let sample = (get-data-sample $source)
        
        # Check each hook
        for hook in $hooks {
            let should_trigger = (check-hook-condition $hook $sample)
            
            if $should_trigger {
                # Execute hook action
                execute-hook $hook $sample
                
                # Log trigger
                $trigger_log = ($trigger_log | append {
                    time: (date now)
                    hook: $hook.id
                    type: $hook.type
                })
                
                print $"\n[Trigger] ($hook.id) at (date now | format date "%H:%M:%S")"
            }
        }
        
        sleep 100ms
    }
    
    # Summary
    print $"\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print "Monitor Summary:"
    print $"  Duration: ((date now) - $start_time | format-duration)"
    print $"  Triggers: ($trigger_log | length)"
    
    if ($trigger_log | length) > 0 {
        print "\nTrigger breakdown:"
        $trigger_log | group-by hook | items { |k,v| print $"  ($k): ($v | length)" }
    }
}

# =============================================================================
# Helper Functions
# =============================================================================

def ensure-hooks-dir []: [ nothing -> nothing ] {
    mkdir $HOOKS_DIR
}

# Get data sample from various sources
def get-data-sample [source: string]: [ nothing -> record ] {
    match $source {
        "simulated" => {
            {
                timestamp: (date now)
                channels: [
                    (random float -100..100)  # Fp1
                    (random float -100..100)  # Fp2
                    (random float -50..50)    # C3
                    (random float -50..50)    # C4
                ]
                bands: {
                    delta: (random float 10..30)
                    theta: (random float 20..40)
                    alpha: (random float 30..60)
                    beta: (random float 20..40)
                    gamma: (random float 5..20)
                }
            }
        }
        _ => {
            # Return empty/default sample
            {
                timestamp: (date now)
                channels: [0 0 0 0]
                bands: { delta: 0 theta: 0 alpha: 0 beta: 0 gamma: 0 }
            }
        }
    }
}

# Check if hook condition is met
def check-hook-condition [hook: record, sample: record]: [ nothing -> bool ] {
    match $hook.type {
        "on_blink" => {
            # Check frontal channels for large deflection
            let frontal = ($sample.channels | take 2 | math avg | math abs)
            $frontal > $hook.threshold
        }
        "on_focus" => {
            # Check alpha/beta ratio
            let ratio = ($sample.bands.alpha / $sample.bands.beta)
            $ratio < $hook.threshold
        }
        "on_relax" => {
            # Check theta/alpha ratio
            let ratio = ($sample.bands.theta / $sample.bands.alpha)
            $ratio > $hook.threshold
        }
        "on_artifact" => {
            # Check for large amplitude across channels
            let max_amp = ($sample.channels | each { |c| $c | math abs } | math max)
            $max_amp > $hook.threshold
        }
        _ => false
    }
}

# Execute hook action
def execute-hook [hook: record, sample: record]: [ nothing -> nothing ] {
    # Update trigger count
    let hook_file = ($HOOKS_DIR | path join $"($hook.id).nuon")
    let updated_hook = ($hook | upsert trigger_count (($hook.trigger_count | default 0) + 1) 
                              | upsert last_triggered (date now))
    $updated_hook | save -f $hook_file
    
    # Execute action with parameters
    try {
        # In a real implementation, we'd pass parameters to the action
        nu -c $hook.action
    } catch { |e|
        print -e $"Hook ($hook.id) failed: ($e.msg)"
    }
}

# Format duration
def format-duration [duration: duration]: [ nothing -> string ] {
    let nanos = ($duration | into int)
    let seconds = ($nanos / 1000000000 | math floor)
    let mins = ($seconds / 60 | math floor)
    let secs = ($seconds mod 60)
    
    $"($mins)m ($secs)s"
}

# =============================================================================
# Example Hook Actions
# =============================================================================

# Play sound when triggered
export def hook-action-sound [sound_file: string]: [ nothing -> nothing ] {
    # Try different audio players
    if (which aplay | is-not-empty) {
        aplay $sound_file out+err> /dev/null
    } else if (which afplay | is-not-empty) {
        afplay $sound_file out+err> /dev/null
    } else if (which paplay | is-not-empty) {
        paplay $sound_file out+err> /dev/null
    }
}

# Log trigger to file
export def hook-action-log [message: string, --file: path]: [ nothing -> nothing ] {
    let log_file = $file | default ($HOOKS_DIR | path join "trigger.log")
    let entry = $"[(date now | format date "%Y-%m-%d %H:%M:%S")] ($message)"
    $entry | save --append $log_file
}

# Send notification
export def hook-action-notify [title: string, message: string]: [ nothing -> nothing ] {
    if (which notify-send | is-not-empty) {
        notify-send $title $message
    } else if $nu.os-info.name == "macos" {
        osascript -e $'display notification "($message)" with title "($title)"'
    }
}

# Change theme temporarily
export def hook-action-theme [theme: string, --duration: duration = 5sec]: [ nothing -> nothing ] {
    let original = (current-theme).name
    set-theme $theme
    sleep $duration
    set-theme $original
}
