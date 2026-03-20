# emacs_color_bridge.nu
# Bridge BCI color stream → Emacs color.index theme
# Connects to SSE :7070, extracts hex color, applies to Emacs via elisp

use std log

const SSE_URL = "http://localhost:7070/events"
const EMACS_SOCKET = "emacs"
const UPDATE_INTERVAL = 50ms  # ~20 Hz for rapid updates
const THEME_CACHE = ($nu.cache-dir | path join "emacs_bci_theme.json")

# ═══════════════════════════════════════════════════════════════════════════
# Emacs Theme Bridge
# ═══════════════════════════════════════════════════════════════════════════

# Convert hex color to RGB
export def hex-to-rgb [hex: string] {
    let clean = ($hex | str replace -a "#" "" | str downcase)
    if ($clean | str length) != 6 {
        return { r: 127, g: 127, b: 127 }  # fallback gray
    }

    let r_hex = ($clean | str substring 0..<2)
    let g_hex = ($clean | str substring 2..<4)
    let b_hex = ($clean | str substring 4..<6)

    let r = (("0x" + $r_hex) | into int)
    let g = (("0x" + $g_hex) | into int)
    let b = (("0x" + $b_hex) | into int)

    { r: $r, g: $g, b: $b }
}

# Compute luminance (for text color contrast)
def luminance [rgb: record] {
    let r = $rgb.r / 255.0
    let g = $rgb.g / 255.0
    let b = $rgb.b / 255.0

    let r_lin = if $r <= 0.03928 { $r / 12.92 } else { (($r + 0.055) / 1.055) ** 2.4 }
    let g_lin = if $g <= 0.03928 { $g / 12.92 } else { (($g + 0.055) / 1.055) ** 2.4 }
    let b_lin = if $b <= 0.03928 { $b / 12.92 } else { (($b + 0.055) / 1.055) ** 2.4 }

    0.2126 * $r_lin + 0.7152 * $g_lin + 0.0722 * $b_lin
}

# Choose text color (white or black) based on background
export def text-color [rgb: record] {
    let lum = (luminance $rgb)
    if $lum > 0.5 { "black" } else { "white" }
}

# Generate Elisp to set Emacs theme
export def elisp-set-theme [hex: string, state: string = "unknown"] {
    let rgb = (hex-to-rgb $hex)
    let fg = (text-color $rgb)
    let r = $rgb.r
    let g = $rgb.g
    let b = $rgb.b

    $"(progn
  ;; Set background color from BCI: ($hex) [$r $g $b]
  ;; State: ($state)
  (set-face-background 'default \"#($hex)\")
  (set-face-foreground 'default \"($fg)\")
  (set-face-background 'mode-line \"#($hex)\")
  (set-face-foreground 'mode-line \"($fg)\")
  (set-face-background 'cursor \"($fg)\")
  (set-face-foreground 'cursor \"#($hex)\")
  (setq color-index-current (list :hex \"#($hex)\" :rgb (list $r $g $b) :state \"($state)\" :timestamp (format-time-string \"%Y-%m-%dT%H:%M:%S\" (current-time))))
  (run-hooks 'color-index-update-hook)
)"
}

# Send Elisp to Emacs via emacsclient
export def emacs-eval [elisp: string] {
    try {
        emacsclient --socket-name $EMACS_SOCKET -e $elisp | head -c 100
    } catch {
        # Fallback: write to /tmp for integration
        $elisp | save -f ($"/tmp/emacs_bci_pending.el") --force
        ""
    }
}

# Apply color to Emacs rapidly
export def apply-to-emacs [color_hex: string, state: string = "unknown"] {
    let elisp = (elisp-set-theme $color_hex $state)
    emacs-eval $elisp | ignore
}

# ═══════════════════════════════════════════════════════════════════════════
# SSE Streaming
# ═══════════════════════════════════════════════════════════════════════════

# Connect to SSE stream and parse JSON events
export def stream-sse [
    --url: string = $SSE_URL
    --timeout: int = 30
] {
    try {
        (curl --silent --max-time $timeout --no-buffer $url
            | lines
            | where { |line| ($line | str starts-with "data: ") }
            | each { |line|
                let json_str = ($line | str replace "data: " "")
                try {
                    $json_str | from json
                } catch {
                    {}
                }
            }
            | where { |obj| ($obj | is-not-empty) })
    } catch {
        error make { msg: $"Failed to connect to SSE: ($url)" }
        []
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Main Bridge Loop
# ═══════════════════════════════════════════════════════════════════════════

# Listen to color stream and update Emacs
export def "main listen" [
    --url: string = $SSE_URL
    --emacs-socket: string = $EMACS_SOCKET
    --no-cache
] {
    print $"🎨 Emacs Color Bridge — listening on ($url)"
    print $"   Hex colors → Emacs background + text contrast"
    print $"   Press Ctrl+C to stop\n"

    mut last_color = ""
    mut last_state = ""
    mut skipped = 0

    for event in (stream-sse --url $url --timeout 0) {
        let hex = $event | get -o "color.hex" | default null
        let state = $event | get -o "brain_state" | default "unknown"

        if ($hex | is-not-empty) and ($hex != $last_color) {
            # Update Emacs
            apply-to-emacs $hex $state

            # Log
            let rgb = (hex-to-rgb $hex)
            print $"  ✓ ($hex) [$($rgb.r) $($rgb.g) $($rgb.b)] state=($state)"

            $last_color = $hex
            $last_state = $state
            $skipped = 0
        } else {
            $skipped = $skipped + 1
            if ($skipped mod 20) == 0 {
                print $"  · (waiting...)"
            }
        }

        sleep ($UPDATE_INTERVAL)
    }

    print "\n[disconnected]"
}

# Daemon mode with auto-restart
export def "main daemon" [
    --url: string = $SSE_URL
    --emacs-socket: string = $EMACS_SOCKET
    --pid-file: path = ($nu.cache-dir | path join "emacs_bci_bridge.pid")
] {
    let existing = try { open $pid_file | into int } catch { null }
    if ($existing | is-not-empty) {
        try {
            kill -0 $existing  # Check if process exists
            print "Bridge already running (PID: $existing)"
            return
        } catch {
            # stale PID, continue
        }
    }

    # Start main loop
    print $"Starting daemon (PID: $nu.pid)"
    $nu.pid | save -f $pid_file

    loop {
        try {
            main listen --url $url --emacs-socket $emacs_socket
        } catch { |err|
            print $"[error] ($err.msg) — restarting in 5s..."
            sleep (5s)
        }
    }
}

# Initialize Emacs hook for receiving updates
export def "main init-emacs" [] {
    let init_code = "
(unless (boundp 'color-index-update-hook)
  (defvar color-index-update-hook nil
    \"Hook run when color.index updates from BCI stream\"))

(unless (boundp 'color-index-current)
  (defvar color-index-current nil
    \"Current color state from BCI: (:hex :rgb :state :timestamp)\"))

;; Log updates to messages
(add-hook 'color-index-update-hook
  (lambda ()
    (message \"[BCI] Color: %s State: %s\"
      (plist-get color-index-current :hex)
      (plist-get color-index-current :state))))

(message \"[BCI] color.index hook initialized\")
"

    print "Initializing Emacs hook..."
    try {
        emacsclient --socket-name $EMACS_SOCKET -e $init_code | ignore
        print "✓ Hook installed"
    } catch {
        print "✗ Could not connect to Emacs (is it running?)"
        print "  Start Emacs server with: M-x server-start"
    }
}

# Test connection and color
export def "main test" [
    --color: string = "#FF6B9D"  # vivid magenta
    --state: string = "test"
] {
    print $"Testing Emacs color bridge..."
    print $"  Color: ($color)"
    print $"  State: ($state)\n"

    apply-to-emacs $color $state

    sleep (3s)
    print "\n✓ Test complete (color should update rapidly)"
}

# Show current status
export def "main status" [] {
    print "Checking connection..."

    let sse_ok = try {
        curl --silent --max-time 2 --head $SSE_URL | str contains "200"
    } catch { false }

    let emacs_ok = try {
        emacsclient --socket-name $EMACS_SOCKET -e "(+ 1 1)" | is-not-empty
    } catch { false }

    [
        {component: "SSE Stream", status: (if $sse_ok { "✓ connected" } else { "✗ failed" }), endpoint: $SSE_URL}
        {component: "Emacs", status: (if $emacs_ok { "✓ running" } else { "✗ not running" }), endpoint: $EMACS_SOCKET}
    ]
}
