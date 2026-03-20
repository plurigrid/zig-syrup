#!/usr/bin/env nu
# Example: Overnight sleep recording with automatic segmentation

use ../record *
use ../analyze *

# Record overnight sleep and analyze in segments
export def main [
    --output-dir: path = "~/sleep_recordings"
    --segment-min: int = 30      # Minutes per segment
    --duration-hours: int = 8    # Total recording duration
]: [ nothing -> table ] {
    
    let output_path = ($output_dir | path expand)
    mkdir $output_path
    
    let date_str = (date now | format date "%Y%m%d")
    let base_name = $"sleep_($date_str)"
    
    print "╔══════════════════════════════════════════╗"
    print "║     Overnight Sleep Recording            ║"
    print "╚══════════════════════════════════════════╝"
    print ""
    print $"Duration: ($duration_hours) hours"
    print $"Segment size: ($segment_min) minutes"
    print $"Output: ($output_path)"
    print ""
    print "Press Ctrl+C to stop recording early"
    print ""
    
    mut segments = []
    
    # Record in segments
    let num_segments = ($duration_hours * 60 / $segment_min | math floor)
    
    for i in 0..<$num_segments {
        let segment_file = ($output_path | path join $"($base_name)_seg($i).csv")
        let segment_duration = ($segment_min * 60 | into duration)
        
        print $"Recording segment ($i + 1)/($num_segments)..."
        
        try {
            let result = (main record 
                --output $segment_file 
                --duration $segment_duration
            )
            
            $segments = ($segments | append {
                segment: $i
                file: $segment_file
                duration: $result.duration_sec
                samples: $result.samples_recorded
            })
            
        } catch { |e|
            print $"Error recording segment ($i): ($e.msg)"
            break
        }
    }
    
    # Generate summary
    print ""
    print "Recording complete! Analyzing segments..."
    
    mut analyses = []
    
    for seg in $segments {
        print $"Analyzing segment ($seg.segment)..."
        
        let analysis = (main analyze $seg.file --bands --features)
        
        $analyses = ($analyses | append {
            segment: $seg.segment
            start_time: ($seg.file | path basename)
            duration: $seg.duration
            delta_power: ($analysis.band_powers | get 0 | get delta)
            theta_power: ($analysis.band_powers | get 0 | get theta)
            alpha_power: ($analysis.band_powers | get 0 | get alpha)
        })
    }
    
    # Save sleep report
    let report_file = ($output_path | path join $"($base_name)_report.json")
    {
        date: $date_str
        total_segments: ($segments | length)
        total_duration_hours: ($segments | get duration | math sum) / 3600
        segments: $analyses
    } | to json | save -f $report_file
    
    print ""
    print $"Sleep study complete!"
    print $"Report: ($report_file)"
    
    $analyses
}
