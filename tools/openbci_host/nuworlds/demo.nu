#!/usr/bin/env nu
# demo.nu - Interactive demonstration script for nuworlds
# Shows all major features step by step with colorful output

use themes.nu *
use utils.nu *

const DEMO_MODES = [quick full bci-only worlds-only]

# =============================================================================
# Main Demo Entry Point
# =============================================================================

# Run interactive demonstration
export def main [
    --mode: string = "quick"    # Demo mode: quick, full, bci-only, worlds-only
]: [ nothing -> nothing ] {
    
    if $mode not-in $DEMO_MODES {
        error make { msg: $"Invalid mode: ($mode). Valid modes: ($DEMO_MODES | str join ', ')" }
    }
    
    # Clear screen and show header
    print "\x1b[2J\x1b[H"  # ANSI clear screen
    show-banner
    
    # Ask for user name
    print -n "Enter your name (or press Enter for 'Guest'): "
    let user_name = (input | default "Guest")
    
    print $"\n👋 Welcome to nuworlds, (ansi cyan_bold)($user_name)(ansi reset)!\n"
    
    # Run selected demo mode
    match $mode {
        "quick" => (run-quick-demo)
        "full" => (run-full-demo)
        "bci-only" => (run-bci-demo)
        "worlds-only" => (run-worlds-demo)
    }
    
    show-footer
}

# =============================================================================
# Demo Modes
# =============================================================================

# Quick demo - highlights in 2 minutes
export def run-quick-demo []: [ nothing -> nothing ] {
    show-section "QUICK DEMO - Overview of nuworlds features"
    
    with-progress "1. Device Detection" {
        simulate-device-detection
    }
    
    with-progress "2. EEG Streaming (simulated)" {
        simulate-streaming 5
    }
    
    with-progress "3. World A/B Testing" {
        simulate-worlds
    }
    
    with-progress "4. Multiplayer Sessions" {
        simulate-multiplayer
    }
    
    print "\n✨ Quick demo complete! Run with --mode full for comprehensive demo."
}

# Full demo - comprehensive walkthrough
export def run-full-demo []: [ nothing -> nothing ] {
    show-section "FULL DEMO - Comprehensive nuworlds Tour"
    
    # Part 1: Initialization
    show-part "PART 1: System Initialization"
    with-progress "Checking system capabilities" {
        sleep 1sec
        print "   ✓ Nushell version: " + (version | get version)
        print "   ✓ OS: " + (sys host | get name)
        print "   ✓ Serial ports: " + ((detect-serial-ports) | length | into string) + " found"
    }
    
    # Part 2: Device Management
    show-part "PART 2: OpenBCI Device Management"
    with-progress "Listing connected devices" {
        simulate-device-detection
    }
    
    with-interactive-prompt "Would you like to see impedance check demo? [y/N]" {
        simulate-impedance-check
    }
    
    # Part 3: Streaming
    show-part "PART 3: Real-time EEG Streaming"
    with-progress "Starting data stream" {
        simulate-streaming 10
    }
    
    with-progress "Calculating band powers" {
        simulate-band-powers
    }
    
    # Part 4: World Management
    show-part "PART 4: A/B World Testing Framework"
    with-progress "Creating world variants" {
        simulate-world-creation
    }
    
    with-progress "Comparing worlds" {
        simulate-world-comparison
    }
    
    # Part 5: Multiplayer
    show-part "PART 5: Multiplayer Session Management"
    with-progress "Creating multiplayer session" {
        simulate-session-creation
    }
    
    with-progress "Assigning players" {
        simulate-player-assignment
    }
    
    # Part 6: Pipelines
    show-part "PART 6: BCI Processing Pipelines"
    with-progress "Creating standard BCI pipeline" {
        simulate-pipeline-creation
    }
    
    # Part 7: Visualization
    show-part "PART 7: Data Visualization"
    print "\n📊 ASCII Visualization Demo:"
    simulate-waveform-ascii
    
    # Part 8: Export
    show-part "PART 8: Data Export & Analysis"
    with-progress "Exporting sample data" {
        simulate-export
    }
    
    print "\n\n✨ Full demo complete! You've seen all major features."
}

# BCI-only demo - focus on EEG/BCI features
export def run-bci-demo []: [ nothing -> nothing ] {
    show-section "BCI DEMO - Brain-Computer Interface Features"
    
    show-part "1. Device Connection"
    simulate-device-detection
    
    show-part "2. Real-time Streaming"
    simulate-streaming 20
    
    show-part "3. Band Power Analysis"
    simulate-band-powers-detailed
    
    show-part "4. Signal Quality Assessment"
    simulate-signal-quality
    
    show-part "5. Artifact Detection"
    simulate-artifact-detection
    
    print "\n✨ BCI demo complete!"
}

# Worlds-only demo - focus on A/B world testing
export def run-worlds-demo []: [ nothing -> nothing ] {
    show-section "WORLDS DEMO - A/B Testing Framework"
    
    show-part "1. World Creation"
    simulate-world-creation-detailed
    
    show-part "2. World Cloning"
    simulate-world-cloning
    
    show-part "3. State Snapshots"
    simulate-snapshots
    
    show-part "4. World Comparison"
    simulate-world-comparison-detailed
    
    show-part "5. Multiplayer Integration"
    simulate-world-multiplayer
    
    print "\n✨ Worlds demo complete!"
}

# =============================================================================
# Simulation Functions
# =============================================================================

# Simulate device detection
def simulate-device-detection []: [ nothing -> nothing ] {
    print "   🔍 Scanning for OpenBCI devices..."
    sleep 500ms
    
    # Check for real devices
    let ports = (detect-serial-ports)
    
    if ($ports | length) > 0 {
        for port in $ports {
            print $"   ✓ Found device at ($port)"
        }
    } else {
        print "   ⚠ No physical devices detected"
        print "   🎮 Using simulated device for demo"
    }
    
    print ""
    print "   ╭──────────┬─────────────┬──────────────┬──────────┬──────────╮"
    print "   │ Type     │ ID          │ Port         │ Channels │ Status   │"
    print "   ├──────────┼─────────────┼──────────────┼──────────┼──────────┤"
    print "   │ Cyton    │ OpenBCI-001 │ /dev/ttyUSB0 │ 8        │ ready    │"
    print "   ╰──────────┴─────────────┴──────────────┴──────────┴──────────╯"
}

# Simulate impedance check
def simulate-impedance-check []: [ nothing -> nothing ] {
    print "   🔌 Measuring electrode impedance..."
    sleep 1sec
    
    print ""
    print "   ╭─────────┬───────────────┬──────────┬──────────────────────╮"
    print "   │ Channel │ Impedance(kΩ) │ Status   │ Recommendation       │"
    print "   ├─────────┼───────────────┼──────────┼──────────────────────┤"
    
    let channels = [Fp1 Fp2 C3 C4 P3 P4 O1 O2]
    let impedances = [5.2 6.1 4.8 5.5 5.9 4.2 6.3 5.1]
    
    for i in 0..7 {
        let ch = ($channels | get $i)
        let imp = ($impedances | get $i)
        let status = if $imp < 5 { "good  " } else if $imp < 10 { "fair  " } else { "poor  " }
        let rec = if $imp < 5 { "No action needed     " } else if $imp < 10 { "Check gel/saline     " } else { "Reposition electrode " }
        print $"   │ ($ch)     │ ($imp)          │ ($status)│ ($rec)│"
    }
    
    print "   ╰─────────┴───────────────┴──────────┴──────────────────────╯"
}

# Simulate EEG streaming
def simulate-streaming [sample_count: int]: [ nothing -> nothing ] {
    print $"   📡 Streaming (simulated) ($sample_count) samples...\n"
    
    print "   ╭─────────────┬──────────┬──────────┬──────────┬──────────╮"
    print "   │ Timestamp   │ Fp1 (µV) │ Fp2 (µV) │ C3 (µV)  │ C4 (µV)  │"
    print "   ├─────────────┼──────────┼──────────┼──────────┼──────────┤"
    
    for i in 0..$sample_count {
        let ts = (date now | format date "%H:%M:%S%.3f")
        let ch0 = (random float -100..100 | math round -p 2)
        let ch1 = (random float -100..100 | math round -p 2)
        let ch2 = (random float -100..100 | math round -p 2)
        let ch3 = (random float -100..100 | math round -p 2)
        
        print -n $"\r   │ ($ts) │ ($ch0) │ ($ch1) │ ($ch2) │ ($ch3) │"
        sleep 100ms
    }
    
    print ""
    print "   ╰─────────────┴──────────┴──────────┴──────────┴──────────╯"
    print ""
    print $"   ✓ Collected ($sample_count) samples"
}

# Simulate band powers
def simulate-band-powers []: [ nothing -> nothing ] {
    print "   🎵 Calculating band powers..."
    sleep 500ms
    
    print ""
    print "   ╭──────┬─────────────┬────────────────────────────────────╮"
    print "   │ Band │ Power (µV²) │ Distribution                       │"
    print "   ├──────┼─────────────┼────────────────────────────────────┤"
    
    let bands = [
        [name, symbol, power, color];
        ["delta", "Δ", 15.2, "blue"]
        ["theta", "θ", 28.4, "cyan"]
        ["alpha", "α", 52.7, "green"]
        ["beta", "β", 35.1, "yellow"]
        ["gamma", "γ", 8.9, "red"]
    ]
    
    let total = ($bands | get power | math sum)
    
    for band in $bands {
        let pct = ($band.power / $total * 100 | math round)
        let bar_len = ($pct / 2 | math floor)
        let bar = ("█" | str repeat $bar_len)
        print $"   │ ($band.symbol)    │ ($band.power)        │ ($bar) ($pct)%         │"
    }
    
    print "   ╰──────┴─────────────┴────────────────────────────────────╯"
}

# Simulate detailed band powers
def simulate-band-powers-detailed []: [ nothing -> nothing ] {
    print "   🎵 Detailed band power analysis...\n"
    
    let channels = [Fp1 Fp2 C3 C4 P3 P4 O1 O2]
    
    for ch in $channels {
        print $"   Channel ($ch):"
        let powers = {
            delta: (random float 10..20)
            theta: (random float 20..40)
            alpha: (random float 40..70)
            beta: (random float 20..50)
            gamma: (random float 5..15)
        }
        
        let bar = (band-power-bar $powers --width 40)
        print $"     ($bar)"
        
        # Show dominant band
        let max_band = ($powers | items { |k,v| {band: $k, power: $v} } | sort-by power | last)
        print $"     Dominant: ($max_band.band) at ($max_band.power | math round -p 1) µV²\n"
    }
}

# Simulate signal quality
def simulate-signal-quality []: [ nothing -> nothing ] {
    print "   📊 Signal quality assessment:\n"
    
    let channels = [Fp1 Fp2 C3 C4 P3 P4 O1 O2]
    
    for ch in $channels {
        let snr = (random float 10..20 | math round -p 1)
        let quality = if $snr > 15 { "excellent" } else if $snr > 12 { "good" } else { "fair" }
        let bar = (quality-bar $snr 0 20)
        print $"   ($ch) │ ($bar) │ ($quality)"
    }
}

# Simulate artifact detection
def simulate-artifact-detection []: [ nothing -> nothing ] {
    print "   ⚡ Detecting artifacts...\n"
    
    let artifacts = [
        [time, type, channel, severity];
        ["00:00:15", "blink", "Fp1,Fp2", "medium"]
        ["00:00:32", "motion", "C3,C4", "low"]
        ["00:01:05", "jaw_clench", "Fp1,Fp2", "high"]
    ]
    
    print "   ╭──────────┬────────────┬───────────┬──────────╮"
    print "   │ Time     │ Type       │ Channels  │ Severity │"
    print "   ├──────────┼────────────┼───────────┼──────────┤"
    
    for art in $artifacts {
        print $"   │ ($art.time) │ ($art.type) │ ($art.channel) │ ($art.severity)   │"
    }
    
    print "   ╰──────────┴────────────┴───────────┴──────────╯"
}

# Simulate world creation
def simulate-world-creation []: [ nothing -> nothing ] {
    print "   🌍 Creating world variants...\n"
    
    print "   Creating a://baseline_world..."
    sleep 300ms
    print "   ✓ Created baseline world with default physics"
    
    print "   Creating b://variant_world..."
    sleep 300ms  
    print "   ✓ Created variant with modified gravity (0.8x)"
    
    print "   Creating c://experimental_world..."
    sleep 300ms
    print "   ✓ Created experimental world with new features"
}

# Simulate detailed world creation
def simulate-world-creation-detailed []: [ nothing -> nothing ] {
    print "   🌍 World creation details:\n"
    
    print "   a://baseline_world"
    print "     Template: default"
    print "     Physics: {gravity: 9.8, friction: 0.5}"
    print "     Entities: 0"
    print "     State: ready\n"
    
    print "   b://variant_world"
    print "     Template: default (modified)"
    print "     Physics: {gravity: 7.8, friction: 0.3}"
    print "     Cloned from: a://baseline_world"
    print "     Modifications: [gravity ×0.8, friction ×0.6]\n"
    
    print "   c://experimental_world"
    print "     Template: experimental"
    print "     Physics: {gravity: 11.0, friction: 0.7, wind: true}"
    print "     Features: [wind_particles, dynamic_lighting]"
}

# Simulate world comparison
def simulate-world-comparison []: [ nothing -> nothing ] {
    print "   🔍 Comparing a://baseline vs b://variant...\n"
    
    print "   Parameter changes: 2"
    print "   Entity changes: +0 -0 ~0"
    print "   State divergence: 12.5%\n"
    
    print "   Changes:"
    print "     ~ physics.gravity: 9.8 → 7.8"
    print "     ~ physics.friction: 0.5 → 0.3"
}

# Simulate detailed world comparison
def simulate-world-comparison-detailed []: [ nothing -> nothing ] {
    print "   🔍 Detailed world comparison:\n"
    
    print "   a://baseline vs b://variant vs c://experimental\n"
    
    print "   Parameter matrix:"
    print "   ╭──────────────┬───────────┬───────────┬─────────────┬────────╮"
    print "   │ Parameter    │ Baseline  │ Variant   │ Experimental│ Diff   │"
    print "   ├──────────────┼───────────┼───────────┼─────────────┼────────┤"
    print "   │ gravity      │ 9.8       │ 7.8       │ 11.0        │ high   │"
    print "   │ friction     │ 0.5       │ 0.3       │ 0.7         │ high   │"
    print "   │ wind_enabled │ false     │ false     │ true        │ unique │"
    print "   │ entities     │ 12        │ 12        │ 8           │ medium │"
    print "   ╰──────────────┴───────────┴───────────┴─────────────┴────────╯"
}

# Simulate world cloning
def simulate-world-cloning []: [ nothing -> nothing ] {
    print "   📋 Cloning worlds...\n"
    
    print "   Cloning a://baseline → b://variant_copy..."
    sleep 500ms
    print "   ✓ Cloned successfully\n"
    
    print "   Snapshot created: baseline_v0"
    print "   State hash: a1b2c3d4e5f6"
}

# Simulate snapshots
def simulate-snapshots []: [ nothing -> nothing ] {
    print "   📸 World snapshots:\n"
    
    print "   ╭──────────┬──────────────────────┬─────────┬────────────┬──────────────╮"
    print "   │ Version  │ Timestamp            │ Entities│ Message    │ Hash         │"
    print "   ├──────────┼──────────────────────┼─────────┼────────────┼──────────────┤"
    print "   │ v0       │ 2025-02-03 10:00:00  │ 0       │ Initial    │ abc123...    │"
    print "   │ v1       │ 2025-02-03 10:15:23  │ 5       │ Add objects│ def456...    │"
    print "   │ v2       │ 2025-02-03 10:30:45  │ 12      │ Full setup │ ghi789...    │"
    print "   ╰──────────┴──────────────────────┴─────────┴────────────┴──────────────╯"
}

# Simulate worlds
def simulate-worlds []: [ nothing -> nothing ] {
    print "   🌍 Active worlds:\n"
    print "   • a://baseline (baseline) - 12 entities"
    print "   • b://variant (variant) - 12 entities"
    print "   • c://experimental (experimental) - 8 entities"
}

# Simulate multiplayer
def simulate-multiplayer []: [ nothing -> nothing ] {
    print "   🎮 Multiplayer session:\n"
    print "   Session: test-session-001"
    print "   Players: 3/3"
    print "     • Player1 → a://baseline"
    print "     • Player2 → b://variant"
    print "     • Player3 → c://experimental"
    print "   Status: running"
}

# Simulate session creation
def simulate-session-creation []: [ nothing -> nothing ] {
    print "   🎮 Creating multiplayer session..."
    sleep 500ms
    print "   ✓ Session ID: demo-session-001"
    print "   ✓ Player slots: 3"
    print "   ✓ Duration: 5min"
}

# Simulate player assignment
def simulate-player-assignment []: [ nothing -> nothing ] {
    print "   👥 Assigning players to worlds...\n"
    
    print "   Assigning Alice → a://baseline..."
    sleep 200ms
    print "   ✓ Alice assigned (baseline)"
    
    print "   Assigning Bob → b://variant..."
    sleep 200ms
    print "   ✓ Bob assigned (variant)"
    
    print "   Assigning Carol → c://experimental..."
    sleep 200ms
    print "   ✓ Carol assigned (experimental)"
}

# Simulate world multiplayer
def simulate-world-multiplayer []: [ nothing -> nothing ] {
    print "   🎮 World multiplayer state:\n"
    
    print "   Session: worlds-demo-session"
    print "   "
    print "   World state convergence:"
    print "   ╭──────────────┬─────────┬───────────┬──────────────╮"
    print "   │ World        │ Players │ State Hash│ Sync Status  │"
    print "   ├──────────────┼─────────┼───────────┼──────────────┤"
    print "   │ a://baseline │ 1       │ a1b2c3... │ ✓ synced     │"
    print "   │ b://variant  │ 1       │ d4e5f6... │ ✓ synced     │"
    print "   │ c://experimental│ 1    │ g7h8i9... │ ⚠ divergence │"
    print "   ╰──────────────┴─────────┴───────────┴──────────────╯"
    
    print "\n   ⚠ c://experimental has state divergence from baseline"
    print "     Recommendation: Run sync or resolve conflicts"
}

# Simulate pipeline creation
def simulate-pipeline-creation []: [ nothing -> nothing ] {
    print "   ⚙️  Creating BCI pipeline...\n"
    
    print "   Nodes:"
    print "     [1] raw_acquisition → [2] filter → [3] feature_extract → [4] classify → [5] visualize"
    
    print "\n   Configuration:"
    print "     Sample rate: 250 Hz"
    print "     Channels: 8"
    print "     Filter: 1-50 Hz bandpass, 60 Hz notch"
    print "     Features: bandpower, RMS, variance"
    print "     Classifier: LDA"
    
    print "\n   Edges:"
    print "     raw_acquisition → filter (buffer: 1250 samples)"
    print "     filter → feature_extract (buffer: 1024 samples)"
    print "     feature_extract → classify (buffer: 100 samples)"
    print "     classify → visualize (buffer: 100 samples)"
}

# Simulate waveform ASCII
def simulate-waveform-ascii []: [ nothing -> nothing ] {
    let channels = ["Fp1" "Fp2" "C3" "C4"]
    
    for ch in $channels {
        print $"   ($ch) │"
        
        # Generate 40 samples of waveform
        mut line = ""
        for i in 0..40 {
            let t = $i / 10.0
            let value = (100 * (2 * 3.14159 * 10 * $t | math sin) | math round)
            let height = (($value + 100) / 10 | math floor)
            
            if $height > 15 {
                $line = $line + "│"
            } else if $height > 10 {
                $line = $line + "╱"
            } else if $height > 5 {
                $line = $line + "─"
            } else {
                $line = $line + "╲"
            }
        }
        
        print $"($line)"
    }
}

# Simulate export
def simulate-export []: [ nothing -> nothing ] {
    print "   📤 Export formats:\n"
    
    print "   • CSV: eeg_data_2025-02-03.csv (245 KB)"
    print "   • JSON: eeg_data_2025-02-03.json (512 KB)"
    print "   • EDF: eeg_data_2025-02-03.edf (128 KB)"
    print "   • Parquet: eeg_data_2025-02-03.parquet (89 KB)"
    
    print "\n   Report generated: session_report_2025-02-03.md"
}

# =============================================================================
# UI Helpers
# =============================================================================

# Show banner
def show-banner []: [ nothing -> nothing ] {
    print (ansi cyan_bold)
    print "╔══════════════════════════════════════════════════════════════════╗"
    print "║                                                                  ║"
    print "║   ███╗   ██╗██╗   ██╗██╗    ██╗ ██████╗ ██████╗ ██╗     ███████╗ ║"
    print "║   ████╗  ██║██║   ██║██║    ██║██╔═══██╗██╔══██╗██║     ██╔════╝ ║"
    print "║   ██╔██╗ ██║██║   ██║██║ █╗ ██║██║   ██║██████╔╝██║     ███████╗ ║"
    print "║   ██║╚██╗██║██║   ██║██║███╗██║██║   ██║██╔══██╗██║     ╚════██║ ║"
    print "║   ██║ ╚████║╚██████╔╝╚███╔███╔╝╚██████╔╝██║  ██║███████╗███████║ ║"
    print "║   ╚═╝  ╚═══╝ ╚═════╝  ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝╚══════╝ ║"
    print "║                                                                  ║"
    print "║         OpenBCI + A/B World Testing Framework                    ║"
    print "║                                                                  ║"
    print "╚══════════════════════════════════════════════════════════════════╝"
    print (ansi reset)
}

# Show section header
def show-section [title: string]: [ nothing -> nothing ] {
    print ""
    print (ansi cyan_bold)
    print $"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print $"  ($title)"
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print (ansi reset)
}

# Show part header
def show-part [title: string]: [ nothing -> nothing ] {
    print ""
    print (ansi yellow_bold)
    print $"▶ ($title)"
    print (ansi reset)
}

# Show footer
def show-footer []: [ nothing -> nothing ] {
    print ""
    print (ansi cyan_bold)
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print "  Thank you for exploring nuworlds!"
    print ""
    print "  Next steps:"
    print "    • nuworlds repl          Start interactive REPL"
    print "    • nuworlds dashboard     Launch real-time dashboard"
    print "    • nuworlds workflow      Run pre-built workflows"
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print (ansi reset)
    print ""
}

# Run command with progress indicator
def with-progress [label: string, block: closure]: [ nothing -> nothing ] {
    print $"\n⏳ ($label)..."
    do $block
    print "✓ Complete"
}

# Interactive prompt
export def with-interactive-prompt [prompt: string, block: closure]: [ nothing -> nothing ] {
    print -n $"\n($prompt) "
    let response = (input)
    
    if ($response | downcase) == "y" or ($response | downcase) == "yes" {
        do $block
    } else {
        print "   (Skipped)"
    }
}

# Quality bar
def quality-bar [value: float, min: float, max: float]: [ nothing -> string ] {
    let pct = (($value - $min) / ($max - $min) * 100 | math min 100 | math max 0)
    let filled = ($pct / 5 | math floor)
    let empty = 20 - $filled
    
    let color = if $pct > 75 { (ansi green) } else if $pct > 50 { (ansi yellow) } else { (ansi red) }
    let bar = ("█" | str repeat $filled) + ("░" | str repeat $empty)
    
    $"($color)($bar)(ansi reset) ($value | math round -p 1)"
}

# Band power bar
export def band-power-bar [powers: record, --width: int]: [ nothing -> string ] {
    let total = ($powers | values | math sum)
    if $total == 0 { return ("░" | str repeat $width) }
    
    let delta_w = ($powers.delta / $total * $width | math round)
    let theta_w = ($powers.theta / $total * $width | math round)
    let alpha_w = ($powers.alpha / $total * $width | math round)
    let beta_w = ($powers.beta / $total * $width | math round)
    let gamma_w = ($width - $delta_w - $theta_w - $alpha_w - $beta_w)
    
    (ansi blue_dim) + ("█" | str repeat $delta_w) +
    (ansi cyan) + ("█" | str repeat $theta_w) +
    (ansi green) + ("█" | str repeat $alpha_w) +
    (ansi yellow) + ("█" | str repeat $beta_w) +
    (ansi red) + ("█" | str repeat $gamma_w) +
    (ansi reset)
}

# Detect serial ports
def detect-serial-ports []: [ nothing -> list ] {
    let patterns = ["/dev/ttyUSB*" "/dev/ttyACM*" "/dev/cu.usbserial*"]
    mut ports = []
    for pattern in $patterns {
        let found = (try { glob $pattern } catch { [] })
        $ports = ($ports | append $found)
    }
    $ports
}

# Run if executed directly
if ($env.FILE_PWD? | default "") == ($env.CURRENT_FILE? | default "" | path dirname) {
    main --mode quick
}
