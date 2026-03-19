"""
Wire 2+3: Valence Bridge — Fisher Geometry → Phenomenal Field → Color

Takes the Fisher-Rao distance matrix from Wire 1 and:
1. Interpolates 8 channels onto 2D scalp grid (phenomenal field)
2. Runs QRI vortex detection (adapted from qri_valence_mlx.py)
3. Computes valence = -log(vortex_count + ε)
4. Projects (Φ, valence, fisher_mean) → deterministic color

This bridges:
- fisher_eeg.py (Wire 1) → information geometry
- qri_valence_mlx.py → vortex topology
- Gay.jl okhsl_learnable.jl (Wire 4) → Enzyme-trained color projection

For now, Wire 4 uses a fixed golden-angle color projection.
Once Enzyme training is run, the learned parameters replace the defaults.
"""

import numpy as np
from dataclasses import dataclass
from typing import Tuple, Dict, Optional
import json
import sys
import hashlib

from fisher_eeg import (
    EEGEpoch, BandPower, CHANNELS_10_20, BANDS,
    fisher_distance_matrix, phi_mip, d4_symmetry_breaking,
    classify_state, epoch_from_raw_eeg,
)


# ═══════════════════════════════════════════════════════════════════════════
# 10-20 Electrode Positions (normalized to [0,1]²)
# ═══════════════════════════════════════════════════════════════════════════

ELECTRODE_POS = {
    "Fp1": (0.30, 0.90),  # frontal left
    "Fp2": (0.70, 0.90),  # frontal right
    "C3":  (0.25, 0.50),  # central left
    "C4":  (0.75, 0.50),  # central right
    "P3":  (0.30, 0.20),  # parietal left
    "P4":  (0.70, 0.20),  # parietal right
    "O1":  (0.35, 0.05),  # occipital left
    "O2":  (0.65, 0.05),  # occipital right
}

GRID_SIZE = 16  # 16×16 phenomenal field


# ═══════════════════════════════════════════════════════════════════════════
# Phenomenal Field Construction
# ═══════════════════════════════════════════════════════════════════════════

def interpolate_scalp_field(
    epoch: EEGEpoch,
    band: str = "alpha",
    grid_size: int = GRID_SIZE,
) -> np.ndarray:
    """
    Interpolate electrode band powers onto a regular 2D grid.
    Uses inverse-distance weighting (IDW) — simple, no scipy dependency.

    Parameters:
        epoch: EEG epoch with band powers
        band: which frequency band to visualize ("alpha", "beta", etc.)
        grid_size: output grid resolution

    Returns:
        (grid_size, grid_size) array — the phenomenal field
    """
    band_idx = BANDS.index(band)
    field = np.zeros((grid_size, grid_size))
    weights = np.zeros((grid_size, grid_size))

    for ch_name, (ex, ey) in ELECTRODE_POS.items():
        power = epoch.channels[ch_name].simplex[band_idx]
        gx, gy = int(ex * (grid_size - 1)), int(ey * (grid_size - 1))

        for i in range(grid_size):
            for j in range(grid_size):
                dx = (i - gx) / grid_size
                dy = (j - gy) / grid_size
                dist = np.sqrt(dx * dx + dy * dy) + 1e-6
                w = 1.0 / (dist ** 2)  # IDW power=2
                field[i, j] += power * w
                weights[i, j] += w

    return field / weights


def multi_band_field(epoch: EEGEpoch, grid_size: int = GRID_SIZE) -> np.ndarray:
    """
    Construct phenomenal field from all bands.
    Uses alpha-theta ratio as the primary field value (engagement proxy).
    """
    alpha_field = interpolate_scalp_field(epoch, "alpha", grid_size)
    theta_field = interpolate_scalp_field(epoch, "theta", grid_size)
    beta_field = interpolate_scalp_field(epoch, "beta", grid_size)

    # Engagement = (alpha + beta) / (theta + epsilon)
    # High engagement → focused; low → drowsy
    return (alpha_field + beta_field) / (theta_field + 1e-10)


# ═══════════════════════════════════════════════════════════════════════════
# QRI Vortex Detection (adapted from qri_valence_mlx.py, pure numpy)
# ═══════════════════════════════════════════════════════════════════════════

def detect_vortices(field: np.ndarray, threshold: float = 0.5) -> Tuple[int, float]:
    """
    Detect topological defects via 2D FFT phase winding.

    Returns (vortex_count, symmetry_score).

    Based on QRI Symmetry Theory of Valence:
    - Vortices = broken symmetries in the phenomenal field
    - Fewer vortices = higher valence = more consonant experience
    """
    fft_result = np.fft.fft2(field)
    magnitude = np.abs(fft_result)
    phase = np.angle(fft_result)

    size = field.shape[0]

    # Symmetry score: ratio of low-freq to total energy
    total_energy = np.sum(magnitude ** 2)
    low_freq_mask = np.zeros_like(magnitude, dtype=bool)
    cutoff = size // 8
    for i in range(size):
        for j in range(size):
            di = min(i, size - i)
            dj = min(j, size - j)
            if di * di + dj * dj < cutoff * cutoff:
                low_freq_mask[i, j] = True

    low_freq_energy = np.sum(magnitude[low_freq_mask] ** 2)
    symmetry = low_freq_energy / (total_energy + 1e-10)

    # Phase gradient vortex detection
    grad_x = np.abs(np.diff(phase, axis=0))
    grad_y = np.abs(np.diff(phase, axis=1))

    # Wrap phase differences to [-π, π]
    grad_x = np.where(grad_x > np.pi, 2 * np.pi - grad_x, grad_x)
    grad_y = np.where(grad_y > np.pi, 2 * np.pi - grad_y, grad_y)

    vortex_count = int(np.sum(grad_x > threshold) + np.sum(grad_y > threshold))

    return vortex_count, float(symmetry)


def compute_valence(vortex_count: int, epsilon: float = 1e-6) -> float:
    """
    Valence = -log(vortex_count + ε)

    Fewer defects → higher valence → more consonant phenomenal state.
    """
    return -np.log(vortex_count + epsilon)


# ═══════════════════════════════════════════════════════════════════════════
# Color Projection (Wire 4 stub — golden angle until Enzyme training)
# ═══════════════════════════════════════════════════════════════════════════

GOLDEN_ANGLE = 137.5077640500378  # degrees
PLASTIC_ANGLE = 205.1442270324102  # GF(3) ternary variant


@dataclass
class IntegratedColor:
    """Color encoding integrated information state."""
    h: float  # hue [0, 360)
    c: float  # chroma [0, 1]
    l: float  # lightness [0, 1]
    r: int    # sRGB red [0, 255]
    g: int    # sRGB green [0, 255]
    b: int    # sRGB blue [0, 255]
    hex: str  # "#RRGGBB"
    trit: int # GF(3) trit


def hcl_to_rgb(h: float, c: float, l: float) -> Tuple[int, int, int]:
    """
    Convert HCL to sRGB via HSL intermediate.
    Simplified conversion for the golden-angle projection.
    """
    # HCL → HSL approximation
    s = c
    h_norm = h / 360.0

    def hue_to_rgb(p, q, t):
        if t < 0: t += 1
        if t > 1: t -= 1
        if t < 1/6: return p + (q - p) * 6 * t
        if t < 1/2: return q
        if t < 2/3: return p + (q - p) * (2/3 - t) * 6
        return p

    if s == 0:
        r = g = b = l
    else:
        q = l * (1 + s) if l < 0.5 else l + s - l * s
        p = 2 * l - q
        r = hue_to_rgb(p, q, h_norm + 1/3)
        g = hue_to_rgb(p, q, h_norm)
        b = hue_to_rgb(p, q, h_norm - 1/3)

    ri = max(0, min(255, int(r * 255)))
    gi = max(0, min(255, int(g * 255)))
    bi = max(0, min(255, int(b * 255)))
    return ri, gi, bi


def project_to_color(
    phi: float,
    valence: float,
    mean_fisher: float,
    trit: int,
    seed: int = 1069,
) -> IntegratedColor:
    """
    Project (Φ, valence, fisher_distance) → deterministic color.

    Golden-angle projection (default until Enzyme-trained params replace it):
    - Hue: determined by Φ mod golden_angle (dispersed across states)
    - Chroma: from valence (high valence → saturated)
    - Lightness: from mean Fisher distance (high distance → bright)

    The seed ensures deterministic reproducibility (SPI guarantee).
    """
    # Deterministic hash for stability
    state_bytes = f"{phi:.6f}:{valence:.6f}:{mean_fisher:.6f}:{seed}".encode()
    hash_val = int(hashlib.sha256(state_bytes).hexdigest()[:8], 16)

    # Hue from Φ via golden angle rotation
    hue = (phi * GOLDEN_ANGLE + hash_val * 0.001) % 360.0

    # Chroma from valence: high valence → high saturation
    # valence ∈ (-∞, -log(ε)] typically [-10, 0]
    valence_norm = 1.0 / (1.0 + np.exp(-valence - 3.0))  # sigmoid centering
    chroma = 0.3 + 0.6 * valence_norm

    # Lightness from Fisher distance
    fisher_norm = 1.0 / (1.0 + np.exp(-mean_fisher + 1.0))
    lightness = 0.3 + 0.4 * fisher_norm

    # GF(3) trit adjustment
    if trit == 1:    # PLUS: warmer
        hue = (hue + 20) % 360
    elif trit == -1:  # MINUS: cooler
        hue = (hue - 20) % 360

    r, g, b = hcl_to_rgb(hue, chroma, lightness)
    hex_str = f"#{r:02x}{g:02x}{b:02x}"

    return IntegratedColor(
        h=hue, c=chroma, l=lightness,
        r=r, g=g, b=b, hex=hex_str, trit=trit,
    )


# ═══════════════════════════════════════════════════════════════════════════
# Content Identifier (CID) for Verifiability
# ═══════════════════════════════════════════════════════════════════════════

def compute_cid(color: IntegratedColor, phi: float, valence: float) -> str:
    """
    Content-addressed identifier for the color+state pair.
    SHA-256 of the canonical representation.
    Suitable for Merkle tree leaf in qualia_market.move.
    """
    canonical = json.dumps({
        "hex": color.hex,
        "trit": color.trit,
        "phi": round(phi, 6),
        "valence": round(valence, 6),
    }, sort_keys=True)
    return hashlib.sha256(canonical.encode()).hexdigest()


# ═══════════════════════════════════════════════════════════════════════════
# Full Pipeline: EEG → Fisher → Φ → Valence → Color → CID
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class ColorEpoch:
    """Complete integrated information → color mapping for one epoch."""
    epoch_id: int
    state: str
    confidence: float
    phi: float
    valence: float
    vortex_count: int
    symmetry_score: float
    trit: int
    mean_fisher: float
    color: IntegratedColor
    cid: str
    partition: Tuple


def process_epoch(epoch: EEGEpoch) -> ColorEpoch:
    """Full pipeline for one epoch."""
    # Wire 1: Fisher geometry
    D = fisher_distance_matrix(epoch)
    phi, partition = phi_mip(epoch)
    sym = d4_symmetry_breaking(epoch)
    classification = classify_state(epoch)

    mean_fisher = float(D[np.triu_indices_from(D, k=1)].mean()) if D.size > 0 else 0.0

    # Wire 2+3: Phenomenal field → vortex detection
    field = multi_band_field(epoch)
    vortex_count, symmetry_score = detect_vortices(field)
    valence = compute_valence(vortex_count)

    # Wire 4: Color projection
    trit = classification["trit"]
    color = project_to_color(phi, valence, mean_fisher, trit)
    cid = compute_cid(color, phi, valence)

    return ColorEpoch(
        epoch_id=epoch.epoch_id,
        state=classification["state"],
        confidence=classification["confidence"],
        phi=phi,
        valence=valence,
        vortex_count=vortex_count,
        symmetry_score=symmetry_score,
        trit=trit,
        mean_fisher=mean_fisher,
        color=color,
        cid=cid,
        partition=tuple(partition),
    )


# ═══════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════

def main():
    """Full pipeline: EEG CSV → information-geometric color."""
    import csv

    if len(sys.argv) < 2:
        print("Usage: python valence_bridge.py <recordings.csv> [window_size]")
        sys.exit(1)

    csv_path = sys.argv[1]
    window_size = int(sys.argv[2]) if len(sys.argv) > 2 else 250

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

        ce = process_epoch(epoch)
        results.append({
            "epoch_id": ce.epoch_id,
            "state": ce.state,
            "confidence": ce.confidence,
            "phi": ce.phi,
            "valence": ce.valence,
            "vortex_count": ce.vortex_count,
            "symmetry_score": ce.symmetry_score,
            "trit": ce.trit,
            "mean_fisher": ce.mean_fisher,
            "color_hex": ce.color.hex,
            "color_rgb": [ce.color.r, ce.color.g, ce.color.b],
            "color_hcl": [ce.color.h, ce.color.c, ce.color.l],
            "cid": ce.cid,
        })

        # ANSI color preview
        r, g, b = ce.color.r, ce.color.g, ce.color.b
        color_block = f"\033[48;2;{r};{g};{b}m  \033[0m"
        print(
            f"epoch={i:4d} {color_block} {ce.color.hex} "
            f"state={ce.state:12s} Φ={ce.phi:.1f} "
            f"val={ce.valence:.2f} vortex={ce.vortex_count:4d} "
            f"trit={ce.trit:+d} cid={ce.cid[:12]}…"
        )

    output_path = csv_path.rsplit(".", 1)[0] + "_color.json"
    with open(output_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nWrote {len(results)} color epochs to {output_path}")


if __name__ == "__main__":
    main()
