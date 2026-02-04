# OpenBCI Configuration Module
# Manages configuration files and settings

const DEFAULT_CONFIG = {
    version: "0.2.0"
    default_port: null
    default_sample_rate: 250
    default_channels: 8
    default_duration: "60sec"
    default_output_format: "csv"
    default_viz_mode: "terminal"
    
    # Streaming settings
    streaming: {
        buffer_size: 256
        packet_timeout_ms: 1000
        reconnect_attempts: 3
        impedance_check_interval_sec: 30
    }
    
    # Recording settings
    recording: {
        default_directory: "~/openbci_recordings"
        auto_save_metadata: true
        compression: "none"
        edf_physical_max: 32767
        edf_physical_min: -32768
    }
    
    # Visualization settings
    visualization: {
        terminal_width: 80
        terminal_height: 24
        refresh_rate_hz: 10
        color_scheme: "default"
        show_legend: true
    }
    
    # Analysis settings
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
    
    # Device settings
    device: {
        auto_connect: false
        preferred_board: null  # "cyton", "daisy", "ganglion"
        cyton_baud_rate: 115200
        ganglion_ble_timeout_sec: 10
        default_board_mode: "default"
    }
    
    # Hypergraph integration
    hypergraph: {
        enabled: false
        socket_path: "~/.config/openbci/hypergraph.sock"
        default_graph: "eeg_sessions"
        auto_sync: false
    }
    
    # Pipeline settings
    pipelines: {
        default_pipeline: null
        auto_save_logs: true
        log_directory: "~/.config/openbci/pipeline_logs"
        max_concurrent: 4
    }
}

# Get configuration directory
def config-dir []: [ nothing -> path ] {
    $nu.home-path | path join ".config" "openbci"
}

# Get configuration file path
def config-file []: [ nothing -> path ] {
    config-dir | path join "config.nuon"
}

# Get current configuration
def get-config []: [ nothing -> record ] {
    let file = (config-file)
    if ($file | path exists) {
        try {
            open $file
        } catch {
            $DEFAULT_CONFIG
        }
    } else {
        $DEFAULT_CONFIG
    }
}

# Save configuration
def save-config [config: record]: [ nothing -> nothing ] {
    let dir = (config-dir)
    mkdir $dir
    $config | save -f (config-file)
}

# Configuration management commands
#
# Usage:
#   openbci config init              # Create default configuration
#   openbci config get <key>         # Read config value
#   openbci config set <key> <value> # Update config value
#   openbci config edit              # Open in $EDITOR
#   openbci config show              # Show current config
export def "main config" []: [ nothing -> string ] {
    $"OpenBCI Configuration Management

USAGE:
    openbci config <subcommand> [args]

SUBCOMMANDS:
    init       Create default configuration file
    get        Get a configuration value
    set        Set a configuration value
    edit       Open configuration in $EDITOR
    show       Show current configuration
    reset      Reset to default configuration
    validate   Validate configuration

EXAMPLES:
    openbci config init
    openbci config get default_sample_rate
    openbci config set default_sample_rate 500
    openbci config set device.preferred_board cyton
    openbci config edit
"
}

# Initialize default configuration
export def "main config init" [
    --force(-f)  # Overwrite existing config
]: [ nothing -> record ] {
    let file = (config-file)
    
    if ($file | path exists) and (not $force) {
        print "Configuration already exists. Use --force to overwrite."
        return (get-config)
    }
    
    mkdir (config-dir)
    $DEFAULT_CONFIG | save -f $file
    
    print $"Configuration initialized at ($file)"
    print "Edit with: openbci config edit"
    
    $DEFAULT_CONFIG
}

# Get configuration value
export def "main config get" [
    key?: string  # Configuration key (dot notation, e.g., 'streaming.buffer_size')
]: [ nothing -> any ] {
    let config = (get-config)
    
    if $key == null {
        # Show all config
        $config
    } else {
        # Navigate nested keys
        let parts = ($key | split ".")
        mut value = $config
        
        for part in $parts {
            if $part in $value {
                $value = ($value | get $part)
            } else {
                error make { msg: $"Configuration key '($key)' not found" }
            }
        }
        
        $value
    }
}

# Set configuration value
export def "main config set" [
    key: string       # Configuration key (dot notation)
    value: string     # Value to set
]: [ nothing -> record ] {
    let config = (get-config)
    let parts = ($key | split ".")
    
    # Parse value
    let parsed_value = (parse_config_value $value)
    
    # Update nested value
    let new_config = (set_nested_value $config $parts $parsed_value)
    
    save-config $new_config
    
    print $"Set ($key) = ($parsed_value)"
    
    $new_config
}

# Parse configuration value to appropriate type
def parse_config_value [value: string]: [ nothing -> any ] {
    # Try integer
    if ($value | find -r '^-?\d+$' | is-not-empty) {
        $value | into int
    } else if ($value | find -r '^-?\d+\.\d+$' | is-not-empty) {
        # Float
        $value | into float
    } else if $value == "true" or $value == "false" {
        # Boolean
        $value == "true"
    } else if ($value | str starts-with "[") and ($value | str ends-with "]") {
        # List
        $value | from nuon
    } else if ($value | str starts-with "{") and ($value | str ends-with "}") {
        # Record
        $value | from nuon
    } else {
        # String
        $value
    }
}

# Set nested value in record
def set_nested_value [record: record, path: list, value: any]: [ nothing -> record ] {
    if ($path | length) == 1 {
        $record | insert ($path | first) $value
    } else {
        let key = ($path | first)
        let rest = ($path | skip 1)
        let current = ($record | get -i $key | default {})
        let new_value = (set_nested_value $current $rest $value)
        $record | insert $key $new_value
    }
}

# Edit configuration in $EDITOR
export def "main config edit" []: [ nothing -> nothing ] {
    let file = (config-file)
    
    if not ($file | path exists) {
        print "No configuration found. Creating default..."
        main config init
    }
    
    let editor = ($env.EDITOR | default "nano")
    run-external $editor $file
    
    # Validate after edit
    try {
        let _ = (open $file)
        print "Configuration updated and validated."
    } catch { |e|
        print $"Error in configuration: ($e.msg)"
        print "Please fix the errors and try again."
    }
}

# Show current configuration
export def "main config show" []: [ nothing -> nothing ] {
    let config = (get-config)
    let file = (config-file)
    
    print $"Configuration file: ($file)"
    print ""
    
    print "\e[1mGeneral Settings\e[0m"
    print $"  Version: ($config.version)"
    print $"  Default Port: ($config.default_port | default 'not set')"
    print $"  Sample Rate: ($config.default_sample_rate) Hz"
    print $"  Channels: ($config.default_channels)"
    print $"  Output Format: ($config.default_output_format)"
    
    print ""
    print "\e[1mStreaming Settings\e[0m"
    print $"  Buffer Size: ($config.streaming.buffer_size)"
    print $"  Packet Timeout: ($config.streaming.packet_timeout_ms) ms"
    print $"  Reconnect Attempts: ($config.streaming.reconnect_attempts)"
    
    print ""
    print "\e[1mRecording Settings\e[0m"
    print $"  Default Directory: ($config.recording.default_directory)"
    print $"  Auto-save Metadata: ($config.recording.auto_save_metadata)"
    
    print ""
    print "\e[1mDevice Settings\e[0m"
    print $"  Auto-connect: ($config.device.auto_connect)"
    print $"  Preferred Board: ($config.device.preferred_board | default 'any')"
    print $"  Baud Rate: ($config.device.cyton_baud_rate)"
    
    print ""
    print "\e[1mHypergraph Integration\e[0m"
    print $"  Enabled: ($config.hypergraph.enabled)"
    print $"  Socket Path: ($config.hypergraph.socket_path)"
}

# Reset configuration to defaults
export def "main config reset" [
    --confirm: boolean = false  # Confirm reset
]: [ nothing -> record ] {
    if not $confirm {
        print "This will reset all configuration to defaults."
        print "Run with --confirm to proceed."
        return (get-config)
    }
    
    main config init --force
}

# Validate configuration
export def "main config validate" []: [ nothing -> record ] {
    let config = (get-config)
    mut errors = []
    mut warnings = []
    
    # Check required fields
    if ($config.version | is-empty) {
        $errors = ($errors | append "Missing version field")
    }
    
    # Validate sample rate
    if $config.default_sample_rate < 1 or $config.default_sample_rate > 16000 {
        $errors = ($errors | append "Invalid default_sample_rate (must be 1-16000)")
    }
    
    # Validate channels
    if $config.default_channels < 1 or $config.default_channels > 16 {
        $errors = ($errors | append "Invalid default_channels (must be 1-16)")
    }
    
    # Validate streaming settings
    if $config.streaming.buffer_size < 1 {
        $errors = ($errors | append "Invalid streaming.buffer_size")
    }
    
    # Validate output format
    let valid_formats = [csv parquet edf json jsonl]
    if not ($config.default_output_format in $valid_formats) {
        $warnings = ($warnings | append $"Unusual output format: ($config.default_output_format)")
    }
    
    # Check for unknown keys
    let known_keys = ($DEFAULT_CONFIG | columns)
    for key in ($config | columns) {
        if not ($key in $known_keys) {
            $warnings = ($warnings | append $"Unknown configuration key: ($key)")
        }
    }
    
    # Results
    let result = {
        valid: ($errors | is-empty)
        errors: $errors
        warnings: $warnings
        config_version: $config.version
    }
    
    if $result.valid {
        print "✓ Configuration is valid"
        if ($warnings | is-not-empty) {
            print "\nWarnings:"
            for warning in $warnings {
                print $"  ! ($warning)"
            }
        }
    } else {
        print "✗ Configuration has errors:"
        for error in $errors {
            print $"  ✗ ($error)"
        }
    }
    
    $result
}

# Import configuration from file
export def "main config import" [
    source: path  # Source configuration file
]: [ nothing -> record ] {
    if not ($source | path exists) {
        error make { msg: $"Source file not found: ($source)" }
    }
    
    let imported = (open $source)
    save-config $imported
    
    print $"Configuration imported from ($source)"
    
    # Validate
    main config validate
    
    $imported
}

# Export configuration to file
export def "main config export" [
    destination: path  # Destination file
]: [ nothing -> nothing ] {
    let config = (get-config)
    $config | save -f $destination
    print $"Configuration exported to ($destination)"
}

# Get configuration value with default
def get-config-value [key: string, default: any = null]: [ nothing -> any ] {
    let config = (get-config)
    let parts = ($key | split ".")
    
    mut value = $config
    for part in $parts {
        if $part in $value {
            $value = ($value | get $part)
        } else {
            return $default
        }
    }
    
    $value
}

# List all available configuration keys
export def "main config keys" []: [ nothing -> table ] {
    let keys = [
        [key category description default_value];
        
        [version general "Configuration version" "0.2.0"]
        [default_port general "Default serial port" null]
        [default_sample_rate general "Default sample rate in Hz" 250]
        [default_channels general "Default number of channels" 8]
        [default_duration general "Default recording duration" "60sec"]
        [default_output_format general "Default file format" "csv"]
        [default_viz_mode general "Default visualization mode" "terminal"]
        
        [streaming.buffer_size streaming "Samples per buffer" 256]
        [streaming.packet_timeout_ms streaming "Packet timeout" 1000]
        [streaming.reconnect_attempts streaming "Reconnection attempts" 3]
        [streaming.impedance_check_interval_sec streaming "Impedance check interval" 30]
        
        [recording.default_directory recording "Default save location" "~/openbci_recordings"]
        [recording.auto_save_metadata recording "Save metadata with recordings" true]
        [recording.compression recording "File compression" "none"]
        
        [visualization.terminal_width visualization "Terminal width" 80]
        [visualization.terminal_height visualization "Terminal height" 24]
        [visualization.refresh_rate_hz visualization "Display refresh rate" 10]
        [visualization.color_scheme visualization "Color scheme" "default"]
        
        [device.auto_connect device "Auto-connect on startup" false]
        [device.preferred_board device "Preferred board type" null]
        [device.cyton_baud_rate device "Cyton baud rate" 115200]
        [device.ganglion_ble_timeout_sec device "Ganglion BLE timeout" 10]
        
        [hypergraph.enabled hypergraph "Enable hypergraph integration" false]
        [hypergraph.socket_path hypergraph "Hypergraph socket path" "~/.config/openbci/hypergraph.sock"]
        [hypergraph.default_graph hypergraph "Default graph name" "eeg_sessions"]
    ]
    
    $keys
}

# Interactive configuration wizard
export def "main config wizard" []: [ nothing -> record ] {
    print "OpenBCI Configuration Wizard"
    print ""
    
    mut config = (get-config)
    
    # Sample rate
    print "1. Default Sample Rate (Hz)"
    print "   Common values: 250 (Cyton), 200 (Ganglion), 1000 (high-speed)"
    let sample_rate = (input "Sample rate [250]: ") | default "250" | into int
    $config = ($config | insert default_sample_rate $sample_rate)
    
    # Channels
    print ""
    print "2. Default Number of Channels"
    print "   Cyton: 8, Cyton+Daisy: 16, Ganglion: 4"
    let channels = (input "Channels [8]: ") | default "8" | into int
    $config = ($config | insert default_channels $channels)
    
    # Output format
    print ""
    print "3. Default Output Format"
    print "   Options: csv, parquet, edf, json"
    let format = (input "Format [csv]: ") | default "csv"
    $config = ($config | insert default_output_format $format)
    
    # Recording directory
    print ""
    print "4. Default Recording Directory"
    let rec_dir = (input "Directory [~/openbci_recordings]: ") | default "~/openbci_recordings"
    $config = ($config | insert recording.default_directory $rec_dir)
    
    # Auto-connect
    print ""
    print "5. Auto-connect to first available device?"
    let auto_connect = (input "Auto-connect [false]: ") | default "false" | $in == "true"
    $config = ($config | insert device.auto_connect $auto_connect)
    
    # Preferred board
    print ""
    print "6. Preferred Board Type"
    print "   Options: cyton, daisy, ganglion, (empty for auto)"
    let board = (input "Preferred board []: ")
    $config = ($config | insert device.preferred_board (if $board == "" { null } else { $board }))
    
    # Save
    print ""
    print "Saving configuration..."
    save-config $config
    
    print "✓ Configuration saved!"
    
    $config
}
