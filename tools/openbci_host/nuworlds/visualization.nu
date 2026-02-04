# visualization.nu
# Terminal visualization for EEG data
# ASCII sparklines, bar charts, and head maps

use std log
use ./eeg_types.nu [BANDS CHANNEL_POSITIONS_8]
use ./signal_processing.nu [all-band-powers]

# =============================================================================
# Sparkline Generation
# =============================================================================

# Sparkline characters for different levels
const SPARK_CHARS = ['▁' '▂' '▃' '▄' '▅' '▆' '▇' '█']

# Generate a sparkline from a series of values
export def sparkline [
    width?: int              # Width in characters (auto if not specified)
] {
    let values = $in
    let n = $values | length
    
    if $n == 0 {
        return ""
    }
    
    let min_val = ($values | math min)
    let max_val = ($values | math max)
    let range = $max_val - $min_val
    
    # Determine width and step
    let use_width = if ($width | is-not-empty) { $width } else { [($n | into int) 60] | math min }
    let step = if $use_width >= $n { 1 } else { ($n / $use_width | math floor) }
    
    mut result = ""
    mut i = 0
    
    while $i < $n {
        let end_idx = [($i + $step) $n] | math min
        let chunk = $values | range ($i | into int)..<($end_idx | into int)
        let avg = $chunk | math avg
        
        # Map to spark character
        let normalized = if $range > 0 { ($avg - $min_val) / $range } else { 0 }
        let idx = ($normalized * 7 | into int) | into int
        let char_idx = [$idx 7] | math min
        $result = $result + ($SPARK_CHARS | get $char_idx)
        
        $i = $i + $step
    }
    
    $result
}

# =============================================================================
# EEG Channel Plotting
# =============================================================================

# Plot EEG channels as sparklines
export def eeg-plot [
    --width: int = 50        # Width of sparklines
    --height: int = null     # Number of samples to show (all if null)
    --channels: list = null  # Specific channels to plot (all if null)
    --scale: string = "auto" # Scale: auto, fixed, normalized
    --channel-names: list = null
] {
    let data = $in
    let n_samples = $data | length
    let n_ch = ($data | first).channels | length
    
    let show_samples = if ($height | is-not-empty) { [$height $n_samples] | math min } else { $n_samples }
    let plot_data = $data | last $show_samples
    
    let ch_indices = if ($channels | is-not-empty) {
        $channels
    } else {
        0..<($n_ch)
    }
    
    let names = if ($channel_names | is-not-empty) {
        $channel_names
    } else {
        0..<($n_ch) | each {|i| $"Ch($i)"}
    }
    
    print "╔══════════════════════════════════════════════════════════════╗"
    print "║                    EEG Channel Signals                       ║"
    print "╠══════════════════════════════════════════════════════════════╣"
    
    for ch in $ch_indices {
        let ch_name = ($names | get $ch | default $"Ch($ch)")
        let values = ($plot_data | each {|row| $row.channels | get $ch})
        
        # Apply scaling
        let scaled_values = match $scale {
            "normalized" => {
                let mean = $values | math avg
                let std = $values | math stddev
                if $std > 0 {
                    $values | each {|x| ($x - $mean) / $std }
                } else {
                    $values
                }
            }
            "fixed" => {
                # Clip to typical EEG range
                $values | each {|x| [([-100 $x 100] | math max) -100] | math min }
            }
            _ => $values
        }
        
        let spark = $scaled_values | sparkline --width $width
        let current = $values | last
        let color = if ($current | math abs) > 500 { "red" } else if ($current | math abs) > 200 { "yellow" } else { "green" }
        
        print $"║ (ansi cyan)($ch_name | fill -a r -w 4)(ansi reset) │(ansi ($color))($spark)(ansi reset) │ ($current | fill -a l -w 8 | into string | str substring 0..8) µV ║"
    }
    
    print "╚══════════════════════════════════════════════════════════════╝"
    print $"   Samples: ($show_samples) | Scale: ($scale)"
}

# =============================================================================
# Band Power Visualization
# =============================================================================

# Visualize band powers as bar charts
export def band-bars [
    --sampling-rate: int = 250
    --width: int = 40
    --relative: bool = true  # Show relative (%) vs absolute power
] {
    let data = $in
    let powers = $data | all-band-powers --sampling-rate $sampling_rate
    
    print "╔══════════════════════════════════════════════════════════════╗"
    print "║                     EEG Band Powers                          ║"
    print "╠══════════════════════════════════════════════════════════════╣"
    
    let bands_list = [delta theta alpha beta gamma]
    let band_colors = {delta: red theta: yellow alpha: green beta: blue gamma: magenta}
    
    let max_power = if $relative {
        1.0
    } else {
        $powers.absolute | values | each {|b| $b.avg_power} | math max
    }
    
    for band in $bands_list {
        let band_info = $powers.absolute | get $band
        let value = if $relative {
            $powers.relative | get $band
        } else {
            $band_info.avg_power
        }
        
        let normalized = if $max_power > 0 { $value / $max_power } else { 0 }
        let bar_len = ($normalized * ($width | into float) | into int)
        let bar = '█' | str repeat $bar_len
        let empty = ' ' | str repeat ($width - $bar_len)
        
        let color = $band_colors | get $band
        let label = $band_info.band_name
        let freq_range = $"($band_info.channels.0.low_freq)-($band_info.channels.0.high_freq) Hz"
        
        let value_str = if $relative {
            $"($value * 100 | into int)%"
        } else {
            $"($value | into int) µV²"
        }
        
        print $"║ (ansi ($color))($label | fill -a r -w 6)(ansi reset) │(ansi ($color))($bar)(ansi reset)($empty)│ ($value_str | fill -a l -w 8) ($freq_range | fill -a l -w 12) ║"
    }
    
    print "╚══════════════════════════════════════════════════════════════╝"
    print $"   Total Power: ($powers.total_power | into int) µV² | Samples: ($powers.samples_analyzed)"
}

# =============================================================================
# Topographic Preview (ASCII Head Map)
# =============================================================================

# Simple ASCII representation of EEG electrode positions
export def topo-preview [
    --channel-values: list = null  # Current values for each channel
    --width: int = 40
] {
    let positions = $CHANNEL_POSITIONS_8
    let ch_names = [Fp1 Fp2 C3 C4 P7 P8 O1 O2]
    
    # Default values if not provided
    let values = if ($channel_values | is-not-empty) {
        $channel_values
    } else {
        [0 0 0 0 0 0 0 0]
    }
    
    # Normalize values for color mapping
    let max_val = $values | math abs | math max
    let normalized = if $max_val > 0 {
        $values | each {|v| $v / $max_val }
    } else {
        $values
    }
    
    # Color map for values
    def value-color [val: float] {
        let abs_val = $val | math abs
        if $abs_val > 0.7 { "red" }
        else if $abs_val > 0.4 { "yellow" }
        else if $abs_val > 0.1 { "green" }
        else { "white" }
    }
    
    def value-char [val: float] {
        let abs_val = $val | math abs
        if $abs_val > 0.7 { '●' }
        else if $abs_val > 0.4 { '◐' }
        else if $abs_val > 0.1 { '○' }
        else { '·' }
    }
    
    print ""
    print "                    ╭─────────╮"
    print "                  ╱             ╲"
    
    # Fp1, Fp2 positions
    let fp1_color = value-color ($normalized | get 0)
    let fp1_char = value-char ($normalized | get 0)
    let fp2_color = value-color ($normalized | get 1)
    let fp2_char = value-char ($normalized | get 1)
    
    print $"    (ansi cyan)Fp1(ansi reset)  (ansi ($fp1_color))($fp1_char)(ansi reset) ╱               ╲ (ansi ($fp2_color))($fp2_char)(ansi reset)  (ansi cyan)Fp2(ansi reset)"
    print "                     │     N     │"
    
    # C3, C4 positions
    let c3_color = value-color ($normalized | get 2)
    let c3_char = value-char ($normalized | get 2)
    let c4_color = value-color ($normalized | get 3)
    let c4_char = value-char ($normalized | get 3)
    
    print $"    (ansi cyan)C3(ansi reset)   (ansi ($c3_color))($c3_char)(ansi reset) │               │ (ansi ($c4_color))($c4_char)(ansi reset)   (ansi cyan)C4(ansi reset)"
    print "                     │      C      │"
    print "           L         │             │         R"
    
    # P7, P8 positions
    let p7_color = value-color ($normalized | get 4)
    let p7_char = value-char ($normalized | get 4)
    let p8_color = value-color ($normalized | get 5)
    let p8_char = value-char ($normalized | get 5)
    
    print $"    (ansi cyan)P7(ansi reset)   (ansi ($p7_color))($p7_char)(ansi reset) │               │ (ansi ($p8_color))($p8_char)(ansi reset)   (ansi cyan)P8(ansi reset)"
    
    # O1, O2 positions
    let o1_color = value-color ($normalized | get 6)
    let o1_char = value-char ($normalized | get 6)
    let o2_color = value-color ($normalized | get 7)
    let o2_char = value-char ($normalized | get 7)
    
    print $"    (ansi cyan)O1(ansi reset)   (ansi ($o1_color))($o1_char)(ansi reset)  ╲               ╱  (ansi ($o2_color))($o2_char)(ansi reset)   (ansi cyan)O2(ansi reset)"
    print "                    ╰─────────╯"
    print ""
    
    # Legend
    print "    Legend: ● High activity  ◐ Medium  ○ Low  · None"
    print $"    Scale: ±($max_val | into int) µV"
    print ""
}

# Real-time topographic animation (updates continuously)
export def topo-live [
    --window: int = 50       # Samples to average for display
    --interval: float = 0.5  # Update interval in seconds
    --duration: int = 60     # Total duration in seconds
] {
    let data = $in
    mut buffer = []
    mut last_update = (date now)
    mut count = 0
    
    for row in $data {
        $buffer = ($buffer | append $row)
        
        # Keep buffer at window size
        if ($buffer | length) > $window {
            $buffer = ($buffer | drop 1)
        }
        
        # Update display at interval
        let now = (date now)
        let elapsed = ($now - $last_update | into int) / 1_000_000_000
        
        if $elapsed >= $interval and ($buffer | length) >= $window {
            # Clear screen (ANSI escape)
            print -n "\e[2J\e[H"
            
            # Calculate averages
            let n_ch = ($buffer | first).channels | length
            mut avgs = []
            for ch in 0..<($n_ch) {
                let avg = $buffer | each {|r| $r.channels | get $ch} | math avg
                $avgs = ($avgs | append $avg)
            }
            
            # Show topographic preview
            topo-preview --channel-values $avgs
            
            $last_update = $now
            $count = $count + 1
            
            # Exit if duration exceeded
            if $count >= ($duration | into float) / $interval {
                break
            }
        }
    }
}

# =============================================================================
# Signal Quality Visualization
# =============================================================================

# Visualize signal quality for all channels
export def quality-view [
    --width: int = 30
] {
    let quality_data = $in
    
    print "╔══════════════════════════════════════════════════════════════╗"
    print "║                   Signal Quality Overview                    ║"
    print "╠══════════════════════════════════════════════════════════════╣"
    
    for ch in $quality_data.channels {
        let score = $ch.quality_score
        let bar_len = ($score * ($width | into float) | into int)
        let bar = '█' | str repeat $bar_len
        let empty = '░' | str repeat ($width - $bar_len)
        
        let color = if $score > 0.8 { "green" }
            else if $score > 0.5 { "yellow" }
            else { "red" }
        
        let status = if $ch.is_flatline { "FLATLINE" }
            else if $ch.is_saturated { "SATURATED" }
            else if $ch.has_line_noise { "NOISY" }
            else { "GOOD" }
        
        print $"║ Ch($ch.channel) │(ansi ($color))($bar)(ansi reset)($empty)│ ($score * 100 | into int)% ($status | fill -a l -w 10) ║"
    }
    
    print "╠══════════════════════════════════════════════════════════════╣"
    print $"║ Overall Quality: ($quality_data.overall_score * 100 | into int)%                                        ║"
    print "╚══════════════════════════════════════════════════════════════╝"
}

# =============================================================================
# Time Series Summary
# =============================================================================

# Show a compact summary of the time series
export def eeg-summary [] {
    let data = $in
    let n = $data | length
    let n_ch = ($data | first).channels | length
    let duration = ($data | last).timestamp - ($data | first).timestamp
    let sampling_rate = if $duration > 0 { $n / $duration } else { 0 }
    
    # Calculate statistics per channel
    mut stats = []
    for ch in 0..<($n_ch) {
        let values = $data | each {|row| $row.channels | get $ch}
        $stats = ($stats | append {
            channel: $ch
            mean: ($values | math avg)
            std: ($values | math stddev)
            min: ($values | math min)
            max: ($values | math max)
        })
    }
    
    print "╔══════════════════════════════════════════════════════════════╗"
    print "║                    EEG Data Summary                          ║"
    print "╠══════════════════════════════════════════════════════════════╣"
    print $"║ Duration:      ($duration | into int) seconds                                         ║"
    print $"║ Samples:       ($n)                                            ║"
    print $"║ Channels:      ($n_ch)                                               ║"
    print $"║ Sample Rate:   ($sampling_rate | into int) Hz                                            ║"
    print "╠══════════════════════════════════════════════════════════════╣"
    print "║ Channel Statistics (µV):                                     ║"
    print "║        Mean      Std      Min      Max                       ║"
    
    for s in $stats {
        print $"║ Ch($s.channel)  ($s.mean | into int | fill -a r -w 6)  ($s.std | into int | fill -a r -w 6)  ($s.min | into int | fill -a r -w 6)  ($s.max | into int | fill -a r -w 6) ║"
    }
    
    print "╚══════════════════════════════════════════════════════════════╝"
}

# =============================================================================
# Multi-Panel Dashboard
# =============================================================================

# Show a complete dashboard with all visualizations
export def dashboard [
    --samples: int = 250     # Samples for timeseries display
    --bands-samples: int = 500  # Samples for band power calculation
] {
    let data = $in
    let n = $data | length
    
    # Clear screen
    print -n "\e[2J\e[H"
    
    # Header
    print "╔══════════════════════════════════════════════════════════════════════════╗"
    print "║                     OpenBCI EEG Dashboard v0.1                           ║"
    print $"║                     ($n) samples | (date now | format date '%H:%M:%S')                                          ║"
    print "╚══════════════════════════════════════════════════════════════════════════╝"
    print ""
    
    # Channel signals (last N samples)
    $data | last $samples | eeg-plot --width 50
    
    print ""
    
    # Band powers
    $data | last $bands_samples | band-bars --width 30
    
    print ""
    
    # Topographic preview (current values)
    let n_ch = ($data | first).channels | length
    mut current = []
    for ch in 0..<($n_ch) {
        let val = $data | last | get channels | get $ch
        $current = ($current | append $val)
    }
    topo-preview --channel-values $current
}

# Live dashboard that updates continuously
export def dashboard-live [
    --window: int = 250      # Samples for display window
    --update-interval: float = 1.0  # Seconds between updates
] {
    mut buffer = []
    mut last_update = (date now)
    
    for row in $in {
        $buffer = ($buffer | append $row)
        
        # Keep buffer at window size
        if ($buffer | length) > $window {
            $buffer = ($buffer | drop 1)
        }
        
        # Update at interval
        let now = (date now)
        let elapsed = ($now - $last_update | into int) / 1_000_000_000
        
        if $elapsed >= $update_interval and ($buffer | length) >= $window {
            $buffer | dashboard
            $last_update = $now
        }
    }
}
