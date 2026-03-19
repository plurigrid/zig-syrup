"""
Wire 1: Fisher-Rao Metric on EEG Band Power Distributions

Maps 8-channel EEG band powers to information-geometric distances.
Each channel's (delta, theta, alpha, beta, gamma) vector lives on
the probability simplex after normalization. The Fisher-Rao distance
between two such distributions is:

    d(p, q)² = 4 Σᵢ (√pᵢ - √qᵢ)²

which equals the squared Hellinger distance × 4, and is the geodesic
distance on the statistical manifold with Fisher information metric.

Integrates with:
- state_manager.nu (replaces heuristic theta/alpha/beta classifier)
- soft-machine/bci-hypergraph (D₄ symmetry channel structure)
- qri_valence_mlx.py (Wire 3: valence from vortex detection)
- okhsl_learnable.jl (Wire 4: Enzyme-trained color projection)

References:
- Amari, S. (2016). Information Geometry and Its Applications.
- Tononi, G. (2004). An information integration theory of consciousness.
"""

import numpy as np
from dataclasses import dataclass, field
from typing import List, Tuple, Optional, Dict
import json
import sys


# ═══════════════════════════════════════════════════════════════════════════
# Band Power Simplex
# ═══════════════════════════════════════════════════════════════════════════

BANDS = ["delta", "theta", "alpha", "beta", "gamma"]
BAND_RANGES_HZ = {
    "delta": (0.5, 4.0),
    "theta": (4.0, 8.0),
    "alpha": (8.0, 13.0),
    "beta": (13.0, 30.0),
    "gamma": (30.0, 50.0),
}

CHANNELS_10_20 = ["Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2"]

# D₄ symmetry: rotation and reflection on 10-20 layout
# r: Fp1 → C3 → O1 → C4 → Fp1 (90° rotation around vertex)
# s: Fp1 ↔ Fp2, C3 ↔ C4, P3 ↔ P4, O1 ↔ O2 (hemispheric reflection)
D4_ROTATION = {"Fp1": "C3", "C3": "O1", "O1": "C4", "C4": "Fp1",
               "Fp2": "P4", "P4": "O2", "O2": "P3", "P3": "Fp2"}
D4_REFLECTION = {"Fp1": "Fp2", "Fp2": "Fp1", "C3": "C4", "C4": "C3",
                 "P3": "P4", "P4": "P3", "O1": "O2", "O2": "O1"}


@dataclass
class BandPower:
    """Normalized band power distribution on the 5-simplex."""
    channel: str
    raw: np.ndarray          # [delta, theta, alpha, beta, gamma] raw power
    simplex: np.ndarray      # normalized to sum=1 (probability distribution)
    sqrt_simplex: np.ndarray # √p for Fisher-Rao computation

    @staticmethod
    def from_raw(channel: str, powers: np.ndarray, epsilon: float = 1e-10) -> "BandPower":
        raw = np.asarray(powers, dtype=np.float64)
        raw = np.maximum(raw, epsilon)  # ensure positivity
        simplex = raw / raw.sum()
        return BandPower(
            channel=channel,
            raw=raw,
            simplex=simplex,
            sqrt_simplex=np.sqrt(simplex),
        )


@dataclass
class EEGEpoch:
    """One epoch of 8-channel band powers with Fisher geometry."""
    channels: Dict[str, BandPower]
    timestamp: float = 0.0
    epoch_id: int = 0

    @staticmethod
    def from_band_dict(bands: Dict[str, np.ndarray], **kwargs) -> "EEGEpoch":
        channels = {ch: BandPower.from_raw(ch, powers) for ch, powers in bands.items()}
        return EEGEpoch(channels=channels, **kwargs)


# ═══════════════════════════════════════════════════════════════════════════
# Fisher-Rao Distance
# ═══════════════════════════════════════════════════════════════════════════

def fisher_rao_distance(p: BandPower, q: BandPower) -> float:
    """
    Geodesic distance on the statistical manifold.

    d(p, q) = 2 arccos(Σ √pᵢ √qᵢ)

    This is the exact geodesic on the probability simplex with
    Fisher information metric. Equivalent to:
        d² = 4 Σ (√pᵢ - √qᵢ)²
    via the identity arccos(1 - x/2)² = x for small x.
    """
    bhattacharyya_coeff = np.dot(p.sqrt_simplex, q.sqrt_simplex)
    # Clamp for numerical stability
    bhattacharyya_coeff = np.clip(bhattacharyya_coeff, -1.0, 1.0)
    return 2.0 * np.arccos(bhattacharyya_coeff)


def fisher_distance_matrix(epoch: EEGEpoch) -> np.ndarray:
    """
    8×8 Fisher-Rao distance matrix between all channel pairs.
    Entry (i,j) = geodesic distance between channel i and j
    on the statistical manifold of band power distributions.
    """
    n = len(CHANNELS_10_20)
    D = np.zeros((n, n))
    for i, ch_i in enumerate(CHANNELS_10_20):
        for j, ch_j in enumerate(CHANNELS_10_20):
            if i < j:
                d = fisher_rao_distance(epoch.channels[ch_i], epoch.channels[ch_j])
                D[i, j] = d
                D[j, i] = d
    return D


# ═══════════════════════════════════════════════════════════════════════════
# Integrated Information (Φ) via Minimum Information Partition
# ═══════════════════════════════════════════════════════════════════════════

def entropy(simplex: np.ndarray, epsilon: float = 1e-10) -> float:
    """Shannon entropy of a distribution on the simplex."""
    p = np.maximum(simplex, epsilon)
    return -np.sum(p * np.log2(p))


def joint_entropy(channels: List[BandPower]) -> float:
    """
    Joint entropy of multiple channels.
    Approximation: treat as product distribution (independence assumption)
    then subtract mutual information estimated from Fisher distances.
    """
    # Under independence: H(A,B) = H(A) + H(B)
    # Correction: H(A,B) = H(A) + H(B) - I(A;B)
    # We estimate I(A;B) from Fisher-Rao distance:
    # Small distance → high MI, large distance → low MI
    h_sum = sum(entropy(ch.simplex) for ch in channels)
    if len(channels) <= 1:
        return h_sum

    # Pairwise MI correction via Fisher distance
    mi_total = 0.0
    for i in range(len(channels)):
        for j in range(i + 1, len(channels)):
            d = fisher_rao_distance(channels[i], channels[j])
            # MI ≈ -log(d/π) for d ∈ (0, π]; max MI when d→0
            mi_total += max(0.0, -np.log2(d / np.pi + 1e-10))
    return h_sum - mi_total


def phi_mip(epoch: EEGEpoch) -> Tuple[float, Tuple[List[str], List[str]]]:
    """
    Integrated information Φ via minimum information partition.

    For 8 channels, enumerate all 2⁷ - 1 = 127 nontrivial bipartitions.
    For each (A, B):
        Φ(A,B) = I(A;B) = H(A) + H(B) - H(A∪B)
    Φ = min over all bipartitions.

    Returns (phi_value, (partition_A, partition_B)).
    """
    n = len(CHANNELS_10_20)
    all_channels = [epoch.channels[ch] for ch in CHANNELS_10_20]
    h_total = joint_entropy(all_channels)

    min_phi = float("inf")
    best_partition = ([], [])

    # Enumerate bipartitions: use bitmask 1..2^(n-1)-1
    # (only need half due to symmetry A↔B)
    for mask in range(1, 2 ** (n - 1)):
        part_a = [CHANNELS_10_20[i] for i in range(n) if mask & (1 << i)]
        part_b = [CHANNELS_10_20[i] for i in range(n) if not (mask & (1 << i))]

        channels_a = [epoch.channels[ch] for ch in part_a]
        channels_b = [epoch.channels[ch] for ch in part_b]

        h_a = joint_entropy(channels_a)
        h_b = joint_entropy(channels_b)

        # Mutual information = H(A) + H(B) - H(A,B)
        mi = h_a + h_b - h_total
        mi = max(0.0, mi)  # numerical floor

        if mi < min_phi:
            min_phi = mi
            best_partition = (part_a, part_b)

    return min_phi, best_partition


# ═══════════════════════════════════════════════════════════════════════════
# D₄ Symmetry Breaking Score
# ═══════════════════════════════════════════════════════════════════════════

def d4_symmetry_breaking(epoch: EEGEpoch) -> Dict[str, float]:
    """
    Measure how much each D₄ generator breaks symmetry.

    For reflection s: compare d(ch, s(ch)) for all channels
    For rotation r: compare d(ch, r(ch)) for all channels

    Low breaking → brain in symmetric state (rest, meditation)
    High breaking → asymmetric activation (focused attention, lateralized)
    """
    scores = {}

    # Reflection symmetry breaking
    ref_distances = []
    for ch, reflected in D4_REFLECTION.items():
        if ch < reflected:  # avoid double counting
            d = fisher_rao_distance(epoch.channels[ch], epoch.channels[reflected])
            ref_distances.append(d)
    scores["reflection"] = float(np.mean(ref_distances))

    # Rotation symmetry breaking
    rot_distances = []
    for ch, rotated in D4_ROTATION.items():
        d = fisher_rao_distance(epoch.channels[ch], epoch.channels[rotated])
        rot_distances.append(d)
    scores["rotation"] = float(np.mean(rot_distances))

    # Total symmetry = geometric mean
    scores["total"] = float(np.sqrt(scores["reflection"] * scores["rotation"]))

    return scores


# ═══════════════════════════════════════════════════════════════════════════
# GF(3) Trit Assignment from Information Geometry
# ═══════════════════════════════════════════════════════════════════════════

def gf3_trit_from_phi(phi: float, sym_breaking: float) -> int:
    """
    Map (Φ, symmetry_breaking) to GF(3) trit.

    PLUS (+1):    high Φ, low breaking → integrated, symmetric (meditative)
    ERGODIC (0):  medium → transitional, balanced
    MINUS (-1):   low Φ, high breaking → fragmented, asymmetric (drowsy/stressed)
    """
    # Composite score: Φ penalized by symmetry breaking
    score = phi / (1.0 + sym_breaking)

    if score > 1.5:
        return 1   # PLUS
    elif score > 0.5:
        return 0   # ERGODIC
    else:
        return -1  # MINUS


# ═══════════════════════════════════════════════════════════════════════════
# State Classification (replaces heuristic in state_manager.nu)
# ═══════════════════════════════════════════════════════════════════════════

def classify_state(epoch: EEGEpoch) -> Dict:
    """
    Information-geometric brain state classification.

    Returns dict compatible with state_manager.nu format:
    {state, confidence, phi, trit, symmetry_breaking, fisher_matrix}
    """
    # Compute Fisher distance matrix
    D = fisher_distance_matrix(epoch)

    # Compute Φ
    phi, partition = phi_mip(epoch)

    # D₄ symmetry breaking
    sym = d4_symmetry_breaking(epoch)

    # GF(3) trit
    trit = gf3_trit_from_phi(phi, sym["total"])

    # State from information geometry
    # High Φ + low breaking → meditative/focused
    # Low Φ + high breaking → drowsy/stressed
    # Medium → relaxed/unknown
    mean_fisher = float(D[np.triu_indices_from(D, k=1)].mean()) if D.size > 0 else 0.0

    # Thresholds calibrated for 8-channel OpenBCI Cyton
    # Φ range: ~24-35 for typical states
    # Fisher distance range: 0-0.5 for adjacent channels
    if phi > 32.0 and sym["reflection"] < 0.15:
        state = "meditative"
        confidence = min(0.95, phi / 36.0)
    elif phi > 30.0 and sym["total"] < 0.2 and mean_fisher < 0.3:
        state = "relaxed"
        confidence = min(0.85, phi / 35.0)
    elif phi < 26.0 and sym["total"] > 0.1:
        state = "focused"
        confidence = min(0.9, (35.0 - phi) / 12.0)
    elif phi < 25.0 and sym["reflection"] > 0.05:
        state = "drowsy"
        confidence = 0.7
    elif phi < 28.0 and sym["total"] > 0.15:
        state = "stressed"
        confidence = 0.65
    elif phi > 28.0 and sym["total"] < 0.15:
        state = "alert"
        confidence = 0.7
    else:
        state = "unknown"
        confidence = 0.4

    return {
        "state": state,
        "confidence": confidence,
        "phi": float(phi),
        "trit": trit,
        "partition": [list(partition[0]), list(partition[1])],
        "symmetry_breaking": sym,
        "mean_fisher_distance": mean_fisher,
        "fisher_matrix": D.tolist(),
    }


# ═══════════════════════════════════════════════════════════════════════════
# CSV Ingestion (from duck/recordings_eeg.csv or live stream)
# ═══════════════════════════════════════════════════════════════════════════

def epoch_from_raw_eeg(samples: np.ndarray, sample_rate: int = 250) -> EEGEpoch:
    """
    Convert raw EEG samples (N × 8) to band powers via Welch PSD.

    Parameters:
        samples: (N, 8) array of microvolt values
        sample_rate: Hz (250 for Cyton, 200 for Ganglion)

    Returns:
        EEGEpoch with band powers computed per channel.
    """
    from scipy.signal import welch

    bands = {}
    for ch_idx, ch_name in enumerate(CHANNELS_10_20):
        signal = samples[:, ch_idx]
        freqs, psd = welch(signal, fs=sample_rate, nperseg=min(len(signal), sample_rate))

        powers = np.zeros(5)
        for band_idx, (band_name, (f_low, f_high)) in enumerate(BAND_RANGES_HZ.items()):
            mask = (freqs >= f_low) & (freqs < f_high)
            powers[band_idx] = np.trapz(psd[mask], freqs[mask]) if mask.any() else 1e-10

        bands[ch_name] = powers

    return EEGEpoch.from_band_dict(bands)


# ═══════════════════════════════════════════════════════════════════════════
# CLI Entry Point
# ═══════════════════════════════════════════════════════════════════════════

def main():
    """Process EEG CSV and output information-geometric classification."""
    import csv

    if len(sys.argv) < 2:
        print("Usage: python fisher_eeg.py <recordings.csv> [window_size]")
        print("  window_size: samples per epoch (default: 250 = 1 second)")
        sys.exit(1)

    csv_path = sys.argv[1]
    window_size = int(sys.argv[2]) if len(sys.argv) > 2 else 250

    # Read CSV
    rows = []
    with open(csv_path) as f:
        reader = csv.reader(f)
        for row in reader:
            rows.append([float(x) for x in row])

    samples = np.array(rows)
    n_epochs = len(samples) // window_size

    results = []
    for i in range(n_epochs):
        window = samples[i * window_size : (i + 1) * window_size]
        epoch = epoch_from_raw_eeg(window)
        epoch.epoch_id = i
        result = classify_state(epoch)
        result["epoch_id"] = i
        results.append(result)

        # Print per-epoch summary
        print(
            f"epoch={i:4d} state={result['state']:12s} "
            f"Φ={result['phi']:.3f} trit={result['trit']:+d} "
            f"sym_break={result['symmetry_breaking']['total']:.3f} "
            f"conf={result['confidence']:.2f}"
        )

    # Write full results as JSON
    output_path = csv_path.rsplit(".", 1)[0] + "_fisher.json"
    with open(output_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nWrote {len(results)} epochs to {output_path}")


if __name__ == "__main__":
    main()
