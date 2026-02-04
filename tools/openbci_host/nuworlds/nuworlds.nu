#!/usr/bin/env nu
# nuworlds.nu - Master command for nuworlds
# Single entry point: nuworlds <command>
# Subcommands: demo, workflow, dashboard, repl, doctor, update

use init.nu *
use themes.nu *
use utils.nu *

const VERSION = "0.2.0"
const CONFIG_DIR = ($nu.home-path | path join ".config" "nuworlds")

# =============================================================================
# Main Entry Point
# =============================================================================

# nuworlds - OpenBCI + A/B World Testing Framework
#
# Usage:
#   nuworlds demo           # Run interactive demo
#   nuworlds workflow       # Run pre-built workflows
#   nuworlds dashboard      # Launch real-time dashboard
#   nuworlds repl           # Start interactive REPL
#   nuworlds doctor         # System diagnostics
#   nuworlds update         # Check for updates
#
# Examples:
#   nuworlds demo --mode full
#   nuworlds workflow bci-focus-tracker
#   nuworlds dashboard --theme matrix
export def main []: [ nothing -> string ] {
    $"nuworlds v($VERSION) - OpenBCI + A/B World Testing Framework

USAGE:
    nuworlds <command> [args]

COMMANDS:
    demo        Interactive demonstration (quick, full, bci-only, worlds-only)
    workflow    Run pre-built workflows
    dashboard   Real-time terminal dashboard
    repl        Interactive REPL with state persistence
    doctor      System diagnostics and troubleshooting
    update      Check for updates
    init        Initialize nuworlds (first run)
    theme       Manage color themes

ALIASES:
    obs         openbci stream
    obr         openbci record
    oba         openbci analyze
    obv         openbci viz
    wab         world_ab
    mp3         mp session new --players 3

EXAMPLES:
    # Run full interactive demo
    nuworlds demo --mode full

    # Run focus tracking workflow
    nuworlds workflow bci-focus-tracker

    # Launch dashboard with ocean theme
    nuworlds dashboard --theme ocean

    # Start REPL
    nuworlds repl

    # Run system diagnostics
    nuworlds doctor

For more help:
    nuworlds <command> --help
"
}

# =============================================================================
# Subcommands
# =============================================================================

# Run interactive demonstration
export def "main demo" [
    --mode: string = "quick"    # Demo mode: quick, full, bci-only, worlds-only
]: [ nothing -> nothing ] {
    # Check initialization
    if not (is-initialized) {
        print "⚠️  nuworlds not initialized. Running init first..."
        init
        print ""
    }
    
    let demo_script = ($env.FILE_PWD? | default "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds" | path join "demo.nu")
    
    if ($demo_script | path exists) {
        nu $demo_script --mode $mode
    } else {
        # Built-in quick demo
        run-builtin-demo $mode
    }
}

# Run pre-built workflows
export def "main workflow" [
    name?: string              # Workflow name
    --list(-l)                 # List available workflows
]: [ nothing -> any ] {
    let workflows_script = ($env.FILE_PWD? | default "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds" | path join "workflows.nu")
    
    if $list or $name == null {
        print "Available workflows:"
        print "  bci-focus-tracker    Stream → alpha detection → focus state → log"
        print "  ab-test-eeg          3 worlds + 3 players + EEG input → winner"
        print "  meditation-monitor   Real-time meditation depth with audio cues"
        print "  sleep-recorder       Overnight recording with auto-stage detection"
        print "  neurofeedback-game   Game controlled by brain state"
        print ""
        print "Usage: nuworlds workflow <name>"
        return
    }
    
    if ($workflows_script | path exists) {
        nu $workflows_script $name
    } else {
        error make { msg: $"Workflow script not found: ($workflows_script)" }
    }
}

# Launch real-time terminal dashboard
export def "main dashboard" [
    --theme: string = "default"    # Color theme: default, minimal, high-contrast, ocean, matrix
    --duration: duration           # Auto-close after duration
]: [ nothing -> nothing ] {
    # Check initialization
    if not (is-initialized) {
        print "⚠️  nuworlds not initialized. Running init first..."
        init
        print ""
    }
    
    let dashboard_script = ($env.FILE_PWD? | default "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds" | path join "dashboard.nu")
    
    if ($dashboard_script | path exists) {
        nu $dashboard_script --theme $theme --duration $duration?
    } else {
        error make { msg: $"Dashboard script not found: ($dashboard_script)" }
    }
}

# Start interactive REPL
export def "main repl" [
    --theme: string = "default"    # Color theme
]: [ nothing -> nothing ] {
    # Check initialization
    if not (is-initialized) {
        print "⚠️  nuworlds not initialized. Running init first..."
        init
        print ""
    }
    
    let repl_script = ($env.FILE_PWD? | default "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds" | path join "repl.nu")
    
    if ($repl_script | path exists) {
        nu $repl_script --theme $theme
    } else {
        # Simple built-in repl
        run-builtin-repl
    }
}

# System diagnostics
export def "main doctor" []: [ nothing -> record ] {
    print "🔬 nuworlds System Diagnostics\n"
    
    mut results = {
        initialized: false
        directories: {}
        dependencies: {}
        devices: []
        issues: []
        recommendations: []
    }
    
    # Check initialization
    print "Checking initialization..."
    $results.initialized = (is-initialized)
    if $results.initialized {
        print "  ✓ nuworlds initialized"
    } else {
        print "  ✗ nuworlds not initialized"
        $results.issues = ($results.issues | append "Not initialized")
        $results.recommendations = ($results.recommendations | append "Run: nuworlds init")
    }
    
    # Check directories
    print "\nChecking directories..."
    let dirs = {
        config: ($CONFIG_DIR | path exists)
        worlds: ($CONFIG_DIR | path join "worlds" | path exists)
        sessions: ($CONFIG_DIR | path join "sessions" | path exists)
        recordings: (($nu.home-path | path join ".local" "share" "nuworlds" "recordings") | path exists)
    }
    $results.directories = $dirs
    
    for dir in ($dirs | columns) {
        if ($dirs | get $dir) {
            print $"  ✓ ($dir)"
        } else {
            print $"  ✗ ($dir)"
        }
    }
    
    # Check dependencies
    print "\nChecking dependencies..."
    let deps = {
        nushell: (version | get version)
        python3: (which python3 | is-not-empty)
        bluetoothctl: (which bluetoothctl | is-not-empty)
    }
    $results.dependencies = $deps
    
    for dep in ($deps | columns) {
        let val = ($deps | get $dep)
        if ($val | describe) == "bool" {
            if $val {
                print $"  ✓ ($dep)"
            } else {
                print $"  ⚠ ($dep) not found"
            }
        } else {
            print $"  ✓ ($dep): ($val)"
        }
    }
    
    # Check for OpenBCI devices
    print "\nScanning for OpenBCI devices..."
    let devices = (detect-devices)
    $results.devices = $devices
    
    if ($devices | length) > 0 {
        for device in $devices {
            print $"  ✓ Found ($device.type) at ($device.port)"
        }
    } else {
        print "  ⚠ No devices detected"
        $results.issues = ($results.issues | append "No OpenBCI devices found")
        $results.recommendations = ($results.recommendations | append "Connect OpenBCI device and check USB/Bluetooth")
    }
    
    # Summary
    print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if ($results.issues | length) == 0 {
        print "✅ All systems operational"
    } else {
        print $"⚠️  ($results.issues | length) issue(s) found:"
        for issue in $results.issues {
            print $"   - ($issue)"
        }
        print "\nRecommendations:"
        for rec in $results.recommendations {
            print $"   • ($rec)"
        }
    }
    
    $results
}

# Check for updates
export def "main update" [--check-only]: [ nothing -> record ] {
    print "🔄 Checking for updates...\n"
    
    let current = $VERSION
    
    # In a real implementation, this would check a remote URL
    # For now, simulate with local check
    let latest = $current  # Would be fetched from GitHub
    
    print $"Current version: ($current)"
    print $"Latest version:  ($latest)"
    
    if $current == $latest {
        print "\n✅ You are running the latest version"
    } else {
        print "\n⚠️  A new version is available"
        print "   Update with: git pull origin main"
    }
    
    { current: $current, latest: $latest, up_to_date: ($current == $latest) }
}

# Initialize nuworlds
export def "main init" [--reset]: [ nothing -> nothing ] {
    if $reset {
        init reset
    } else {
        init
    }
}

# Theme management
export def "main theme" [
    action?: string        # Action: list, set, demo
    name?: string          # Theme name for set action
]: [ nothing -> any ] {
    if $action == null or $action == "list" {
        print "Available themes:"
        list-themes | table
    } else if $action == "set" {
        if $name == null {
            print "Usage: nuworlds theme set <name>"
            print "Available: default, minimal, high-contrast, ocean, matrix"
        } else {
            set-theme $name
        }
    } else if $action == "demo" {
        demo
    } else {
        print $"Unknown action: ($action)"
        print "Usage: nuworlds theme [list|set|demo]"
    }
}

# Show version
export def "main version" []: [ nothing -> record ] {
    {
        version: $VERSION
        nushell: (version | get version)
        os: (sys host | get name)
        arch: (sys host | get arch)
    }
}

# =============================================================================
# Helper Functions
# =============================================================================

# Run built-in demo (when demo.nu not found)
def run-builtin-demo [mode: string]: [ nothing -> nothing ] {
    print $"🧠 nuworlds Demo (mode: ($mode))\n"
    
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print "OpenBCI Device Simulation"
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Simulate device listing
    print "\n📱 Connected devices:"
    print "  Type     │ ID            │ Port         │ Channels"
    print "  ─────────┼───────────────┼──────────────┼─────────"
    print "  Cyton    │ OpenBCI-Demo  │ /dev/ttyUSB0 │ 8"
    
    # Simulate streaming
    print "\n📊 Simulated EEG stream (5 samples):"
    mut samples = []
    for i in 0..5 {
        $samples = ($samples | append {
            timestamp: (date now | format date "%H:%M:%S%.3f")
            ch0: (random float 0..100 | math round -p 2)
            ch1: (random float 0..100 | math round -p 2)
            ch2: (random float 0..100 | math round -p 2)
        })
    }
    $samples | table
    
    if $mode == "full" or $mode == "worlds-only" {
        print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print "A/B World Testing"
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        print "\n🌍 Active worlds:"
        print "  URI        │ Variant    │ Entities │ Version"
        print "  ───────────┼────────────┼──────────┼────────"
        print "  a://test   │ baseline   │ 12       │ 0"
        print "  b://test   │ variant    │ 12       │ 0"
        print "  c://test   │ experimental│ 8       │ 0"
    }
    
    if $mode == "full" or $mode == "bci-only" {
        print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print "Band Powers"
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        print "\n🎵 Simulated band powers:"
        print "  Band  │ Power (µV²) │ Bar"
        print "  ──────┼─────────────┼────────────────────────────"
        print "  Δ     │ 15.23       │ ████░░░░░░░░░░░░░░░░"
        print "  θ     │ 28.45       │ ███████░░░░░░░░░░░░░"
        print "  α     │ 52.67       │ █████████████░░░░░░░"
        print "  β     │ 35.12       │ ████████░░░░░░░░░░░░"
        print "  γ     │ 8.91        │ ██░░░░░░░░░░░░░░░░░░"
    }
    
    print "\n✅ Demo complete!"
}

# Run built-in REPL (when repl.nu not found)
def run-builtin-repl []: [ nothing -> nothing ] {
    print "🖥️  nuworlds REPL (built-in)"
    print "Type 'exit' or press Ctrl+D to quit\n"
    
    mut running = true
    mut vars = {}
    
    while $running {
        print -n "nuworlds> "
        let input = (input)
        
        if $input == "exit" or $input == "quit" {
            $running = false
        } else if $input == ".help" {
            print "Commands:"
            print "  .help    Show this help"
            print "  .vars    Show defined variables"
            print "  exit     Exit REPL"
        } else if $input == ".vars" {
            if ($vars | is-empty) {
                print "No variables defined"
            } else {
                $vars | table
            }
        } else if ($input | str starts-with "let ") {
            # Simple variable assignment capture
            print "Variable assignment noted (use full nushell syntax)"
        } else if $input != "" {
            try {
                let result = (nu -c $input)
                $result | print
            } catch { |e|
                print $"Error: ($e.msg)"
            }
        }
    }
    
    print "\nGoodbye!"
}

# Detect OpenBCI devices
def detect-devices []: [ nothing -> list ] {
    mut devices = []
    
    # Check common serial ports
    let patterns = ["/dev/ttyUSB*" "/dev/ttyACM*" "/dev/cu.usbserial*"]
    for pattern in $patterns {
        let found = (try { glob $pattern } catch { [] })
        for port in $found {
            $devices = ($devices | append {
                type: "Cyton"
                port: $port
                status: "detected"
            })
        }
    }
    
    $devices
}

# Helper for is-initialized
export def is-initialized []: [ nothing -> bool ] {
    let marker = ($CONFIG_DIR | path join "initialized.nuon")
    $marker | path exists
}

# =============================================================================
# Aliases
# =============================================================================

# These are available when the module is used
export alias obs = openbci stream
export alias obr = openbci record  
export alias oba = openbci analyze
export alias obv = openbci viz
export alias wab = world_ab
export alias mp3 = mp session new --players 3
