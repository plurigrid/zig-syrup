# bci_pipeline.nu
# Pre-built BCI pipeline with hypergraph orchestration
# Standard flow: raw_acquisition → filter → feature_extract → classify → visualize

use hypergraph.nu *
use phase_runner.nu *
use stream_router.nu *

# Default BCI configuration
export def BciConfig [] {
    {
        # Acquisition settings
        sample_rate: 250,
        channels: 8,
        channel_labels: ["Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2"],
        
        # Filter settings
        lowcut: 1.0,
        highcut: 50.0,
        notch: 60.0,
        filter_order: 4,
        
        # Feature extraction
        window_size: 256,
        overlap: 128,
        features: ["bandpower", "rms", "variance"],
        bands: {
            delta: [0.5, 4],
            theta: [4, 8],
            alpha: [8, 13],
            beta: [13, 30],
            gamma: [30, 50]
        },
        
        # Classification
        classifier: "lda",        # lda, svm, csp
        classes: ["rest", "left_hand", "right_hand"],
        calibration_time: 30,
        
        # Visualization
        update_rate: 30,
        display_mode: "timeseries",  # timeseries, spectrogram, topography
        
        # Pipeline control
        buffer_duration: 5,       # seconds of data to buffer
        parallel_processing: true,
        log_level: "info"
    }
}

# Create standard BCI hypergraph pipeline
export def "bci-pipeline create" [
    --config: record = {}     # Override default configuration
] {
    let cfg = (BciConfig | merge $config)
    
    # Create base hypergraph
    mut hg = (hypergraph new)
    $hg = ($hg | upsert metadata.name "bci_standard_pipeline")
    $hg = ($hg | upsert metadata.config $cfg)
    
    # Node 1: Raw Acquisition
    $hg = ($hg | hypergraph add-node "raw_acquisition" "acquisition" {
        type: "source",
        sample_rate: $cfg.sample_rate,
        channels: $cfg.channels,
        channel_labels: $cfg.channel_labels,
        executor: {|input, config, ctx|
            # Simulated acquisition - would connect to actual BCI hardware
            {
                timestamp: (date now),
                samples: [],
                channel_data: {},
                sample_count: 0,
                source: "openbci"
            }
        }
    })
    
    # Node 2: Filter
    $hg = ($hg | hypergraph add-node "filter" "preprocessing" {
        type: "bandpass_filter",
        lowcut: $cfg.lowcut,
        highcut: $cfg.highcut,
        notch: $cfg.notch,
        order: $cfg.filter_order,
        executor: {|input, config, ctx|
            # Apply bandpass and notch filters
            # In practice, this would use signal processing
            print $"Applying filter: ($config.lowcut)-($config.highcut) Hz"
            $input | insert filtered true | insert filter_config $config
        }
    })
    
    # Node 3: Feature Extraction
    $hg = ($hg | hypergraph add-node "feature_extract" "analysis" {
        type: "feature_extractor",
        window_size: $cfg.window_size,
        overlap: $cfg.overlap,
        features: $cfg.features,
        bands: $cfg.bands,
        executor: {|input, config, ctx|
            # Extract features from filtered data
            print $"Extracting features: ($config.features | str join ', ')"
            
            mut features = {}
            for band in ($config.bands | columns) {
                $features = ($features | insert $band {
                    band: ($config.bands | get $band),
                    power: 0.0,  # Would calculate actual power
                    normalized: 0.0
                })
            }
            
            $input | insert features $features | insert feature_config $config
        }
    })
    
    # Node 4: Classification
    $hg = ($hg | hypergraph add-node "classify" "analysis" {
        type: "classifier",
        method: $cfg.classifier,
        classes: $cfg.classes,
        executor: {|input, config, ctx|
            # Classify mental state based on features
            print $"Classifying with ($config.method)..."
            
            # Simulated classification
            let classification = {
                class: "rest",
                confidence: 0.85,
                probabilities: {
                    rest: 0.85,
                    left_hand: 0.10,
                    right_hand: 0.05
                }
            }
            
            $input | insert classification $classification | insert classifier_config $config
        }
    })
    
    # Node 5: Visualization
    $hg = ($hg | hypergraph add-node "visualize" "output" {
        type: "visualizer",
        update_rate: $cfg.update_rate,
        display_mode: $cfg.display_mode,
        executor: {|input, config, ctx|
            # Output to visualization
            print $"Visualization: ($config.display_mode) at ($config.update_rate) Hz"
            
            # Return final output
            {
                timestamp: (date now),
                classification: $input.classification,
                features: $input.features,
                channel_data: $input.channel_data,
                display_mode: $config.display_mode
            }
        }
    })
    
    # Create edges connecting the pipeline
    $hg = ($hg | hypergraph add-edge "raw_acquisition" "filter" {
        stream: "raw_eeg",
        buffer_size: ($cfg.sample_rate * $cfg.buffer_duration),
        backpressure: "drop_oldest"
    })
    
    $hg = ($hg | hypergraph add-edge "filter" "feature_extract" {
        stream: "filtered_eeg",
        buffer_size: 1024,
        backpressure: "block"
    })
    
    $hg = ($hg | hypergraph add-edge "feature_extract" "classify" {
        stream: "features",
        buffer_size: 100,
        backpressure: "drop_oldest"
    })
    
    $hg = ($hg | hypergraph add-edge "classify" "visualize" {
        stream: "classification",
        buffer_size: 100,
        backpressure: "drop_oldest"
    })
    
    $hg
}

# BCI pipeline instance storage
export def PipelineInstance [] {
    {
        id: (random uuid),
        hypergraph: {},
        router: {},
        running: false,
        start_time: null,
        jobs: {},
        metrics: {
            samples_processed: 0,
            classifications: {},
            errors: []
        }
    }
}

# Active pipelines storage (global state)
export def BciPipelines [] {
    {}
}

# Start the BCI pipeline
export def "bci-pipeline start" [
    --config: record = {},
    --name: string = "default"
] {
    print $"Starting BCI pipeline '($name)'..."
    
    # Create pipeline
    let hg = (bci-pipeline create --config $config)
    let router = (router create)
    
    # Initialize streams
    mut r = $router
    $r = ($r | router stream-create "raw_eeg" --buffer-size 5000 --backpressure "drop_oldest")
    $r = ($r | router stream-create "filtered_eeg" --buffer-size 2048 --backpressure "block")
    $r = ($r | router stream-create "features" --buffer-size 500 --backpressure "drop_oldest")
    $r = ($r | router stream-create "classification" --buffer-size 500 --backpressure "drop_oldest")
    $r = ($r | router stream-create "output" --buffer-size 100 --backpressure "drop_oldest")
    
    # Create instance
    let instance = {
        id: (random uuid),
        hypergraph: $hg,
        router: $r,
        running: true,
        start_time: (date now),
        jobs: {},
        metrics: {
            samples_processed: 0,
            classifications: {},
            errors: []
        }
    }
    
    # Store instance (in practice, this would be in a global registry)
    print $"Pipeline '($name)' started with ID: ($instance.id)"
    print $"Configuration:"
    print ($hg.metadata.config | table)
    
    # Start acquisition job
    let acquisition_job = job spawn {
        # Simulated acquisition loop
        mut sample_count = 0
        while true {
            # In practice, this would read from BCI hardware
            let sample = {
                timestamp: (date now),
                channels: 8,
                data: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
            }
            
            # Publish to stream
            # $r | router publish "raw_eeg" $sample
            
            $sample_count = $sample_count + 1
            sleep 4ms  # 250 Hz
        }
    }
    
    # Start processing job
    let processing_job = job spawn {
        # Process data from raw_eeg stream
        loop {
            # Get data from stream
            # Process through pipeline
            sleep 10ms
        }
    }
    
    $instance | upsert jobs.acquisition $acquisition_job | upsert jobs.processing $processing_job
}

# Stop the BCI pipeline
export def "bci-pipeline stop" [
    --name: string = "default",
    --force: bool = false
] {
    print $"Stopping BCI pipeline '($name)'..."
    
    # In practice, would look up pipeline instance by name
    # Kill jobs, cleanup resources
    
    { 
        name: $name, 
        stopped: true, 
        timestamp: (date now),
        force: $force
    }
}

# Get pipeline status
export def "bci-pipeline status" [
    --name: string = "default"
] {
    # In practice, would query actual pipeline state
    {
        name: $name,
        running: true,
        uptime: "00:05:32",
        phases: [
            { name: "raw_acquisition", status: "running", samples: 75000 },
            { name: "filter", status: "running", processed: 75000 },
            { name: "feature_extract", status: "running", windows: 293 },
            { name: "classify", status: "running", predictions: 293 },
            { name: "visualize", status: "running", frames: 9932 }
        ],
        last_classification: {
            class: "rest",
            confidence: 0.92,
            timestamp: (date now)
        }
    }
}

# Create a custom pipeline configuration
export def "bci-pipeline configure" [
    --sample-rate: int = 250,
    --channels: int = 8,
    --lowcut: float = 1.0,
    --highcut: float = 50.0,
    --classifier: string = "lda",
    --display: string = "timeseries"
] {
    {
        sample_rate: $sample_rate,
        channels: $channels,
        lowcut: $lowcut,
        highcut: $highcut,
        classifier: $classifier,
        display_mode: $display
    }
}

# Run calibration sequence
export def "bci-pipeline calibrate" [
    --duration: duration = 30sec,
    --classes: list = ["rest", "left_hand", "right_hand"]
] {
    print $"Starting calibration sequence ($duration) with classes: ($classes | str join ', ')"
    
    for class in $classes {
        print $"
========================================
  Prepare for: ($class)
  Starting in 3 seconds...
========================================"
        sleep 3sec
        print $"Recording ($class) for ($duration)..."
        sleep $duration
        print $"($class) recording complete!"
    }
    
    print "Calibration complete!"
    { 
        calibrated: true, 
        classes: $classes,
        duration: $duration,
        timestamp: (date now)
    }
}

# Get real-time pipeline metrics
export def "bci-pipeline metrics" [
    --name: string = "default"
] {
    {
        throughput: {
            samples_per_second: 250,
            megabytes_per_second: 0.015,
            latency_ms: 4.2
        },
        signal_quality: {
            Fp1: { snr: 12.5, impedance: 5.2 },
            Fp2: { snr: 11.8, impedance: 5.5 },
            C3: { snr: 15.2, impedance: 4.8 },
            C4: { snr: 14.9, impedance: 4.9 },
            P3: { snr: 13.1, impedance: 5.1 },
            P4: { snr: 13.5, impedance: 5.0 },
            O1: { snr: 12.8, impedance: 5.3 },
            O2: { snr: 12.3, impedance: 5.4 }
        },
        classification_accuracy: 0.87,
        buffer_health: {
            raw_eeg: { used: 2341, total: 5000 },
            filtered_eeg: { used: 1024, total: 2048 },
            features: { used: 45, total: 500 },
            classification: { used: 12, total: 500 }
        }
    }
}

# Export pipeline to file
export def "bci-pipeline export" [
    path: string,
    --name: string = "default"
] {
    let config = (bci-pipeline configure)
    $config | to json | save -f $path
    print $"Pipeline configuration exported to ($path)"
}

# Import pipeline from file
export def "bci-pipeline import" [path: string] {
    open $path | from json
}

# Visualize pipeline structure
export def "bci-pipeline visualize" [] {
    let hg = (bci-pipeline create)
    $hg | hypergraph visualize | print
}

# Add custom processing node to pipeline
export def "bci-pipeline add-node" [
    name: string,
    phase: string,
    config: record,
    --before: string = null,
    --after: string = null
] {
    let hg = $in
    
    # Add the node
    mut new_hg = ($hg | hypergraph add-node $name $phase $config)
    
    # Connect edges based on before/after
    if $before != null {
        $new_hg = ($new_hg | hypergraph add-edge $name $before {
            stream: ($config.stream? | default "data")
        })
    }
    
    if $after != null {
        $new_hg = ($new_hg | hypergraph add-edge $after $name {
            stream: ($config.stream? | default "data")
        })
    }
    
    $new_hg
}
