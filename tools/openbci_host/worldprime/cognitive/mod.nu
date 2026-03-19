# cognitive/mod.nu
# Signal → Worlds → Fusion pipeline for cognitive architecture
# First stage of the multi-stage cognitive processing pipeline

# =============================================================================
# Module Imports
# =============================================================================

# Signal input and preprocessing
export use signal_input.nu [
    SignalConfig,
    SignalState,
    "signal acquire",
    "signal preprocess",
    "signal window",
    "signal quality",
    "quality monitor",
    "signal route",
    "signal extract",
    generate-simulated-sample,
    check-sample-quality
]

# World projections (a://, b://, c://)
export use worlds_projection.nu [
    WorldProjectionConfig,
    "worlds project",
    "worlds stats",
    project-world-a,
    project-world-b,
    project-world-c,
    extract-features-world,
    extract-hjorth-parameters,
    extract-entropy-measures,
    extract-fractal-dimensions,
    select-optimal-world
]

# Multi-world fusion engine
export use fusion_engine.nu [
    FusionConfig,
    FusionState,
    "fusion bayesian",
    "fusion dempster-shafer",
    "fusion kalman",
    "fusion consensus",
    "fusion ensemble",
    fuse-states-weighted,
    calculate-entropy
]

# Signal-world bridge
export use signal_worlds_bridge.nu [
    BridgeConfig,
    BridgeState,
    "bridge signal-to-world",
    "bridge world-to-signal",
    "bridge sync",
    "bridge interpolate",
    "bridge pipeline",
    extract-signal-features,
    interpolate-states
]

# =============================================================================
# Pipeline Orchestration
# =============================================================================

# Run the complete Signal → Worlds → Fusion pipeline
export def "cognitive pipeline" [
    --duration: duration = 30sec      # Acquisition duration
    --simulate: bool = true           # Use simulated data
    --fusion-method: string = "ensemble"  # bayesian, dempster-shafer, kalman, consensus, ensemble
    --worlds: list = [a b c]         # Worlds to project into
    --adaptive: bool = true           # Enable adaptive world selection
]: [ nothing -> record ] {
    print "╔══════════════════════════════════════════════════════════════╗"
    print "║     Signal → Worlds → Fusion Cognitive Pipeline              ║"
    print "╚══════════════════════════════════════════════════════════════╝"
    print ""
    
    # Stage 1: Signal Acquisition
    print "▶ Stage 1: Signal Acquisition"
    print $"  Duration: ($duration)"
    print $"  Simulated: ($simulate)"
    print ""
    
    let signal_result = (signal acquire --duration $duration --simulate $simulate)
    
    print $"  ✓ Acquired ($signal_result.metadata.sample_count) samples"
    print ""
    
    # Stage 2: Signal Preprocessing
    print "▶ Stage 2: Signal Preprocessing"
    
    let preprocessed = ($signal_result.samples | signal preprocess --remove-dc --notch-freq 60)
    
    print "  ✓ Filtering complete"
    print ""
    
    # Stage 3: Signal Quality Check
    print "▶ Stage 3: Signal Quality Assessment"
    
    let quality = ($preprocessed | signal quality)
    
    print $"  Overall Quality: ($quality.overall_score | math round -p 2) [($quality.overall_status)]"
    print $"  Good Channels: ($quality.summary.good_channels)/($quality.channels | length)"
    print ""
    
    # Stage 4: World Projection
    print "▶ Stage 4: World Projection"
    print $"  Worlds: ($worlds | str join ', ')"
    print $"  Adaptive Selection: ($adaptive)"
    print ""
    
    let signal_data = {
        buffer: $preprocessed,
        quality: $quality,
        metadata: $signal_result.metadata
    }
    
    let world_projections = (worlds project $signal_data --worlds $worlds --adaptive $adaptive)
    
    for w in $worlds {
        let world_info = $world_projections.worlds | get $w
        let state = $world_info.projection.state
        print $"  World ($w | str upcase) [($world_info.name)]:"
        print $"    Focus: ($state.focus | math round -p 2)"
        print $"    Relaxation: ($state.relaxation | math round -p 2)"
        print $"    Confidence: ($world_info.confidence | math round -p 2)"
    }
    
    if $world_projections.selected_world? != null {
        print $"  → Selected World: ($world_projections.selected_world.selected_id | str upcase)"
    }
    print ""
    
    # Stage 5: Multi-World Fusion
    print "▶ Stage 5: Multi-World Fusion"
    print $"  Method: ($fusion_method)"
    print ""
    
    let fusion_result = match $fusion_method {
        "bayesian" => (fusion bayesian $world_projections),
        "dempster-shafer" => (fusion dempster-shafer $world_projections),
        "kalman" => (fusion kalman $world_projections),
        "consensus" => (fusion consensus $world_projections),
        "ensemble" => (fusion ensemble $world_projections),
        _ => (fusion ensemble $world_projections)
    }
    
    let fused_state = $fusion_result.state
    
    print "  Fused Cognitive State:"
    print $"    Arousal: ($fused_state.arousal | math round -p 2)"
    print $"    Valence: ($fused_state.valence | math round -p 2)"
    print $"    Focus: ($fused_state.focus | math round -p 2)"
    print $"    Relaxation: ($fused_state.relaxation | math round -p 2)"
    print $"    Cognitive Load: ($fused_state.cognitive_load | math round -p 2)"
    print $"    Fatigue: ($fused_state.fatigue | math round -p 2)"
    print ""
    print $"  Fusion Confidence: ($fusion_result.confidence | math round -p 2)"
    
    if $fusion_method == "ensemble" and $fusion_result.agreement_score? != null {
        print $"  Method Agreement: ($fusion_result.agreement_score | math round -p 2)"
    }
    print ""
    
    # Stage 6: Signal-World Bridge
    print "▶ Stage 6: Signal-World Bridge"
    
    let bridge_result = (bridge signal-to-world $signal_data)
    
    print $"  Mapping Confidence: ($bridge_result.confidence | math round -p 2)"
    print ""
    
    # Final Output
    print "╔══════════════════════════════════════════════════════════════╗"
    print "║                    Pipeline Complete                         ║"
    print "╚══════════════════════════════════════════════════════════════╝"
    print ""
    
    # Return structured output for next stage
    {
        stage: "signal-worlds-fusion",
        timestamp: (date now),
        input: {
            duration: $duration,
            samples_acquired: $signal_result.metadata.sample_count,
            signal_quality: $quality.overall_score
        },
        worlds: $world_projections.worlds,
        selected_world: $world_projections.selected_world,
        fusion: {
            method: $fusion_method,
            state: $fused_state,
            confidence: $fusion_result.confidence,
            uncertainty: $fusion_result.uncertainty?,
            full_result: $fusion_result
        },
        bridge: $bridge_result,
        output: {
            cognitive_state: $fused_state,
            confidence: $fusion_result.confidence,
            ready_for_learning: ($fusion_result.confidence > 0.5)
        }
    }
}

# Quick test of the cognitive pipeline
export def "cognitive demo" [
    --quick: bool = false
]: [ nothing -> record ] {
    let duration = if $quick { 5sec } else { 10sec }
    
    cognitive pipeline --duration $duration --simulate true --fusion-method ensemble
}

# Show cognitive module information
export def "cognitive info" [] {
    {
        name: "cognitive",
        version: "0.1.0",
        description: "Signal → Worlds → Fusion pipeline for cognitive architecture",
        stages: [
            { name: "signal", description: "Signal acquisition and preprocessing", rate_hz: 250 },
            { name: "worlds", description: "Multi-world projection (a://, b://, c://)", variants: ["baseline", "enhanced", "experimental"] },
            { name: "fusion", description: "Multi-world sensor fusion", methods: ["bayesian", "dempster-shafer", "kalman", "consensus", "ensemble"] },
            { name: "bridge", description: "Signal-world bidirectional bridge", rates: {signal: 250, world: 30} }
        ],
        commands: [
            "cognitive pipeline",
            "cognitive demo",
            "cognitive info"
        ]
    }
}

# Export module info
export def module-info [] {
    cognitive info
}
