"""
Wire 4 Bridge: Enzyme Color Training Data Export / Import

Bridges the Python BCI pipeline ↔ Julia Gay.jl Enzyme training:

1. EXPORT: Converts labeled EEG epochs → Julia training data (JSON)
   - Seeds derived from (Φ, valence, mean_fisher) state vector
   - Class labels from brain state classification
   - Ready for enzyme_learn_colorspace!() in GayEnzymeExt.jl

2. IMPORT: Reads trained OkhslParameters + SeedProjection from Julia
   - Replaces golden-angle stub in valence_bridge.py:project_to_color()
   - Deterministic: same state vector → same color post-training

3. GENERATE: Writes a Julia training script that runs Gay.jl + Enzyme

The trained parameters learn to:
- Map same brain state → similar hue (intra-class cohesion)
- Map different states → distinct hues (inter-class separation)
- Maintain perceptual uniformity via OkhslParameters gamma
"""

import json
import sys
import hashlib
import math
import os
from dataclasses import dataclass, asdict
from typing import List, Dict, Optional, Tuple

import numpy as np


# ═══════════════════════════════════════════════════════════════════════════
# Enzyme Parameter Structures (Python mirrors of Julia types)
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class OkhslParameters:
    """Mirror of Gay.jl OkhslParameters."""
    h_scale: float = 360.0
    h_offset: float = 0.0
    s_min: float = 0.5
    s_max: float = 0.9
    l_min: float = 0.35
    l_max: float = 0.75
    gamma: float = 1.0


@dataclass
class SeedProjection:
    """Mirror of Gay.jl SeedProjection."""
    w_h: List[float] = None
    w_s: List[float] = None
    w_l: List[float] = None
    bias: List[float] = None

    def __post_init__(self):
        phi = 1.618033988749895
        if self.w_h is None:
            self.w_h = [1.0/phi, 1.0/phi**2, 1.0/phi**3]
        if self.w_s is None:
            self.w_s = [1.0/phi**4, 1.0/phi**5, 1.0/phi**6]
        if self.w_l is None:
            self.w_l = [1.0/phi**7, 1.0/phi**8, 1.0/phi**9]
        if self.bias is None:
            self.bias = [0.0, 0.5, 0.35]


@dataclass
class EnzymeTrainedColorSpace:
    """Complete trained color space from Enzyme."""
    params: OkhslParameters
    projection: SeedProjection
    training_loss: float = 0.0
    training_epochs: int = 0
    n_classes: int = 0


# ═══════════════════════════════════════════════════════════════════════════
# Enzyme-compatible Forward Pass (Python port of Julia enzyme_forward_color)
# ═══════════════════════════════════════════════════════════════════════════

def enzyme_forward_color(
    params: OkhslParameters,
    proj: SeedProjection,
    seed: float,
) -> Tuple[float, float, float, float, float, float]:
    """
    Python port of GayEnzymeExt.jl enzyme_forward_color.
    Returns (r, g, b, h, s, l) for the given seed.
    """
    omega1 = 2 * math.pi * 0.618033988749895
    omega2 = 2 * math.pi * 0.414213562373095
    omega3 = 2 * math.pi * 0.302775637731995

    f1 = 0.5 + 0.5 * math.sin(seed * omega1)
    f2 = 0.5 + 0.5 * math.sin(seed * omega2 + 1.0)
    f3 = 0.5 + 0.5 * math.sin(seed * omega3 + 2.0)

    # Project features
    h_raw = proj.w_h[0]*f1 + proj.w_h[1]*f2 + proj.w_h[2]*f3 + proj.bias[0]
    s_raw = proj.w_s[0]*f1 + proj.w_s[1]*f2 + proj.w_s[2]*f3 + proj.bias[1]
    l_raw = proj.w_l[0]*f1 + proj.w_l[1]*f2 + proj.w_l[2]*f3 + proj.bias[2]

    # Apply Okhsl parameters
    h = params.h_offset + params.h_scale * h_raw
    h_normalized = h / 360.0
    h_mod = 360.0 * (h_normalized - math.floor(h_normalized))

    s_sigmoid = 1.0 / (1.0 + math.exp(-params.gamma * (s_raw - 0.5) * 4.0))
    s = params.s_min + (params.s_max - params.s_min) * s_sigmoid

    l_sigmoid = 1.0 / (1.0 + math.exp(-params.gamma * (l_raw - 0.5) * 4.0))
    l = params.l_min + (params.l_max - params.l_min) * l_sigmoid

    # HSL to RGB (soft sector selection matching Julia)
    h_norm = h_mod / 360.0
    c = (1.0 - abs(2.0*l - 1.0)) * s
    h6 = h_norm * 6.0
    x = c * (1.0 - abs((h6 % 2.0) - 1.0))
    m = l - c/2.0

    sigma = 0.1
    def soft_step(x, a):
        return 1.0 / (1.0 + math.exp(-(x - a) / sigma))

    s0 = soft_step(h6, 0.0) * (1.0 - soft_step(h6, 1.0))
    s1 = soft_step(h6, 1.0) * (1.0 - soft_step(h6, 2.0))
    s2 = soft_step(h6, 2.0) * (1.0 - soft_step(h6, 3.0))
    s3 = soft_step(h6, 3.0) * (1.0 - soft_step(h6, 4.0))
    s4 = soft_step(h6, 4.0) * (1.0 - soft_step(h6, 5.0))
    s5 = soft_step(h6, 5.0) * (1.0 - soft_step(h6, 6.0))

    r = s0*c + s1*x + s4*x + s5*c + m
    g = s0*x + s1*c + s2*c + s3*x + m
    b = s2*x + s3*c + s4*c + s5*x + m

    def soft_clamp(x):
        return 0.5 + 0.5 * math.tanh((x - 0.5) * 4.0)

    return (soft_clamp(r), soft_clamp(g), soft_clamp(b), h_mod, s, l)


# ═══════════════════════════════════════════════════════════════════════════
# State Vector → Seed Conversion
# ═══════════════════════════════════════════════════════════════════════════

STATE_TO_CLASS = {
    "meditative": 1,
    "relaxed": 2,
    "focused": 3,
    "alert": 4,
    "stressed": 5,
    "drowsy": 6,
    "unknown": 0,
}


def state_vector_to_seed(phi: float, valence: float, mean_fisher: float) -> float:
    """
    Convert (Φ, valence, mean_fisher) state vector to a float64 seed
    compatible with Gay.jl's seed_to_features_smooth().

    The seed must be deterministic: same state → same seed.
    We use a hash-based approach that preserves locality.
    """
    # Canonical string → SHA-256 → float64 seed
    canonical = f"{phi:.6f}:{valence:.6f}:{mean_fisher:.6f}"
    h = hashlib.sha256(canonical.encode()).hexdigest()
    # Take first 16 hex chars → uint64 → float64
    seed_int = int(h[:16], 16)
    return float(seed_int)


# ═══════════════════════════════════════════════════════════════════════════
# EXPORT: Color epochs → Julia training data
# ═══════════════════════════════════════════════════════════════════════════

def export_training_data(color_json_path: str, output_path: str):
    """
    Read color pipeline output and export as Julia-compatible training data.

    Input: JSON from valence_bridge.py (array of epoch dicts)
    Output: JSON with {seeds: Float64[], class_labels: Int[], metadata: {...}}
    """
    with open(color_json_path) as f:
        epochs = json.load(f)

    seeds = []
    class_labels = []
    metadata = []

    for ep in epochs:
        phi = ep["phi"]
        valence = ep["valence"]
        mean_fisher = ep.get("mean_fisher", 0.0)
        state = ep["state"]

        seed = state_vector_to_seed(phi, valence, mean_fisher)
        label = STATE_TO_CLASS.get(state, 0)

        seeds.append(seed)
        class_labels.append(label)
        metadata.append({
            "epoch_id": ep["epoch_id"],
            "state": state,
            "phi": phi,
            "valence": valence,
            "color_hex": ep.get("color_hex", ""),
            "cid": ep.get("cid", ""),
        })

    training_data = {
        "seeds": seeds,
        "class_labels": class_labels,
        "n_classes": len(set(class_labels)),
        "n_samples": len(seeds),
        "metadata": metadata,
        "source": color_json_path,
    }

    with open(output_path, "w") as f:
        json.dump(training_data, f, indent=2)

    # Summary
    from collections import Counter
    counts = Counter(class_labels)
    print(f"  Exported {len(seeds)} training samples to {output_path}")
    print(f"  Classes ({len(counts)}):")
    class_names = {v: k for k, v in STATE_TO_CLASS.items()}
    for label, count in sorted(counts.items()):
        print(f"    {class_names.get(label, 'unknown'):12s} (label={label}): {count} samples")

    return training_data


# ═══════════════════════════════════════════════════════════════════════════
# IMPORT: Trained parameters from Julia → Python
# ═══════════════════════════════════════════════════════════════════════════

def import_trained_params(params_json_path: str) -> EnzymeTrainedColorSpace:
    """
    Import trained OkhslParameters + SeedProjection from Julia output.

    Expected JSON format:
    {
        "params": {"h_scale": ..., "h_offset": ..., ...},
        "projection": {"w_h": [...], "w_s": [...], "w_l": [...], "bias": [...]},
        "training_loss": ...,
        "training_epochs": ...,
        "n_classes": ...
    }
    """
    with open(params_json_path) as f:
        data = json.load(f)

    params = OkhslParameters(**data["params"])
    proj = SeedProjection(**data["projection"])

    return EnzymeTrainedColorSpace(
        params=params,
        projection=proj,
        training_loss=data.get("training_loss", 0.0),
        training_epochs=data.get("training_epochs", 0),
        n_classes=data.get("n_classes", 0),
    )


def enzyme_project_to_color(
    trained: EnzymeTrainedColorSpace,
    phi: float,
    valence: float,
    mean_fisher: float,
    trit: int,
):
    """
    Replacement for valence_bridge.py:project_to_color() using trained Enzyme params.

    Drop-in replacement that uses the learned color space instead of golden-angle.
    """
    from valence_bridge import IntegratedColor

    seed = state_vector_to_seed(phi, valence, mean_fisher)
    r, g, b, h, s, l = enzyme_forward_color(trained.params, trained.projection, seed)

    # GF(3) trit adjustment (same as golden-angle version)
    if trit == 1:
        h = (h + 20) % 360
    elif trit == -1:
        h = (h - 20) % 360

    ri = max(0, min(255, int(r * 255)))
    gi = max(0, min(255, int(g * 255)))
    bi = max(0, min(255, int(b * 255)))
    hex_str = f"#{ri:02x}{gi:02x}{bi:02x}"

    return IntegratedColor(
        h=h, c=s, l=l,
        r=ri, g=gi, b=bi, hex=hex_str, trit=trit,
    )


# ═══════════════════════════════════════════════════════════════════════════
# GENERATE: Julia training script
# ═══════════════════════════════════════════════════════════════════════════

def generate_julia_training_script(
    training_data_path: str,
    output_params_path: str,
    script_path: str,
    lr: float = 0.01,
    epochs: int = 100,
):
    """Generate a Julia script that trains Gay.jl LearnableOkhsl on BCI data."""
    script = f'''# Auto-generated training script for Gay.jl Enzyme color space
# Input:  {training_data_path} (from enzyme_color_train.py export)
# Output: {output_params_path} (trained OkhslParameters + SeedProjection)

using JSON3
using Gay
using Gay.OkhslLearnable

# Load Enzyme extension if available
try
    using Enzyme
    @info "Enzyme.jl loaded — using true autodiff"
catch
    @warn "Enzyme.jl not found — falling back to finite differences"
end

# ─── Load training data ───────────────────────────────────────────────
data = JSON3.read(read("{training_data_path}", String))
seeds = Float64.(data.seeds)
class_labels = Int.(data.class_labels)
n_classes = data.n_classes

println("Loaded $(length(seeds)) training samples, $n_classes classes")
println()

# ─── Initialize learnable color space ─────────────────────────────────
cs = LearnableOkhsl()

println("Initial parameters:")
println("  h_scale  = $(cs.params.h_scale)")
println("  h_offset = $(cs.params.h_offset)")
println("  gamma    = $(cs.params.gamma)")
println("  s_range  = [$(cs.params.s_min), $(cs.params.s_max)]")
println("  l_range  = [$(cs.params.l_min), $(cs.params.l_max)]")
println()

# ─── Train ────────────────────────────────────────────────────────────
if @isdefined(Enzyme)
    # Use Enzyme reverse-mode autodiff
    using Gay.GayEnzymeExt: enzyme_learn_colorspace!
    enzyme_learn_colorspace!(cs, seeds, class_labels;
        lr={lr}, epochs={epochs}, verbose=true)
else
    # Fallback to finite-difference training
    learn_colorspace!(cs, seeds, class_labels;
        lr={lr}, epochs={epochs}, verbose=true)
end

println()
println("Trained parameters:")
println("  h_scale  = $(round(cs.params.h_scale, digits=4))")
println("  h_offset = $(round(cs.params.h_offset, digits=4))")
println("  gamma    = $(round(cs.params.gamma, digits=4))")
println("  s_range  = [$(round(cs.params.s_min, digits=4)), $(round(cs.params.s_max, digits=4))]")
println("  l_range  = [$(round(cs.params.l_min, digits=4)), $(round(cs.params.l_max, digits=4))]")
println()

# ─── Show learned colors per class ────────────────────────────────────
println("Learned class colors:")
unique_labels = sort(unique(class_labels))
for label in unique_labels
    idx = findfirst(==(label), class_labels)
    seed = seeds[idx]
    r, g, b = forward_color(cs, seed)
    h = cs.last_h
    println("  Class $label: H=$(round(h, digits=1))° → RGB($(round(r,digits=2)), $(round(g,digits=2)), $(round(b,digits=2)))")
end

# ─── Export trained parameters ────────────────────────────────────────
final_loss = compute_loss(EquivalenceClassObjective(), cs, seeds, class_labels)

output = Dict(
    "params" => Dict(
        "h_scale" => cs.params.h_scale,
        "h_offset" => cs.params.h_offset,
        "s_min" => cs.params.s_min,
        "s_max" => cs.params.s_max,
        "l_min" => cs.params.l_min,
        "l_max" => cs.params.l_max,
        "gamma" => cs.params.gamma,
    ),
    "projection" => Dict(
        "w_h" => cs.projection.w_h,
        "w_s" => cs.projection.w_s,
        "w_l" => cs.projection.w_l,
        "bias" => cs.projection.bias,
    ),
    "training_loss" => final_loss,
    "training_epochs" => {epochs},
    "n_classes" => n_classes,
)

open("{output_params_path}", "w") do io
    JSON3.pretty(io, output)
end

println()
println("Wrote trained parameters to {output_params_path}")
println("Final loss: $(round(final_loss, digits=4))")
'''

    with open(script_path, "w") as f:
        f.write(script)

    print(f"  Generated Julia training script: {script_path}")
    print(f"  Run with: julia --project=.tmp/Gay.jl {script_path}")
    return script_path


# ═══════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════

def main():
    if len(sys.argv) < 2:
        print("Usage: python enzyme_color_train.py <command> [args...]")
        print()
        print("Commands:")
        print("  export <color.json> [output.json]   Export training data for Julia")
        print("  import <params.json>                 Verify imported trained params")
        print("  generate <training.json> [params.json] [script.jl]  Generate Julia script")
        print("  preview <params.json> <color.json>   Preview colors with trained params")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "export":
        color_path = sys.argv[2]
        output_path = sys.argv[3] if len(sys.argv) > 3 else color_path.rsplit(".", 1)[0] + "_training.json"
        export_training_data(color_path, output_path)

    elif cmd == "import":
        params_path = sys.argv[2]
        trained = import_trained_params(params_path)
        print(f"  Loaded trained color space:")
        print(f"    h_scale={trained.params.h_scale:.4f}  h_offset={trained.params.h_offset:.4f}")
        print(f"    gamma={trained.params.gamma:.4f}")
        print(f"    s_range=[{trained.params.s_min:.4f}, {trained.params.s_max:.4f}]")
        print(f"    l_range=[{trained.params.l_min:.4f}, {trained.params.l_max:.4f}]")
        print(f"    loss={trained.training_loss:.4f}  epochs={trained.training_epochs}")

    elif cmd == "generate":
        training_path = sys.argv[2]
        params_path = sys.argv[3] if len(sys.argv) > 3 else "trained_okhsl_params.json"
        script_path = sys.argv[4] if len(sys.argv) > 4 else "train_bci_colorspace.jl"
        generate_julia_training_script(training_path, params_path, script_path)

    elif cmd == "preview":
        params_path = sys.argv[2]
        color_path = sys.argv[3]
        trained = import_trained_params(params_path)
        with open(color_path) as f:
            epochs = json.load(f)

        print(f"  Preview with trained params (loss={trained.training_loss:.4f}):")
        for ep in epochs[:20]:
            color = enzyme_project_to_color(
                trained,
                ep["phi"], ep["valence"], ep.get("mean_fisher", 0.0), ep["trit"],
            )
            r, g, b = color.r, color.g, color.b
            block = f"\033[48;2;{r};{g};{b}m  \033[0m"
            print(
                f"  {block} {color.hex} state={ep['state']:12s} "
                f"Φ={ep['phi']:.1f} trit={ep['trit']:+d}"
            )

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
