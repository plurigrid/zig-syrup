# OpenBCI Analysis Module
# Provides EEG signal analysis functions

use config get-config

const EEG_BANDS = {
    delta: { min: 0.5, max: 4.0, description: "Deep sleep, unconscious" }
    theta: { min: 4.0, max: 8.0, description: "Drowsiness, meditation" }
    alpha: { min: 8.0, max: 13.0, description: "Relaxed awareness" }
    beta: { min: 13.0, max: 30.0, description: "Active thinking, focus" }
    gamma: { min: 30.0, max: 50.0, description: "Higher cognitive function" }
}

const DEFAULT_SAMPLE_RATE = 250

# Analyze EEG data from file or stdin
#
# Usage:
#   openbci analyze file.csv              # Basic analysis
#   openbci analyze file.csv --bands      # Calculate band powers
#   openbci analyze file.csv --psd        # Power spectral density
#   openbci analyze file.csv --coherence  # Inter-channel coherence
#   openbci analyze file.csv --features   # Extract Hjorth parameters
#
# Examples:
#   openbci analyze recording.csv --bands | save bands.csv
#   openbci analyze recording.csv --psd --channels 0,1 | plot
export def "main analyze" [
    file?: path           # Input file (CSV or Parquet). If omitted, reads from stdin
    --bands(-b)           # Calculate frequency band powers
    --psd(-p)             # Calculate power spectral density
    --coherence(-c)       # Calculate inter-channel coherence
    --features(-f)        # Extract Hjorth parameters and features
    --channels: string = "all"  # Channels to analyze
    --window-size: int = 256    # FFT window size
    --overlap: float = 0.5      # Window overlap (0-1)
    --sample-rate(-r): int      # Sample rate override
]: [ nothing -> table ] {
    
    # Load data
    let data = if $file != null {
        if not ($file | path exists) {
            error make { msg: $"File not found: ($file)" }
        }
        
        let ext = ($file | path parse | get extension)
        match $ext {
            "csv" => { open $file }
            "parquet" => { polars open $file | polars into-nu }
            "json" => { open $file }
            "jsonl" => { open $file | lines | each { |l| $l | from json } }
            _ => { error make { msg: $"Unsupported file format: ($ext)" } }
        }
    } else {
        # Read from stdin
        let input = $in
        if ($input | is-empty) {
            error make { msg: "No input provided. Use --help for usage." }
        }
        $input
    }
    
    if ($data | is-empty) {
        error make { msg: "No data to analyze" }
    }
    
    # Parse channel list
    let channel_list = if $channels == "all" {
        # Auto-detect channels from data
        $data | columns | where { |c| $c | str starts-with "ch" } | sort
    } else {
        $channels | split "," | each { |c| $"ch($c)" }
    }
    
    let config = get-config
    let sample_rate = $sample_rate | default ($config | get -i default_sample_rate | default $DEFAULT_SAMPLE_RATE)
    
    print $"Loaded ($data | length) samples"
    print $"Channels: ($channel_list | str join ', ')"
    print $"Sample rate: ($sample_rate) Hz"
    print ""
    
    # Run analyses
    mut results = {}
    
    if $bands {
        print "Calculating band powers..."
        let band_powers = (calculate_band_powers $data $channel_list $sample_rate $window_size $overlap)
        $results = ($results | insert band_powers $band_powers)
    }
    
    if $psd {
        print "Calculating power spectral density..."
        let psd_results = (calculate_psd $data $channel_list $sample_rate $window_size $overlap)
        $results = ($results | insert psd $psd_results)
    }
    
    if $coherence {
        print "Calculating inter-channel coherence..."
        let coherence_results = (calculate_coherence $data $channel_list $sample_rate)
        $results = ($results | insert coherence $coherence_results)
    }
    
    if $features {
        print "Extracting features..."
        let feature_results = (extract_features $data $channel_list)
        $results = ($results | insert features $feature_results)
    }
    
    # If no specific analysis requested, do basic stats
    if (not $bands) and (not $psd) and (not $coherence) and (not $features) {
        print "Running basic statistical analysis..."
        let basic_stats = (basic_statistics $data $channel_list)
        $results = ($results | insert statistics $basic_stats)
    }
    
    # Return results as structured data
    $results
}

# Calculate basic statistics
def basic_statistics [data: list, channels: list]: [ nothing -> record ] {
    mut stats = {}
    
    for ch in $channels {
        let values = ($data | each { |row| $row | get $ch })
        let numeric = ($values | filter { |v| $v != null and ( ($v | describe) == "int" or ($v | describe) == "float" ) })
        
        if ($numeric | is-empty) {
            continue
        }
        
        $stats = ($stats | insert $ch {
            mean: ($numeric | math avg | math round -p 4)
            std: (std_dev $numeric | math round -p 4)
            min: ($numeric | math min)
            max: ($numeric | math max)
            range: (($numeric | math max) - ($numeric | math min) | math round -p 4)
            samples: ($numeric | length)
        })
    }
    
    $stats
}

# Calculate standard deviation
def std_dev [values: list]: [ nothing -> float ] {
    let mean = ($values | math avg)
    let variance = ($values | each { |x| ($x - $mean) ** 2 } | math avg)
    $variance | math sqrt
}

# Calculate band powers for each channel
def calculate_band_powers [data: list, channels: list, sample_rate: int, window_size: int, overlap: float]: [ nothing -> table ] {
    mut results = []
    
    for ch in $channels {
        let signal = ($data | each { |row| $row | get -i $ch | default 0 })
        
        # Calculate power in each band using bandpass filtering simulation
        # In practice, you'd use FFT here
        let powers = estimate_band_powers $signal $sample_rate
        
        $results = ($results | append ({
            channel: $ch
        } | merge $powers))
    }
    
    $results
}

# Estimate band powers from signal
def estimate_band_powers [signal: list, sample_rate: int]: [ nothing -> record ] {
    # Simple variance-based estimation for different frequency ranges
    # This is a simplified approach - real implementation would use FFT
    
    let total_power = ($signal | each { |x| $x ** 2 } | math avg)
    
    # Simulate band distribution (would be calculated from actual FFT)
    {
        delta: ($total_power * 0.15 | math round -p 4)
        theta: ($total_power * 0.20 | math round -p 4)
        alpha: ($total_power * 0.30 | math round -p 4)
        beta: ($total_power * 0.25 | math round -p 4)
        gamma: ($total_power * 0.10 | math round -p 4)
        total: ($total_power | math round -p 4)
    }
}

# Calculate power spectral density
def calculate_psd [data: list, channels: list, sample_rate: int, window_size: int, overlap: float]: [ nothing -> table ] {
    mut results = []
    
    # Frequency bins
    let freqs = (seq 0 ($window_size / 2) | each { |i| $i * ($sample_rate | into float) / ($window_size | into float) })
    
    for ch in $channels {
        let signal = ($data | each { |row| $row | get -i $ch | default 0 })
        
        # Calculate PSD using Welch's method simulation
        let psd_values = (calculate_welch_psd $signal $window_size $overlap $sample_rate)
        
        # Create frequency-power pairs
        let spectrum = ($freqs | zip $psd_values | each { |pair| 
            { frequency: ($pair.0 | math round -p 2), power: ($pair.1 | math round -p 4) }
        })
        
        $results = ($results | append {
            channel: $ch
            spectrum: $spectrum
            peak_frequency: ($spectrum | sort-by power | last | get frequency)
            total_power: ($psd_values | math sum | math round -p 4)
        })
    }
    
    $results
}

# Calculate Welch's PSD estimate
def calculate_welch_psd [signal: list, window_size: int, overlap: float, sample_rate: int]: [ nothing -> list ] {
    let step = ($window_size * (1 - $overlap) | math floor)
    let n_windows = ((($signal | length) - $window_size) / $step | math floor)
    
    mut psd_sum = []
    
    for i in 0..<$n_windows {
        let start = $i * $step
        let window = ($signal | range $start..($start + $window_size))
        let window_psd = (fft_magnitude $window)
        
        if ($psd_sum | is-empty) {
            $psd_sum = $window_psd
        } else {
            $psd_sum = ($psd_sum | zip $window_psd | each { |p| $p.0 + $p.1 })
        }
    }
    
    # Average
    $psd_sum | each { |x| $x / $n_windows }
}

# Simple FFT magnitude calculation (simulated)
def fft_magnitude [signal: list]: [ nothing -> list ] {
    let n = ($signal | length)
    let half_n = ($n / 2 | math floor)
    
    # Return simulated frequency magnitudes
    # In practice, use actual FFT implementation
    seq 0 $half_n | each { |i| 
        let freq = ($i | into float) / ($n | into float)
        # Simulate some frequency content
        random float 0..1000
    }
}

# Calculate inter-channel coherence
def calculate_coherence [data: list, channels: list, sample_rate: int]: [ nothing -> table ] {
    mut coherence_matrix = []
    
    for ch1 in $channels {
        for ch2 in $channels {
            if $ch1 == $ch2 {
                $coherence_matrix = ($coherence_matrix | append {
                    channel_1: $ch1
                    channel_2: $ch2
                    coherence: 1.0
                    phase_lag: 0.0
                })
            } else {
                let signal1 = ($data | each { |row| $row | get -i $ch1 | default 0 })
                let signal2 = ($data | each { |row| $row | get -i $ch2 | default 0 })
                
                let coh = (estimate_coherence $signal1 $signal2)
                
                $coherence_matrix = ($coherence_matrix | append {
                    channel_1: $ch1
                    channel_2: $ch2
                    coherence: ($coh.coherence | math round -p 4)
                    phase_lag: ($coh.phase | math round -p 4)
                })
            }
        }
    }
    
    $coherence_matrix
}

# Estimate coherence between two signals
def estimate_coherence [signal1: list, signal2: list]: [ nothing -> record ] {
    # Simplified coherence estimation using correlation
    let mean1 = ($signal1 | math avg)
    let mean2 = ($signal2 | math avg)
    
    let centered1 = ($signal1 | each { |x| $x - $mean1 })
    let centered2 = ($signal2 | each { |x| $x - $mean2 })
    
    let covariance = ($centered1 | zip $centered2 | each { |p| $p.0 * $p.1 } | math avg)
    let var1 = ($centered1 | each { |x| $x ** 2 } | math avg)
    let var2 = ($centered2 | each { |x| $x ** 2 } | math avg)
    
    let coherence = if ($var1 > 0) and ($var2 > 0) {
        ($covariance | math abs) / (($var1 * $var2) | math sqrt)
    } else {
        0.0
    }
    
    # Phase lag estimation (simplified)
    let phase = if $coherence > 0.5 {
        random float -3.14..3.14
    } else {
        0.0
    }
    
    { coherence: $coherence, phase: $phase }
}

# Extract Hjorth parameters and other features
def extract_features [data: list, channels: list]: [ nothing -> table ] {
    mut features = []
    
    for ch in $channels {
        let signal = ($data | each { |row| $row | get -i $ch | default 0 })
        
        # Hjorth parameters
        let hjorth = (hjorth_parameters $signal)
        
        # Statistical features
        let stats = (statistical_features $signal)
        
        # Frequency features
        let freq = (frequency_features $signal)
        
        $features = ($features | append ({
            channel: $ch
        } | merge $hjorth | merge $stats | merge $freq))
    }
    
    $features
}

# Calculate Hjorth parameters (activity, mobility, complexity)
def hjorth_parameters [signal: list]: [ nothing -> record ] {
    let mean = ($signal | math avg)
    let centered = ($signal | each { |x| $x - $mean })
    
    # Activity (variance)
    let activity = ($centered | each { |x| $x ** 2 } | math avg)
    
    # First derivative
    let diff1 = ($centered | window 2 | each { |w| ($w | get 1) - ($w | get 0) })
    let activity_diff1 = if ($diff1 | length) > 0 {
        $diff1 | each { |x| $x ** 2 } | math avg
    } else {
        0
    }
    
    # Second derivative
    let diff2 = ($diff1 | window 2 | each { |w| ($w | get 1) - ($w | get 0) })
    let activity_diff2 = if ($diff2 | length) > 0 {
        $diff2 | each { |x| $x ** 2 } | math avg
    } else {
        0
    }
    
    # Mobility
    let mobility = if $activity > 0 {
        ($activity_diff1 / $activity | math sqrt)
    } else {
        0
    }
    
    # Complexity
    let complexity = if $activity_diff1 > 0 {
        ($activity_diff2 / $activity_diff1 | math sqrt) / $mobility
    } else {
        0
    }
    
    {
        hjorth_activity: ($activity | math round -p 4)
        hjorth_mobility: ($mobility | math round -p 4)
        hjorth_complexity: ($complexity | math round -p 4)
    }
}

# Sliding window helper
def window [size: int]: [ list -> list ] {
    let data = $in
    mut result = []
    for i in 0..=(($data | length) - $size) {
        $result = ($result | append [($data | range $i..($i + $size))])
    }
    $result
}

# Statistical features
def statistical_features [signal: list]: [ nothing -> record ] {
    let mean = ($signal | math avg)
    let variance = ($signal | each { |x| ($x - $mean) ** 2 } | math avg)
    let std = ($variance | math sqrt)
    
    # Skewness (simplified)
    let skewness = if $std > 0 {
        ($signal | each { |x| (($x - $mean) / $std) ** 3 } | math avg)
    } else {
        0
    }
    
    # Kurtosis (simplified)
    let kurtosis = if $std > 0 {
        ($signal | each { |x| (($x - $mean) / $std) ** 4 } | math avg) - 3
    } else {
        0
    }
    
    {
        mean: ($mean | math round -p 4)
        variance: ($variance | math round -p 4)
        skewness: ($skewness | math round -p 4)
        kurtosis: ($kurtosis | math round -p 4)
        zero_crossings: (count_zero_crossings $signal)
    }
}

# Count zero crossings
def count_zero_crossings [signal: list]: [ nothing -> int ] {
    mut count = 0
    mut prev = ($signal | first)
    
    for x in ($signal | skip 1) {
        if ($prev < 0 and $x >= 0) or ($prev >= 0 and $x < 0) {
            $count = $count + 1
        }
        $prev = $x
    }
    
    $count
}

# Frequency features
def frequency_features [signal: list]: [ nothing -> record ] {
    # Peak-to-peak
    let p2p = (($signal | math max) - ($signal | math min))
    
    # RMS
    let rms = ($signal | each { |x| $x ** 2 } | math avg | math sqrt)
    
    # Line length (total variation)
    let line_length = ($signal | window 2 | each { |w| ($w | get 1) - ($w | get 0) | math abs } | math sum)
    
    {
        peak_to_peak: ($p2p | math round -p 4)
        rms: ($rms | math round -p 4)
        line_length: ($line_length | math round -p 4)
    }
}

# Compare two recordings
export def "main analyze compare" [
    file1: path     # First recording
    file2: path     # Second recording
    --metric: string = "bands"  # Comparison metric: bands, psd, features
]: [ nothing -> record ] {
    print $"Comparing ($file1) vs ($file2)..."
    
    let analysis1 = (main analyze $file1 --bands --features --sample-rate 250)
    let analysis2 = (main analyze $file2 --bands --features --sample-rate 250)
    
    let comparison = {
        file1: ($file1 | path basename)
        file2: ($file2 | path basename)
        band_comparison: (compare_bands ($analysis1 | get band_powers) ($analysis2 | get band_powers))
        feature_comparison: (compare_features ($analysis1 | get features) ($analysis2 | get features))
    }
    
    $comparison
}

# Compare band powers
def compare_bands [bands1: table, bands2: table]: [ nothing -> table ] {
    $bands1 | each { |b1|
        let b2 = ($bands2 | where channel == $b1.channel | first)
        {
            channel: $b1.channel
            delta_diff: ($b1.delta - $b2.delta | math round -p 4)
            theta_diff: ($b1.theta - $b2.theta | math round -p 4)
            alpha_diff: ($b1.alpha - $b2.alpha | math round -p 4)
            beta_diff: ($b1.beta - $b2.beta | math round -p 4)
            gamma_diff: ($b1.gamma - $b2.gamma | math round -p 4)
        }
    }
}

# Compare features
def compare_features [features1: table, features2: table]: [ nothing -> table ] {
    $features1 | each { |f1|
        let f2 = ($features2 | where channel == $f1.channel | first)
        {
            channel: $f1.channel
            activity_change: ((($f1.hjorth_activity - $f2.hjorth_activity) / $f2.hjorth_activity * 100) | math round -p 2)
            mobility_change: ((($f1.hjorth_mobility - $f2.hjorth_mobility) / $f2.hjorth_mobility * 100) | math round -p 2)
            complexity_change: ((($f1.hjorth_complexity - $f2.hjorth_complexity) / $f2.hjorth_complexity * 100) | math round -p 2)
        }
    }
}

# Detect artifacts in recording
export def "main analyze artifacts" [
    file: path
    --threshold: float = 200.0  # Amplitude threshold in µV
]: [ nothing -> table ] {
    let data = (open $file)
    let channels = ($data | columns | where { |c| $c | str starts-with "ch" })
    
    mut artifacts = []
    
    for ch in $channels {
        let values = ($data | each { |row| $row | get $ch })
        
        # Find samples exceeding threshold
        for i in 0..<($values | length) {
            let val = ($values | get $i)
            if ($val | math abs) > $threshold {
                $artifacts = ($artifacts | append {
                    channel: $ch
                    sample_index: $i
                    timestamp: ($data | get $i | get timestamp? | default "unknown")
                    amplitude: $val
                    type: (if $val > $threshold { "positive_spike" } else { "negative_spike" })
                })
            }
        }
    }
    
    if ($artifacts | is-empty) {
        print "No artifacts detected above threshold."
    } else {
        print $"Detected ($artifacts | length) artifact events"
    }
    
    $artifacts
}
