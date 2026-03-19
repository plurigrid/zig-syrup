# metrics.nu
# Performance and data metrics for BCI pipeline
# Stream latency, sample drop detection, throughput, signal quality

# Metrics collector
export def MetricsCollector [] {
    {
        stream_metrics: {},
        signal_quality: {},
        processing_metrics: {},
        system_metrics: {},
        start_time: (date now),
        samples_processed: 0,
        samples_dropped: 0,
        errors: []
    }
}

# Stream latency metrics
export def StreamMetrics [stream_name: string] {
    {
        stream: $stream_name,
        latency_samples: [],
        current_latency_ms: 0,
        avg_latency_ms: 0,
        max_latency_ms: 0,
        p50_latency_ms: 0,
        p95_latency_ms: 0,
        p99_latency_ms: 0,
        last_update: (date now)
    }
}

# Signal quality metrics per channel
export def ChannelMetrics [channel: string] {
    {
        channel: $channel,
        snr_db: 0.0,              # Signal-to-noise ratio
        impedance_kohm: 0.0,      # Electrode impedance
        variance: 0.0,            # Signal variance
        rms_uv: 0.0,              # RMS amplitude
        quality_score: 0.0,       # 0-1 quality score
        artifact_count: 0,        # Detected artifacts
        last_good_sample: null,
        flatline_duration: 0sec   # Duration of flat signal
    }
}

# Processing throughput metrics
export def ThroughputMetrics [] {
    {
        samples_per_second: 0.0,
        windows_per_second: 0.0,
        classifications_per_second: 0.0,
        megabytes_per_second: 0.0,
        processing_delay_ms: 0.0,
        buffer_utilization: 0.0,
        last_update: (date now)
    }
}

# Create new metrics collector
export def "metrics new" [] {
    MetricsCollector
}

# Record latency measurement
export def "metrics record-latency" [
    stream: string,
    latency_ms: float
] {
    let collector = $in
    
    mut new_collector = $collector
    
    # Initialize stream metrics if needed
    if ($stream not-in $collector.stream_metrics) {
        $new_collector = ($new_collector | upsert stream_metrics {||
            $collector.stream_metrics | insert $stream (StreamMetrics $stream)
        })
    }
    
    # Add latency sample
    let current = ($new_collector.stream_metrics | get $stream)
    let updated_samples = (($current.latency_samples | append $latency_ms) | last 1000)
    
    # Calculate statistics
    let sorted = ($updated_samples | sort)
    let count = ($sorted | length)
    
    let stats = {
        latency_samples: $updated_samples,
        current_latency_ms: $latency_ms,
        avg_latency_ms: ($sorted | math avg),
        max_latency_ms: ($sorted | math max),
        p50_latency_ms: (if $count > 0 { $sorted | get ($count * 0.5 | into int) } else { 0 }),
        p95_latency_ms: (if $count > 0 { $sorted | get ($count * 0.95 | into int) } else { 0 }),
        p99_latency_ms: (if $count > 0 { $sorted | get ($count * 0.99 | into int) } else { 0 }),
        last_update: (date now)
    }
    
    $new_collector | upsert stream_metrics.($stream) $stats
}

# Detect and record sample drops
export def "metrics check-drops" [
    expected_samples: int,    # Expected number of samples
    actual_samples: int       # Actual number received
] {
    let collector = $in
    
    let dropped = $expected_samples - $actual_samples
    
    if $dropped > 0 {
        print $"WARNING: ($dropped) samples dropped!"
        $collector 
        | upsert samples_dropped {|c| $c.samples_dropped + $dropped }
        | upsert errors {||
            $collector.errors | append {
                type: "sample_drop",
                count: $dropped,
                timestamp: (date now),
                severity: (if $dropped > 10 { "high" } else { "medium" })
            } | last 100
        }
    } else {
        $collector
    }
}

# Update signal quality for a channel
export def "metrics update-channel" [
    channel: string,
    --snr: float = null,
    --impedance: float = null,
    --variance: float = null,
    --rms: float = null,
    --artifacts: int = 0
] {
    let collector = $in
    
    mut new_collector = $collector
    
    # Initialize channel metrics if needed
    if ($channel not-in $collector.signal_quality) {
        $new_collector = ($new_collector | upsert signal_quality {||
            $collector.signal_quality | insert $channel (ChannelMetrics $channel)
        })
    }
    
    let current = ($new_collector.signal_quality | get $channel)
    mut updated = $current
    
    if $snr != null {
        $updated = ($updated | upsert snr_db $snr)
    }
    if $impedance != null {
        $updated = ($updated | upsert impedance_kohm $impedance)
    }
    if $variance != null {
        $updated = ($updated | upsert variance $variance)
    }
    if $rms != null {
        $updated = ($updated | upsert rms_uv $rms)
    }
    if $artifacts > 0 {
        $updated = ($updated | upsert artifact_count {|c| $c.artifact_count + $artifacts})
    }
    
    # Calculate quality score
    let snr_score = (if $updated.snr_db > 10 { 1.0 } else { $updated.snr_db / 10 })
    let impedance_score = (if $updated.impedance_kohm < 10 { 1.0 } else { 10 / $updated.impedance_kohm })
    let artifact_score = (1.0 - ($updated.artifact_count | into float) / 100)
    
    $updated = ($updated | upsert quality_score (($snr_score + $impedance_score + $artifact_score) / 3))
    $updated = ($updated | upsert last_good_sample (date now))
    
    $new_collector | upsert signal_quality.($channel) $updated
}

# Record processing throughput
export def "metrics record-throughput" [
    --samples: int = 0,
    --windows: int = 0,
    --classifications: int = 0,
    --bytes: int = 0,
    --delay_ms: float = 0
] {
    let collector = $in
    
    mut new_collector = $collector
    
    # Initialize if needed
    if ($new_collector.processing_metrics | is-empty) {
        $new_collector = ($new_collector | upsert processing_metrics (ThroughputMetrics))
    }
    
    let now = (date now)
    let last_update = ($new_collector.processing_metrics.last_update)
    let elapsed_secs = ((now - $last_update) | into int) / 1000000000.0
    
    if $elapsed_secs > 0 {
        let current = $new_collector.processing_metrics
        let updated = {
            samples_per_second: ($samples | into float) / $elapsed_secs,
            windows_per_second: ($windows | into float) / $elapsed_secs,
            classifications_per_second: ($classifications | into float) / $elapsed_secs,
            megabytes_per_second: (($bytes | into float) / $elapsed_secs) / 1048576,
            processing_delay_ms: $delay_ms,
            buffer_utilization: $current.buffer_utilization,
            last_update: $now
        }
        
        $new_collector 
        | upsert processing_metrics $updated
        | upsert samples_processed {|c| $c.samples_processed + $samples }
    } else {
        $new_collector
    }
}

# Get all metrics summary
export def "metrics summary" [] {
    let collector = $in
    
    let uptime = (date now) - $collector.start_time
    
    {
        uptime: $uptime,
        samples: {
            processed: $collector.samples_processed,
            dropped: $collector.samples_dropped,
            drop_rate: (if $collector.samples_processed > 0 {
                ($collector.samples_dropped | into float) / $collector.samples_processed
            } else { 0 })
        },
        streams: ($collector.stream_metrics | transpose name metrics | each {|s|
            {
                name: $s.name,
                latency_ms: $s.metrics.avg_latency_ms,
                p95_ms: $s.metrics.p95_latency_ms
            }
        }),
        signal_quality: ($collector.signal_quality | transpose channel metrics | each {|c|
            {
                channel: $c.channel,
                snr_db: $c.metrics.snr_db,
                impedance_kohm: $c.metrics.impedance_kohm,
                quality: $c.metrics.quality_score
            }
        }),
        throughput: $collector.processing_metrics,
        errors: ($collector.errors | length)
    }
}

# Get stream metrics
export def "metrics stream" [name: string] {
    let collector = $in
    
    if ($name not-in $collector.stream_metrics) {
        print $"No metrics for stream '($name)'"
        return null
    }
    
    $collector.stream_metrics | get $name
}

# Get channel metrics
export def "metrics channel" [name: string] {
    let collector = $in
    
    if ($name not-in $collector.signal_quality) {
        print $"No metrics for channel '($name)'"
        return null
    }
    
    $collector.signal_quality | get $name
}

# Export metrics to JSON
export def "metrics export" [] {
    $in | to json
}

# Export metrics for external monitoring (e.g., Prometheus format)
export def "metrics export-prometheus" [] {
    let collector = $in
    
    mut output = "# BCI Pipeline Metrics\n"
    
    # Sample metrics
    $output = $output + $"bci_samples_processed_total ($collector.samples_processed)\n"
    $output = $output + $"bci_samples_dropped_total ($collector.samples_dropped)\n"
    
    # Stream latency metrics
    for stream in ($collector.stream_metrics | columns) {
        let metrics = ($collector.stream_metrics | get $stream)
        $output = $output + $"bci_stream_latency_ms{stream=\"($stream)\"} ($metrics.avg_latency_ms)\n"
        $output = $output + $"bci_stream_latency_p95_ms{stream=\"($stream)\"} ($metrics.p95_latency_ms)\n"
    }
    
    # Channel quality metrics
    for channel in ($collector.signal_quality | columns) {
        let metrics = ($collector.signal_quality | get $channel)
        $output = $output + $"bci_channel_snr_db{channel=\"($channel)\"} ($metrics.snr_db)\n"
        $output = $output + $"bci_channel_impedance_kohm{channel=\"($channel)\"} ($metrics.impedance_kohm)\n"
        $output = $output + $"bci_channel_quality{channel=\"($channel)\"} ($metrics.quality_score)\n"
    }
    
    # Throughput metrics
    if not ($collector.processing_metrics | is-empty) {
        let tp = $collector.processing_metrics
        $output = $output + $"bci_throughput_samples_per_second ($tp.samples_per_second)\n"
        $output = $output + $"bci_throughput_megabytes_per_second ($tp.megabytes_per_second)\n"
        $output = $output + $"bci_processing_delay_ms ($tp.processing_delay_ms)\n"
    }
    
    $output
}

# Real-time metrics dashboard
export def "metrics dashboard" [
    --interval: duration = 1sec
] {
    let collector = $in
    
    print "Starting metrics dashboard..."
    print ""
    
    job spawn {
        loop {
            # Clear screen (would use ANSI codes in practice)
            print "\n\n=== BCI Pipeline Metrics ==="
            print (date now | format date "%Y-%m-%d %H:%M:%S")
            print ""
            
            let summary = $collector | metrics summary
            
            # Display throughput
            print "Throughput:"
            print $"  Samples/sec: ($summary.throughput.samples_per_second? | default 0 | into string | str substring ..6)"
            print $"  MB/sec: ($summary.throughput.megabytes_per_second? | default 0 | into string | str substring ..6)"
            print $"  Delay: ($summary.throughput.processing_delay_ms? | default 0 | into string | str substring ..5) ms"
            print ""
            
            # Display stream latencies
            print "Stream Latencies:"
            for stream in $summary.streams {
                print $"  ($stream.name): avg=($stream.latency_ms | into string | str substring ..5)ms p95=($stream.p95_ms | into string | str substring ..5)ms"
            }
            print ""
            
            # Display signal quality
            print "Signal Quality:"
            for ch in $summary.signal_quality {
                let status = (if $ch.quality > 0.8 { "✓" } else if $ch.quality > 0.5 { "⚠" } else { "✗" })
                print $"  ($status) ($ch.channel): SNR=($ch.snr_db | into string | str substring ..5)dB Z=($ch.impedance_kohm | into string | str substring ..4)kΩ"
            }
            print ""
            
            # Display sample stats
            print $"Samples: processed=($summary.samples.processed) dropped=($summary.samples.dropped) rate=($summary.samples.drop_rate * 100 | into string | str substring ..4)%"
            
            sleep $interval
        }
    }
    
    $collector
}

# Reset all metrics
export def "metrics reset" [] {
    MetricsCollector
}

# Alert on metric thresholds
export def "metrics check-alerts" [
    --max-latency-ms: float = 100,
    --max-drop-rate: float = 0.01,
    --min-quality: float = 0.5
] {
    let collector = $in
    
    mut alerts = []
    
    # Check stream latencies
    for stream in ($collector.stream_metrics | columns) {
        let metrics = ($collector.stream_metrics | get $stream)
        if $metrics.p95_latency_ms > $max_latency_ms {
            $alerts = ($alerts | append {
                severity: "warning",
                type: "high_latency",
                stream: $stream,
                value: $metrics.p95_latency_ms,
                threshold: $max_latency_ms,
                timestamp: (date now)
            })
        }
    }
    
    # Check drop rate
    if $collector.samples_processed > 0 {
        let drop_rate = ($collector.samples_dropped | into float) / $collector.samples_processed
        if $drop_rate > $max_drop_rate {
            $alerts = ($alerts | append {
                severity: "critical",
                type: "high_drop_rate",
                value: $drop_rate,
                threshold: $max_drop_rate,
                timestamp: (date now)
            })
        }
    }
    
    # Check signal quality
    for channel in ($collector.signal_quality | columns) {
        let metrics = ($collector.signal_quality | get $channel)
        if $metrics.quality_score < $min_quality {
            $alerts = ($alerts | append {
                severity: "warning",
                type: "poor_signal_quality",
                channel: $channel,
                value: $metrics.quality_score,
                threshold: $min_quality,
                timestamp: (date now)
            })
        }
    }
    
    $alerts
}

# Log metrics to file
export def "metrics log" [
    path: string,
    --interval: duration = 5sec
] {
    let collector = $in
    
    print $"Logging metrics to ($path) every ($interval)..."
    
    job spawn {
        loop {
            let summary = $collector | metrics summary
            $summary | to json | save --append $path
            sleep $interval
        }
    }
    
    $collector
}
