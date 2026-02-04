#!/usr/bin/env nu
# dashboard.nu - Real-time terminal dashboard for nuworlds
# Multi-panel display: EEG waveforms, band powers, world state

use themes.nu *

const REFRESH_RATE = 100ms
const DEFAULT_DURATION = 300sec

# =============================================================================
# Main Dashboard
# =============================================================================

# Launch real-time terminal dashboard
export def main [
    --theme: string = "default"     # Color theme
    --duration: duration            # Auto-close after duration
    --no-worlds                     # Hide world state panel
]: [ nothing -> nothing ] {
    
    # Clear screen
    print "\x1b[2J\x1b[H"
    
    # Show header
    show-dashboard-header
    
    # Initialize state
    mut state = {
        running: true
        paused: false
        start_time: (date now)
        auto_close: $duration
        samples: []
        band_powers: {
            delta: 15.0
            theta: 25.0
            alpha: 45.0
            beta: 30.0
            gamma: 10.0
        }
        worlds: {
            active: 3
            sessions: 1
            players: 3
        }
        message: "Press 'h' for help, 'q' to quit"
    }
    
    # Main loop
    while $state.running {
        # Check for auto-close
        if $state.auto_close != null {
            let elapsed = ((date now) - $state.start_time)
            if $elapsed >= $state.auto_close {
                $state.running = false
                break
            }
        }
        
        if not $state.paused {
            # Clear and redraw
            print "\x1b[H"  # Move cursor to home
            
            # Generate new sample
            $state.samples = (update-samples $state.samples)
            $state.band_powers = (update-band-powers $state.band_powers)
            
            # Draw all panels
            draw-dashboard $state --no-worlds=$no_worlds
        }
        
        # Check for keyboard input (non-blocking simulation)
        # In real implementation, this would use terminal raw mode
        sleep $REFRESH_RATE
        
        # Simulate key press handling
        # This would normally read from stdin in raw mode
    }
    
    # Cleanup
    print "\x1b[2J\x1b[H"
    print "Dashboard closed. Session saved."
}

# =============================================================================
# Dashboard Drawing
# =============================================================================

def draw-dashboard [state: record, --no-worlds]: [ nothing -> nothing ] {
    let term_width = 80
    let term_height = 24
    
    # Header
    draw-header $state
    
    # Row 1: EEG Waveforms
    let waveform_height = if $no_worlds { 12 } else { 8 }
    print ""
    draw-waveform-panel $state.samples --height $waveform_height
    
    # Row 2: Band Powers
    print ""
    draw-band-power-panel $state.band_powers
    
    # Row 3: World State (if enabled)
    if not $no_worlds {
        print ""
        draw-world-panel $state.worlds
    }
    
    # Footer
    print ""
    draw-footer $state
}

def draw-header [state: record]: [ nothing -> nothing ] {
    let elapsed = ((date now) - $state.start_time)
    let elapsed_str = (format-duration-short $elapsed)
    
    print (ansi cyan_bold)
    print $"╭──────────────────────────────── nuworlds Dashboard ────────────────────────────╮"
    print $"│  ⏱ ($elapsed_str)  │  Status: (if $state.paused { "PAUSED " } else { "ACTIVE " })  │  ($state.message)" + (" " | str repeat (20 - ($state.message | str length))) + "│"
    print $"╰────────────────────────────────────────────────────────────────────────────────╯"
    print (ansi reset)
}

def draw-waveform-panel [samples: list, --height: int]: [ nothing -> nothing ] {
    print (ansi yellow_bold)
    print $"┌─ EEG Waveforms (8 channels @ 250Hz) ─────────────────────────────────────────┐"
    print (ansi reset)
    
    let channels = ["Fp1" "Fp2" "C3" "C4" "P3" "P4" "O1" "O2"]
    let width = 70
    
    # Generate simulated waveforms for each channel
    for ch in $channels {
        let waveform = (generate-waveform $ch $width)
        let ch_padded = ($ch | str lpad -l 4 -c ' ')
        print $"│ ($ch_padded) │($waveform)│"
    }
    
    print "└──────────────────────────────────────────────────────────────────────────────┘"
}

def draw-band-power-panel [powers: record]: [ nothing -> nothing ] {
    print (ansi green_bold)
    print $"┌─ Band Powers ────────────────────────────────────────────────────────────────┐"
    print (ansi reset)
    
    let total = ($powers | values | math sum)
    
    # Individual bars
    for band in [delta theta alpha beta gamma] {
        let value = ($powers | get $band)
        let pct = ($value / $total * 100)
        let bar = (render-bar $pct 40)
        let symbol = (band-symbol $band)
        let color = (band-ansi $band)
        
        print $"│ (colorize $symbol $color) │($bar)│ ($value | math round -p 1) µV²  │"
    }
    
    # Composite bar
    print "├──────────────────────────────────────────────────────────────────────────────┤"
    let composite = (render-band-composite $powers 50)
    print $"│ Σ  │($composite)│ Total: ($total | math round -p 1) │"
    
    print "└──────────────────────────────────────────────────────────────────────────────┘"
}

def draw-world-panel [worlds: record]: [ nothing -> nothing ] {
    print (ansi magenta_bold)
    print $"┌─ World State ────────────────────────────────────────────────────────────────┐"
    print (ansi reset)
    
    print $"│  Active Worlds: ($worlds.active)  │  Sessions: ($worlds.sessions)  │  Players: ($worlds.players)                                                │"
    print "├──────────────────────────────────────────────────────────────────────────────┤"
    print "│  World              │ Variant       │ Entities │ Players │ Status           │"
    print "├─────────────────────┼───────────────┼──────────┼─────────┼──────────────────┤"
    print "│  a://baseline       │ baseline      │ 12       │ 1       │ ✓ synced         │"
    print "│  b://variant        │ variant       │ 12       │ 1       │ ✓ synced         │"
    print "│  c://experimental   │ experimental  │ 8        │ 1       │ ⚠ diverged       │"
    print "└─────────────────────┴───────────────┴──────────┴─────────┴──────────────────┘"
}

def draw-footer [state: record]: [ nothing -> nothing ] {
    print (ansi cyan_dim)
    print $"  [q]uit  [p]ause  [s]ave  [r]eset  [h]elp  [1-8] toggle channel"
    print (ansi reset)
}

# =============================================================================
# Rendering Functions
# =============================================================================

def generate-waveform [channel: string, width: int]: [ nothing -> string ] {
    # Generate simulated EEG waveform
    mut waveform = ""
    let base_freq = match $channel {
        "Fp1" | "Fp2" => 10  # Alpha
        "C3" | "C4" => 20   # Beta
        "P3" | "P4" => 8    # Alpha
        "O1" | "O2" => 12   # Alpha
        _ => 10
    }
    
    for i in 0..$width {
        let t = ($i | into float) / 10.0
        let amp = (random float -1.0..1.0) + (math sin $base_freq * $t)
        let normalized = (($amp + 2.0) / 4.0 * 3.0 | math floor | math max 0 | math min 3)
        
        let char = match $normalized {
            0 => (ansi green) + "▁" + (ansi reset)
            1 => (ansi green) + "▃" + (ansi reset)
            2 => (ansi green) + "▅" + (ansi reset)
            3 => (ansi green) + "█" + (ansi reset)
            _ => " "
        }
        
        $waveform = $waveform + $char
    }
    
    $waveform
}

def render-bar [pct: float, width: int]: [ nothing -> string ] {
    let filled = ($pct / 100.0 * $width | math floor)
    let empty = $width - $filled
    
    ("█" | str repeat $filled) + ("░" | str repeat $empty)
}

def render-band-composite [powers: record, width: int]: [ nothing -> string ] {
    let total = ($powers | values | math sum)
    
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

def band-symbol [band: string]: [ nothing -> string ] {
    match $band {
        "delta" => "Δ 1-4"
        "theta" => "θ 4-8"
        "alpha" => "α 8-13"
        "beta" => "β 13-30"
        "gamma" => "γ 30-50"
        _ => "?"
    }
}

def band-ansi [band: string]: [ nothing -> string ] {
    match $band {
        "delta" => "blue_bold"
        "theta" => "cyan_bold"
        "alpha" => "green_bold"
        "beta" => "yellow_bold"
        "gamma" => "red_bold"
        _ => "white"
    }
}

# =============================================================================
# State Updates
# =============================================================================

def update-samples [samples: list]: [ nothing -> list ] {
    # Add new sample, keep last 1000
    let new_sample = {
        timestamp: (date now)
        channels: (random float -100..100)
    }
    
    $samples | append $new_sample | last 1000
}

def update-band-powers [powers: record]: [ nothing -> record ] {
    # Slightly vary the band powers
    {
        delta: ($powers.delta + (random float -2..2) | math max 5 | math min 30)
        theta: ($powers.theta + (random float -3..3) | math max 10 | math min 50)
        alpha: ($powers.alpha + (random float -5..5) | math max 20 | math min 80)
        beta: ($powers.beta + (random float -3..3) | math max 10 | math min 60)
        gamma: ($powers.gamma + (random float -1..1) | math max 3 | math min 25)
    }
}

# =============================================================================
# Helper Functions
# =============================================================================

def format-duration-short [duration: duration]: [ nothing -> string ] {
    let nanos = ($duration | into int)
    let seconds = ($nanos / 1000000000 | math floor)
    let mins = ($seconds / 60 | math floor)
    let secs = ($seconds mod 60)
    
    $"($mins | into string | str lpad -l 2 -c '0'):($secs | into string | str lpad -l 2 -c '0')"
}

def show-dashboard-header []: [ nothing -> nothing ] {
    print (ansi cyan_bold)
    print ""
    print "╔══════════════════════════════════════════════════════════════════════════════╗"
    print "║                     nuworlds Real-Time Dashboard                             ║"
    print "║                                                                              ║"
    print "║   Controls: [q]uit  [p]ause  [s]ave  [r]eset  [h]elp                         ║"
    print "╚══════════════════════════════════════════════════════════════════════════════╝"
    print (ansi reset)
}

# Colorize helper
def colorize [text: string, color: string]: [ nothing -> string ] {
    match $color {
        "blue_bold" => $"\e[1;34m($text)\e[0m"
        "cyan_bold" => $"\e[1;36m($text)\e[0m"
        "green_bold" => $"\e[1;32m($text)\e[0m"
        "yellow_bold" => $"\e[1;33m($text)\e[0m"
        "red_bold" => $"\e[1;31m($text)\e[0m"
        _ => $text
    }
}

# =============================================================================
# Keyboard Control (Simulated)
# =============================================================================

# This would be implemented with termios for real keyboard control
# For now, we provide the structure

export def handle-key [key: string, state: record]: [ nothing -> record ] {
    match $key {
        "q" | "Q" => ($state | upsert running false)
        "p" | "P" => ($state | upsert paused (not $state.paused))
        "s" | "S" => { save-session $state; $state | upsert message "Session saved" }
        "r" | "R" => ($state | upsert samples [] | upsert message "Reset")
        "h" | "H" => ($state | upsert message "q:quit p:pause s:save r:reset")
        _ => $state
    }
}

def save-session [state: record]: [ nothing -> nothing ] {
    let filename = $"dashboard_session_(date now | format date "%Y%m%d_%H%M%S").nuon"
    $state | save -f $filename
}

# Run if executed directly
if ($env.FILE_PWD? | default "") == ($env.CURRENT_FILE? | default "" | path dirname) {
    main --duration 30sec
}
