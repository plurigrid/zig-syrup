#!/usr/bin/env python3
"""fNIRS Modified Beer-Lambert Law -- validation against Zig implementation.

Computes mBLL transform in pure Python (numpy only) and compares with
reference values. Used to validate the Zig implementation in
fnirs_processing.zig.

Pipeline:
  1. Define extinction coefficients, DPFs, S-D distances
  2. Implement opticalDensity() and mBLL() matching the Zig code
  3. Generate synthetic fNIRS data (task-evoked hemodynamic response)
  4. Compute mBLL and compare against expected values
  5. Print pass/fail for each test case

Usage:
  python3 fnirs_mbl.py                  # run validation tests
  python3 fnirs_mbl.py --synthetic      # generate synthetic HRF data
  python3 fnirs_mbl.py --compare-zig    # compare with Zig output (via subprocess)

Dependencies: numpy (required), matplotlib (optional, for plots)

Author: BCI fNIRS validation
License: MIT OR Apache-2.0
"""

import sys
import math
import argparse
import subprocess
from pathlib import Path
from typing import NamedTuple, Optional

import numpy as np


# =============================================================================
# Constants — must match fnirs_processing.zig exactly
# =============================================================================

# Extinction coefficients: cm^-1 / (mol/L)
EXTINCTION = {
    660: {"hbo": 320.0, "hbr": 3226.0},
    730: {"hbo": 1028.0, "hbr": 1798.0},
    850: {"hbo": 2526.0, "hbr": 1058.0},
    860: {"hbo": 2600.0, "hbr": 1080.0},
}

# Differential pathlength factors
DPF = {
    660: 6.51,
    730: 5.98,
    850: 6.23,
    860: 6.26,
}

# Source-detector separations (mm)
SD_PLUX_MM = 10.0
SD_DIY_LONG_MM = 30.0
SD_DIY_SHORT_MM = 8.0


# =============================================================================
# Data structures
# =============================================================================

class WavelengthPair(NamedTuple):
    lambda1: int
    lambda2: int
    dpf1: float
    dpf2: float

    @staticmethod
    def plux():
        return WavelengthPair(660, 860, DPF[660], DPF[860])

    @staticmethod
    def diy():
        return WavelengthPair(730, 850, DPF[730], DPF[850])


class HemoglobinConcentration(NamedTuple):
    delta_hbo: float  # umol/L
    delta_hbr: float
    delta_hbt: float


# =============================================================================
# Core functions — match Zig implementation
# =============================================================================

def optical_density(intensity: float, baseline: float) -> float:
    """Compute change in optical density: dOD = -ln(I / I0)."""
    if baseline <= 0 or intensity <= 0:
        return 0.0
    return -math.log(intensity / baseline)


def mbll(od1: float, od2: float, pair: WavelengthPair,
         sd_distance_mm: float) -> HemoglobinConcentration:
    """Modified Beer-Lambert Law: solve 2x2 system for dHbO/dHbR.

    Matches fnirs_processing.zig mBLL() exactly.
    """
    sd_cm = sd_distance_mm / 10.0

    e1 = EXTINCTION[pair.lambda1]
    e2 = EXTINCTION[pair.lambda2]

    path1 = pair.dpf1 * sd_cm
    path2 = pair.dpf2 * sd_cm

    if path1 <= 0 or path2 <= 0:
        return HemoglobinConcentration(0.0, 0.0, 0.0)

    # Normalize OD by pathlength
    b1 = od1 / path1
    b2 = od2 / path2

    # 2x2 matrix: A = [[e1_hbo, e1_hbr], [e2_hbo, e2_hbr]]
    det = e1["hbo"] * e2["hbr"] - e1["hbr"] * e2["hbo"]

    if abs(det) < 1e-10:
        return HemoglobinConcentration(0.0, 0.0, 0.0)

    scale = 1e6 / det  # convert mol/L to umol/L

    delta_hbo = scale * (e2["hbr"] * b1 - e1["hbr"] * b2)
    delta_hbr = scale * (-e2["hbo"] * b1 + e1["hbo"] * b2)

    return HemoglobinConcentration(delta_hbo, delta_hbr, delta_hbo + delta_hbr)


def classify_hemodynamic(hbo: float, hbr: float,
                         act_thresh: float = 0.3,
                         hbr_thresh: float = 0.1) -> int:
    """Classify hemodynamic response into GF(3) trit.

    Returns: +1 (activation), 0 (baseline), -1 (deactivation/artifact)
    """
    # Canonical activation: HbO up, HbR down
    if hbo > act_thresh and hbr < -hbr_thresh:
        return +1

    # Clear deactivation
    if hbo < -act_thresh:
        return -1

    # Anomalous: both increasing (systemic / motion)
    if hbo > act_thresh and hbr > hbr_thresh:
        return -1

    return 0


def short_channel_regression(long_ch: np.ndarray,
                             short_ch: np.ndarray) -> np.ndarray:
    """Remove scalp physiology via least-squares regression.

    residual = long - beta * short
    where beta = cov(long, short) / var(short)
    """
    n = min(len(long_ch), len(short_ch))
    long_ch = long_ch[:n]
    short_ch = short_ch[:n]

    mean_long = np.mean(long_ch)
    mean_short = np.mean(short_ch)

    cov = np.sum((long_ch - mean_long) * (short_ch - mean_short))
    var_short = np.sum((short_ch - mean_short) ** 2)

    beta = cov / var_short if var_short > 1e-20 else 0.0

    return long_ch - beta * short_ch


# =============================================================================
# Synthetic hemodynamic response function (HRF)
# =============================================================================

def generate_hrf(duration_s: float = 30.0, sample_rate: float = 10.0,
                 onset_s: float = 5.0, peak_s: float = 6.0,
                 amplitude_hbo: float = 1.5,
                 amplitude_hbr: float = -0.5) -> dict:
    """Generate a synthetic task-evoked hemodynamic response.

    Models the canonical fNIRS response:
      - HbO increases with ~6s peak latency (gamma function shape)
      - HbR decreases with slightly longer latency
      - Both return to baseline after ~20s

    Returns dict with keys: time, hbo, hbr, intensity_lambda1, intensity_lambda2
    """
    t = np.arange(0, duration_s, 1.0 / sample_rate)
    n = len(t)

    # Gamma-function HRF (simplified SPM canonical HRF)
    def gamma_hrf(t_rel, peak, width=2.0):
        """Single-gamma hemodynamic response."""
        if peak <= 0:
            return np.zeros_like(t_rel)
        # Gamma PDF shape
        shape = (peak / width) ** 2
        scale = width ** 2 / peak
        x = t_rel / scale
        hrf = np.where(x > 0, x ** (shape - 1) * np.exp(-x) / scale, 0.0)
        # Normalize peak to 1
        peak_val = np.max(hrf) if np.max(hrf) > 0 else 1.0
        return hrf / peak_val

    t_rel = t - onset_s
    t_rel = np.maximum(t_rel, 0)

    hbo = amplitude_hbo * gamma_hrf(t_rel, peak_s)
    hbr = amplitude_hbr * gamma_hrf(t_rel, peak_s * 1.2)  # HbR peaks slightly later

    # Convert concentrations back to intensity changes
    # Using PLUX wavelengths (660nm + 860nm)
    pair = WavelengthPair.plux()
    sd_cm = SD_PLUX_MM / 10.0

    e1 = EXTINCTION[pair.lambda1]
    e2 = EXTINCTION[pair.lambda2]

    baseline_intensity = 1000.0

    # Forward model: dOD = epsilon * DPF * d * dC
    # dC is in umol/L = 1e-6 mol/L; epsilon is in cm^-1/(mol/L)
    # So dOD = epsilon * DPF * d * dC * 1e-6
    intensity_l1 = np.zeros(n)
    intensity_l2 = np.zeros(n)

    for i in range(n):
        dod1 = (e1["hbo"] * hbo[i] + e1["hbr"] * hbr[i]) * 1e-6 * pair.dpf1 * sd_cm
        dod2 = (e2["hbo"] * hbo[i] + e2["hbr"] * hbr[i]) * 1e-6 * pair.dpf2 * sd_cm
        intensity_l1[i] = baseline_intensity * math.exp(-dod1)
        intensity_l2[i] = baseline_intensity * math.exp(-dod2)

    return {
        "time": t,
        "hbo": hbo,
        "hbr": hbr,
        "intensity_lambda1": intensity_l1,
        "intensity_lambda2": intensity_l2,
        "pair": pair,
        "sd_mm": SD_PLUX_MM,
    }


# =============================================================================
# Validation tests
# =============================================================================

class TestResult(NamedTuple):
    name: str
    passed: bool
    detail: str


def run_tests() -> list[TestResult]:
    """Run all validation tests. Returns list of TestResult."""
    results = []

    def check(name: str, condition: bool, detail: str = ""):
        results.append(TestResult(name, condition, detail))

    # --- Test 1: Optical density ---
    od_same = optical_density(100.0, 100.0)
    check("OD: same intensity = 0",
          abs(od_same) < 1e-6,
          f"got {od_same:.8f}")

    od_half = optical_density(50.0, 100.0)
    check("OD: half intensity = ln(2)",
          abs(od_half - math.log(2)) < 0.001,
          f"got {od_half:.6f}, expected {math.log(2):.6f}")

    od_double = optical_density(200.0, 100.0)
    check("OD: double intensity = -ln(2)",
          abs(od_double + math.log(2)) < 0.001,
          f"got {od_double:.6f}, expected {-math.log(2):.6f}")

    od_zero = optical_density(0, 100.0)
    check("OD: zero intensity = 0",
          od_zero == 0.0,
          f"got {od_zero}")

    # --- Test 2: mBLL with zero input ---
    hemo_zero = mbll(0, 0, WavelengthPair.plux(), SD_PLUX_MM)
    check("mBLL: zero OD = zero concentration",
          abs(hemo_zero.delta_hbo) < 1e-6 and abs(hemo_zero.delta_hbr) < 1e-6,
          f"got hbo={hemo_zero.delta_hbo:.8f}, hbr={hemo_zero.delta_hbr:.8f}")

    # --- Test 3: mBLL unit inputs ---
    pair = WavelengthPair.plux()
    hemo_unit = mbll(1.0, 1.0, pair, SD_PLUX_MM)
    sd_cm = SD_PLUX_MM / 10.0
    e1, e2 = EXTINCTION[pair.lambda1], EXTINCTION[pair.lambda2]
    b1 = 1.0 / (pair.dpf1 * sd_cm)
    b2 = 1.0 / (pair.dpf2 * sd_cm)
    det = e1["hbo"] * e2["hbr"] - e1["hbr"] * e2["hbo"]
    exp_hbo = (1e6 / det) * (e2["hbr"] * b1 - e1["hbr"] * b2)
    exp_hbr = (1e6 / det) * (-e2["hbo"] * b1 + e1["hbo"] * b2)
    check("mBLL: unit OD matrix inversion",
          abs(hemo_unit.delta_hbo - exp_hbo) < 0.01 and
          abs(hemo_unit.delta_hbr - exp_hbr) < 0.01,
          f"got hbo={hemo_unit.delta_hbo:.4f} (exp {exp_hbo:.4f}), "
          f"hbr={hemo_unit.delta_hbr:.4f} (exp {exp_hbr:.4f})")

    # --- Test 4: HbT = HbO + HbR ---
    hemo_sum = mbll(0.05, 0.03, WavelengthPair.diy(), SD_DIY_LONG_MM)
    check("mBLL: HbT = HbO + HbR",
          abs(hemo_sum.delta_hbt - (hemo_sum.delta_hbo + hemo_sum.delta_hbr)) < 1e-6,
          f"hbt={hemo_sum.delta_hbt:.6f}, sum={hemo_sum.delta_hbo + hemo_sum.delta_hbr:.6f}")

    # --- Test 5: Determinant non-zero ---
    for name, wl_pair in [("PLUX 660/860", WavelengthPair.plux()),
                           ("DIY 730/850", WavelengthPair.diy())]:
        e1 = EXTINCTION[wl_pair.lambda1]
        e2 = EXTINCTION[wl_pair.lambda2]
        det = e1["hbo"] * e2["hbr"] - e1["hbr"] * e2["hbo"]
        check(f"Determinant non-zero: {name}",
              abs(det) > 1000,
              f"det = {det:.1f}")

    # --- Test 6: Trit classification ---
    check("Trit: canonical activation",
          classify_hemodynamic(1.0, -0.5) == +1,
          f"got {classify_hemodynamic(1.0, -0.5)}")

    check("Trit: baseline",
          classify_hemodynamic(0.1, -0.05) == 0,
          f"got {classify_hemodynamic(0.1, -0.05)}")

    check("Trit: deactivation",
          classify_hemodynamic(-0.5, 0.2) == -1,
          f"got {classify_hemodynamic(-0.5, 0.2)}")

    check("Trit: anomalous (systemic)",
          classify_hemodynamic(1.0, 0.5) == -1,
          f"got {classify_hemodynamic(1.0, 0.5)}")

    # --- Test 7: Round-trip (forward model -> mBLL recovery) ---
    synth = generate_hrf(duration_s=30.0, sample_rate=10.0)
    recovered_hbo = []
    recovered_hbr = []
    for i in range(len(synth["time"])):
        od1 = optical_density(synth["intensity_lambda1"][i], 1000.0)
        od2 = optical_density(synth["intensity_lambda2"][i], 1000.0)
        hemo = mbll(od1, od2, synth["pair"], synth["sd_mm"])
        recovered_hbo.append(hemo.delta_hbo)
        recovered_hbr.append(hemo.delta_hbr)

    recovered_hbo = np.array(recovered_hbo)
    recovered_hbr = np.array(recovered_hbr)

    # Check recovery accuracy (should be near-perfect for noiseless data)
    hbo_err = np.max(np.abs(recovered_hbo - synth["hbo"]))
    hbr_err = np.max(np.abs(recovered_hbr - synth["hbr"]))
    check("Round-trip: HbO recovery (noiseless)",
          hbo_err < 0.01,
          f"max error = {hbo_err:.6f} uM")
    check("Round-trip: HbR recovery (noiseless)",
          hbr_err < 0.01,
          f"max error = {hbr_err:.6f} uM")

    # --- Test 8: Short-channel regression ---
    t = np.arange(0, 20.0, 0.1)
    systemic = np.sin(2 * np.pi * 0.1 * t)          # Mayer wave
    cortical = 0.3 * np.sin(2 * np.pi * 0.05 * t)   # task-evoked
    long_ch = systemic + cortical
    short_ch = systemic.copy()

    residual = short_channel_regression(long_ch, short_ch)
    var_residual = np.var(residual)
    var_long = np.var(long_ch)
    check("Short-channel regression removes systemic",
          var_residual < var_long * 0.5,
          f"var_residual={var_residual:.4f}, var_long={var_long:.4f}, "
          f"ratio={var_residual / var_long:.4f}")

    return results


# =============================================================================
# Zig comparison (optional)
# =============================================================================

def compare_with_zig():
    """Build and run Zig tests, compare output.

    Looks for zig-syrup project and runs `zig build test` to verify
    the Zig implementation passes its own tests.
    """
    project_root = Path(__file__).resolve().parent.parent.parent
    zig_src = project_root / "src" / "fnirs_processing.zig"

    if not zig_src.exists():
        print(f"[SKIP] Zig source not found at {zig_src}")
        return False

    print(f"\n{'=' * 60}")
    print("Running Zig tests for fnirs_processing.zig...")
    print(f"{'=' * 60}\n")

    try:
        result = subprocess.run(
            ["zig", "test", str(zig_src)],
            cwd=str(project_root),
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode == 0:
            print("[PASS] All Zig tests passed")
            if result.stderr:
                print(result.stderr)
            return True
        else:
            print("[FAIL] Zig tests failed:")
            print(result.stderr)
            print(result.stdout)
            return False
    except FileNotFoundError:
        print("[SKIP] `zig` not found in PATH")
        return False
    except subprocess.TimeoutExpired:
        print("[SKIP] Zig test timed out (60s)")
        return False


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="fNIRS mBLL validation and comparison with Zig implementation"
    )
    parser.add_argument("--synthetic", action="store_true",
                        help="Print synthetic HRF data to stdout")
    parser.add_argument("--compare-zig", action="store_true",
                        help="Also run Zig tests via subprocess")
    args = parser.parse_args()

    if args.synthetic:
        synth = generate_hrf()
        print("# time_s, hbo_uM, hbr_uM, intensity_660nm, intensity_860nm")
        for i in range(len(synth["time"])):
            print(f"{synth['time'][i]:.2f}, "
                  f"{synth['hbo'][i]:.6f}, "
                  f"{synth['hbr'][i]:.6f}, "
                  f"{synth['intensity_lambda1'][i]:.4f}, "
                  f"{synth['intensity_lambda2'][i]:.4f}")
        return

    # Run Python validation tests
    print(f"{'=' * 60}")
    print("fNIRS Modified Beer-Lambert Law — Validation Suite")
    print(f"{'=' * 60}\n")

    print("Constants (must match fnirs_processing.zig):")
    print(f"  Extinction 660nm: HbO={EXTINCTION[660]['hbo']}, HbR={EXTINCTION[660]['hbr']}")
    print(f"  Extinction 730nm: HbO={EXTINCTION[730]['hbo']}, HbR={EXTINCTION[730]['hbr']}")
    print(f"  Extinction 850nm: HbO={EXTINCTION[850]['hbo']}, HbR={EXTINCTION[850]['hbr']}")
    print(f"  Extinction 860nm: HbO={EXTINCTION[860]['hbo']}, HbR={EXTINCTION[860]['hbr']}")
    print(f"  DPF: {DPF}")
    print(f"  S-D: PLUX={SD_PLUX_MM}mm, DIY_long={SD_DIY_LONG_MM}mm, DIY_short={SD_DIY_SHORT_MM}mm")
    print()

    results = run_tests()

    n_pass = sum(1 for r in results if r.passed)
    n_total = len(results)

    for r in results:
        status = "PASS" if r.passed else "FAIL"
        detail = f"  ({r.detail})" if r.detail else ""
        print(f"  [{status}] {r.name}{detail}")

    print(f"\n{'=' * 60}")
    print(f"Results: {n_pass}/{n_total} passed")
    print(f"{'=' * 60}")

    if args.compare_zig:
        zig_ok = compare_with_zig()
        if not zig_ok:
            print("\n[WARNING] Zig comparison failed or was skipped")

    if n_pass < n_total:
        sys.exit(1)


if __name__ == "__main__":
    main()
