#!/usr/bin/env nu
# Installation script for OpenBCI Nushell CLI

export def main [
    --config-dir: path = "~/.config/nushell"  # Nushell config directory
    --skip-deps: bool                         # Skip dependency checks
]: [ nothing -> nothing ] {
    
    print "╔══════════════════════════════════════════╗"
    print "║     OpenBCI Nushell CLI Installer        ║"
    print "╚══════════════════════════════════════════╝"
    print ""
    
    let config_path = ($config_dir | path expand)
    let module_path = ($config_path | path join "openbci")
    
    # Check if running from correct directory
    if not ("openbci.nu" | path exists) {
        print "Error: Please run this script from the nuworlds directory"
        exit 1
    }
    
    # Check nushell version
    print "Checking nushell version..."
    let nu_version = (version | get version)
    print $"  Found: ($nu_version)"
    
    if not $skip_deps {
        # Check dependencies
        print ""
        print "Checking dependencies..."
        
        let python_available = (which python3 | is-not-empty)
        print $"  Python 3: (if $python_available { '✓' } else { '✗ (optional, for EDF export)' })"
        
        if $python_available {
            let pyedflib_check = (try { python3 -c "import pyedflib" | complete })
            let pyedflib_available = ($pyedflib_check.exit_code == 0)
            print $"  pyedflib: (if $pyedflib_available { '✓' } else { '✗ (optional, for EDF export)' })"
        }
        
        let polars_available = (try { "test" | polars into-df | complete } | get exit_code) == 0
        print $"  polars: (if $polars_available { '✓' } else { '✗ (optional, for Parquet support)' })"
    }
    
    # Create module directory
    print ""
    print $"Installing to ($module_path)..."
    mkdir $module_path
    
    # Copy files
    cp *.nu $module_path
    cp README.nu.md $module_path
    
    # Create config directory
    let openbci_config = ($nu.home-path | path join ".config" "openbci")
    mkdir $openbci_config
    mkdir ($openbci_config | path join "pipelines")
    mkdir ($openbci_config | path join "pipeline_logs")
    mkdir ($nu.home-path | path join "openbci_recordings")
    
    # Generate completions
    print ""
    print "Generating shell completions..."
    let completions_path = ($openbci_config | path join "completions.nu")
    
    # Create completions file
    let completions = $"# OpenBCI Nushell Completions
# Source this in your config.nu

export extern 'openbci' [
    command?: string
    --help(-h)
]

export extern 'openbci device' [
    subcommand?: string
]

export extern 'openbci stream' [
    --channels(-c): string
    --duration(-d): duration
    --format(-f): string
    --filter: string
]

export extern 'openbci record' [
    --output(-o): path
    --duration(-d): duration
    --format: string
]

export extern 'openbci analyze' [
    file: path
    --bands(-b)
    --psd(-p)
    --coherence(-c)
    --features(-f)
]

export extern 'openbci viz' [
    --mode(-m): string
    --channels: string
]

export extern 'openbci config' [
    subcommand?: string
]

export extern 'openbci pipeline' [
    subcommand?: string
]
"
    
    $completions | save -f $completions_path
    print $"  Saved to ($completions_path)"
    
    # Create default config
    print ""
    print "Creating default configuration..."
    
    let default_config = {
        version: "0.2.0"
        default_port: null
        default_sample_rate: 250
        default_channels: 8
        default_duration: "60sec"
        default_output_format: "csv"
        default_viz_mode: "terminal"
        streaming: {
            buffer_size: 256
            packet_timeout_ms: 1000
            reconnect_attempts: 3
            impedance_check_interval_sec: 30
        }
        recording: {
            default_directory: "~/openbci_recordings"
            auto_save_metadata: true
            compression: "none"
            edf_physical_max: 32767
            edf_physical_min: -32768
        }
        visualization: {
            terminal_width: 80
            terminal_height: 24
            refresh_rate_hz: 10
            color_scheme: "default"
            show_legend: true
        }
        analysis: {
            default_window_size: 256
            default_overlap: 0.5
            band_definitions: {
                delta: { min: 0.5, max: 4.0 }
                theta: { min: 4.0, max: 8.0 }
                alpha: { min: 8.0, max: 13.0 }
                beta: { min: 13.0, max: 30.0 }
                gamma: { min: 30.0, max: 50.0 }
            }
        }
        device: {
            auto_connect: false
            preferred_board: null
            cyton_baud_rate: 115200
            ganglion_ble_timeout_sec: 10
            default_board_mode: "default"
        }
        hypergraph: {
            enabled: false
            socket_path: "~/.config/openbci/hypergraph.sock"
            default_graph: "eeg_sessions"
            auto_sync: false
        }
        pipelines: {
            default_pipeline: null
            auto_save_logs: true
            log_directory: "~/.config/openbci/pipeline_logs"
            max_concurrent: 4
        }
    }
    
    $default_config | save -f ($openbci_config | path join "config.nuon")
    print $"  Saved to ($openbci_config | path join "config.nuon")"
    
    # Installation complete
    print ""
    print "╔══════════════════════════════════════════╗"
    print "║     Installation Complete!               ║"
    print "╚══════════════════════════════════════════╝"
    print ""
    print "Next steps:"
    print ""
    print "1. Add to your config.nu:"
    print $"   use ($module_path) *"
    print ""
    print "2. Enable completions by adding to config.nu:"
    print $"   source ($completions_path)"
    print ""
    print "3. Reload nushell or run:"
    print "   source ~/.config/nushell/config.nu"
    print ""
    print "4. Test installation:"
    print "   openbci --help"
    print "   openbci device list"
    print "   openbci config show"
    print ""
    print "For more help: openbci --help"
    print "Documentation: ($module_path)/README.nu.md"
}

# Run installation if executed directly
if (is-main) {
    main
}
