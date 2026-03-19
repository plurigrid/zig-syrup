# OpenBCI Pipeline Module
# Manages data processing pipelines

use config get-config, config-dir
use stream main stream
use record main record
use analyze main analyze
use viz main viz

# Pipeline directory
def pipeline-dir []: [ nothing -> path ] {
    (config-dir) | path join "pipelines"
}

# Log directory
def log-dir []: [ nothing -> path ] {
    (config-dir) | path join "pipeline_logs"
}

# Ensure directories exist
def ensure-dirs []: [ nothing -> nothing ] {
    mkdir (pipeline-dir)
    mkdir (log-dir)
}

# Pipeline management commands
#
# Usage:
#   openbci pipeline list              # List available pipelines
#   openbci pipeline run <name>        # Execute pipeline
#   openbci pipeline create <name>     # Interactive pipeline builder
#   openbci pipeline edit <name>       # Modify pipeline
#   openbci pipeline logs <name>       # View execution logs
export def "main pipeline" []: [ nothing -> string ] {
    $"OpenBCI Pipeline Management

USAGE:
    openbci pipeline <subcommand> [args]

SUBCOMMANDS:
    list       List available pipelines
    run        Execute a pipeline
    create     Create a new pipeline (interactive)
    edit       Edit an existing pipeline
    delete     Delete a pipeline
    logs       View execution logs
    show       Show pipeline details
    export     Export pipeline to file
    import     Import pipeline from file
    copy       Copy an existing pipeline

EXAMPLES:
    openbci pipeline list
    openbci pipeline run alpha-detection
    openbci pipeline create my-pipeline
    openbci pipeline logs my-pipeline --tail 50
"
}

# List available pipelines
export def "main pipeline list" [
    --verbose(-v)  # Show detailed information
]: [ nothing -> table ] {
    ensure-dirs
    
    let dir = (pipeline-dir)
    
    if not ($dir | path exists) {
        print "No pipelines directory found."
        return []
    }
    
    let pipelines = (ls $dir 
        | where name =~ '\.nu$'
        | each { |f|
            let name = ($f.name | path basename | str replace ".nu" "")
            let meta_file = ($dir | path join $"($name).json")
            let metadata = if ($meta_file | path exists) {
                try { open $meta_file } catch { {} }
            } else {
                {}
            }
            
            {
                name: $name
                description: ($metadata | get -i description | default "No description")
                created: ($f.created | format date "%Y-%m-%d")
                modified: ($f.modified | format date "%Y-%m-%d")
                runs: ($metadata | get -i execution_count | default 0)
                last_run: ($metadata | get -i last_run | default "never")
            }
        })
    
    if ($pipelines | is-empty) {
        print "No pipelines found. Create one with: openbci pipeline create <name>"
    }
    
    $pipelines
}

# Create a new pipeline
export def "main pipeline create" [
    name: string   # Pipeline name
]: [ nothing -> record ] {
    ensure-dirs
    
    let pipeline_file = (pipeline-dir | path join $"($name).nu")
    let meta_file = (pipeline-dir | path join $"($name).json")
    
    if ($pipeline_file | path exists) {
        error make { msg: $"Pipeline '($name)' already exists. Use 'openbci pipeline edit ($name)' to modify." }
    }
    
    print $"Creating pipeline: ($name)"
    print ""
    
    # Interactive pipeline builder
    print "Pipeline Type:"
    print "  1. Stream processing (real-time)"
    print "  2. File processing (batch)"
    print "  3. Analysis pipeline"
    print "  4. Custom"
    let ptype = (input "Select type [1]: ") | default "1"
    
    let pipeline_type = match $ptype {
        "1" => "stream"
        "2" => "batch"
        "3" => "analysis"
        _ => "custom"
    }
    
    print ""
    let description = (input "Description: ")
    
    # Generate pipeline template
    let template = (generate_pipeline_template $name $pipeline_type $description)
    
    $template | save -f $pipeline_file
    
    # Create metadata
    let metadata = {
        name: $name
        description: $description
        type: $pipeline_type
        created: (date now | format date "%Y-%m-%d %H:%M:%S")
        modified: (date now | format date "%Y-%m-%d %H:%M:%S")
        execution_count: 0
        last_run: null
    }
    
    $metadata | save -f $meta_file
    
    print ""
    print $"✓ Pipeline '($name)' created at ($pipeline_file)"
    print $"Edit with: openbci pipeline edit ($name)"
    
    $metadata
}

# Generate pipeline template
def generate_pipeline_template [name: string, ptype: string, description: string]: [ nothing -> string ] {
    match $ptype {
        "stream" => {
$"# Pipeline: ($name)
# Description: ($description)
# Type: Stream processing

use ../../../../stream *
use ../../../../analyze *
use ../../../../record *

# Pipeline configuration
const CHANNELS = [0 1 2 3]
const DURATION = 60sec
const SAMPLE_RATE = 250

# Main pipeline function
export def main []: [ nothing -> any ] {
    print $"Starting pipeline: ($name)"
    
    # Step 1: Stream data
    let data = (main stream --channels $CHANNELS --duration $DURATION)
    
    # Step 2: Process (add your processing steps here)
    # let processed = ($data | ...)
    
    # Step 3: Output
    print "Pipeline complete!"
    $data
}

# Run if executed directly
if (is-main) {
    main
}
"
        }
        "batch" => {
$"# Pipeline: ($name)
# Description: ($description)
# Type: Batch processing

use ../../../../analyze *
use ../../../../record *

# Pipeline configuration
const INPUT_FILE = \"input.csv\"
const OUTPUT_FILE = \"output.csv\"

# Main pipeline function
export def main [
    --input: path = $INPUT_FILE
    --output: path = $OUTPUT_FILE
]: [ nothing -> any ] {
    print $"Starting pipeline: ($name)"
    print $\"Processing ($input)...\"
    
    # Step 1: Load data
    let data = (open $input)
    
    # Step 2: Analyze
    let results = (main analyze $data --bands --features)
    
    # Step 3: Save results
    $results | save -f $output
    
    print $\"Results saved to ($output)\"
    $results
}

# Run if executed directly
if (is-main) {
    main
}
"
        }
        "analysis" => {
$"# Pipeline: ($name)
# Description: ($description)
# Type: Analysis pipeline

use ../../../../analyze *

# Pipeline configuration
const WINDOW_SIZE = 256
const OVERLAP = 0.5

# Main analysis pipeline
export def main [
    file: path
]: [ nothing -> any ] {
    print $"Starting analysis pipeline: ($name)"
    
    # Step 1: Load and validate
    let data = (open $file)
    print $\"Loaded ($data | length) samples\"
    
    # Step 2: Extract features
    let features = (main analyze $file --features)
    
    # Step 3: Calculate band powers
    let bands = (main analyze $file --bands)
    
    # Step 4: Detect artifacts
    # let artifacts = (main analyze artifacts $file)
    
    # Step 5: Generate report
    {
        file: $file
        features: $features
        bands: $bands
        # artifacts: $artifacts
    }
}

# Run if executed directly
if (is-main) {
    main
}
"
        }
        _ => {
$"# Pipeline: ($name)
# Description: ($description)
# Type: Custom

# Add your imports here
# use ../../../../stream *

# Main pipeline function
export def main [
    # Add your parameters here
]: [ nothing -> any ] {
    print $\"Running pipeline: ($name)\"
    
    # Add your pipeline steps here
    
    \"Pipeline complete!\"
}

# Run if executed directly
if (is-main) {
    main
}
"
        }
    }
}

# Run a pipeline
export def "main pipeline run" [
    name: string           # Pipeline name
    ...args                # Additional arguments to pass to pipeline
    --verbose(-v)          # Verbose output
    --log: path            # Log file path
]: [ nothing -> any ] {
    ensure-dirs
    
    let pipeline_file = (pipeline-dir | path join $"($name).nu")
    let meta_file = (pipeline-dir | path join $"($name).json")
    
    if not ($pipeline_file | path exists) {
        error make { msg: $"Pipeline '($name)' not found. Run 'openbci pipeline list' to see available pipelines." }
    }
    
    # Load metadata
    mut metadata = if ($meta_file | path exists) {
        open $meta_file
    } else {
        {}
    }
    
    # Create log entry
    let log_entry = {
        timestamp: (date now | format date "%Y-%m-%d %H:%M:%S")
        pipeline: $name
        args: $args
        status: "running"
    }
    
    if $verbose {
        print $"Executing pipeline: ($name)"
        print $"File: ($pipeline_file)"
    }
    
    # Update metadata
    $metadata = ($metadata | upsert execution_count (($metadata | get -i execution_count | default 0) + 1))
    $metadata = ($metadata | upsert last_run (date now | format date "%Y-%m-%d %H:%M:%S"))
    $metadata | save -f $meta_file
    
    # Run the pipeline
    let start_time = date now
    
    try {
        # Source and run the pipeline
        nu -c $"use ($pipeline_file); main ($args | str join ' ')"
        
        let duration = (date now) - $start_time
        
        if $verbose {
            print $"\nPipeline completed in ($duration)"
        }
        
        # Log success
        let log_file = (log-dir | path join $"($name).log")
        let success_entry = ($log_entry | upsert status "success" | upsert duration ($duration | into int))
        $success_entry | to json | save --append $log_file
        
    } catch { |e|
        let duration = (date now) - $start_time
        
        print $"\nPipeline failed: ($e.msg)"
        
        # Log failure
        let log_file = (log-dir | path join $"($name).log")
        let fail_entry = ($log_entry | upsert status "failed" | upsert error $e.msg | upsert duration ($duration | into int))
        $fail_entry | to json | save --append $log_file
    }
}

# Edit a pipeline
export def "main pipeline edit" [
    name: string  # Pipeline name
]: [ nothing -> nothing ] {
    let pipeline_file = (pipeline-dir | path join $"($name).nu")
    
    if not ($pipeline_file | path exists) {
        error make { msg: $"Pipeline '($name)' not found." }
    }
    
    let editor = ($env.EDITOR | default "nano")
    run-external $editor $pipeline_file
    
    # Update metadata
    let meta_file = (pipeline-dir | path join $"($name).json")
    if ($meta_file | path exists) {
        let metadata = (open $meta_file)
        $metadata | upsert modified (date now | format date "%Y-%m-%d %H:%M:%S") | save -f $meta_file
    }
    
    print $"Pipeline '($name)' updated."
}

# Delete a pipeline
export def "main pipeline delete" [
    name: string          # Pipeline name
    --confirm: boolean = false  # Confirm deletion
]: [ nothing -> nothing ] {
    let pipeline_file = (pipeline-dir | path join $"($name).nu")
    let meta_file = (pipeline-dir | path join $"($name).json")
    
    if not ($pipeline_file | path exists) {
        error make { msg: $"Pipeline '($name)' not found." }
    }
    
    if not $confirm {
        print $"This will delete pipeline '($name)'."
        let response = (input "Type 'yes' to confirm: ")
        if $response != "yes" {
            print "Deletion cancelled."
            return
        }
    }
    
    rm $pipeline_file
    if ($meta_file | path exists) {
        rm $meta_file
    }
    
    print $"Pipeline '($name)' deleted."
}

# Show pipeline details
export def "main pipeline show" [
    name: string  # Pipeline name
]: [ nothing -> record ] {
    let pipeline_file = (pipeline-dir | path join $"($name).nu")
    let meta_file = (pipeline-dir | path join $"($name).json")
    
    if not ($pipeline_file | path exists) {
        error make { msg: $"Pipeline '($name)' not found." }
    }
    
    let content = (open $pipeline_file)
    let metadata = if ($meta_file | path exists) {
        open $meta_file
    } else {
        {}
    }
    
    print $"\e[1mPipeline: ($name)\e[0m"
    print $"File: ($pipeline_file)"
    print ""
    print $"Description: ($metadata | get -i description | default 'No description')"
    print $"Type: ($metadata | get -i type | default 'unknown')"
    print $"Created: ($metadata | get -i created | default 'unknown')"
    print $"Modified: ($metadata | get -i modified | default 'unknown')"
    print $"Executions: ($metadata | get -i execution_count | default 0)"
    print $"Last run: ($metadata | get -i last_run | default 'never')"
    print ""
    print "\e[1mContent:\e[0m"
    print $content
    
    {
        name: $name
        content: $content
        metadata: $metadata
    }
}

# View pipeline logs
export def "main pipeline logs" [
    name?: string         # Pipeline name (omit for all)
    --tail: int = 20      # Number of log entries to show
    --follow(-f)          # Follow log output
]: [ nothing -> table ] {
    if $name != null {
        let log_file = (log-dir | path join $"($name).log")
        
        if not ($log_file | path exists) {
            print $"No logs found for pipeline '($name)'"
            return []
        }
        
        let logs = (open $log_file | lines | each { |l| $l | from json } | last $tail)
        
        if $follow {
            print "Following logs (Ctrl+C to stop)..."
            mut last_count = ($logs | length)
            
            loop {
                let current_logs = (open $log_file | lines | each { |l| $l | from json })
                let current_count = ($current_logs | length)
                
                if $current_count > $last_count {
                    let new_logs = ($current_logs | range $last_count..$current_count)
                    for log in $new_logs {
                        print $"[($log.timestamp)] ($log.status): ($log.pipeline)"
                    }
                    $last_count = $current_count
                }
                
                sleep 1sec
            }
        }
        
        $logs
    } else {
        # Show all logs
        let all_logs = (ls (log-dir) | where name =~ '\.log$' | each { |f|
            open $f.name | lines | each { |l| $l | from json }
        } | flatten | sort-by timestamp | last $tail)
        
        $all_logs
    }
}

# Export pipeline
export def "main pipeline export" [
    name: string        # Pipeline name
    destination: path   # Export destination
]: [ nothing -> nothing ] {
    let pipeline_file = (pipeline-dir | path join $"($name).nu")
    let meta_file = (pipeline-dir | path join $"($name).json")
    
    if not ($pipeline_file | path exists) {
        error make { msg: $"Pipeline '($name)' not found." }
    }
    
    let content = (open $pipeline_file)
    let metadata = if ($meta_file | path exists) {
        open $meta_file
    } else {
        {}
    }
    
    let export_data = {
        name: $name
        metadata: $metadata
        content: $content
        exported_at: (date now | format date "%Y-%m-%d %H:%M:%S")
    }
    
    $export_data | save -f $destination
    print $"Pipeline '($name)' exported to ($destination)"
}

# Import pipeline
export def "main pipeline import" [
    source: path  # Source file
    --rename: string  # Rename on import
]: [ nothing -> record ] {
    if not ($source | path exists) {
        error make { msg: $"Source file not found: ($source)" }
    }
    
    let import_data = (open $source)
    
    let name = if $rename != null {
        $rename
    } else {
        $import_data | get -i name | default ($source | path basename | str replace ".nu" "")
    }
    
    let pipeline_file = (pipeline-dir | path join $"($name).nu")
    let meta_file = (pipeline-dir | path join $"($name).json")
    
    if ($pipeline_file | path exists) {
        let response = (input $"Pipeline '($name)' exists. Overwrite? [y/N]: ")
        if $response != "y" and $response != "Y" {
            print "Import cancelled."
            return {}
        }
    }
    
    $import_data.content | save -f $pipeline_file
    
    let metadata = ($import_data.metadata | upsert imported_at (date now | format date "%Y-%m-%d %H:%M:%S"))
    $metadata | save -f $meta_file
    
    print $"Pipeline '($name)' imported."
    
    $metadata
}

# Copy/duplicate pipeline
export def "main pipeline copy" [
    source: string   # Source pipeline name
    dest: string     # Destination pipeline name
]: [ nothing -> record ] {
    let source_file = (pipeline-dir | path join $"($source).nu")
    let source_meta = (pipeline-dir | path join $"($source).json")
    let dest_file = (pipeline-dir | path join $"($dest).nu")
    let dest_meta = (pipeline-dir | path join $"($dest).json")
    
    if not ($source_file | path exists) {
        error make { msg: $"Source pipeline '($source)' not found." }
    }
    
    if ($dest_file | path exists) {
        error make { msg: $"Destination pipeline '($dest)' already exists." }
    }
    
    cp $source_file $dest_file
    
    if ($source_meta | path exists) {
        let metadata = (open $source_meta)
        let new_metadata = ($metadata 
            | upsert name $dest 
            | upsert description $"Copy of ($source): ($metadata.description?)"
            | upsert created (date now | format date "%Y-%m-%d %H:%M:%S")
            | upsert execution_count 0
            | upsert last_run null
        )
        $new_metadata | save -f $dest_meta
    }
    
    print $"Pipeline '($source)' copied to '($dest)'"
    
    { source: $source, destination: $dest }
}

# Pre-built pipeline: Alpha detection
export def "main pipeline alpha" [
    --threshold: float = 0.3  # Alpha power threshold
    --duration: duration = 60sec
]: [ nothing -> table ] {
    print "Running Alpha Detection Pipeline"
    print $"Threshold: ($threshold)"
    print ""
    
    # Stream and detect alpha
    use stream main stream powers
    
    let results = (main stream powers --duration $duration | each { |sample|
        let alpha_total = ($sample | columns | where { |c| $c | str starts-with "ch" } | each { |ch|
            $sample | get $ch | get alpha
        } | math avg)
        
        {
            timestamp: $sample.timestamp
            alpha_power: $alpha_total
            state: (if $alpha_total > $threshold { "relaxed" } else { "active" })
        }
    })
    
    let relaxed_count = ($results | where state == "relaxed" | length)
    let total_count = ($results | length)
    let relaxed_pct = ($relaxed_count * 100 / $total_count | math round -p 1)
    
    print ""
    print $"Results: ($relaxed_count)/($total_count) samples above threshold (($relaxed_pct)%)"
    
    $results
}

# Pre-built pipeline: Artifact removal
export def "main pipeline clean" [
    file: path              # Input file
    --threshold: float = 200.0  # Artifact threshold in µV
    --output: path          # Output file
]: [ nothing -> path ] {
    print "Running Artifact Removal Pipeline"
    
    use analyze main analyze artifacts
    
    # Detect artifacts
    let artifacts = (main analyze artifacts $file --threshold $threshold)
    
    if ($artifacts | is-empty) {
        print "No artifacts detected."
        return $file
    }
    
    print $"Detected ($artifacts | length) artifacts"
    
    # Load data
    let data = (open $file)
    
    # Remove artifact segments (simple approach - zero out)
    let artifact_indices = ($artifacts | get sample_index | uniq)
    let cleaned = ($data | enumerate | each { |row|
        if $row.index in $artifact_indices {
            # Interpolate or mark as invalid
            $row.item  # Keep original for now
        } else {
            $row.item
        }
    })
    
    # Save cleaned data
    let out_file = if $output != null {
        $output
    } else {
        $file | path parse | update stem { |s| $"($s)_cleaned" } | path join
    }
    
    $cleaned | save -f $out_file
    print $"Cleaned data saved to ($out_file)"
    
    $out_file
}
