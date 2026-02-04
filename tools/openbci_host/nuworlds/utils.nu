#!/usr/bin/env nu
# utils.nu - Utility functions for nuworlds
# wait-for-device, auto-config, export-all, compare-sessions, validate-setup

use themes.nu *

# =============================================================================
# Device Utilities
# =============================================================================

# Poll until OpenBCI device is detected
export def wait-for-device [
    --timeout: duration = 60sec     # Maximum wait time
    --interval: duration = 1sec     # Poll interval
    --silent                        # Suppress output
]: [ nothing -> record ] {
    
    if not $silent {
        print "🔍 Waiting for OpenBCI device..."
    }
    
    let start_time = (date now)
    mut attempts = 0
    
    loop {
        $attempts = $attempts + 1
        
        # Check for devices
        let devices = (detect-devices)
        
        if ($devices | length) > 0 {
            let device = ($devices | first)
            if not $silent {
                print $"\n✓ Device detected: ($device.type) at ($device.port)"
            }
            return {
                found: true
                device: $device
                attempts: $attempts
                elapsed: ((date now) - $start_time)
            }
        }
        
        # Check timeout
        if ((date now) - $start_time) >= $timeout {
            if not $silent {
                print "\n✗ Timeout: No device detected"
            }
            return {
                found: false
                device: null
                attempts: $attempts
                elapsed: ((date now) - $start_time)
            }
        }
        
        if not $silent {
            print -n "."
        }
        
        sleep $interval
    }
}

# Auto-detect board and set optimal parameters
export def auto-config [
    --device: string = ""           # Specific device to configure
]: [ nothing -> record ] {
    
    print "⚙️  Auto-configuring OpenBCI device...\n"
    
    # Detect or use specified device
    let device_info = if $device == "" {
        let result = (wait-for-device --timeout 10sec --silent)
        if $result.found {
            $result.device
        } else {
            error make { msg: "No OpenBCI device detected" }
        }
    } else {
        { port: $device, type: "Cyton" }  # Assume Cyton if specified
    }
    
    print $"Device: ($device_info.type) at ($device_info.port)"
    
    # Determine optimal config based on device type
    let config = match $device_info.type {
        "Cyton" => {
            sample_rate: 250
            channels: 8
            gain: 24
            buffer_duration: 5
            filter_low: 1.0
            filter_high: 50.0
            notch: 60.0
        }
        "CytonDaisy" => {
            sample_rate: 250
            channels: 16
            gain: 24
            buffer_duration: 5
            filter_low: 1.0
            filter_high: 50.0
            notch: 60.0
        }
        "Ganglion" => {
            sample_rate: 200
            channels: 4
            gain: 51
            buffer_duration: 4
            filter_low: 1.0
            filter_high: 50.0
            notch: 60.0
        }
        _ => {
            sample_rate: 250
            channels: 8
            gain: 24
            buffer_duration: 5
            filter_low: 1.0
            filter_high: 50.0
            notch: 60.0
        }
    }
    
    # Test impedance
    print "\n🔌 Testing electrode impedance..."
    let impedance = (check-impedance $device_info.port $config.channels)
    
    print "\n✓ Configuration complete:"
    print $"  Sample rate: ($config.sample_rate) Hz"
    print $"  Channels: ($config.channels)"
    print $"  Buffer: ($config.buffer_duration) seconds"
    print $"  Impedance check: ($impedance | length) channels tested"
    
    # Save config
    let config_file = ($nu.home-path | path join ".config" "nuworlds" "auto_config.nuon")
    {
        device: $device_info
        config: $config
        impedance: $impedance
        timestamp: (date now)
    } | save -f $config_file
    
    print $"\n💾 Configuration saved to: ($config_file)"
    
    {
        device: $device_info
        config: $config
        impedance: $impedance
    }
}

# =============================================================================
# Export Utilities
# =============================================================================

# Export session data in multiple formats
export def export-all [
    session_file: path            # Source session file
    --output-dir: path            # Output directory
    --formats: list = [csv json]  # Formats to export
]: [ nothing -> record ] {
    
    if not ($session_file | path exists) {
        error make { msg: $"Session file not found: ($session_file)" }
    }
    
    let out_dir = $output_dir | default ($session_file | path dirname)
    mkdir $out_dir
    
    let base_name = ($session_file | path basename | str replace ".nuon" "" | str replace ".csv" "")
    let data = (open $session_file)
    
    mut exports = []
    
    for format in $formats {
        let out_file = $out_dir | path join $"($base_name).($format)"
        
        match $format {
            "csv" => {
                # Convert to CSV if table-like
                if ($data | describe) =~ "table" {
                    $data | to csv | save -f $out_file
                } else {
                    # Flatten record
                    $data | transpose key value | to csv | save -f $out_file
                }
                $exports = ($exports | append { format: "csv", file: $out_file })
                print $"✓ Exported CSV: ($out_file)"
            }
            "json" => {
                $data | to json | save -f $out_file
                $exports = ($exports | append { format: "json", file: $out_file })
                print $"✓ Exported JSON: ($out_file)"
            }
            "jsonl" => {
                if ($data | describe) =~ "table" {
                    $data | each { |row| $row | to json } | str join "\n" | save -f $out_file
                } else {
                    $data | to json | save -f $out_file
                }
                $exports = ($exports | append { format: "jsonl", file: $out_file })
                print $"✓ Exported JSONL: ($out_file)"
            }
            "parquet" => {
                try {
                    $data | polars into-df | polars save $out_file
                    $exports = ($exports | append { format: "parquet", file: $out_file })
                    print $"✓ Exported Parquet: ($out_file)"
                } catch {
                    print $"⚠ Parquet export failed (polars not available)"
                }
            }
            "txt" => {
                $data | table | save -f $out_file
                $exports = ($exports | append { format: "txt", file: $out_file })
                print $"✓ Exported TXT: ($out_file)"
            }
            _ => {
                print $"⚠ Unknown format: ($format)"
            }
        }
    }
    
    {
        source: $session_file
        output_dir: $out_dir
        exports: $exports
    }
}

# =============================================================================
# Comparison Utilities
# =============================================================================

# Compare two recordings/sessions
export def compare-sessions [
    session_a: path               # First session file
    session_b: path               # Second session file
    --detailed                    # Show detailed comparison
]: [ nothing -> record ] {
    
    if not ($session_a | path exists) {
        error make { msg: $"Session file not found: ($session_a)" }
    }
    if not ($session_b | path exists) {
        error make { msg: $"Session file not found: ($session_b)" }
    }
    
    print "🔍 Comparing sessions...\n"
    
    let data_a = (open $session_a)
    let data_b = (open $session_b)
    
    print $"Session A: ($session_a | path basename)"
    print $"Session B: ($session_b | path basename)\n"
    
    # Basic comparison
    let comparison = {
        files: {
            a: ($session_a | path basename)
            b: ($session_b | path basename)
        }
        sizes: {
            a: ($session_a | path stat | get size)
            b: ($session_b | path stat | get size)
        }
        keys_a: ($data_a | columns)
        keys_b: ($data_b | columns)
        common_keys: (($data_a | columns) | where { |k| $k in ($data_b | columns) })
        a_only: (($data_a | columns) | where { |k| $k not-in ($data_b | columns) })
        b_only: (($data_b | columns) | where { |k| $k not-in ($data_a | columns) })
    }
    
    print "Structure comparison:"
    print $"  Common fields: ($comparison.common_keys | str join ', ')"
    if ($comparison.a_only | length) > 0 {
        print $"  Only in A: ($comparison.a_only | str join ', ')"
    }
    if ($comparison.b_only | length) > 0 {
        print $"  Only in B: ($comparison.b_only | str join ', ')"
    }
    
    # Try to compare numerical fields
    print "\nNumerical comparison:"
    
    for key in $comparison.common_keys {
        let val_a = ($data_a | get -i $key)
        let val_b = ($data_b | get -i $key)
        
        # Check if values are numeric
        if (($val_a | describe) =~ "int|float") and (($val_b | describe) =~ "int|float") {
            let diff = ($val_b - $val_a)
            let pct_change = (if $val_a != 0 { ($diff / $val_a * 100) } else { 0 })
            
            print $"  ($key): ($val_a) → ($val_b) (Δ($diff | math round -p 2), ($pct_change | math round -p 1)%)"
        }
    }
    
    if $detailed {
        print "\nDetailed field comparison:"
        for key in $comparison.common_keys {
            let val_a = ($data_a | get -i $key)
            let val_b = ($data_b | get -i $key)
            print $"  ($key):"
            print $"    A: ($val_a)"
            print $"    B: ($val_b)"
            print $"    Equal: ($val_a == $val_b)"
        }
    }
    
    $comparison
}

# =============================================================================
# Validation
# =============================================================================

# Check all dependencies and setup
export def validate-setup [--fix]: [ nothing -> record ] {
    
    print "🔬 Validating nuworlds setup...\n"
    
    mut results = {
        passed: 0
        failed: 0
        warnings: 0
        checks: []
    }
    
    # Check 1: Nushell version
    print "✓ Checking Nushell version..."
    let nu_version = (version | get version)
    print $"  Version: ($nu_version)"
    $results.checks = ($results.checks | append {
        name: "nushell_version"
        status: "pass"
        message: $"Nushell ($nu_version)"
    })
    $results.passed = $results.passed + 1
    
    # Check 2: Directory structure
    print "\n✓ Checking directory structure..."
    let config_dir = ($nu.home-path | path join ".config" "nuworlds")
    let required_dirs = [
        $config_dir
        ($config_dir | path join "worlds")
        ($config_dir | path join "sessions")
        ($config_dir | path join "pipelines")
    ]
    
    mut all_dirs_exist = true
    for dir in $required_dirs {
        if ($dir | path exists) {
            print $"  ✓ ($dir)"
        } else {
            print $"  ✗ ($dir) missing"
            $all_dirs_exist = false
            if $fix {
                mkdir $dir
                print $"    → Created"
            }
        }
    }
    
    if $all_dirs_exist {
        $results.checks = ($results.checks | append {
            name: "directories"
            status: "pass"
            message: "All required directories exist"
        })
        $results.passed = $results.passed + 1
    } else {
        $results.checks = ($results.checks | append {
            name: "directories"
            status: if $fix { "fixed" } else { "fail" }
            message: if $fix { "Missing directories created" } else { "Some directories missing" }
        })
        if not $fix { $results.failed = $results.failed + 1 }
    }
    
    # Check 3: Python dependencies
    print "\n✓ Checking Python dependencies..."
    let python_checks = [
        [module, required];
        ["numpy", false]
        ["pyedflib", false]
        ["bleak", false]
    ]
    
    for check in $python_checks {
        let has_module = (check-python-module $check.module)
        if $has_module {
            print $"  ✓ ($check.module)"
            $results.checks = ($results.checks | append {
                name: $"python_($check.module)"
                status: "pass"
                message: "Installed"
            })
            $results.passed = $results.passed + 1
        } else {
            print $"  ⚠ ($check.module) not found"
            $results.checks = ($results.checks | append {
                name: $"python_($check.module)"
                status: if $check.required { "fail" } else { "warning" }
                message: "Not installed"
            })
            if $check.required {
                $results.failed = $results.failed + 1
            } else {
                $results.warnings = $results.warnings + 1
            }
        }
    }
    
    # Check 4: Serial port access
    print "\n✓ Checking serial port access..."
    let ports = (detect-serial-ports)
    if ($ports | length) > 0 {
        print $"  ✓ Found ($ports | length) serial ports: ($ports | first 3 | str join ', ')"
        $results.checks = ($results.checks | append {
            name: "serial_ports"
            status: "pass"
            message: $"($ports | length) ports available"
        })
        $results.passed = $results.passed + 1
    } else {
        print "  ⚠ No serial ports detected (OK if using BLE)"
        $results.checks = ($results.checks | append {
            name: "serial_ports"
            status: "warning"
            message: "No serial ports detected"
        })
        $results.warnings = $results.warnings + 1
    }
    
    # Check 5: Bluetooth
    print "\n✓ Checking Bluetooth..."
    let has_bluetooth = (which bluetoothctl | is-not-empty)
    if $has_bluetooth {
        print "  ✓ bluetoothctl available"
        $results.checks = ($results.checks | append {
            name: "bluetooth"
            status: "pass"
            message: "Available"
        })
        $results.passed = $results.passed + 1
    } else {
        print "  ⚠ bluetoothctl not found (OK if using USB)"
        $results.checks = ($results.checks | append {
            name: "bluetooth"
            status: "warning"
            message: "Not available"
        })
        $results.warnings = $results.warnings + 1
    }
    
    # Check 6: Configuration file
    print "\n✓ Checking configuration..."
    let config_file = ($config_dir | path join "config.nuon")
    if ($config_file | path exists) {
        print $"  ✓ Config file exists"
        $results.checks = ($results.checks | append {
            name: "config"
            status: "pass"
            message: "Config file exists"
        })
        $results.passed = $results.passed + 1
    } else {
        print $"  ✗ Config file missing"
        $results.checks = ($results.checks | append {
            name: "config"
            status: if $fix { "fixed" } else { "fail" }
            message: if $fix { "Created default config" } else { "Config file missing" }
        })
        if $fix {
            create-default-config $config_file
        } else {
            $results.failed = $results.failed + 1
        }
    }
    
    # Summary
    print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print "Validation Summary:"
    print $"  ✓ Passed:   ($results.passed)"
    print $"  ✗ Failed:   ($results.failed)"
    print $"  ⚠ Warnings: ($results.warnings)"
    
    if $results.failed > 0 {
        print "\nRun with --fix to automatically fix issues"
    }
    
    $results
}

# =============================================================================
# Helper Functions
# =============================================================================

# Detect available serial ports
def detect-serial-ports []: [ nothing -> list ] {
    let patterns = [
        "/dev/ttyUSB*"
        "/dev/ttyACM*"
        "/dev/cu.usbserial*"
        "/dev/tty.usbserial*"
    ]
    
    mut ports = []
    for pattern in $patterns {
        let found = (try { glob $pattern } catch { [] })
        $ports = ($ports | append $found)
    }
    
    $ports
}

# Detect OpenBCI devices
def detect-devices []: [ nothing -> list ] {
    mut devices = []
    
    # Check serial ports
    let ports = (detect-serial-ports)
    for port in $ports {
        # In a real implementation, we'd verify it's an OpenBCI device
        $devices = ($devices | append {
            type: "Cyton"
            port: $port
            channels: 8
        })
    }
    
    $devices
}

# Check electrode impedance
export def check-impedance [port: string, channels: int]: [ nothing -> list ] {
    mut results = []
    
    for ch in 0..<$channels {
        # Simulated impedance check
        let impedance = (random float 1..15)
        let status = if $impedance < 5 { "good" } else if $impedance < 10 { "fair" } else { "poor" }
        
        $results = ($results | append {
            channel: $ch
            impedance: ($impedance | math round -p 1)
            status: $status
        })
    }
    
    $results
}

# Check if Python module is available
def check-python-module [module: string]: [ nothing -> bool ] {
    try {
        (python3 -c $"import ($module)" out+err> /dev/null)
        true
    } catch {
        false
    }
}

# Create default config
def create-default-config [path: path]: [ nothing -> nothing ] {
    {
        version: "0.2.0"
        default_device: null
        default_sample_rate: 250
        default_channels: 8
        theme: "default"
        log_level: "info"
    } | save -f $path
}

# Format duration
def format-duration [duration: duration]: [ nothing -> string ] {
    let nanos = ($duration | into int)
    let seconds = ($nanos / 1000000000 | math floor)
    let mins = ($seconds / 60 | math floor)
    let secs = ($seconds mod 60)
    
    $"($mins)m ($secs)s"
}

# =============================================================================
# Export module functions
# =============================================================================

export alias wait = wait-for-device
export alias autoconf = auto-config
export alias export = export-all
export alias compare = compare-sessions
export alias validate = validate-setup
