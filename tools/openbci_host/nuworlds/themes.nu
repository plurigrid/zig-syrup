# themes.nu
# Color themes for nuworlds visualizations
# Themes: default, minimal, high-contrast, ocean, matrix

# =============================================================================
# Theme Definitions
# =============================================================================

export const THEMES = {
    default: {
        name: "default"
        description: "Classic terminal colors"
        colors: {
            primary: "cyan"
            secondary: "blue"
            success: "green"
            warning: "yellow"
            error: "red"
            info: "white"
            muted: "gray"
        }
        eeg_bands: {
            delta: { fg: "blue_bg", bg: "blue" }
            theta: { fg: "cyan_bg", bg: "cyan" }
            alpha: { fg: "green_bg", bg: "green" }
            beta: { fg: "yellow_bg", bg: "yellow" }
            gamma: { fg: "red_bg", bg: "red" }
        }
        ui: {
            header: "cyan_bold"
            border: "blue_dim"
            label: "white"
            value: "cyan"
            highlight: "yellow_bold"
        }
        waveform: {
            positive: "green"
            negative: "red"
            zero: "white_dim"
            grid: "gray_dim"
        }
        ascii_chars: {
            filled: "█"
            partial: ["▏" "▎" "▍" "▌" "▋" "▊" "▉" "█"]
            horizontal: "─"
            vertical: "│"
            corner_tl: "┌"
            corner_tr: "┐"
            corner_bl: "└"
            corner_br: "┘"
            cross: "┼"
            arrow_up: "↑"
            arrow_down: "↓"
            diamond: "◆"
            circle: "●"
        }
    }
    
    minimal: {
        name: "minimal"
        description: "Clean monochrome design"
        colors: {
            primary: "white"
            secondary: "gray"
            success: "white"
            warning: "white_bold"
            error: "white_reverse"
            info: "gray"
            muted: "gray_dim"
        }
        eeg_bands: {
            delta: { fg: "gray", bg: "gray_dim" }
            theta: { fg: "white_dim", bg: "gray" }
            alpha: { fg: "white", bg: "white_dim" }
            beta: { fg: "white_bold", bg: "white" }
            gamma: { fg: "white_reverse", bg: "white_bold" }
        }
        ui: {
            header: "white_bold"
            border: "gray_dim"
            label: "gray"
            value: "white"
            highlight: "white_bold"
        }
        waveform: {
            positive: "white"
            negative: "gray"
            zero: "gray_dim"
            grid: "gray_dim"
        }
        ascii_chars: {
            filled: "█"
            partial: ["░" "▒" "▓" "█"]
            horizontal: "-"
            vertical: "|"
            corner_tl: "+"
            corner_tr: "+"
            corner_bl: "+"
            corner_br: "+"
            cross: "+"
            arrow_up: "^"
            arrow_down: "v"
            diamond: "*"
            circle: "o"
        }
    }
    
    "high-contrast": {
        name: "high-contrast"
        description: "Maximum accessibility"
        colors: {
            primary: "white_bold"
            secondary: "cyan_bold"
            success: "green_bold"
            warning: "yellow_bold"
            error: "red_bold_reverse"
            info: "white"
            muted: "gray"
        }
        eeg_bands: {
            delta: { fg: "blue_bold_reverse", bg: "blue_bold" }
            theta: { fg: "cyan_bold_reverse", bg: "cyan_bold" }
            alpha: { fg: "green_bold_reverse", bg: "green_bold" }
            beta: { fg: "yellow_bold_reverse", bg: "yellow_bold" }
            gamma: { fg: "red_bold_reverse", bg: "red_bold" }
        }
        ui: {
            header: "white_bold_reverse"
            border: "white_bold"
            label: "white_bold"
            value: "cyan_bold"
            highlight: "yellow_bold_reverse"
        }
        waveform: {
            positive: "green_bold"
            negative: "red_bold"
            zero: "white_bold"
            grid: "gray_bold"
        }
        ascii_chars: {
            filled: "█"
            partial: ["▖" "▗" "▘" "▙" "▚" "▛" "▜" "▝" "▞" "▟" "█"]
            horizontal: "━"
            vertical: "┃"
            corner_tl: "┏"
            corner_tr: "┓"
            corner_bl: "┗"
            corner_br: "┛"
            cross: "╋"
            arrow_up: "▲"
            arrow_down: "▼"
            diamond: "◉"
            circle: "◉"
        }
    }
    
    ocean: {
        name: "ocean"
        description: "Deep blue aquatic theme"
        colors: {
            primary: "cyan"
            secondary: "blue"
            success: "green_dim"
            warning: "yellow_dim"
            error: "red_dim"
            info: "white_dim"
            muted: "blue_dim"
        }
        eeg_bands: {
            delta: { fg: "dark_blue", bg: "blue_dim" }
            theta: { fg: "blue", bg: "blue" }
            alpha: { fg: "cyan", bg: "cyan_dim" }
            beta: { fg: "light_cyan", bg: "cyan" }
            gamma: { fg: "white_blue", bg: "cyan_bold" }
        }
        ui: {
            header: "cyan_bold"
            border: "blue_dim"
            label: "blue"
            value: "cyan"
            highlight: "white_bold"
        }
        waveform: {
            positive: "cyan"
            negative: "blue"
            zero: "white_dim"
            grid: "blue_dim"
        }
        ascii_chars: {
            filled: "█"
            partial: ["░" "▒" "▓" "█"]
            horizontal: "─"
            vertical: "│"
            corner_tl: "╭"
            corner_tr: "╮"
            corner_bl: "╰"
            corner_br: "╯"
            cross: "┼"
            arrow_up: "↑"
            arrow_down: "↓"
            diamond: "◇"
            circle: "○"
        }
    }
    
    matrix: {
        name: "matrix"
        description: "Green terminal hacker style"
        colors: {
            primary: "green_bold"
            secondary: "green_dim"
            success: "green"
            warning: "yellow_green"
            error: "red_dim"
            info: "green"
            muted: "green_dim"
        }
        eeg_bands: {
            delta: { fg: "green_dim", bg: "dark_green" }
            theta: { fg: "green", bg: "green_dim" }
            alpha: { fg: "green_bold", bg: "green" }
            beta: { fg: "light_green", bg: "green_bold" }
            gamma: { fg: "white_green", bg: "light_green" }
        }
        ui: {
            header: "green_bold"
            border: "green_dim"
            label: "green_dim"
            value: "green"
            highlight: "white_bold"
        }
        waveform: {
            positive: "green_bold"
            negative: "green_dim"
            zero: "white_dim"
            grid: "green_dim"
        }
        ascii_chars: {
            filled: "█"
            partial: ["░" "▒" "▓" "█"]
            horizontal: "═"
            vertical: "║"
            corner_tl: "╔"
            corner_tr: "╗"
            corner_bl: "╚"
            corner_br: "╝"
            cross: "╬"
            arrow_up: "▲"
            arrow_down: "▼"
            diamond: "◊"
            circle: "●"
        }
    }
}

# =============================================================================
# Current Theme State
# =============================================================================

# Get current theme (from config or default)
export def current-theme []: [ nothing -> record ] {
    let config_file = ($nu.home-path | path join ".config" "nuworlds" "config.nuon")
    let theme_name = if ($config_file | path exists) {
        open $config_file | get -i theme | default "default"
    } else {
        "default"
    }
    
    get-theme $theme_name
}

# Get theme by name
export def get-theme [name: string]: [ nothing -> record ] {
    if $name in $THEMES {
        $THEMES | get $name
    } else {
        $THEMES | get "default"
    }
}

# List available themes
export def list-themes []: [ nothing -> table ] {
    $THEMES | transpose name definition | each { |row|
        {
            name: $row.name
            description: $row.definition.description
            primary: $row.definition.colors.primary
        }
    }
}

# Set active theme (updates config)
export def set-theme [name: string]: [ nothing -> nothing ] {
    if $name not-in $THEMES {
        error make { msg: $"Unknown theme: ($name). Use 'list-themes' to see available themes." }
    }
    
    let config_file = ($nu.home-path | path join ".config" "nuworlds" "config.nuon")
    
    if not ($config_file | path exists) {
        error make { msg: "nuworlds not initialized. Run 'init' first." }
    }
    
    let config = (open $config_file)
    $config | upsert theme $name | save -f $config_file
    
    print $"Theme set to: ($name)"
}

# =============================================================================
# Color Application Functions
# =============================================================================

# Apply color to text
export def colorize [text: string, color: string]: [ nothing -> string ] {
    match $color {
        # Basic colors
        "black" => $"\e[30m($text)\e[0m"
        "red" => $"\e[31m($text)\e[0m"
        "green" => $"\e[32m($text)\e[0m"
        "yellow" => $"\e[33m($text)\e[0m"
        "blue" => $"\e[34m($text)\e[0m"
        "magenta" => $"\e[35m($text)\e[0m"
        "cyan" => $"\e[36m($text)\e[0m"
        "white" => $"\e[37m($text)\e[0m"
        "gray" => $"\e[90m($text)\e[0m"
        
        # Bright colors
        "red_bold" => $"\e[1;31m($text)\e[0m"
        "green_bold" => $"\e[1;32m($text)\e[0m"
        "yellow_bold" => $"\e[1;33m($text)\e[0m"
        "blue_bold" => $"\e[1;34m($text)\e[0m"
        "cyan_bold" => $"\e[1;36m($text)\e[0m"
        "white_bold" => $"\e[1;37m($text)\e[0m"
        
        # Dim colors
        "red_dim" => $"\e[2;31m($text)\e[0m"
        "green_dim" => $"\e[2;32m($text)\e[0m"
        "yellow_dim" => $"\e[2;33m($text)\e[0m"
        "blue_dim" => $"\e[2;34m($text)\e[0m"
        "gray_dim" => $"\e[2;90m($text)\e[0m"
        "white_dim" => $"\e[2;37m($text)\e[0m"
        
        # Background colors
        "red_bg" => $"\e[41m($text)\e[0m"
        "green_bg" => $"\e[42m($text)\e[0m"
        "yellow_bg" => $"\e[43m($text)\e[0m"
        "blue_bg" => $"\e[44m($text)\e[0m"
        "cyan_bg" => $"\e[46m($text)\e[0m"
        "white_bg" => $"\e[47m($text)\e[0m"
        
        # Reverse (swap fg/bg)
        "red_reverse" => $"\e[7;31m($text)\e[0m"
        "green_reverse" => $"\e[7;32m($text)\e[0m"
        "yellow_reverse" => $"\e[7;33m($text)\e[0m"
        "blue_reverse" => $"\e[7;34m($text)\e[0m"
        "white_reverse" => $"\e[7m($text)\e[0m"
        
        # Special
        "bold" => $"\e[1m($text)\e[0m"
        "dim" => $"\e[2m($text)\e[0m"
        "underline" => $"\e[4m($text)\e[0m"
        "reverse" => $"\e[7m($text)\e[0m"
        
        _ => $text
    }
}

# Get color for EEG band
export def band-color [band: string]: [ nothing -> record ] {
    let theme = (current-theme)
    if $band in $theme.eeg_bands {
        $theme.eeg_bands | get $band
    } else {
        { fg: "white", bg: "gray" }
    }
}

# Colorize band name
export def colorize-band [band: string]: [ nothing -> string ] {
    let colors = (band-color $band)
    let theme = (current-theme)
    
    # Create colored band name with background
    match $band {
        "delta" => (colorize " Δ " $"($colors.fg)_reverse")
        "theta" => (colorize " θ " $"($colors.fg)_reverse")
        "alpha" => (colorize " α " $"($colors.fg)_reverse")
        "beta" => (colorize " β " $"($colors.fg)_reverse")
        "gamma" => (colorize " γ " $"($colors.fg)_reverse")
        _ => $band
    }
}

# =============================================================================
# Progress Bar Functions
# =============================================================================

# Render a progress bar with theme
export def progress-bar [
    value: float        # Current value (0-100)
    --width: int = 40   # Bar width in characters
    --label: string = ""  # Optional label
]: [ nothing -> string ] {
    let theme = (current-theme)
    let chars = $theme.ascii_chars
    
    let filled_width = ($value / 100.0 * $width | math floor)
    let empty_width = $width - $filled_width
    
    let filled = ($chars.filled | str repeat $filled_width)
    let empty = (" " | str repeat $empty_width)
    
    let bar = $"($chars.corner_tl)($filled)($empty)($chars.corner_tr)"
    
    if $label != "" {
        $"($label) ($bar) ($value | math round -p 1)%"
    } else {
        $"($bar) ($value | math round -p 1)%"
    }
}

# Render a colored multi-segment bar (for band powers)
export def band-power-bar [
    powers: record     # {delta, theta, alpha, beta, gamma}
    --width: int = 50  # Total bar width
]: [ nothing -> string ] {
    let theme = (current-theme)
    let total = ($powers | values | math sum)
    
    if $total == 0 {
        return ("░" | str repeat $width)
    }
    
    # Calculate widths for each band
    let delta_w = ($powers.delta / $total * $width | math round)
    let theta_w = ($powers.theta / $total * $width | math round)
    let alpha_w = ($powers.alpha / $total * $width | math round)
    let beta_w = ($powers.beta / $total * $width | math round)
    let gamma_w = ($width - $delta_w - $theta_w - $alpha_w - $beta_w)
    
    # Build colored segments
    mut bar = ""
    if $delta_w > 0 {
        $bar = $bar + (colorize ("█" | str repeat $delta_w) "blue_dim")
    }
    if $theta_w > 0 {
        $bar = $bar + (colorize ("█" | str repeat $theta_w) "cyan")
    }
    if $alpha_w > 0 {
        $bar = $bar + (colorize ("█" | str repeat $alpha_w) "green")
    }
    if $beta_w > 0 {
        $bar = $bar + (colorize ("█" | str repeat $beta_w) "yellow")
    }
    if $gamma_w > 0 {
        $bar = $bar + (colorize ("█" | str repeat $gamma_w) "red")
    }
    
    $bar
}

# =============================================================================
# Box Drawing
# =============================================================================

# Draw a box around content
export def draw-box [
    content: list       # Lines of content
    --title: string = ""
    --width: int = 60
]: [ nothing -> string ] {
    let theme = (current-theme)
    let chars = $theme.ascii_chars
    
    let inner_width = $width - 2
    
    mut output = ""
    
    # Top border with title
    if $title != "" {
        let title_len = ($title | str length)
        let left_pad = ($inner_width - $title_len - 2) / 2 | math floor
        let right_pad = $inner_width - $title_len - 2 - $left_pad
        let border = ("─" | str repeat $left_pad) + $" [($title)] " + ("─" | str repeat $right_pad)
        $output = $output + $"($chars.corner_tl)($border)($chars.corner_tr)\n"
    } else {
        let border = ("─" | str repeat $inner_width)
        $output = $output + $"($chars.corner_tl)($border)($chars.corner_tr)\n"
    }
    
    # Content lines
    for line in $content {
        let padded = $line | str substring 0..$inner_width
        let right_pad = $inner_width - ($padded | str length)
        $output = $output + $"($chars.vertical)($padded)(' ' | str repeat $right_pad)($chars.vertical)\n"
    }
    
    # Bottom border
    let border = ("─" | str repeat $inner_width)
    $output = $output + $"($chars.corner_bl)($border)($chars.corner_br)"
    
    $output
}

# =============================================================================
# Demo
# =============================================================================

export def demo []: [ nothing -> nothing ] {
    print "🎨 nuworlds Theme Demo\n"
    
    for theme_name in ($THEMES | columns) {
        let theme = ($THEMES | get $theme_name)
        print $"\n━━━ ($theme.name | str upcase) ━━━ ($theme.description)"
        
        # Color samples
        print "\nColors:"
        for color in ($theme.colors | columns) {
            let value = ($theme.colors | get $color)
            print $"  ($color): (colorize $value $value)"
        }
        
        # Band colors
        print "\nEEG Bands:"
        for band in [delta theta alpha beta gamma] {
            print $"  (colorize-band $band)"
        }
        
        # ASCII chars
        print "\nASCII: ($theme.ascii_chars.filled)($theme.ascii_chars.arrow_up)($theme.ascii_chars.diamond)($theme.ascii_chars.circle)"
    }
    
    print "\n\nProgress bars:"
    print (progress-bar 25 --label "Low")
    print (progress-bar 50 --label "Mid")
    print (progress-bar 75 --label "High")
    print (progress-bar 100 --label "Full")
    
    print "\nBand power distribution:"
    print (band-power-bar {delta: 10, theta: 20, alpha: 35, beta: 25, gamma: 10})
}
