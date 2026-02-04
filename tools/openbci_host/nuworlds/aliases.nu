#!/usr/bin/env nu
# aliases.nu - Short command aliases for nuworlds
# Provides convenient shortcuts for common operations

# =============================================================================
# OpenBCI Aliases
# =============================================================================

# obs - openbci stream
# Stream EEG data from OpenBCI device
export alias obs = openbci stream

# obse - openbci stream (with specific electrodes)
# Stream from frontal electrodes only (Fp1, Fp2)
export alias obse = openbci stream --channels 0,1

# obsa - openbci stream all channels
export alias obsa = openbci stream --channels all

# obr - openbci record
# Record EEG data to file
export alias obr = openbci record

# obr5 - openbci record 5 minutes
export alias obr5 = openbci record --duration 5min

# obr10 - openbci record 10 minutes
export alias obr10 = openbci record --duration 10min

# oba - openbci analyze
# Analyze recorded EEG data
export alias oba = openbci analyze

# obab - openbci analyze --bands
# Analyze with band power calculation
export alias obab = openbci analyze --bands

# obv - openbci viz
# Visualize data in terminal
export alias obv = openbci viz

# obvt - openbci viz --mode terminal
export alias obvt = openbci viz --mode terminal

# obvw - openbci viz --mode waveform
export alias obvw = openbci viz --mode waveform

# obd - openbci device
export alias obd = openbci device

# obdl - openbci device list
export alias obdl = openbci device list

# obdi - openbci device info
export alias obdi = openbci device info

# =============================================================================
# World A/B Testing Aliases
# =============================================================================

# wab - world_ab
export alias wab = world_ab

# wabl - world list
export alias wabl = world list

# wabc - world create
export alias wabc = world create

# wabco - world compare
export alias wabco = world compare

# wabcl - world clone
export alias wabcl = world clone

# wabs - world snapshot
export alias wabs = world snapshot

# wabdel - world delete
export alias wabdel = world delete

# Quick world creation aliases
export alias wa = world create a://
export alias wb = world create b://
export alias wc = world create c://

# =============================================================================
# Multiplayer Session Aliases
# =============================================================================

# mp - multiplayer
export alias mp = multiplayer

# mps - mp session
export alias mps = mp session

# mpsn - mp session new
export alias mpsn = mp session new

# mp3 - mp session new --players 3
export alias mp3 = mp session new --players 3

# mp5 - mp session new --players 5
export alias mp5 = mp session new --players 5

# mpsa - mp session assign
export alias mpsa = mp session assign

# mpsl - mp session list
export alias mpsl = mp session list

# mpsi - mp session info
export alias mpsi = mp session info

# mpso - mp session observe
export alias mpso = mp session observe

# =============================================================================
# BCI Pipeline Aliases
# =============================================================================

# bci - bci-pipeline
export alias bci = bci-pipeline

# bcis - bci-pipeline start
export alias bcis = bci-pipeline start

# bcist - bci-pipeline stop
export alias bcist = bci-pipeline stop

# bcistat - bci-pipeline status
export alias bcistat = bci-pipeline status

# bcim - bci-pipeline metrics
export alias bcim = bci-pipeline metrics

# bcical - bci-pipeline calibrate
export alias bcical = bci-pipeline calibrate

# =============================================================================
# nuworlds Aliases
# =============================================================================

# nw - nuworlds
export alias nw = nuworlds

# nwd - nuworlds demo
export alias nwd = nuworlds demo

# nwdf - nuworlds demo --mode full
export alias nwdf = nuworlds demo --mode full

# nwdb - nuworlds demo --mode bci-only
export alias nwdb = nuworlds demo --mode bci-only

# nww - nuworlds workflow
export alias nww = nuworlds workflow

# nwdash - nuworlds dashboard
export alias nwdash = nuworlds dashboard

# nwr - nuworlds repl
export alias nwr = nuworlds repl

# nwdoc - nuworlds doctor
export alias nwdoc = nuworlds doctor

# =============================================================================
# Utility Aliases
# =============================================================================

# wait - wait-for-device
export alias wait = wait-for-device

# autoconf - auto-config
export alias autoconf = auto-config

# validate - validate-setup
export alias validate = validate-setup

# Export aliases
export alias xall = export-all
export alias cmp = compare-sessions

# =============================================================================
# Quick Action Aliases
# =============================================================================

# Quick focus tracking session
export alias focus = nuworlds workflow bci-focus-tracker

# Quick meditation session
export alias meditate = nuworlds workflow meditation-monitor

# Quick A/B test
export alias abtest = nuworlds workflow ab-test-eeg

# Quick game
export alias game = nuworlds workflow neurofeedback-game

# Quick sleep recording
export alias sleeprec = nuworlds workflow sleep-recorder

# =============================================================================
# Directory Shortcuts
# =============================================================================

# cd to nuworlds config
export def cdnw []: [ nothing -> nothing ] {
    cd ($nu.home-path | path join ".config" "nuworlds")
}

# cd to nuworlds recordings
export def cdnwr []: [ nothing -> nothing ] {
    cd ($nu.home-path | path join ".local" "share" "nuworlds" "recordings")
}

# cd to nuworlds source
export def cdnws []: [ nothing -> nothing ] {
    cd "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds"
}

# List recordings
export def lsr []: [ nothing -> table ] {
    ls ($nu.home-path | path join ".local" "share" "nuworlds" "recordings")
}

# List worlds
export def lsw []: [ nothing -> table ] {
    ls ($nu.home-path | path join ".config" "nuworlds" "worlds")
}

# List sessions
export def lss []: [ nothing -> table ] {
    ls ($nu.home-path | path join ".config" "nuworlds" "sessions")
}

# =============================================================================
# Theme Aliases
# =============================================================================

# theme list
export alias tl = nuworlds theme list

# theme set default
export alias td = nuworlds theme set default

# theme set ocean
export alias to = nuworlds theme set ocean

# theme set matrix
export alias tm = nuworlds theme set matrix

# =============================================================================
# Hook Aliases
# =============================================================================

# hook list
export alias hl = hook list

# hook types
export alias ht = hook types

# hook monitor
export alias hm = hook monitor

# =============================================================================
# Function Aliases (for commands with parameters)
# =============================================================================

# Quick world creation with common parameters
export def quick-world [
    name: string
    --variant (-v): string = "a"
    --from (-f): string = ""
]: [ nothing -> record ] {
    let uri = $"($variant)://($name)"
    if $from != "" {
        world clone $from $uri
    } else {
        world create $uri
    }
}

# Quick session with auto-assign
export def quick-session [
    --players (-p): int = 3
    --duration (-d): duration = 5min
]: [ nothing -> string ] {
    let session_id = (mp session new --players $players)
    print $"Created session: ($session_id)"
    
    # Create worlds
    world create a://baseline
    world create b://variant --from a://baseline
    world create c://experimental --from a://baseline
    
    # Assign players
    mp session assign $session_id player1 a://baseline
    mp session assign $session_id player2 b://variant
    mp session assign $session_id player3 c://experimental
    
    $session_id
}

# Quick recording with auto-analysis
export def quick-record [
    duration: duration = 60sec
    --analyze (-a)              # Auto-analyze after recording
]: [ nothing -> record ] {
    let filename = $"recording_(date now | format date "%Y%m%d_%H%M%S").csv"
    
    print $"Recording for ($duration)..."
    openbci record --output $filename --duration $duration
    
    print $"Saved to: ($filename)"
    
    if $analyze {
        print "Analyzing..."
        openbci analyze $filename --bands
    }
    
    { file: $filename, duration: $duration }
}

# Show system status
export def status []: [ nothing -> record ] {
    {
        initialized: ($nu.home-path | path join ".config" "nuworlds" "initialized.nuon" | path exists)
        config_dir: ($nu.home-path | path join ".config" "nuworlds") | path exists
        recordings_dir: ($nu.home-path | path join ".local" "share" "nuworlds" "recordings") | path exists
        nushell_version: (version | get version)
        theme: (current-theme).name
    }
}

# Quick help
export def h []: [ nothing -> nothing ] {
    print "nuworlds Quick Reference:"
    print ""
    print "OpenBCI:"
    print "  obs      - Stream EEG"
    print "  obr5     - Record 5 min"
    print "  oba      - Analyze data"
    print "  obv      - Visualize"
    print ""
    print "Worlds:"
    print "  wa name  - Create a://name"
    print "  wb name  - Create b://name"
    print "  wabl     - List worlds"
    print ""
    print "Sessions:"
    print "  mp3      - New 3-player session"
    print "  mpsl     - List sessions"
    print ""
    print "Workflows:"
    print "  focus    - Focus tracking"
    print "  meditate - Meditation monitor"
    print "  abtest   - A/B test"
    print "  game     - Neurofeedback game"
    print ""
    print "Utils:"
    print "  nwdoc    - System doctor"
    print "  validate - Validate setup"
    print "  nwdash   - Launch dashboard"
    print "  nwr      - Start REPL"
}
