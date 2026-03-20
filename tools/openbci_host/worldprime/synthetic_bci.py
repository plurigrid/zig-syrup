"""
Realistic Synthetic BCI Generator

Matches the Go SyntheticBCI generator in soft-machine/bci-hypergraph/openbci.go:
- Per-channel phase offsets (φ = ch × π/4)
- State-dependent band amplitude profiles
- SplitMix64 deterministic noise (seed 1069)
- State transitions over time

Generates CSVs with proper per-channel variation for testing
the Fisher-Rao / Φ / valence pipeline.
"""

import numpy as np
from typing import List, Tuple
import sys


# SplitMix64 matching Go implementation
class SplitMix64:
    def __init__(self, seed: int = 1069):
        self.state = seed & 0xFFFFFFFFFFFFFFFF

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
        z = z ^ (z >> 31)
        return z & 0xFFFFFFFFFFFFFFFF

    def noise(self) -> float:
        """Uniform noise in [-2.5, 2.5], matching Go: (rng%10000/10000 - 0.5) * 5"""
        return (float(self.next() % 10000) / 10000.0 - 0.5) * 5.0


# Brain state profiles matching Go code (openbci.go:318-327)
STATE_PROFILES = {
    "resting":  {"delta": 0.3, "theta": 0.3, "alpha": 0.8, "beta": 0.2, "gamma": 0.1},
    "focused":  {"delta": 0.1, "theta": 0.2, "alpha": 0.3, "beta": 0.7, "gamma": 0.5},
    "drowsy":   {"delta": 0.5, "theta": 0.9, "alpha": 0.4, "beta": 0.1, "gamma": 0.05},
    "alert":    {"delta": 0.1, "theta": 0.1, "alpha": 0.2, "beta": 0.6, "gamma": 0.8},
    "meditative": {"delta": 0.2, "theta": 0.6, "alpha": 0.9, "beta": 0.1, "gamma": 0.05},
    "stressed": {"delta": 0.2, "theta": 0.1, "alpha": 0.1, "beta": 0.9, "gamma": 0.7},
}

# Band center frequencies (Hz)
BAND_FREQS = {"delta": 2.0, "theta": 6.0, "alpha": 10.0, "beta": 20.0, "gamma": 40.0}
# Band amplitudes (microvolts base)
BAND_AMPS = {"delta": 50.0, "theta": 30.0, "alpha": 40.0, "beta": 20.0, "gamma": 10.0}

SAMPLE_RATE = 250  # Hz
NUM_CHANNELS = 8


def generate_state_sequence(
    total_seconds: int = 60,
    states: List[str] = None,
    transition_every: int = 10,
) -> List[Tuple[str, int]]:
    """Generate a sequence of (state, duration_samples) pairs."""
    if states is None:
        states = ["resting", "focused", "drowsy", "alert", "meditative", "stressed"]

    sequence = []
    t = 0
    idx = 0
    while t < total_seconds:
        dur = min(transition_every, total_seconds - t)
        sequence.append((states[idx % len(states)], dur * SAMPLE_RATE))
        t += dur
        idx += 1
    return sequence


def generate_eeg(
    state_sequence: List[Tuple[str, int]],
    seed: int = 1069,
    lateralization: float = 0.3,
) -> np.ndarray:
    """
    Generate realistic 8-channel EEG matching SyntheticBCI.generateSample().

    Parameters:
        state_sequence: list of (state_name, n_samples)
        seed: SplitMix64 seed for deterministic noise
        lateralization: how much channels differ (0=identical, 1=maximum)

    Returns:
        (N, 8) array of microvolt values
    """
    rng = SplitMix64(seed)
    all_samples = []

    t = 0.0
    dt = 1.0 / SAMPLE_RATE

    # Per-channel lateralization weights (asymmetric brain activity)
    # Left hemisphere (Fp1, C3, P3, O1) vs right (Fp2, C4, P4, O2)
    # Channels: Fp1=0, Fp2=1, C3=2, C4=3, P3=4, P4=5, O1=6, O2=7
    lateral_weights = np.array([
        # delta  theta  alpha  beta   gamma  (per channel modulation)
        [1.0,    1.0,   1.2,   0.8,   0.9],   # Fp1: more alpha (left frontal)
        [1.0,    1.0,   0.8,   1.2,   1.1],   # Fp2: more beta (right frontal)
        [0.9,    1.1,   1.3,   0.7,   0.8],   # C3: high alpha (left central)
        [1.1,    0.9,   0.7,   1.3,   1.2],   # C4: high beta (right central)
        [1.2,    1.2,   1.1,   0.9,   0.7],   # P3: more theta (left parietal)
        [0.8,    0.8,   0.9,   1.1,   1.3],   # P4: more gamma (right parietal)
        [1.3,    1.0,   1.4,   0.6,   0.5],   # O1: very high alpha (left occipital)
        [0.7,    1.0,   0.6,   1.4,   1.5],   # O2: very high gamma (right occipital)
    ])

    # Blend between uniform and lateralized
    lateral_weights = (1.0 - lateralization) * np.ones_like(lateral_weights) + lateralization * lateral_weights

    for state_name, n_samples in state_sequence:
        profile = STATE_PROFILES[state_name]
        bands = list(BAND_FREQS.keys())

        for _ in range(n_samples):
            sample = np.zeros(NUM_CHANNELS)

            for ch in range(NUM_CHANNELS):
                phi = float(ch) * np.pi / 4.0  # phase offset per channel
                noise = rng.noise()

                signal = 0.0
                for bi, band in enumerate(bands):
                    amp = profile[band] * BAND_AMPS[band] * lateral_weights[ch, bi]
                    freq = BAND_FREQS[band]
                    signal += amp * np.sin(2 * np.pi * freq * t + phi)

                signal += noise
                sample[ch] = signal

            all_samples.append(sample)
            t += dt

    return np.array(all_samples)


def main():
    """Generate synthetic EEG CSV with realistic per-channel variation."""
    total_seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1069
    output = sys.argv[3] if len(sys.argv) > 3 else "synthetic_eeg.csv"
    lateralization = float(sys.argv[4]) if len(sys.argv) > 4 else 0.3

    states = ["resting", "focused", "drowsy", "alert", "meditative", "stressed"]
    sequence = generate_state_sequence(total_seconds, states, transition_every=10)

    print(f"Generating {total_seconds}s of synthetic EEG (seed={seed}, lat={lateralization})")
    print(f"State sequence:")
    for state, n in sequence:
        print(f"  {state:12s} {n/SAMPLE_RATE:.0f}s ({n} samples)")

    samples = generate_eeg(sequence, seed=seed, lateralization=lateralization)

    # Write CSV (no header, matching recordings_eeg.csv format)
    np.savetxt(output, samples, delimiter=",", fmt="%.10f")
    print(f"\nWrote {len(samples)} samples ({len(samples)/SAMPLE_RATE:.0f}s) to {output}")

    # Also write state labels for ground truth
    labels_path = output.rsplit(".", 1)[0] + "_labels.csv"
    with open(labels_path, "w") as f:
        for state, n in sequence:
            for _ in range(n):
                f.write(f"{state}\n")
    print(f"Wrote ground truth labels to {labels_path}")


if __name__ == "__main__":
    main()
