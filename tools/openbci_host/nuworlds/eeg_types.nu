# eeg_types.nu
# Type definitions and data structures for OpenBCI EEG processing
# Compatible with nushell 0.88+

# =============================================================================
# EEG Sample Record Type
# =============================================================================

# Define the structure of an EEG sample record
# Usage: $sample | describe-type EEGSample
export def EEGSample [] {
    {
        timestamp: float,      # Unix timestamp with microsecond precision
        sample_num: int,       # Sample number (wraps at buffer size)
        channels: list<float>, # Channel values in microvolts [8] or [16]
        aux: list<float>       # Auxiliary data (accelerometer) [3]
    }
}

# =============================================================================
# Channel Configuration Constants
# =============================================================================

# Standard 10-20 montage channel names for Cyton (8 channels)
export const CYTON_CHANNELS_8 = [Fp1 Fp2 C3 C4 P7 P8 O1 O2]

# Standard 10-20 montage with Daisy module (16 channels)
export const CYTON_CHANNELS_16 = [
    Fp1 Fp2 C3 C4 P7 P8 O1 O2
    F3 F4 T7 T8 P3 P4 Fz Cz
]

# Ganglion channel names (4 channels)
export const GANGLION_CHANNELS = [Ch1 Ch2 Ch3 Ch4]

# Default channel positions for visualization (8-channel layout)
# Format: [x y] where x,y are -1.0 to 1.0 (normalized head coordinates)
export const CHANNEL_POSITIONS_8 = {
    Fp1: [-0.3 0.8]
    Fp2: [0.3 0.8]
    C3: [-0.5 0.0]
    C4: [0.5 0.0]
    P7: [-0.7 -0.4]
    P8: [0.7 -0.4]
    O1: [-0.3 -0.8]
    O2: [0.3 -0.8]
}

# Extended positions for 16-channel layout
export const CHANNEL_POSITIONS_16 = {
    Fp1: [-0.3 0.9]
    Fp2: [0.3 0.9]
    F3: [-0.5 0.5]
    F4: [0.5 0.5]
    C3: [-0.5 0.0]
    C4: [0.5 0.0]
    P3: [-0.5 -0.5]
    P4: [0.5 -0.5]
    O1: [-0.3 -0.9]
    O2: [0.3 -0.9]
    F7: [-0.8 0.4]
    F8: [0.8 0.4]
    T7: [-0.9 0.0]
    T8: [0.9 0.0]
    P7: [-0.8 -0.4]
    P8: [0.8 -0.4]
}

# =============================================================================
# EEG Band Definitions
# =============================================================================

# Standard EEG frequency bands
export const BANDS = {
    delta: {low: 0.5 high: 4.0 name: "Delta" color: "red"}
    theta: {low: 4.0 high: 8.0 name: "Theta" color: "yellow"}
    alpha: {low: 8.0 high: 13.0 name: "Alpha" color: "green"}
    beta: {low: 13.0 high: 30.0 name: "Beta" color: "blue"}
    gamma: {low: 30.0 high: 100.0 name: "Gamma" color: "magenta"}
}

# Extended gamma bands
export const GAMMA_BANDS = {
    low_gamma: {low: 30.0 high: 50.0 name: "Low Gamma" color: "light_purple"}
    high_gamma: {low: 50.0 high: 100.0 name: "High Gamma" color: "purple"}
}

# All bands combined
export def all-bands [] {
    $BANDS | merge $GAMMA_BANDS
}

# =============================================================================
# Sampling Rate Constants
# =============================================================================

export const CYTON_SAMPLE_RATE = 250
export const GANGLION_SAMPLE_RATE = 200
export const DEFAULT_SAMPLE_RATE = 250

# =============================================================================
# Unit Constants
# =============================================================================

# Conversion factors
export const UV_TO_V = 0.000001
export const V_TO_UV = 1000000

# Typical EEG amplitude ranges (in microvolts)
export const EEG_RANGES = {
    typical: {min: -100 max: 100}
    normal: {min: -200 max: 200}
    artifact: {min: -1000 max: 1000}
}

# =============================================================================
# Helper Functions for Type Validation
# =============================================================================

# Check if a record is a valid EEG sample
export def is-valid-sample [sample: record] -> bool {
    ($sample | get timestamp? | is-not-empty) and
    ($sample | get channels? | is-not-empty) and
    (($sample.channels | length) in [4 8 16])
}

# Get the number of channels from a sample
export def channel-count [sample: record] -> int {
    $sample.channels | length
}

# Create a sample from raw data
export def new-sample [
    timestamp: float
    sample_num: int
    channels: list
    aux?: list
] -> record {
    {
        timestamp: $timestamp
        sample_num: $sample_num
        channels: $channels
        aux: ($aux | default [0.0 0.0 0.0])
    }
}

# =============================================================================
# Export module info
# =============================================================================

export def module-info [] {
    {
        name: "eeg_types"
        version: "0.1.0"
        description: "Type definitions for OpenBCI EEG data"
    }
}
