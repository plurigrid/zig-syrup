#!/usr/bin/env nu
# Example: Real-time alpha wave monitoring with alert

use ../stream *
use ../viz *

# Monitor alpha waves and alert when high
export def main [
    --threshold: float = 0.5      # Alpha power threshold
    --duration: duration = 5min   # Monitoring duration
    --alert-cmd: string = ""      # Command to run on alert
]: [ nothing -> nothing ] {
    print "╔══════════════════════════════════════════╗"
    print "║     Alpha Wave Monitor                   ║"
    print $"║     Threshold: ($threshold)              ║"
    print "╚══════════════════════════════════════════╝"
    print ""
    
    mut alert_count = 0
    mut last_alert = null
    
    # Stream band powers
    main stream powers --duration $duration | each { |sample|
        # Calculate average alpha across channels
        let alphas = ($sample | columns | where { |c| $c | str starts-with "ch" } | each { |ch|
            $sample | get $ch | get alpha
        })
        
        let avg_alpha = ($alphas | math avg)
        let max_alpha = ($alphas | math max)
        
        # Display
        let bar = ("█" | str repeat ($avg_alpha * 20 | math floor))
        let bar_padded = $bar | fill -a l -w 20
        print -n $"\rAlpha: │($bar_padded)│ ($avg_alpha | math round -p 2) "
        
        if $avg_alpha > $threshold {
            print -n " ★ RELAXED ★"
            
            # Alert logic (debounced)
            let time_since_last = if $last_alert != null {
                (date now) - $last_alert
            } else {
                10000sec
            }
            
            if ($time_since_last | into int) > 5000000000 {
                $alert_count = $alert_count + 1
                $last_alert = (date now)
                
                print ""
                print $"\n✓ RELAXED STATE DETECTED at ($sample.timestamp)!"
                
                if $alert_cmd != "" {
                    nu -c $alert_cmd
                }
            }
        }
    }
    
    print ""
    print ""
    print $"Monitoring complete. Alerts: ($alert_count)"
}
