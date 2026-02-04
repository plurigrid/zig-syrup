# init.nu
# Initialization script for nuworlds - Run on first use
# Detects system capabilities, creates configs, tests connections

const CONFIG_DIR = ($nu.home-path | path join ".config" "nuworlds")
const DATA_DIR = ($nu.home-path | path join ".local" "share" "nuworlds")
const SESSIONS_DIR = ($CONFIG_DIR | path join "sessions")
const WORLDS_DIR = ($CONFIG_DIR | path join "worlds")
const RECORDINGS_DIR = ($DATA_DIR | path join "recordings")
const PIPES_DIR = "/tmp/nuworlds"

# =============================================================================
# Main Initialization
# =============================================================================

export def main []: [ nothing -> record ] {
    print ""
    print "╔══════════════════════════════════════════════════════════════╗"
    print "║                nuworlds Initialization                       ║"
    print "║         OpenBCI + A/B World Testing Framework                ║"
    print "╚══════════════════════════════════════════════════════════════╝"
    print ""
    
    let start_time = (date now)
    mut results = {
        directories_created: []
        configs_generated: []
        capabilities: {}
        tests_passed: 0
        tests_failed: 0
        warnings: []
    }
    
    # Step 1: Create directories
    print "📁 Creating directories..."
    $results.directories_created = (create-directories)
    
    # Step 2: Detect capabilities
    print "\n🔍 Detecting system capabilities..."
    $results.capabilities = (detect-capabilities)
    
    # Step 3: Generate configs
    print "\n⚙️  Generating configuration files..."
    $results.configs_generated = (generate-configs $results.capabilities)
    
    # Step 4: Test connections
    print "\n🔌 Testing connections..."
    let test_results = (test-connections)
    $results.tests_passed = $test_results.passed
    $results.tests_failed = $test_results.failed
    $results.warnings = $test_results.warnings
    
    # Step 5: Generate shell configs
    print "\n🐚 Generating shell integration..."
    generate-shell-configs
    
    # Summary
    let duration = ((date now) - $start_time)
    
    print ""
    print "╔══════════════════════════════════════════════════════════════╗"
    print "║               Initialization Complete!                       ║"
    print "╚══════════════════════════════════════════════════════════════╝"
    print ""
    print $"📊 Summary:"
    print $"   Directories: ($results.directories_created | length) created"
    print $"   Config files: ($results.configs_generated | length) generated"
    print $"   Tests: ($results.tests_passed) passed, ($results.tests_failed) failed"
    print $"   Duration: ($duration | format-duration)"
    
    if ($results.warnings | length) > 0 {
        print "\n⚠️  Warnings:"
        for warning in $results.warnings {
            print $"   - ($warning)"
        }
    }
    
    print "\n🚀 Quick start:"
    print "   nuworlds demo        # Run interactive demo"
    print "   nuworlds repl        # Start interactive REPL"
    print "   nuworlds dashboard   # Launch real-time dashboard"
    print ""
    
    # Save init marker
    { 
        initialized_at: (date now)
        version: "0.2.0"
        capabilities: $results.capabilities
    } | save -f ($CONFIG_DIR | path join "initialized.nuon")
    
    $results
}

# =============================================================================
# Directory Creation
# =============================================================================

def create-directories []: [ nothing -> list ] {
    let dirs = [
        $CONFIG_DIR
        $DATA_DIR
        $SESSIONS_DIR
        $WORLDS_DIR
        $RECORDINGS_DIR
        $PIPES_DIR
        ($CONFIG_DIR | path join "pipelines")
        ($CONFIG_DIR | path join "themes")
        ($CONFIG_DIR | path join "hooks")
    ]
    
    mut created = []
    for dir in $dirs {
        mkdir $dir
        $created = ($created | append $dir)
        print $"   ✓ ($dir)"
    }
    
    $created
}

# =============================================================================
# Capability Detection
# =============================================================================

def detect-capabilities []: [ nothing -> record ] {
    {
        # System info
        os: (sys host | get name)
        arch: (sys host | get arch)
        
        # Hardware
        serial_ports: (detect-serial-ports)
        bluetooth: (which bluetoothctl | is-not-empty)
        
        # Software
        nushell_version: (version | get version)
        python3: (which python3 | is-not-empty)
        has_bleak: (check-python-module "bleak")
        has_numpy: (check-python-module "numpy")
        has_pyedflib: (check-python-module "pyedflib")
        
        # Network
        has_nc: (which nc | is-not-empty)
        has_socat: (which socat | is-not-empty)
        
        # Audio
        has_aplay: (which aplay | is-not-empty)
        has_afplay: (which afplay | is-not-empty)  # macOS
        
        # Visualization
        has_gnuplot: (which gnuplot | is-not-empty)
    }
}

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

# Check if Python module is available
def check-python-module [module: string]: [ nothing -> bool ] {
    try {
        (python3 -c $"import ($module)" out+err> /dev/null)
        true
    } catch {
        false
    }
}

# =============================================================================
# Config Generation
# =============================================================================

def generate-configs [caps: record]: [ nothing -> list ] {
    mut configs = []
    
    # Main config
    let main_config = {
        version: "0.2.0"
        default_device: null
        default_sample_rate: 250
        default_channels: 8
        data_dir: $DATA_DIR
        recordings_dir: $RECORDINGS_DIR
        auto_connect: true
        log_level: "info"
        theme: "default"
        
        # EEG processing defaults
        eeg: {
            lowcut: 1.0
            highcut: 50.0
            notch: 60.0
            window_size: 256
        }
        
        # Band definitions
        bands: {
            delta: { min: 0.5, max: 4.0, color: "blue" }
            theta: { min: 4.0, max: 8.0, color: "cyan" }
            alpha: { min: 8.0, max: 13.0, color: "green" }
            beta: { min: 13.0, max: 30.0, color: "yellow" }
            gamma: { min: 30.0, max: 50.0, color: "red" }
        }
        
        # Focus/relax detection thresholds
        thresholds: {
            focus_alpha_beta_ratio: 0.8
            relax_theta_alpha_ratio: 1.2
            artifact_threshold_uv: 500
        }
    }
    $main_config | save -f ($CONFIG_DIR | path join "config.nuon")
    $configs = ($configs | append "config.nuon")
    print "   ✓ config.nuon"
    
    # Device config
    let device_config = {
        cyton: {
            baud_rate: 115200
            channels: 8
            sample_rate: 250
            packet_size: 33
        }
        ganglion: {
            channels: 4
            sample_rate: 200
            ble_timeout: 10
        }
        daisy: {
            channels: 16
            sample_rate: 250
        }
    }
    $device_config | save -f ($CONFIG_DIR | path join "devices.nuon")
    $configs = ($configs | append "devices.nuon")
    print "   ✓ devices.nuon"
    
    # Workflow presets
    let workflow_presets = {
        meditation: {
            duration: 600sec
            feedback_interval: 30sec
            target_band: "alpha"
            min_duration: 300sec
        }
        focus_training: {
            duration: 300sec
            target_state: "focus"
            feedback_type: "visual"
            threshold: 0.8
        }
        sleep_study: {
            duration: 28800sec  # 8 hours
            auto_stop: true
            stage_detection: true
        }
        ab_test: {
            min_session_time: 60sec
            switch_interval: 300sec
            metrics: ["engagement", "focus", "satisfaction"]
        }
    }
    $workflow_presets | save -f ($CONFIG_DIR | path join "workflows.nuon")
    $configs = ($configs | append "workflows.nuon")
    print "   ✓ workflows.nuon"
    
    $configs
}

# =============================================================================
# Connection Tests
# =============================================================================

def test-connections []: [ nothing -> record ] {
    mut passed = 0
    mut failed = 0
    mut warnings = []
    
    # Test 1: Serial ports
    print "   Testing serial port access..."
    let serial_test = (test-serial-access)
    if $serial_test.success {
        print $"     ✓ Found ($serial_test.ports | length) serial ports"
        $passed = $passed + 1
    } else {
        print "     ⚠ No serial ports found (OK if using BLE)"
        $warnings = ($warnings | append "No serial ports detected")
    }
    
    # Test 2: Bluetooth
    print "   Testing Bluetooth availability..."
    if (which bluetoothctl | is-not-empty) {
        print "     ✓ bluetoothctl available"
        $passed = $passed + 1
    } else {
        print "     ⚠ bluetoothctl not found (OK if using USB)"
        $warnings = ($warnings | append "Bluetooth tools not available")
    }
    
    # Test 3: Python dependencies
    print "   Testing Python dependencies..."
    let python_ok = (which python3 | is-not-empty)
    if $python_ok {
        print "     ✓ Python 3 available"
        $passed = $passed + 1
        
        # Check modules
        let modules = [numpy pyedflib]
        for mod in $modules {
            if (check-python-module $mod) {
                print $"     ✓ ($mod) available"
                $passed = $passed + 1
            } else {
                print $"     ⚠ ($mod) not installed"
                $warnings = ($warnings | append $"Python module ($mod) missing")
            }
        }
    } else {
        print "     ✗ Python 3 not found"
        $failed = $failed + 1
        $warnings = ($warnings | append "Python 3 is required for some features")
    }
    
    # Test 4: Write permissions
    print "   Testing write permissions..."
    let test_file = ($CONFIG_DIR | path join ".write_test")
    try {
        "" | save -f $test_file
        rm $test_file
        print "     ✓ Write permissions OK"
        $passed = $passed + 1
    } catch {
        print "     ✗ Cannot write to config directory"
        $failed = $failed + 1
        $warnings = ($warnings | append "No write permission to config directory")
    }
    
    { passed: $passed, failed: $failed, warnings: $warnings }
}

# Test serial port access
def test-serial-access []: [ nothing -> record ] {
    let ports = (detect-serial-ports)
    {
        success: ($ports | length) > 0
        ports: $ports
    }
}

# =============================================================================
# Shell Config Generation
# =============================================================================

def generate-shell-configs []: [ nothing -> nothing ] {
    let nu_config = $"# nuworlds shell integration
# Add to your config.nu:
#   source ($CONFIG_DIR | path join "shell_integration.nu")

# Module path
export-env {
    $env.NUWORLDS_DIR = "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds"
    $env.NUWORLDS_CONFIG = "($CONFIG_DIR)"
}

# Aliases
export alias obs = openbci stream
export alias obr = openbci record
export alias oba = openbci analyze
export alias obv = openbci viz
export alias wab = world_ab
export alias mp3 = mp session new --players 3

# Completions
use ($env.NUWORLDS_DIR | path join "nuworlds.nu") *
"
    
    $nu_config | save -f ($CONFIG_DIR | path join "shell_integration.nu")
    print "   ✓ shell_integration.nu"
    
    print ""
    print "📋 To enable shell integration, add this to your config.nu:"
    print $"   source ($CONFIG_DIR | path join 'shell_integration.nu')"
}

# =============================================================================
# Utility Functions
# =============================================================================

def format-duration [duration: duration]: [ nothing -> string ] {
    let nanos = ($duration | into int)
    let seconds = ($nanos / 1000000000 | math floor)
    let mins = ($seconds / 60 | math floor)
    let secs = ($seconds mod 60)
    
    if $mins > 0 {
        $"($mins)m ($secs)s"
    } else {
        $"($secs)s"
    }
}

# Check if already initialized
export def is-initialized []: [ nothing -> bool ] {
    let marker = ($CONFIG_DIR | path join "initialized.nuon")
    $marker | path exists
}

# Reset initialization (for testing)
export def reset []: [ nothing -> nothing ] {
    print "⚠️  This will delete all nuworlds configuration and data!"
    print "Are you sure? [type 'yes' to confirm]"
    let confirm = (input)
    
    if $confirm == "yes" {
        rm -rf $CONFIG_DIR
        rm -rf $DATA_DIR
        print "✓ nuworlds configuration reset"
    } else {
        print "Cancelled"
    }
}

# Run if executed directly
if ($env.FILE_PWD? | default "") == ($env.CURRENT_FILE? | default "" | path dirname) {
    main
}
