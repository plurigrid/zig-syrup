#!/usr/bin/env nu
# workflows.nu - Pre-built workflows for worldprime
# Usage: worldprime workflow <name>

use themes.nu *
use utils.nu *

const WORKFLOWS = [bci-focus-tracker ab-test-eeg meditation-monitor sleep-recorder neurofeedback-game]

# =============================================================================
# Main Entry
# =============================================================================

export def main [name?: string]: [ nothing -> nothing ] {
    if $name == null {
        list-workflows
        return
    }
    
    if $name not-in $WORKFLOWS {
        error make { msg: $"Unknown workflow: ($name). Available: ($WORKFLOWS | str join ', ')" }
    }
    
    # Clear screen
    print "\x1b[2J\x1b[H"
    
    show-workflow-header $name
    
    match $name {
        "bci-focus-tracker" => (workflow-bci-focus-tracker)
        "ab-test-eeg" => (workflow-ab-test-eeg)
        "meditation-monitor" => (workflow-meditation-monitor)
        "sleep-recorder" => (workflow-sleep-recorder)
        "neurofeedback-game" => (workflow-neurofeedback-game)
    }
}

# =============================================================================
# Workflow List
# =============================================================================

export def list-workflows []: [ nothing -> nothing ] {
    print "🔄 Available Workflows\n"
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    print "1. bci-focus-tracker"
    print "   Stream → alpha detection → focus state → log"
    print "   Monitors focus levels in real-time\n"
    
    print "2. ab-test-eeg"
    print "   3 worlds + 3 players + EEG input → winner"
    print "   A/B test world variants with brain data\n"
    
    print "3. meditation-monitor"
    print "   Real-time meditation depth with audio cues"
    print "   Guided meditation with neurofeedback\n"
    
    print "4. sleep-recorder"
    print "   Overnight recording with auto-stage detection"
    print "   Full night sleep study recording\n"
    
    print "5. neurofeedback-game"
    print "   Game controlled by brain state"
    print "   Train focus/relaxation through gameplay\n"
    
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print "Usage: worldprime workflow <name>"
}

# =============================================================================
# Workflow 1: BCI Focus Tracker
# =============================================================================

# Stream → alpha detection → focus state → log
def workflow-bci-focus-tracker []: [ nothing -> nothing ] {
    print "\n📋 Workflow: BCI Focus Tracker"
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    # Configuration
    print "⚙️  Configuration:"
    print "   • Sample rate: 250 Hz"
    print "   • Focus threshold: alpha/beta < 0.8"
    print "   • Analysis window: 4 seconds"
    print "   • Log file: focus_session.csv\n"
    
    # Wait for device
    print "🔌 Step 1: Device Connection"
    wait-for-device --timeout 30sec --silent
    print "   ✓ Device ready\n"
    
    # Calibration
    print "🎯 Step 2: Baseline Calibration"
    print "   Please relax and look at the center of the screen..."
    sleep 5sec
    
    mut baseline_alpha = 0.0
    mut baseline_beta = 0.0
    
    print -n "   Calibrating"
    for i in 0..5 {
        print -n "."
        sleep 500ms
    }
    
    # Simulated baseline
    $baseline_alpha = (random float 30..50)
    $baseline_beta = (random float 20..40)
    print $" ✓\n"
    print $"   Baseline α: ($baseline_alpha | math round -p 1) µV²"
    print $"   Baseline β: ($baseline_beta | math round -p 1) µV²\n"
    
    # Main tracking loop
    print "🧠 Step 3: Focus Tracking (press Ctrl+C to stop)\n"
    
    print "   Time     │ α/β Ratio │ Focus Level │ Status"
    print "   ─────────┼───────────┼─────────────┼─────────────────"
    
    mut focus_log = []
    mut start_time = (date now)
    
    for i in 0..30 {
        let elapsed = $"00:($i | into string | str lpad -l 2 -c '0')"
        
        # Simulate band powers
        let alpha = (random float ($baseline_alpha * 0.5)..($baseline_alpha * 1.5))
        let beta = (random float ($baseline_beta * 0.5)..($baseline_beta * 1.5))
        let ratio = ($alpha / $beta)
        
        # Determine focus level
        let focus_level = if $ratio < 0.6 { "High  " } else if $ratio < 0.9 { "Medium" } else { "Low   " }
        let status = if $ratio < 0.6 { "✓ Focused  " } else if $ratio < 0.9 { "~ Drifting " } else { "✗ Distracted" }
        
        print $"   ($elapsed)  │ ($ratio | math round -p 2)      │ ($focus_level)    │ ($status)"
        
        $focus_log = ($focus_log | append {
            time: $elapsed
            alpha: $alpha
            beta: $beta
            ratio: $ratio
            focus_level: $focus_level
        })
        
        sleep 1sec
    }
    
    # Summary
    print ""
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print "📊 Session Summary:\n"
    
    let high_focus = ($focus_log | where { |r| $r.ratio < 0.6 } | length)
    let med_focus = ($focus_log | where { |r| $r.ratio >= 0.6 and $r.ratio < 0.9 } | length)
    let low_focus = ($focus_log | where { |r| $r.ratio >= 0.9 } | length)
    
    print $"   High focus:   ($high_focus)s (" + (($high_focus / 31.0 * 100) | math round -p 1) + "%)"
    print $"   Medium focus: ($med_focus)s (" + (($med_focus / 31.0 * 100) | math round -p 1) + "%)"
    print $"   Low focus:    ($low_focus)s (" + (($low_focus / 31.0 * 100) | math round -p 1) + "%)"
    
    # Save log
    let log_file = $"focus_session_(date now | format date "%Y%m%d_%H%M%S").csv"
    $focus_log | to csv | save -f $log_file
    print $"\n💾 Session saved to: ($log_file)"
}

# =============================================================================
# Workflow 2: A/B Test EEG
# =============================================================================

# 3 worlds + 3 players + EEG input → winner
def workflow-ab-test-eeg []: [ nothing -> nothing ] {
    print "\n📋 Workflow: A/B Test with EEG"
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    # Setup
    print "⚙️  Experiment Setup:"
    print "   • Worlds: a://baseline, b://variant, c://experimental"
    print "   • Players: 3 (1 per world)"
    print "   • Metrics: Engagement, Focus, Satisfaction"
    print "   • Duration: 2 min per world\n"
    
    # Create worlds
    print "🌍 Step 1: Creating World Variants"
    print "   Creating a://baseline_world..."
    sleep 500ms
    print "   ✓ Baseline world (default physics, standard lighting)"
    
    print "   Creating b://variant_world..."
    sleep 500ms
    print "   ✓ Variant world (reduced gravity, enhanced colors)"
    
    print "   Creating c://experimental_world..."
    sleep 500ms
    print "   ✓ Experimental world (dynamic lighting, wind effects)\n"
    
    # Create session
    print "🎮 Step 2: Creating Multiplayer Session"
    let session_id = "ab-test-" + (random uuid | str substring 0..6)
    print $"   Session ID: ($session_id)"
    print "   ✓ Session configured for 3 players\n"
    
    # Assign players
    print "👥 Step 3: Assigning Players"
    print "   Player A → a://baseline_world"
    print "   Player B → b://variant_world"
    print "   Player C → c://experimental_world"
    print "   ✓ All players assigned\n"
    
    # Run test
    print "🧪 Step 4: Running A/B Test (2 minutes each)\n"
    
    mut results = {}
    
    for world in [baseline variant experimental] {
        print $"   Testing ($world) world..."
        
        # Simulate 2 minutes of EEG data
        mut engagement_scores = []
        mut focus_scores = []
        
        for i in 0..12 {
            $engagement_scores = ($engagement_scores | append (random float 0.3..1.0))
            $focus_scores = ($focus_scores | append (random float 0.4..0.95))
            print -n "."
            sleep 100ms
        }
        
        let avg_engagement = ($engagement_scores | math avg | math round -p 2)
        let avg_focus = ($focus_scores | math avg | math round -p 2)
        let satisfaction = (random float 3.0..5.0 | math round -p 1)
        
        $results = ($results | insert $world {
            engagement: $avg_engagement
            focus: $avg_focus
            satisfaction: $satisfaction
            composite: (($avg_engagement + $avg_focus + $satisfaction / 5.0) / 3.0 | math round -p 2)
        })
        
        print " ✓"
    }
    
    # Results
    print "\n📊 Step 5: Results\n"
    
    print "   ╭─────────────┬────────────┬─────────┬─────────────┬───────────╮"
    print "   │ World       │ Engagement │ Focus   │ Satisfaction│ Composite │"
    print "   ├─────────────┼────────────┼─────────┼─────────────┼───────────┤"
    
    for world in [baseline variant experimental] {
        let r = ($results | get $world)
        let world_name = if $world == "baseline" { "a://baseline " } else if $world == "variant" { "b://variant  " } else { "c://experimental" }
        print $"   │ ($world_name)│ ($r.engagement)         │ ($r.focus)      │ ($r.satisfaction)          │ ($r.composite)        │"
    }
    
    print "   ╰─────────────┴────────────┴─────────┴─────────────┴───────────╯"
    
    # Winner
    let winner = ($results | items { |k,v| {world: $k, score: $v.composite} } | sort-by score | last)
    print $"\n🏆 Winner: ($winner.world) with composite score ($winner.score)"
    
    print "\n💡 Recommendations:"
    print $"   • Deploy ($winner.world) configuration to production"
    print "   • Further optimize based on individual metric performance"
    print "   • Consider follow-up test with refined parameters"
}

# =============================================================================
# Workflow 3: Meditation Monitor
# =============================================================================

# Real-time meditation depth with audio cues
def workflow-meditation-monitor []: [ nothing -> nothing ] {
    print "\n📋 Workflow: Meditation Monitor"
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    # Configuration
    print "⚙️  Configuration:"
    print "   • Session duration: 10 minutes"
    print "   • Target: theta/alpha ratio > 1.2 (deep relaxation)"
    print "   • Feedback: audio cues + visual guidance"
    print "   • Auto-end: when target sustained for 60s\n"
    
    # Setup
    print "🧘 Step 1: Preparation"
    print "   ✓ Find a comfortable position"
    print "   ✓ Close your eyes or maintain soft gaze"
    print "   ✓ Audio cues enabled\n"
    
    print -n "   Starting in 3..."
    sleep 1sec
    print -n " 2..."
    sleep 1sec
    print " 1...\n"
    
    # Main session
    print "🧘 Step 2: Meditation Session\n"
    
    print "   Time    │ θ/α Ratio │ Depth   │ Guidance"
    print "   ────────┼───────────┼─────────┼─────────────────────────"
    
    mut deep_count = 0
    mut max_depth = 0.0
    
    for min in 0..10 {
        for sec in [0 30] {
            let time_str = $"($min):(if $sec == 0 { "00" } else { "30" })"
            
            # Simulate meditation depth
            let theta = (random float 40..80)
            let alpha = (random float 30..60)
            let ratio = ($theta / $alpha)
            
            let depth = if $ratio > 1.5 { "Deep    " } else if $ratio > 1.2 { "Relaxed " } else { "Active  " }
            
            let guidance = if $ratio > 1.5 {
                $deep_count = $deep_count + 1
                "[bell] Maintain state        "
            } else if $ratio > 1.2 {
                "Breathe slowly...            "
            } else {
                "Let thoughts pass...         "
            }
            
            if $ratio > $max_depth {
                $max_depth = $ratio
            }
            
            print $"   ($time_str)   │ ($ratio | math round -p 2)       │ ($depth)│ ($guidance)"
            
            sleep 100ms  # Fast for demo
        }
    }
    
    # Summary
    print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print "📊 Session Summary:\n"
    
    print $"   Session duration: 10:00"
    print $"   Max depth ratio: ($max_depth | math round -p 2)"
    print $"   Deep state time: ($deep_count * 30 / 60 | math round -p 1) minutes"
    
    if $max_depth > 1.5 {
        print "\n   🌟 Excellent session! You achieved deep meditation."
    } else if $max_depth > 1.2 {
        print "\n   ✓ Good session. You reached a relaxed state."
    } else {
        print "\n   ~ Keep practicing. Try longer exhales."
    }
    
    # Audio cue file
    print "\n🔔 Audio cue log saved: meditation_cues_$(date now | format date "%Y%m%d").log"
}

# =============================================================================
# Workflow 4: Sleep Recorder
# =============================================================================

# Overnight recording with auto-stage detection
def workflow-sleep-recorder []: [ nothing -> nothing ] {
    print "\n📋 Workflow: Sleep Recorder"
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    # Configuration
    print "⚙️  Configuration:"
    print "   • Recording duration: 8 hours"
    print "   • Sample rate: 250 Hz"
    print "   • Auto-stage detection: enabled"
    print "   • Hypnogram generation: enabled"
    print "   • Smart alarm: 6:00-6:30 AM in light sleep\n"
    
    # Setup
    print "🌙 Step 1: Pre-sleep Setup"
    print "   ✓ Impedance check: all channels < 10kΩ"
    print "   ✓ Battery level: 85%"
    print "   ✓ Storage available: 4.2 GB"
    print "   ✓ SD card inserted\n"
    
    print "🛏️  Step 2: Positioning"
    print "   Recommended electrode placement:"
    print "   • Fp1, Fp2: Forehead (frontal activity)"
    print "   • C3, C4: Central (motor/sleep spindles)"
    print "   • O1, O2: Occipital (alpha/theta detection)"
    print "   • Reference: Earlobe or mastoid\n"
    
    print -n "   Starting recording in "
    for i in [3 2 1] {
        print -n $"($i) "
        sleep 1sec
    }
    print "\n"
    
    # Simulate recording (condensed for demo)
    print "⏺️  Step 3: Recording (simulated - 30 seconds)\n"
    
    print "   Time  │ Stage │ SpO2 │ Movement"
    print "   ──────┼───────┼──────┼──────────"
    
    let stages = ["Awake" "N1" "N2" "N3" "REM"]
    let stage_dist = [0.05 0.1 0.5 0.2 0.15]  # Probabilities
    
    mut current_stage_idx = 0  # Start awake
    
    for hour in 0..2 {
        for min in [0 15 30 45] {
            let time_str = $"($hour + 23 | $in mod 24):(if $min == 0 { "00" } else { $min })"
            
            # Simulate stage transitions
            if (random float 0..1) < 0.2 {
                $current_stage_idx = (random int 0..4)
            }
            
            let stage = ($stages | get $current_stage_idx)
            let spo2 = (random float 94..99 | math round)
            let movement = if $current_stage_idx == 0 { "High" } else if $current_stage_idx == 4 { "Low " } else { "Med " }
            
            print $"   ($time_str) │ ($stage)  │ ($spo2)% │ ($movement)       "
            sleep 100ms
        }
    }
    
    # Summary
    print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print "📊 Sleep Analysis (simulated):\n"
    
    print "   Sleep Architecture:"
    print "   ╭─────────┬────────────┬─────────────────────────────────╮"
    print "   │ Stage   │ Duration   │ Hypnogram                       │"
    print "   ├─────────┼────────────┼─────────────────────────────────┤"
    print "   │ Awake   │ 45 min     │ ██                              │"
    print "   │ N1      │ 30 min     │ ████                            │"
    print "   │ N2      │ 210 min    │ ████████████████                │"
    print "   │ N3      │ 90 min     │ ███████                         │"
    print "   │ REM     │ 75 min     │ ██████                          │"
    print "   ╰─────────┴────────────┴─────────────────────────────────┴"
    
    print "\n   Sleep Efficiency: 87%"
    print "   Sleep Onset: 12 minutes"
    print "   REM Latency: 95 minutes"
    print "   Awakenings: 4"
    
    print "\n💾 Files saved:"
    print "   • sleep_2025-02-03.edf (EEG data)"
    print "   • sleep_2025-02-03_stages.csv (stage annotations)"
    print "   • sleep_2025-02-03_report.pdf (full report)"
}

# =============================================================================
# Workflow 5: Neurofeedback Game
# =============================================================================

# Game controlled by brain state
def workflow-neurofeedback-game []: [ nothing -> nothing ] {
    print "\n📋 Workflow: Neurofeedback Game"
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    # Introduction
    print "🎮 Game: Focus Flyer"
    print "   Control a spaceship with your brain!"
    print "   • High alpha (relax) = Ship rises"
    print "   • Low alpha (focus) = Ship dives"
    print "   • Collect stars, avoid asteroids\n"
    
    # Calibration
    print "⚙️  Step 1: Calibration (10 seconds)"
    print "   Please relax... then focus when prompted."
    
    print -n "   Relaxing"
    for i in 0..3 {
        print -n "."
        sleep 500ms
    }
    let relaxed_alpha = (random float 50..80)
    print $" ✓ (α: ($relaxed_alpha | math round -p 1))"
    
    print -n "   Focusing"
    for i in 0..3 {
        print -n "."
        sleep 500ms
    }
    let focused_alpha = (random float 20..40)
    print $" ✓ (α: ($focused_alpha | math round -p 1))\n"
    
    print $"   Calibration: relaxed=($relaxed_alpha | math round -p 0), focused=($focused_alpha | math round -p 0)"
    
    # Game
    print "\n🚀 Step 2: Play! (30 seconds)\n"
    
    print "   Score: 0     Stars: 0     Time: 0:00"
    print ""
    print "         │"
    print "         │  ★"
    print "         │"
    print "      ▲  │       ◆"
    print "         │"
    print "         │"
    print "━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print ""
    
    mut score = 0
    mut stars = 0
    mut ship_y = 3
    
    for sec in 0..30 {
        # Simulate player control
        let alpha = (random float $focused_alpha..$relaxed_alpha)
        let target_y = (if $alpha > (($relaxed_alpha + $focused_alpha) / 2) { 2 } else { 4 })
        
        # Smooth movement
        if $ship_y < $target_y {
            $ship_y = $ship_y + 1
        } else if $ship_y > $target_y {
            $ship_y = $ship_y - 1
        }
        
        # Random events
        let has_star = (random bool)
        let has_asteroid = (random bool)
        let star_y = (random int 1..5)
        let asteroid_y = (random int 1..5)
        
        # Score calculation
        if $has_star and $star_y == $ship_y {
            $score = $score + 100
            $stars = $stars + 1
        }
        
        # Draw frame (simplified)
        print -n $"\r   Score: ($score)     Stars: ($stars)     Time: 0:(if $sec < 10 { "0" + ($sec | into string) } else { $sec })   Ship: (if $ship_y < 3 { "RISING " } else { "DIVING " }) α=($alpha | math round -p 0)"
        
        sleep 100ms
    }
    
    # Game over
    print "\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print "🎉 Game Over!\n"
    
    print $"   Final Score: ($score)"
    print $"   Stars Collected: ($stars)"
    print $"   Performance Rating: (if $score > 2000 { "⭐⭐⭐⭐⭐" } else if $score > 1000 { "⭐⭐⭐⭐" } else { "⭐⭐⭐" })"
    
    print "\n💡 Tips for next time:"
    print "   • Relax completely to rise quickly"
    print "   • Focus sharply to dive for low stars"
    print "   • Practice state switching for better control"
}

# =============================================================================
# Helper Functions
# =============================================================================

def show-workflow-header [name: string]: [ nothing -> nothing ] {
    print (ansi cyan_bold)
    print "╔══════════════════════════════════════════════════════════════════╗"
    print $"║  Workflow: ($name | str upcase)" + ((" " | str repeat (35 - ($name | str length)))) + "║"
    print "╚══════════════════════════════════════════════════════════════════╝"
    print (ansi reset)
}

# Wait for device with timeout
def wait-for-device [--timeout: duration = 30sec, --silent]: [ nothing -> bool ] {
    let start = (date now)
    
    loop {
        # Check for serial ports
        let ports = (try { glob "/dev/ttyUSB*" } catch { [] }) | 
                    append (try { glob "/dev/ttyACM*" } catch { [] })
        
        if ($ports | length) > 0 {
            return true
        }
        
        if ((date now) - $start) > $timeout {
            return false
        }
        
        if not $silent {
            print -n "."
        }
        
        sleep 500ms
    }
    
    false
}

# Run if executed directly
if ($env.FILE_PWD? | default "") == ($env.CURRENT_FILE? | default "" | path dirname) {
    list-workflows
}
