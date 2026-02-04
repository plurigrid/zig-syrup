# OpenBCI Visualization Module
# Terminal-based EEG visualization

use config get-config
use device main device info
use stream read_samples, start_device_streaming, stop_device_streaming
use analyze calculate_band_powers

const DEFAULT_CHANNELS = 8
const DEFAULT_SAMPLE_RATE = 250
const TERMINAL_WIDTH = 80
const TERMINAL_HEIGHT = 24

# Visualize EEG data in terminal
#
# Usage:
#   openbci viz --mode terminal      # Real-time terminal plots
#   openbci viz --mode ascii         # ASCII art brain map
#   openbci viz --bands              # Show frequency band bars
#   openbci viz --waveform           # Channel waveforms
#   openbci viz --topo               # Topographic head map
#
# Examples:
#   openbci viz --mode terminal
#   openbci stream | openbci viz --waveform --channels 0,1
#   openbci analyze recording.csv --bands | openbci viz --bands
export def "main viz" [
    --mode(-m): string = "terminal"    # Visualization mode: terminal, ascii, waveform, bands, topo
    --channels(-c): string = "all"     # Channels to visualize
    --duration(-d): duration           # Visualization duration
    --refresh-rate: int = 10           # Refresh rate in Hz
]: [ nothing -> nothing ] {
    
    let channel_list = if $channels == "all" {
        seq 0 ($DEFAULT_CHANNELS - 1)
    } else {
        $channels | split "," | each { into int }
    }
    
    match $mode {
        "terminal" => { viz_terminal $channel_list $duration $refresh_rate }
        "ascii" => { viz_ascii_brain $channel_list $duration }
        "waveform" => { viz_waveform $channel_list $duration $refresh_rate }
        "bands" => { viz_bands $channel_list $duration $refresh_rate }
        "topo" => { viz_topo $channel_list $duration }
        _ => { error make { msg: $"Unknown mode: ($mode). Use: terminal, ascii, waveform, bands, topo" } }
    }
}

# Terminal-based real-time plot
def viz_terminal [channels: list, duration: duration, refresh_rate: int]: [ nothing -> nothing ] {
    clear
    
    let device_info = try { device info } catch { { port: null } }
    
    if ($device_info.port | is-empty) {
        print "No device connected. Using simulated data."
    } else {
        start_device_streaming $device_info.port
    }
    
    let end_time = if $duration != null {
        (date now) + $duration
    } else {
        null
    }
    
    let port = $device_info.port
    let buffer_size = ($DEFAULT_SAMPLE_RATE / $refresh_rate | math floor)
    
    # Initialize display buffer for each channel
    mut display_buffers = {}
    for ch in $channels {
        $display_buffers = ($display_buffers | insert $"ch($ch)" [])
    }
    
    try {
        loop {
            if $end_time != null and (date now) >= $end_time {
                break
            }
            
            # Move cursor to top
            print -n "\e[H"
            
            # Read samples
            let samples = if ($port | is-empty) {
                generate_simulated_samples $buffer_size $channels
            } else {
                read_samples $port $buffer_size $channels
            }
            
            # Update display buffers
            for ch in $channels {
                let ch_key = $"ch($ch)"
                let values = ($samples | each { |s| $s | get $ch_key })
                let current_buffer = ($display_buffers | get $ch_key)
                let new_buffer = ($current_buffer | append $values | last $TERMINAL_WIDTH)
                $display_buffers = ($display_buffers | insert $ch_key $new_buffer)
            }
            
            # Draw header
            print -n $"\e[1;36mOpenBCI Real-time Visualization\e[0m\n"
            print -n $"Mode: Terminal | Channels: ($channels | str join ', ') | Rate: ($refresh_rate) Hz\n"
            print -n "─" | str repeat $TERMINAL_WIDTH
            print ""
            
            # Draw channel plots
            for ch in $channels {
                let ch_key = $"ch($ch)"
                let buffer = ($display_buffers | get $ch_key)
                
                if ($buffer | length) > 0 {
                    let current = ($buffer | last | math round -p 1)
                    let plot_line = (render_plot_line $buffer $ch $current)
                    print $plot_line
                }
            }
            
            # Draw legend
            print ""
            print -n "\e[90m"
            print -n "Scale: "
            print -n "\e[32m▁▂▃▄▅▆▇█\e[0m "
            print -n "-200µV to +200µV | "
            print -n "\e[31m█\e[0m > 150µV | "
            print -n "\e[34m█\e[0m < -150µV"
            print ""
            print "Press Ctrl+C to stop"
            
            sleep (1000ms / $refresh_rate)
        }
    } catch { |e|
        # Clean exit
    }
    
    if ($port | is-not-empty) {
        stop_device_streaming $port
    }
    
    # Clear screen and restore cursor
    print "\e[2J\e[H"
    print "Visualization ended."
}

# Render a single plot line for a channel
def render_plot_line [values: list, channel: int, current: float]: [ nothing -> string ] {
    let plot_chars = [▁ ▂ ▃ ▄ ▅ ▆ ▇ █]
    let min_val = -200.0
    let max_val = 200.0
    let range = $max_val - $min_val
    
    let plot = ($values | each { |v|
        let normalized = (($v - $min_val) / $range)
        let idx = ($normalized * 7 | math floor)
        let clamped_idx = ([0 $idx 7] | math max | math min)
        $plot_chars | get $clamped_idx
    } | str join)
    
    let color = if $current > 150 {
        "\e[31m"  # Red for high amplitude
    } else if $current < -150 {
        "\e[34m"  # Blue for negative high amplitude
    } else {
        "\e[32m"  # Green for normal
    }
    
    let status = if ($current | math abs) > 150 {
        "⚠ HIGH"
    } else {
    "    "
    }
    
    $"ch($channel | fill -a r -w 2): ($color)($plot)\e[0m ($current | fill -a l -w 6)µV ($status)"
}

# ASCII art brain map visualization
def viz_ascii_brain [channels: list, duration: duration]: [ nothing -> nothing ] {
    clear
    
    let end_time = if $duration != null {
        (date now) + $duration
    } else {
        null
    }
    
    # 10-20 system positions for 8 channels
    let channel_positions = {
        ch0: { x: 20, y: 6, label: "Fp1" }   # Frontal left
        ch1: { x: 40, y: 6, label: "Fp2" }   # Frontal right
        ch2: { x: 15, y: 12, label: "C3" }   # Central left
        ch3: { x: 45, y: 12, label: "C4" }   # Central right
        ch4: { x: 10, y: 18, label: "P3" }   # Parietal left
        ch5: { x: 50, y: 18, label: "P4" }   # Parietal right
        ch6: { x: 30, y: 10, label: "Cz" }   # Central midline
        ch7: { x: 30, y: 20, label: "Pz" }   # Parietal midline
    }
    
    try {
        loop {
            if $end_time != null and (date now) >= $end_time {
                break
            }
            
            print -n "\e[H"
            
            # Generate simulated activity levels
            let activity = ($channels | each { |ch|
                { channel: $ch, level: (random float 0..1) }
            })
            
            # Draw brain outline
            let brain = draw_brain_outline $channel_positions $activity
            
            print "\e[1;36mOpenBCI Brain Activity Map\e[0m"
            print ""
            $brain | str join "\n" | print
            print ""
            
            # Draw activity legend
            print "Activity Level: \e[90m░\e[0m low  \e[93m▒\e[0m med  \e[91m█\e[0m high"
            print ""
            
            # Channel activity table
            $activity | each { |a|
                let intensity = if $a.level > 0.7 {
                    "\e[91mHIGH\e[0m"
                } else if $a.level > 0.3 {
                    "\e[93mMED \e[0m"
                } else {
                    "\e[90mLOW \e[0m"
                }
                $"ch($a.channel): ($intensity) ($a.level * 100 | math round)%"
            } | str join " | " | print
            
            print ""
            print "Press Ctrl+C to stop"
            
            sleep 200ms
        }
    } catch { |e|
        # Clean exit
    }
    
    print "\e[2J\e[H"
    print "Visualization ended."
}

# Draw ASCII brain outline with channel positions
def draw_brain_outline [positions: record, activity: list]: [ nothing -> list ] {
    let width = 60
    let height = 25
    
    # Initialize empty canvas
    mut canvas = (seq 0 $height | each { " " | str repeat $width })
    
    # Draw head outline (oval)
    let head_chars = [
        "          ██████████████          "
        "       ███              ███       "
        "     ██                    ██     "
        "    █                        █    "
        "   █                          █   "
        "  █                            █  "
        "  █                            █  "
        " █                              █ "
        " █                              █ "
        " █                              █ "
        " █                              █ "
        "  █                            █  "
        "  █                            █  "
        "   █                          █   "
        "    █                        █    "
        "     ██                    ██     "
        "       ███              ███       "
        "          ██████████████          "
    ]
    
    # Center the head
    let start_y = 3
    let start_x = 13
    
    # Place head outline on canvas
    for i in 0..<($head_chars | length) {
        let line = $head_chars | get $i
        let y = $start_y + $i
        if $y < $height {
            let old_line = $canvas | get $y
            let new_line = ($old_line | str substring 0..$start_x) + $line + ($old_line | str substring ($start_x + ($line | length))..)
            $canvas = ($canvas | update $y $new_line)
        }
    }
    
    # Add channel markers
    for act in $activity {
        let ch_key = $"ch($act.channel)"
        if $ch_key in $positions {
            let pos = ($positions | get $ch_key)
            let char = if $act.level > 0.7 {
                "\e[91m█\e[0m"
            } else if $act.level > 0.3 {
                "\e[93m▒\e[0m"
            } else {
                "\e[90m░\e[0m"
            }
            
            let old_line = $canvas | get $pos.y
            let new_line = ($old_line | str substring 0..$pos.x) + $char + ($old_line | str substring ($pos.x + 1)..)
            $canvas = ($canvas | update $pos.y $new_line)
            
            # Add label below
            let label_y = $pos.y + 1
            if $label_y < $height {
                let label_line = $canvas | get $label_y
                let label = $pos.label
                let label_start = $pos.x - (($label | length) / 2 | math floor)
                let new_label_line = ($label_line | str substring 0..$label_start) + $label + ($label_line | str substring ($label_start + ($label | length))..)
                $canvas = ($canvas | update $label_y $new_label_line)
            }
        }
    }
    
    $canvas
}

# Waveform visualization
def viz_waveform [channels: list, duration: duration, refresh_rate: int]: [ nothing -> nothing ] {
    clear
    
    let device_info = try { device info } catch { { port: null } }
    let port = $device_info.port
    let buffer_size = ($DEFAULT_SAMPLE_RATE / $refresh_rate | math floor)
    
    if ($port | is-not-empty) {
        start_device_streaming $port
    }
    
    let end_time = if $duration != null {
        (date now) + $duration
    } else {
        null
    }
    
    mut history = {}
    for ch in $channels {
        $history = ($history | insert $"ch($ch)" [])
    }
    
    try {
        loop {
            if $end_time != null and (date now) >= $end_time {
                break
            }
            
            print -n "\e[H"
            
            # Read samples
            let samples = if ($port | is-empty) {
                generate_simulated_samples $buffer_size $channels
            } else {
                read_samples $port $buffer_size $channels
            }
            
            # Update history
            for ch in $channels {
                let ch_key = $"ch($ch)"
                let values = ($samples | each { |s| $s | get $ch_key })
                let current_hist = ($history | get $ch_key)
                let new_hist = ($current_hist | append $values | last ($TERMINAL_WIDTH - 15))
                $history = ($history | insert $ch_key $new_hist)
            }
            
            print "\e[1;36mEEG Waveforms\e[0m"
            print ""
            
            # Draw each channel waveform
            for ch in $channels {
                let ch_key = $"ch($ch)"
                let signal = ($history | get $ch_key)
                
                if ($signal | length) > 0 {
                    let waveform = (draw_waveform $signal $ch)
                    print $waveform
                }
            }
            
            sleep (1000ms / $refresh_rate)
        }
    } catch { |e|
        # Clean exit
    }
    
    if ($port | is-not-empty) {
        stop_device_streaming $port
    }
    
    print "\e[2J\e[H"
}

# Draw waveform line
def draw_waveform [signal: list, channel: int]: [ nothing -> string ] {
    let height = 6
    let min_val = -200.0
    let max_val = 200.0
    let range = $max_val - $min_val
    
    # Create vertical levels
    let levels = ($signal | each { |v|
        let normalized = (($v - $min_val) / $range)
        let level = ($normalized * ($height - 1) | math floor)
        [0 $level ($height - 1)] | math max | math min
    })
    
    let current = ($signal | last | math round -p 1)
    
    $"ch($channel | fill -a r -w 2): [($levels | str join ',')] ($current)µV"
}

# Band power visualization
def viz_bands [channels: list, duration: duration, refresh_rate: int]: [ nothing -> nothing ] {
    clear
    
    let device_info = try { device info } catch { { port: null } }
    let port = $device_info.port
    let buffer_size = 256
    
    if ($port | is-not-empty) {
        start_device_streaming $port
    }
    
    let end_time = if $duration != null {
        (date now) + $duration
    } else {
        null
    }
    
    let bands = [delta theta alpha beta gamma]
    let band_colors = {
        delta: "\e[34m"  # Blue
        theta: "\e[36m"  # Cyan
        alpha: "\e[32m"  # Green
        beta: "\e[33m"   # Yellow
        gamma: "\e[31m"  # Red
    }
    
    try {
        loop {
            if $end_time != null and (date now) >= $end_time {
                break
            }
            
            print -n "\e[H"
            
            # Read samples
            let samples = if ($port | is-empty) {
                generate_simulated_samples $buffer_size $channels
            } else {
                read_samples $port $buffer_size $channels
            }
            
            # Calculate band powers
            let band_powers = (calculate_band_powers $samples $channels 250 $buffer_size 0.5)
            
            print "\e[1;36mFrequency Band Powers\e[0m"
            print ""
            
            # Draw bar chart for each channel
            for bp in $band_powers {
                let ch = $bp.channel
                print $"\e[1m($ch)\e[0m"
                
                for band in $bands {
                    let power = ($bp | get $band)
                    let color = ($band_colors | get $band)
                    let bar = "█" | str repeat ($power / 10 | math floor)
                    let bar_padded = $bar | fill -a l -w 30
                    print $"  ($color)($band | fill -a r -w 5)\e[0m │($bar_padded)│ ($power)"
                }
                print ""
            }
            
            print "Legend: \e[34mδ(0.5-4Hz)\e[0m \e[36mθ(4-8Hz)\e[0m \e[32mα(8-13Hz)\e[0m \e[33mβ(13-30Hz)\e[0m \e[31mγ(30-50Hz)\e[0m"
            print "Press Ctrl+C to stop"
            
            sleep (1000ms / $refresh_rate)
        }
    } catch { |e|
        # Clean exit
    }
    
    if ($port | is-not-empty) {
        stop_device_streaming $port
    }
    
    print "\e[2J\e[H"
}

# Topographic map visualization (simplified)
def viz_topo [channels: list, duration: duration]: [ nothing -> nothing ] {
    # Similar to ascii brain but with interpolated colors
    viz_ascii_brain $channels $duration
}

# Generate simulated samples
def generate_simulated_samples [count: int, channels: list]: [ nothing -> list ] {
    mut samples = []
    let now = date now
    
    for i in 0..<$count {
        let timestamp = $now + ($i * 4ms)
        mut sample = {
            timestamp: ($timestamp | format date "%Y-%m-%d %H:%M:%S%.3f")
            sample_num: $i
        }
        
        for ch in $channels {
            let t = ($i | into float) / 250.0
            let alpha = 100 * (2 * 3.14159 * 10 * $t | math sin)
            let beta = 50 * (2 * 3.14159 * 20 * $t | math sin)
            let noise = (random float -20..20)
            let value = ($alpha + $beta + $noise) * (1.0 - ($ch | into float) * 0.1)
            $sample = ($sample | insert $"ch($ch)" ($value | math round -p 2))
        }
        
        $samples = ($samples | append $sample)
    }
    
    $samples
}

# Plot from file (static visualization)
export def "main viz file" [
    file: path              # Recording file to visualize
    --channels: string = "all"  # Channels to plot
    --type: string = "waveform"  # Plot type: waveform, bands
    --start: int = 0        # Start sample
    --duration: duration    # Duration to plot
]: [ nothing -> nothing ] {
    
    let data = (open $file)
    let channel_list = if $channels == "all" {
        $data | columns | where { |c| $c | str starts-with "ch" } | sort
    } else {
        $channels | split "," | each { |c| $"ch($c)" }
    }
    
    let sample_rate = 250
    let num_samples = if $duration != null {
        let seconds = ($duration | into int) / 1000000000
        ($seconds * $sample_rate | math floor)
    } else {
        1000
    }
    
    let plot_data = ($data | range $start..($start + $num_samples))
    
    print $"Plotting ($file | path basename) - ($plot_data | length) samples"
    
    for ch in $channel_list {
        let values = ($plot_data | each { |row| $row | get $ch })
        let stats = {
            min: ($values | math min | math round -p 1)
            max: ($values | math max | math round -p 1)
            mean: ($values | math avg | math round -p 1)
        }
        
        print ""
        print $"\e[1m($ch)\e[0m - min: ($stats.min) max: ($stats.max) mean: ($stats.mean)"
        
        # Simple sparkline
        let sparkline = ($values | every (($values | length) / 50 | math floor) | each { |v|
            let idx = ((($v + 200) / 400) * 7 | math floor)
            let clamped = ([0 $idx 7] | math max | math min)
            [▁ ▂ ▃ ▄ ▅ ▆ ▇ █] | get $clamped
        } | str join)
        
        print $"  ($sparkline)"
    }
}
