#!/usr/bin/env nu
# repl.nu - Interactive REPL for nuworlds
# Custom prompt, command history, tab completion, persistent variables

use themes.nu *

const HISTORY_FILE = ($nu.home-path | path join ".config" "nuworlds" "repl_history.txt")
const VARS_FILE = ($nu.home-path | path join ".config" "nuworlds" "repl_vars.nuon")
const WELCOME_BANNER = "
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   🧠 nuworlds Interactive REPL                                   ║
║                                                                  ║
║   Commands: .help  .vars  .worlds  .sessions  .clear  .quit      ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
"

# =============================================================================
# Main REPL Entry Point
# =============================================================================

# Start interactive REPL
export def main [
    --theme: string = "default"     # Color theme
]: [ nothing -> nothing ] {
    
    # Clear screen and show welcome
    print "\x1b[2J\x1b[H"
    print (ansi cyan_bold)
    print $WELCOME_BANNER
    print (ansi reset)
    
    # Load persistent state
    mut repl_state = load-repl-state
    $repl_state.theme = $theme
    
    # REPL loop
    mut running = true
    mut history = (load-history)
    
    while $running {
        # Show prompt
        let prompt = (build-prompt $repl_state)
        print -n $prompt
        
        # Get input
        let input = (input)
        
        # Skip empty lines
        if ($input | str trim) == "" {
            continue
        }
        
        # Add to history
        $history = ($history | append $input | last 1000)
        
        # Process command
        let result = (process-command $input $repl_state)
        
        # Update state if modified
        if ($result.state | is-not-empty) {
            $repl_state = $result.state
        }
        
        # Print output
        if ($result.output | is-not-empty) {
            $result.output | print
        }
        
        # Check for exit
        if $result.exit {
            $running = false
        }
    }
    
    # Save state
    save-repl-state $repl_state
    save-history $history
    
    print "\n👋 Goodbye!"
}

# =============================================================================
# Command Processing
# =============================================================================

def process-command [input: string, state: record]: [ nothing -> record ] {
    let trimmed = ($input | str trim)
    let parts = ($trimmed | split " ")
    let cmd = ($parts | first)
    let args = ($parts | skip 1)
    
    # Special REPL commands (start with .)
    if ($cmd | str starts-with ".") {
        match $cmd {
            ".help" => {
                output: (show-help)
                state: $state
                exit: false
            }
            ".vars" => {
                output: (show-vars $state)
                state: $state
                exit: false
            }
            ".worlds" => {
                output: (show-worlds)
                state: $state
                exit: false
            }
            ".sessions" => {
                output: (show-sessions)
                state: $state
                exit: false
            }
            ".history" => {
                output: (show-history $state.history? | default [])
                state: $state
                exit: false
            }
            ".clear" => {
                print "\x1b[2J\x1b[H"
                output: ""
                state: $state
                exit: false
            }
            ".save" => {
                let name = ($args | first? | default $"session_(date now | format date "%Y%m%d_%H%M%S")")
                output: (save-session $state $name)
                state: $state
                exit: false
            }
            ".load" => {
                let name = ($args | first? | default "")
                if $name == "" {
                    output: "Usage: .load <session-name>"
                    state: $state
                    exit: false
                } else {
                    let loaded = (load-session $name)
                    output: $loaded.message
                    state: $loaded.state
                    exit: false
                }
            }
            ".theme" => {
                let new_theme = ($args | first? | default "")
                if $new_theme == "" {
                    output: $"Current theme: ($state.theme). Available: default, minimal, high-contrast, ocean, matrix"
                    state: $state
                    exit: false
                } else {
                    output: $"Theme set to: ($new_theme)"
                    state: ($state | upsert theme $new_theme)
                    exit: false
                }
            }
            ".quit" | ".exit" | ".q" => {
                output: ""
                state: $state
                exit: true
            }
            _ => {
                output: $"Unknown command: ($cmd). Type .help for available commands."
                state: $state
                exit: false
            }
        }
    } else {
        # Regular nushell command - try to execute
        let exec_result = (execute-nushell $trimmed $state)
        {
            output: $exec_result.output
            state: $exec_result.state
            exit: false
        }
    }
}

# =============================================================================
# REPL Commands
# =============================================================================

def show-help []: [ nothing -> string ] {
    $"REPL Commands:
  .help         Show this help message
  .vars         Show defined variables
  .worlds       List active worlds
  .sessions     List active sessions
  .history      Show command history
  .clear        Clear screen
  .save [name]  Save current session
  .load <name>  Load saved session
  .theme <name> Change color theme
  .quit         Exit REPL

Special Variables:
  $eeg          Latest EEG sample
  $bands        Latest band powers
  $worlds       World registry
  $session      Current session

Nushell Commands:
  Any valid nushell command works here.
  Use 'let x = 5' to define persistent variables.
"
}

def show-vars [state: record]: [ nothing -> string ] {
    if ($state.vars? | is-empty) {
        "No variables defined. Use 'let <name> = <value>' to define."
    } else {
        $state.vars | table
    }
}

def show-worlds []: [ nothing -> string ] {
    let worlds_dir = ($nu.home-path | path join ".config" "nuworlds" "worlds")
    
    if not ($worlds_dir | path exists) {
        return "No worlds directory found. Run 'nuworlds init' first."
    }
    
    let world_files = (ls $worlds_dir | where name ends-with ".nuon" | default [])
    
    if ($world_files | is-empty) {
        "No worlds created yet. Use 'world create a://name' to create."
    } else {
        print "Active worlds:"
        $world_files | each { |f| 
            let world = (open $f.name)
            $"  ($world.uri) - ($world.variant) - ($world.entities | length) entities"
        } | str join "\n"
    }
}

def show-sessions []: [ nothing -> string ] {
    let sessions_dir = ($nu.home-path | path join ".config" "nuworlds" "sessions")
    
    if not ($sessions_dir | path exists) {
        return "No sessions directory found."
    }
    
    let session_files = (ls $sessions_dir | where name ends-with ".nuon" | default [])
    
    if ($session_files | is-empty) {
        "No active sessions. Use 'mp session new' to create."
    } else {
        print "Sessions:"
        $session_files | each { |f|
            let sess = (open $f.name)
            $"  ($sess.id) - ($sess.name) - ($sess.status) - ($sess.players | length) players"
        } | str join "\n"
    }
}

def show-history [history: list]: [ nothing -> string ] {
    if ($history | is-empty) {
        "No command history."
    } else {
        $history | enumerate | each { |item| 
            $"($item.index + 1 | into string | str lpad -l 3 -c ' ')  ($item.item)"
        } | str join "\n"
    }
}

# =============================================================================
# Nushell Execution
# =============================================================================

def execute-nushell [command: string, state: record]: [ nothing -> record ] {
    # Check if it's a variable assignment
    let is_assignment = ($command | parse -r '^let\s+(\w+)\s*=\s*(.+)$')
    
    if ($is_assignment | is-not-empty) {
        # Variable assignment - store in state
        let var_name = $is_assignment.0.capture0
        let var_expr = $is_assignment.0.capture1
        
        try {
            let value = (nu -c $var_expr)
            let new_vars = ($state.vars? | default {} | upsert $var_name $value)
            {
                output: $"($var_name) = ($value)"
                state: ($state | upsert vars $new_vars)
            }
        } catch { |e|
            {
                output: $"Error: ($e.msg)"
                state: $state
            }
        }
    } else {
        # Regular command execution
        try {
            let output = (nu -c $command)
            {
                output: $output
                state: $state
            }
        } catch { |e|
            {
                output: $"Error: ($e.msg)"
                state: $state
            }
        }
    }
}

# =============================================================================
# Session Persistence
# =============================================================================

def save-session [state: record, name: string]: [ nothing -> string ] {
    let sessions_dir = ($nu.home-path | path join ".config" "nuworlds" "repl_sessions")
    mkdir $sessions_dir
    
    let filename = $sessions_dir | path join $"($name).nuon"
    $state | save -f $filename
    
    $"Session saved as '($name)'"
}

def load-session [name: string]: [ nothing -> record ] {
    let sessions_dir = ($nu.home-path | path join ".config" "nuworlds" "repl_sessions")
    let filename = $sessions_dir | path join $"($name).nuon"
    
    if ($filename | path exists) {
        let state = (open $filename)
        {
            message: $"Session '($name)' loaded"
            state: $state
        }
    } else {
        {
            message: $"Session '($name)' not found"
            state: {}
        }
    }
}

# =============================================================================
# State Management
# =============================================================================

def load-repl-state []: [ nothing -> record ] {
    if ($VARS_FILE | path exists) {
        open $VARS_FILE
    } else {
        {
            theme: "default"
            vars: {}
            history: []
            eeg: {}
            bands: {}
            worlds: {}
            session: null
        }
    }
}

def save-repl-state [state: record]: [ nothing -> nothing ] {
    mkdir ($VARS_FILE | path dirname)
    $state | save -f $VARS_FILE
}

def load-history []: [ nothing -> list ] {
    if ($HISTORY_FILE | path exists) {
        open $HISTORY_FILE | lines
    } else {
        []
    }
}

def save-history [history: list]: [ nothing -> nothing ] {
    mkdir ($HISTORY_FILE | path dirname)
    $history | str join "\n" | save -f $HISTORY_FILE
}

# =============================================================================
# Prompt Builder
# =============================================================================

def build-prompt [state: record]: [ nothing -> string ] {
    let theme_colors = match $state.theme {
        "ocean" => { primary: "\e[36m" secondary: "\e[34m" reset: "\e[0m" }
        "matrix" => { primary: "\e[32m" secondary: "\e[32;2m" reset: "\e[0m" }
        "minimal" => { primary: "\e[37m" secondary: "\e[90m" reset: "\e[0m" }
        _ => { primary: "\e[36m" secondary: "\e[34m" reset: "\e[0m" }
    }
    
    let var_count = ($state.vars? | default {} | length)
    let world_indicator = if ($state.worlds? | is-not-empty) { "🌍" } else { "" }
    
    $"($theme_colors.secondary)nu($theme_colors.primary)worlds($theme_colors.reset) ($world_indicator)($var_count) ($theme_colors.secondary)>($theme_colors.reset) "
}

# =============================================================================
# Tab Completion (Basic)
# =============================================================================

export def complete [prefix: string]: [ nothing -> list ] {
    let commands = [
        ".help" ".vars" ".worlds" ".sessions" ".history" ".clear" ".save" ".load" ".theme" ".quit"
        "world create" "world list" "world compare" "world clone"
        "mp session new" "mp session list" "mp session assign"
        "openbci stream" "openbci record" "openbci analyze"
        "bci-pipeline start" "bci-pipeline stop" "bci-pipeline status"
    ]
    
    $commands | where { |c| $c | str starts-with $prefix }
}

# Run if executed directly
if ($env.FILE_PWD? | default "") == ($env.CURRENT_FILE? | default "" | path dirname) {
    main
}
