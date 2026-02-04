#!/usr/bin/env nu
# Example: Stream EEG data and filter by amplitude

use ../stream *
use ../device *

# Stream data and filter for high-amplitude events
export def main [
    --threshold: float = 150.0  # Amplitude threshold in µV
    --duration: duration = 60sec
]: [ nothing -> table ] {
    print $"Streaming with threshold: ($threshold) µV"
    print "Capturing high-amplitude events..."
    print ""
    
    # Stream and filter
    let events = (main stream --duration $duration | filter { |sample|
        # Check if any channel exceeds threshold
        $sample | columns | where { |c| $c | str starts-with "ch" } | any { |ch|
            ($sample | get $ch | math abs) > $threshold
        }
    })
    
    let event_count = ($events | length)
    print $""
    print $"Found ($event_count) high-amplitude events"
    
    if $event_count > 0 {
        print "\nEvent samples:"
        $events | first 10
    }
    
    $events
}
