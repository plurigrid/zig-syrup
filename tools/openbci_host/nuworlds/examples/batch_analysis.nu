#!/usr/bin/env nu
# Example: Batch analyze multiple recordings

use ../analyze *
use ../record *

# Analyze all recordings in a directory
export def main [
    input_dir: path = "~/openbci_recordings"  # Directory with recordings
    --output: path = "~/analysis_results"      # Output directory
    --pattern: string = "*.csv"                # File pattern to match
]: [ nothing -> table ] {
    
    let input_path = ($input_dir | path expand)
    let output_path = ($output_dir | path expand)
    
    mkdir $output_path
    
    # Find all matching files
    let files = (ls $input_path | where name =~ $pattern)
    
    if ($files | is-empty) {
        print $"No files matching '($pattern)' found in ($input_path)"
        return []
    }
    
    print $"Found ($files | length) files to analyze"
    print ""
    
    mut results = []
    
    for file in $files {
        print $"Analyzing ($file.name | path basename)..."
        
        try {
            # Run analysis
            let analysis = (main analyze $file.name --bands --features --psd)
            
            # Save individual results
            let out_file = ($output_path | path join ($file.name | path basename | str replace ".csv" "_analysis.json"))
            $analysis | to json | save -f $out_file
            
            # Collect summary
            let summary = {
                file: ($file.name | path basename)
                status: "success"
                band_powers: ($analysis | get band_powers)
                features: ($analysis | get features)
            }
            
            $results = ($results | append $summary)
            print $"  ✓ Saved to ($out_file | path basename)"
            
        } catch { |e|
            print $"  ✗ Error: ($e.msg)"
            $results = ($results | append {
                file: ($file.name | path basename)
                status: "error"
                error: $e.msg
            })
        }
    }
    
    # Save combined summary
    let summary_file = ($output_path | path join "batch_summary.json")
    $results | to json | save -f $summary_file
    
    print ""
    print $"Batch analysis complete!"
    print $"Results saved to: ($output_path)"
    print $"Summary: ($summary_file)"
    
    $results
}
