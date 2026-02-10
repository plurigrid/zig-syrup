"""
Phase 2: Python FFI Bridge for Bridge 9 (BCI-Phenomenal Integration)

Connects existing Python BCI infrastructure with Lux Bridge 9 implementation:
- fisher_eeg.py → EEG classification + Fisher-Rao metric
- valence_bridge.py → Phenomenal field synthesis + color projection
- Lux Bridge 9 → Formal morphisms (EEG ↔ Generalized Coordinates)

This module exports Bridge 9 functions and types to Python via the Lux Python backend.

Architecture:
  1. Python EEG_Epoch → Lux EEG_Signal mapping
  2. Call bridge_9_morphism_forward (EEG → Robot) via compiled Lux
  3. Call bridge_9_morphism_backward (Robot → Phenomenal) for feedback
  4. Integration with existing Aptos qualia market
  5. DuckDB logging of E2E traces
"""

import numpy as np
import json
from dataclasses import dataclass, asdict
from typing import List, Tuple, Dict, Optional, Union
import hashlib
import sys

# Import existing Fisher-Rao and valence infrastructure
from fisher_eeg import (
    EEGEpoch, BandPower, CHANNELS_10_20, BANDS,
    fisher_distance_matrix, phi_mip, classify_state,
)
from valence_bridge import (
    ColorEpoch, process_epoch, project_to_color,
)


# ═══════════════════════════════════════════════════════════════════════════
# Python Type Mappings for Lux Bridge 9
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class LuxEEGSignal:
    """
    Maps Python EEG_Epoch to Lux EEG_Signal type.

    Lux type structure:
    (Record
      [timestamp Int
       channel_index Int
       band_powers (List Real)
       raw_amplitude Real
       phase_angle Real
       artifact_flag Boolean])
    """
    timestamp: int
    channel_index: int
    band_powers: List[float]
    raw_amplitude: float
    phase_angle: float
    artifact_flag: bool

    def to_lux_dict(self) -> Dict:
        """Convert to Lux-compatible record."""
        return {
            "timestamp": self.timestamp,
            "channel_index": self.channel_index,
            "band_powers": self.band_powers,
            "raw_amplitude": self.raw_amplitude,
            "phase_angle": self.phase_angle,
            "artifact_flag": self.artifact_flag,
        }

    @staticmethod
    def from_python_epoch(epoch: EEGEpoch, channel_idx: int) -> "LuxEEGSignal":
        """Extract single-channel EEG signal from Python EEG_Epoch."""
        ch_name = CHANNELS_10_20[channel_idx]
        band_power = epoch.channels[ch_name]

        return LuxEEGSignal(
            timestamp=int(epoch.timestamp * 1000),  # ms
            channel_index=channel_idx,
            band_powers=band_power.raw.tolist(),
            raw_amplitude=float(np.linalg.norm(band_power.raw)),
            phase_angle=0.0,  # placeholder: compute from raw signal if needed
            artifact_flag=False,  # placeholder: implement artifact detection
        )


@dataclass
class LuxPhenomenalState:
    """
    Maps Bridge 9 phenomenal output back to Python.

    Lux type structure:
    (Record
      [phi Real
       valence Real
       entropy Real
       dominant_band Text
       dominant_power Real
       timestamp Int
       confidence Real])
    """
    phi: float
    valence: float
    entropy: float
    dominant_band: str
    dominant_power: float
    timestamp: int
    confidence: float

    @staticmethod
    def from_lux_dict(data: Dict) -> "LuxPhenomenalState":
        """Convert Lux record to Python."""
        return LuxPhenomenalState(
            phi=data.get("phi", 0.0),
            valence=data.get("valence", 0.0),
            entropy=data.get("entropy", 0.0),
            dominant_band=data.get("dominant_band", "alpha"),
            dominant_power=data.get("dominant_power", 0.0),
            timestamp=data.get("timestamp", 0),
            confidence=data.get("confidence", 0.0),
        )

    def to_dict(self) -> Dict:
        return asdict(self)


@dataclass
class LuxGeneralizedCoordinate:
    """
    Maps Bridge 9 robot output back to Python.

    Lux type structure:
    (Record
      [joint_index Int
       angle_radians Real
       velocity Real
       torque Real
       confidence Real])
    """
    joint_index: int
    angle_radians: float
    velocity: float
    torque: float
    confidence: float

    @staticmethod
    def from_lux_dict(data: Dict) -> "LuxGeneralizedCoordinate":
        """Convert Lux record to Python."""
        return LuxGeneralizedCoordinate(
            joint_index=data.get("joint_index", 0),
            angle_radians=data.get("angle_radians", 0.0),
            velocity=data.get("velocity", 0.0),
            torque=data.get("torque", 0.0),
            confidence=data.get("confidence", 0.0),
        )

    def to_dict(self) -> Dict:
        return asdict(self)


# ═══════════════════════════════════════════════════════════════════════════
# Bridge 9 Morphism Wrappers (FFI Layer)
# ═══════════════════════════════════════════════════════════════════════════

class Bridge9FFI:
    """
    FFI layer connecting Python BCI to Lux Bridge 9 implementation.

    For now, this provides mock implementations that preserve the Bridge 9
    semantics. Once Lux Python backend is available, these will call the
    actual Lux functions.

    Reference implementation: /Users/bob/i/lux/stdlib/source/library/lux/world/bci-phenomenal-bridge.lux
    """

    # PLACEHOLDER: When Lux Python backend is available, import like:
    # from lux_bridge_9 import (
    #     bridge_9_morphism_forward,
    #     bridge_9_morphism_backward,
    #     fisher_rao_metric,
    #     compute_phenomenal_state,
    #     qualia_market_commitment,
    # )

    @staticmethod
    def fisher_rao_metric(
        band_powers_1: List[float],
        band_powers_2: List[float],
    ) -> float:
        """
        Compute Fisher-Rao distance between two EEG band power distributions.

        Implementation: 2 * arccos(Σ √pᵢ √qᵢ)
        Matches Lux: fisher_rao_metric in bci-phenomenal-bridge.lux line 120-138
        """
        p = np.array(band_powers_1) / (sum(band_powers_1) + 1e-10)
        q = np.array(band_powers_2) / (sum(band_powers_2) + 1e-10)

        sqrt_p = np.sqrt(p)
        sqrt_q = np.sqrt(q)
        bhattacharyya_coeff = float(np.dot(sqrt_p, sqrt_q))
        bhattacharyya_coeff = np.clip(bhattacharyya_coeff, -1.0, 1.0)

        return 2.0 * np.arccos(bhattacharyya_coeff)

    @staticmethod
    def compute_phenomenal_state(eeg_epoch: EEGEpoch) -> LuxPhenomenalState:
        """
        Transform EEG epoch into phenomenal field representation.

        Computes:
        - Fisher-Rao distance → φ (engagement angle, [0, π/2])
        - Alpha band power → valence (affect, [-1, +1])
        - Shannon entropy → uncertainty measure ([0, 8] bits)
        - Dominant band → which frequency dominates
        - Confidence → signal quality metric

        Matches Lux: compute_phenomenal_state in bci-phenomenal-bridge.lux line 159-201
        """
        # Use existing Python infrastructure to compute these
        classification = classify_state(eeg_epoch)

        # Fisher-Rao reference (baseline) from first epoch
        baseline_powers = np.array([1.0, 1.0, 1.0, 1.0, 1.0]) / 5.0
        baseline_bp = BandPower.from_raw("baseline", baseline_powers)

        # Compute engagement angle φ
        ch0 = eeg_epoch.channels[CHANNELS_10_20[0]]
        fisher_dist = Bridge9FFI.fisher_rao_metric(
            ch0.raw.tolist(),
            baseline_bp.raw.tolist(),
        )
        phi = np.clip(fisher_dist / np.pi * (np.pi / 2), 0, np.pi / 2)

        # Alpha band power → valence
        alpha_powers = [eeg_epoch.channels[ch].simplex[2] for ch in CHANNELS_10_20]
        alpha_mean = float(np.mean(alpha_powers))
        valence = 2.0 * alpha_mean - 1.0  # normalize to [-1, +1]

        # Shannon entropy
        all_powers = np.concatenate([eeg_epoch.channels[ch].raw for ch in CHANNELS_10_20])
        all_simplex = all_powers / (np.sum(all_powers) + 1e-10)
        entropy = -np.sum(all_simplex * np.log2(all_simplex + 1e-10))

        # Dominant band
        band_totals = np.zeros(5)
        for ch_name in CHANNELS_10_20:
            band_totals += eeg_epoch.channels[ch_name].simplex
        dominant_band_idx = int(np.argmax(band_totals))
        dominant_band = BANDS[dominant_band_idx]
        dominant_power = float(band_totals[dominant_band_idx] / 8)

        return LuxPhenomenalState(
            phi=float(phi),
            valence=float(valence),
            entropy=float(entropy),
            dominant_band=dominant_band,
            dominant_power=dominant_power,
            timestamp=int(eeg_epoch.timestamp * 1000),
            confidence=float(classification.get("confidence", 0.5)),
        )

    @staticmethod
    def phenomenal_to_generalized(
        phenomenal_state: LuxPhenomenalState,
        joint_index: int,
    ) -> LuxGeneralizedCoordinate:
        """
        Map phenomenal state to joint command.

        angle_radians = φ - π/2 + 0.3 × valence
        velocity ∝ entropy
        torque = dominant_power × confidence × 10

        Matches Lux: phenomenal_to_generalized in bci-phenomenal-bridge.lux line 227-246
        """
        angle_radians = (
            phenomenal_state.phi - (np.pi / 2) +
            0.3 * phenomenal_state.valence
        )
        velocity = np.clip(phenomenal_state.entropy / 8.0, 0, 2.0)
        torque = phenomenal_state.dominant_power * phenomenal_state.confidence * 10.0

        return LuxGeneralizedCoordinate(
            joint_index=joint_index,
            angle_radians=float(np.clip(angle_radians, -np.pi, np.pi)),
            velocity=float(velocity),
            torque=float(torque),
            confidence=phenomenal_state.confidence,
        )

    @staticmethod
    def bridge_9_morphism_forward(
        eeg_epoch: EEGEpoch,
    ) -> List[LuxGeneralizedCoordinate]:
        """
        Bridge 9 forward morphism: EEG → Generalized Coordinates (8-DOF robot arm).

        Pipeline: EEG → Phenomenal state → 8 joint angles/velocities/torques

        Matches Lux: bridge_9_morphism_forward in bci-phenomenal-bridge.lux line 260-283
        """
        phenomenal = Bridge9FFI.compute_phenomenal_state(eeg_epoch)

        coords = []
        for joint_idx in range(8):  # 8-DOF robot arm
            coord = Bridge9FFI.phenomenal_to_generalized(
                phenomenal,
                joint_idx,
            )
            coords.append(coord)

        return coords

    @staticmethod
    def bridge_9_morphism_backward(
        coords: List[LuxGeneralizedCoordinate],
    ) -> LuxPhenomenalState:
        """
        Bridge 9 backward morphism: Generalized Coordinates → Phenomenal state (feedback).

        Synthesizes conscious experience from robot movement (proprioceptive phenomenology).

        Matches Lux: bridge_9_morphism_backward in bci-phenomenal-bridge.lux line 295-320
        """
        if not coords:
            raise ValueError("Cannot synthesize phenomenal state from empty coordinate list")

        # Reconstruct phenomenal state from joint angles/velocities/torques
        phi = float(np.clip(coords[0].angle_radians + (np.pi / 2), 0, np.pi / 2))
        valence = float(np.mean([c.angle_radians for c in coords]) / 0.3)
        entropy = float(np.mean([c.velocity for c in coords]) * 8.0)
        dominant_power = float(np.mean([c.torque for c in coords]) / 10.0)
        confidence = float(np.mean([c.confidence for c in coords]))

        return LuxPhenomenalState(
            phi=phi,
            valence=np.clip(valence, -1, 1),
            entropy=np.clip(entropy, 0, 8),
            dominant_band="alpha",  # placeholder
            dominant_power=dominant_power,
            timestamp=0,  # set by caller
            confidence=confidence,
        )

    @staticmethod
    def bridge_9_conservation(
        eeg_epoch: EEGEpoch,
        coords: List[LuxGeneralizedCoordinate],
    ) -> bool:
        """
        Verify conservation of action across EEG→Robot mapping.

        EEG_Action = entropy × φ × duration
        Mech_Action = Σ(torque × angle)
        Conservative if 0.1 < ratio < 10.0

        Matches Lux: bridge_9_conservation in bci-phenomenal-bridge.lux line 332-352
        """
        phenomenal = Bridge9FFI.compute_phenomenal_state(eeg_epoch)

        eeg_action = phenomenal.entropy * phenomenal.phi * 0.1  # 100ms epoch
        mech_action = sum(c.torque * abs(c.angle_radians) for c in coords)

        if mech_action < 1e-6:
            ratio = 1.0  # neutral case
        else:
            ratio = eeg_action / mech_action

        return 0.1 < ratio < 10.0

    @staticmethod
    def qualia_market_commitment(
        phenomenal_state: LuxPhenomenalState,
        domain_id: int = 3,  # BCI_DECODING
    ) -> Dict:
        """
        Generate Aptos blockchain commit for Qualia Market.

        Maps valence → capability (READ/WRITE/EXECUTE)
        Returns CID and trit for on-chain verification.

        Matches Lux: qualia_market_commitment in bci-phenomenal-bridge.lux line 364-401
        """
        # Capability from valence
        if phenomenal_state.valence < -0.33:
            capability = "READ"
            trit = -1  # MINUS
        elif phenomenal_state.valence <= 0.33:
            capability = "WRITE"
            trit = 0   # ERGODIC
        else:
            capability = "EXECUTE"
            trit = 1   # PLUS

        # CID = SHA-256(phenomenal_state || timestamp)
        canonical = json.dumps({
            "phi": round(phenomenal_state.phi, 6),
            "valence": round(phenomenal_state.valence, 6),
            "entropy": round(phenomenal_state.entropy, 6),
            "dominant_band": phenomenal_state.dominant_band,
            "timestamp": phenomenal_state.timestamp,
            "domain_id": domain_id,
        }, sort_keys=True)
        cid = hashlib.sha256(canonical.encode()).hexdigest()

        return {
            "cid": cid,
            "trit": trit,
            "capability": capability,
            "domain_id": domain_id,
            "canonical": canonical,
        }


# ═══════════════════════════════════════════════════════════════════════════
# Full E2E Pipeline Integration
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class Bridge9Result:
    """
    Complete Bridge 9 E2E result: EEG → Phenomenal → Robot → Feedback → Color → Commitment
    """
    epoch_id: int
    timestamp_ms: int

    # Input: EEG
    eeg_state: str
    eeg_confidence: float
    phi: float

    # Intermediate: Phenomenal
    phenomenal_state: LuxPhenomenalState

    # Output: Robot (8-DOF)
    joint_commands: List[LuxGeneralizedCoordinate]
    conservation_holds: bool

    # Feedback: Phenomenal (from robot)
    feedback_phenomenal: LuxPhenomenalState

    # Color (for visualization)
    color_hex: str
    color_rgb: Tuple[int, int, int]

    # Qualia market
    commitment: Dict

    def to_dict(self) -> Dict:
        """Serialize for DuckDB or JSON output."""
        return {
            "epoch_id": self.epoch_id,
            "timestamp_ms": self.timestamp_ms,
            "eeg_state": self.eeg_state,
            "eeg_confidence": self.eeg_confidence,
            "phi": self.phi,
            "phenomenal": self.phenomenal_state.to_dict(),
            "joint_commands": [c.to_dict() for c in self.joint_commands],
            "conservation_holds": self.conservation_holds,
            "feedback_phenomenal": self.feedback_phenomenal.to_dict(),
            "color": {
                "hex": self.color_hex,
                "rgb": list(self.color_rgb),
            },
            "commitment": self.commitment,
        }


def process_eeg_to_robot(
    eeg_epoch: EEGEpoch,
    epoch_id: int = 0,
) -> Bridge9Result:
    """
    Full E2E Bridge 9 pipeline.

    EEG → Phenomenal → Generalized Coords → Conservation Check →
    Feedback Phenomenal → Color → Qualia Market Commitment
    """
    # 1. Forward morphism: EEG → Robot
    coords = Bridge9FFI.bridge_9_morphism_forward(eeg_epoch)

    # 2. Compute phenomenal state
    phenomenal = Bridge9FFI.compute_phenomenal_state(eeg_epoch)

    # 3. Verify conservation
    conservation = Bridge9FFI.bridge_9_conservation(eeg_epoch, coords)

    # 4. Backward morphism: Robot → Phenomenal (feedback)
    feedback_phenomenal = Bridge9FFI.bridge_9_morphism_backward(coords)
    feedback_phenomenal.timestamp = int(eeg_epoch.timestamp * 1000)

    # 5. Color projection (reuse existing pipeline)
    color_epoch = process_epoch(eeg_epoch)
    color_rgb = (color_epoch.color.r, color_epoch.color.g, color_epoch.color.b)

    # 6. Qualia market commitment
    commitment = Bridge9FFI.qualia_market_commitment(phenomenal, domain_id=3)

    # 7. EEG classification for logging
    classification = classify_state(eeg_epoch)

    return Bridge9Result(
        epoch_id=epoch_id,
        timestamp_ms=int(eeg_epoch.timestamp * 1000),
        eeg_state=classification["state"],
        eeg_confidence=classification["confidence"],
        phi=phenomenal.phi,
        phenomenal_state=phenomenal,
        joint_commands=coords,
        conservation_holds=conservation,
        feedback_phenomenal=feedback_phenomenal,
        color_hex=color_epoch.color.hex,
        color_rgb=color_rgb,
        commitment=commitment,
    )


# ═══════════════════════════════════════════════════════════════════════════
# CLI: Full pipeline demo
# ═══════════════════════════════════════════════════════════════════════════

def main():
    """Demo: Process EEG CSV through full Bridge 9 pipeline."""
    import csv

    if len(sys.argv) < 2:
        print("Usage: python bridge_9_ffi.py <recordings.csv> [window_size]")
        print("       Processes EEG through full Bridge 9 pipeline:")
        print("       EEG → Phenomenal → Robot → Feedback → Color → Qualia Commitment")
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
        from fisher_eeg import epoch_from_raw_eeg

        window = samples[i * window_size : (i + 1) * window_size]
        epoch = epoch_from_raw_eeg(window)
        epoch.epoch_id = i

        result = process_eeg_to_robot(epoch, epoch_id=i)
        results.append(result.to_dict())

        # Print summary
        color_block = f"\033[48;2;{result.color_rgb[0]};{result.color_rgb[1]};{result.color_rgb[2]}m  \033[0m"
        print(
            f"epoch={i:3d} {color_block} {result.color_hex} "
            f"state={result.eeg_state:12s} φ={result.phi:.2f} "
            f"val={result.phenomenal_state.valence:.2f} "
            f"cons={'✓' if result.conservation_holds else '✗'} "
            f"cap={result.commitment['capability']:8s} "
            f"cid={result.commitment['cid'][:12]}…"
        )

    # Write full results
    output_path = csv_path.rsplit(".", 1)[0] + "_bridge9.json"
    with open(output_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nWrote {len(results)} Bridge 9 results to {output_path}")


if __name__ == "__main__":
    main()
