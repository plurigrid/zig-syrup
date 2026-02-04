#!/usr/bin/env nu
# OpenBCI CLI - Main entry point for nushell
# A comprehensive command-line interface for OpenBCI brain-computer interface operations

use device *
use stream *
use record *
use analyze *
use viz *
use config *
use pipeline *

# Main OpenBCI CLI command
# 
# Usage:
#   openbci device list              # List connected devices
#   openbci stream                   # Start streaming data
#   openbci record --duration 60s    # Record data to file
#   openbci analyze session.csv      # Analyze recorded data
#   openbci viz --mode terminal      # Visualize in terminal
#   openbci config init              # Initialize configuration
#   openbci pipeline list            # List available pipelines
#
# Examples:
#   openbci stream | where ch1 > 100
#   openbci record --output brain.csv --duration 5min
#   openbci analyze recording.csv --bands | save bands.json
export def main []: [ nothing -> string ] {
    $"OpenBCI CLI for Nushell (version (version))

USAGE:
    openbci <command> [args]

COMMANDS:
    device      Manage OpenBCI devices (list, connect, info, impedance)
    stream      Stream EEG data to stdout or pipes
    record      Record EEG data to files (CSV, Parquet, EDF)
    analyze     Analyze recorded or live EEG data
    viz         Visualize data in terminal
    config      Manage configuration
    pipeline    Run and manage data processing pipelines
    complete    Generate shell completions
    version     Show version information
    status      Show system status

EXAMPLES:
    # List connected devices
    openbci device list

    # Stream from channel 0 and 1 for 60 seconds
    openbci stream --channels 0,1 --duration 60s

    # Record 5 minutes to CSV
    openbci record --output session.csv --duration 5min

    # Analyze and extract band powers
    openbci analyze recording.csv --bands

    # Real-time terminal visualization
    openbci viz --mode terminal

    # Run a processing pipeline
    openbci pipeline run alpha-detection

For more help on a command:
    openbci <command> --help
"
}

# Show version information
export def "main version" []: [ nothing -> record ] {
    {
        version: (version)
        nushell_version: (version | get version)
        build_date: "2025-01-27"
        supported_boards: [Cyton CytonDaisy Ganglion]
        features: [streaming recording analysis visualization pipelines]
    }
}

# Get module version
def version []: [ nothing -> string ] {
    "0.2.0"
}

# Show system status
export def "main status" []: [ nothing -> record ] {
    let config_file = ($nu.home-path | path join ".config" "openbci" "config.nuon")
    let config_exists = ($config_file | path exists)
    
    let default_port = if $config_exists {
        open $config_file | get -i default_port | default "not set"
    } else {
        "not set"
    }
    
    let python_available = (which python3 | is-not-empty)
    let pyedflib_available = if $python_available {
        (python3 -c "import pyedflib" out+err> /dev/null; echo $env.LAST_EXIT_CODE) == 0
    } else {
        false
    }
    
    {
        config_file: $config_file
        config_exists: $config_exists
        default_port: $default_port
        python_available: $python_available
        pyedflib_available: $pyedflib_available
        modules_loaded: [device stream record analyze viz config pipeline]
        hypergraph_connected: (check_hypergraph_connection)
    }
}

# Check if hypergraph backend is available
def check_hypergraph_connection []: [ nothing -> bool ] {
    # Check if the hypergraph service is running
    let sock_path = ($nu.home-path | path join ".config" "openbci" "hypergraph.sock")
    if ($sock_path | path exists) {
        # Try to ping the service
        try {
            echo '{"ping": true}' | nc -U $sock_path | is-not-empty
        } catch {
            false
        }
    } else {
        false
    }
}

# Generate shell completions
export def "main complete" [
    --shell: string = "nu"  # Shell type (nu, bash, zsh, fish)
]: [ nothing -> string ] {
    match $shell {
        "nu" => { generate_nu_completions }
        "bash" => { generate_bash_completions }
        "zsh" => { generate_zsh_completions }
        "fish" => { generate_fish_completions }
        _ => { error make { msg: $"Unknown shell: ($shell)" } }
    }
}

# Generate nushell completions
def generate_nu_completions []: [ nothing -> string ] {
$"# OpenBCI Nushell Completions
# Add to your config.nu: source ($nu.home-path)/.config/openbci/completions.nu

export extern 'openbci' [
    command?: string@'nu-complete openbci commands'
    --help(-h)
]

export extern 'openbci device' [
    subcommand?: string@'nu-complete device commands'
]

export extern 'openbci stream' [
    --channels(-c): string      # Channels to stream (e.g., '0,1,2')
    --duration(-d): duration    # Stream duration
    --format(-f): string@'nu-complete formats'  # Output format
    --filter: string            # Filter expression
    --sample-rate(-r): int      # Sample rate override
]

export extern 'openbci record' [
    --output(-o): path          # Output file path
    --duration(-d): duration    # Recording duration
    --format: string@'nu-complete record formats'
    --trigger: string           # Trigger event
]

export extern 'openbci analyze' [
    file: path
    --bands(-b)                 # Calculate band powers
    --psd(-p)                   # Power spectral density
    --coherence(-c)             # Inter-channel coherence
    --features(-f)              # Extract Hjorth parameters
]

export extern 'openbci viz' [
    --mode(-m): string@'nu-complete viz modes'
    --channels: string          # Channels to visualize
]

export extern 'openbci config' [
    subcommand?: string@'nu-complete config commands'
    key?: string
    value?: string
]

export extern 'openbci pipeline' [
    subcommand?: string@'nu-complete pipeline commands'
    name?: string@'nu-complete pipeline names'
]

def 'nu-complete openbci commands' []: [ nothing -> list<string> ] {
    [device stream record analyze viz config pipeline complete version status]
}

def 'nu-complete device commands' []: [ nothing -> list<string> ] {
    [list connect info impedance]
}

def 'nu-complete config commands' []: [ nothing -> list<string> ] {
    [init get set edit show]
}

def 'nu-complete pipeline commands' []: [ nothing -> list<string> ] {
    [list run create edit delete logs]
}

def 'nu-complete formats' []: [ nothing -> list<string> ] {
    [table json jsonl csv]
}

def 'nu-complete record formats' []: [ nothing -> list<string> ] {
    [csv parquet edf]
}

def 'nu-complete viz modes' []: [ nothing -> list<string> ] {
    [terminal ascii waveform bands topo]
}

def 'nu-complete pipeline names' []: [ nothing -> list<string> ] {
    let pipeline_dir = ($nu.home-path | path join ".config" "openbci" "pipelines")
    if ($pipeline_dir | path exists) {
        ls $pipeline_dir | where type == file | get name | path basename | str replace ".nu" ""
    } else {
        []
    }
}
"
}

# Generate bash completions
def generate_bash_completions []: [ nothing -> string ] {
$"# OpenBCI Bash Completions
# Source this file in your .bashrc

_openbci_completions() {
    local cur=\"\${COMP_WORDS[COMP_CWORD]}\"
    local prev=\"\${COMP_WORDS[COMP_CWORD-1]}\"
    
    case \"\${COMP_WORDS[1]}\" in
        device)
            COMPREPLY=( $(compgen -W 'list connect info impedance' -- \"$cur\") )
            ;;
        stream)
            COMPREPLY=( $(compgen -W '--channels --duration --format --filter --sample-rate' -- \"$cur\") )
            ;;
        record)
            COMPREPLY=( $(compgen -W '--output --duration --format --trigger' -- \"$cur\") )
            ;;
        analyze)
            COMPREPLY=( $(compgen -W '--bands --psd --coherence --features' -- \"$cur\") )
            ;;
        viz)
            COMPREPLY=( $(compgen -W '--mode --channels' -- \"$cur\") )
            ;;
        config)
            COMPREPLY=( $(compgen -W 'init get set edit show' -- \"$cur\") )
            ;;
        pipeline)
            COMPREPLY=( $(compgen -W 'list run create edit delete logs' -- \"$cur\") )
            ;;
        *)
            COMPREPLY=( $(compgen -W 'device stream record analyze viz config pipeline complete version status' -- \"$cur\") )
            ;;
    esac
}

complete -F _openbci_completions openbci
"
}

# Generate zsh completions
def generate_zsh_completions []: [ nothing -> string ] {
$"#compdef openbci
# OpenBCI Zsh Completions

_openbci() {
    local curcontext=\"$curcontext\" state line
    typeset -A opt_args
    
    _arguments -C \\
        '1: :->command' \\
        '*: :->args' && ret=0
    
    case \"$state\" in
        command)
            _values 'commands' \\
                'device[Manage OpenBCI devices]' \\
                'stream[Stream EEG data]' \\
                'record[Record EEG data]' \\
                'analyze[Analyze EEG data]' \\
                'viz[Visualize data]' \\
                'config[Manage configuration]' \\
                'pipeline[Manage pipelines]' \\
                'complete[Generate shell completions]' \\
                'version[Show version]' \\
                'status[Show system status]'
            ;;
        args)
            case \"$line[1]\" in
                device)
                    _values 'subcommands' 'list' 'connect' 'info' 'impedance'
                    ;;
                config)
                    _values 'subcommands' 'init' 'get' 'set' 'edit' 'show'
                    ;;
                pipeline)
                    _values 'subcommands' 'list' 'run' 'create' 'edit' 'delete' 'logs'
                    ;;
            esac
            ;;
    esac
}

compdef _openbci openbci
"
}

# Generate fish completions
def generate_fish_completions []: [ nothing -> string ] {
$"# OpenBCI Fish Completions

# Main commands
complete -c openbci -f -n __fish_use_subcommand -a 'device' -d 'Manage OpenBCI devices'
complete -c openbci -f -n __fish_use_subcommand -a 'stream' -d 'Stream EEG data'
complete -c openbci -f -n __fish_use_subcommand -a 'record' -d 'Record EEG data'
complete -c openbci -f -n __fish_use_subcommand -a 'analyze' -d 'Analyze EEG data'
complete -c openbci -f -n __fish_use_subcommand -a 'viz' -d 'Visualize data'
complete -c openbci -f -n __fish_use_subcommand -a 'config' -d 'Manage configuration'
complete -c openbci -f -n __fish_use_subcommand -a 'pipeline' -d 'Manage pipelines'
complete -c openbci -f -n __fish_use_subcommand -a 'complete' -d 'Generate shell completions'
complete -c openbci -f -n __fish_use_subcommand -a 'version' -d 'Show version'
complete -c openbci -f -n __fish_use_subcommand -a 'status' -d 'Show system status'

# Device subcommands
complete -c openbci -f -n '__fish_seen_subcommand_from device' -a 'list' -d 'List devices'
complete -c openbci -f -n '__fish_seen_subcommand_from device' -a 'connect' -d 'Connect to device'
complete -c openbci -f -n '__fish_seen_subcommand_from device' -a 'info' -d 'Device info'
complete -c openbci -f -n '__fish_seen_subcommand_from device' -a 'impedance' -d 'Check impedance'

# Config subcommands  
complete -c openbci -f -n '__fish_seen_subcommand_from config' -a 'init' -d 'Initialize config'
complete -c openbci -f -n '__fish_seen_subcommand_from config' -a 'get' -d 'Get config value'
complete -c openbci -f -n '__fish_seen_subcommand_from config' -a 'set' -d 'Set config value'
complete -c openbci -f -n '__fish_seen_subcommand_from config' -a 'edit' -d 'Edit config'
complete -c openbci -f -n '__fish_seen_subcommand_from config' -a 'show' -d 'Show config'

# Options
complete -c openbci -l channels -s c -d 'Channels to stream'
complete -c openbci -l duration -s d -d 'Duration'
complete -c openbci -l format -s f -d 'Output format'
complete -c openbci -l output -s o -d 'Output file'
complete -c openbci -l sample-rate -s r -d 'Sample rate'
"
}
