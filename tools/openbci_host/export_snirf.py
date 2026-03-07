#!/usr/bin/env python3
"""SNIRF Export -- write fNIRS data in Shared Near-Infrared Spectroscopy Format.

Writes .snirf files (HDF5-based) compatible with Homer3, MNE-NIRS, and other
standard fNIRS analysis tools. Follows SNIRF specification v1.1.

Usage:
    python export_snirf.py --input fnirs_data.json --output recording.snirf
    python export_snirf.py --synthetic --output test.snirf  # synthetic test file
"""

import sys
import json
import argparse
import math
from datetime import datetime
from typing import Dict, List, Optional, Tuple

# =============================================================================
# Optional imports
# =============================================================================

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

try:
    import h5py
    HAS_H5PY = True
except ImportError:
    HAS_H5PY = False

# =============================================================================
# Constants
# =============================================================================

SNIRF_FORMAT_VERSION = "1.1"

# Default PLUX fNIRS wavelengths (nm)
DEFAULT_WAVELENGTHS = [660.0, 860.0]

# Default probe geometry: 4 sources, 4 detectors on prefrontal cortex
DEFAULT_SOURCE_POS = [
    [-30.0, 0.0, 0.0],
    [-10.0, 0.0, 0.0],
    [10.0, 0.0, 0.0],
    [30.0, 0.0, 0.0],
]

DEFAULT_DETECTOR_POS = [
    [-20.0, 20.0, 0.0],
    [0.0, 20.0, 0.0],
    [20.0, 20.0, 0.0],
    [40.0, 20.0, 0.0],
]

# Data type codes (SNIRF spec)
DATA_TYPE_RAW = 1
DATA_TYPE_PROCESSED = 99999


# =============================================================================
# Synthetic data generator
# =============================================================================

def generate_synthetic_fnirs(
    duration: float = 60.0,
    sample_rate: float = 10.0,
    n_sources: int = 4,
    n_detectors: int = 4,
    wavelengths: Optional[List[float]] = None,
) -> Dict:
    """Generate synthetic fNIRS data for testing.

    Simulates hemodynamic response function (HRF) with task blocks,
    physiological noise (cardiac, respiratory, Mayer waves), and
    measurement noise.

    Args:
        duration: recording duration in seconds
        sample_rate: sampling rate in Hz
        n_sources: number of light sources
        n_detectors: number of detectors
        wavelengths: wavelengths in nm (default: [660, 860])

    Returns:
        dict with keys: time, data, source_pos, detector_pos, wavelengths,
        measurement_list, stim, metadata
    """
    if wavelengths is None:
        wavelengths = list(DEFAULT_WAVELENGTHS)

    n_time = int(duration * sample_rate)
    n_channels = n_sources * n_detectors * len(wavelengths)
    dt = 1.0 / sample_rate

    # Time vector
    time_vec = [i * dt for i in range(n_time)]

    # Generate measurement list: (source, detector, wavelength_idx)
    meas_list = []
    for wi, _wl in enumerate(wavelengths):
        for si in range(n_sources):
            for di in range(n_detectors):
                meas_list.append({
                    "sourceIndex": si + 1,
                    "detectorIndex": di + 1,
                    "wavelengthIndex": wi + 1,
                    "dataType": DATA_TYPE_RAW,
                    "dataTypeIndex": 1,
                })

    # Generate data: HRF + noise
    data = []
    for _ch_idx in range(n_channels):
        channel_data = []
        for i in range(n_time):
            t = time_vec[i]

            # Baseline optical density
            baseline = 1.0

            # Task-evoked HRF: 10s blocks every 30s
            hrf_val = 0.0
            block_t = t % 30.0
            if 5.0 <= block_t <= 15.0:
                # Canonical HRF: gamma function approximation
                tau = block_t - 5.0
                if tau > 0:
                    hrf_val = 0.02 * (tau / 5.0) * math.exp(-(tau - 5.0) / 3.0)

            # Physiological noise
            cardiac = 0.005 * math.sin(2 * math.pi * 1.1 * t)       # ~1.1 Hz heartbeat
            respiratory = 0.003 * math.sin(2 * math.pi * 0.25 * t)  # ~0.25 Hz breathing
            mayer = 0.002 * math.sin(2 * math.pi * 0.1 * t)         # ~0.1 Hz Mayer wave

            # Measurement noise (pseudo-random via deterministic formula)
            noise = 0.001 * math.sin(t * 137.035 + _ch_idx * 31.7)

            value = baseline + hrf_val + cardiac + respiratory + mayer + noise
            channel_data.append(value)
        data.append(channel_data)

    # Stimulus markers: task blocks
    stim_data = []
    t = 5.0
    while t < duration:
        stim_data.append([t, 10.0, 1.0])  # onset, duration, amplitude
        t += 30.0

    # Source/detector positions
    source_pos = DEFAULT_SOURCE_POS[:n_sources]
    detector_pos = DEFAULT_DETECTOR_POS[:n_detectors]

    return {
        "time": time_vec,
        "data": data,
        "source_pos": source_pos,
        "detector_pos": detector_pos,
        "wavelengths": wavelengths,
        "measurement_list": meas_list,
        "stim": {"name": "task", "data": stim_data},
        "metadata": {
            "SubjectID": "synthetic-001",
            "MeasurementDate": datetime.now().strftime("%Y-%m-%d"),
            "MeasurementTime": datetime.now().strftime("%H:%M:%S"),
            "LengthUnit": "mm",
            "TimeUnit": "s",
            "FrequencyUnit": "Hz",
        },
        "sample_rate": sample_rate,
        "n_time": n_time,
        "n_channels": n_channels,
    }


# =============================================================================
# SNIRF writer
# =============================================================================

def write_snirf(output_path: str, fnirs_data: Dict):
    """Write fNIRS data to SNIRF format (.snirf / HDF5).

    Follows SNIRF v1.1 specification:
      /formatVersion
      /nirs/
        /data1/
          /dataTimeSeries  (nTime x nChannel float64)
          /time            (nTime float64)
          /measurementList1..N/
            sourceIndex, detectorIndex, wavelengthIndex, dataType, dataTypeIndex
        /probe/
          /sourcePos3D     (nSource x 3 float64)
          /detectorPos3D   (nDetector x 3 float64)
          /wavelengths     (nWavelength float64)
        /stim1/
          /name            string
          /data            (nStim x 3 float64: onset, duration, amplitude)
        /metaDataTags/
          /SubjectID       string
          /MeasurementDate string
          /LengthUnit      string

    Args:
        output_path: path to output .snirf file
        fnirs_data: dict from generate_synthetic_fnirs() or loaded JSON
    """
    if not HAS_H5PY:
        print("Error: h5py not installed. Run: pip install h5py", file=sys.stderr)
        sys.exit(1)

    n_time = fnirs_data["n_time"]
    n_channels = fnirs_data["n_channels"]
    meas_list = fnirs_data["measurement_list"]
    metadata = fnirs_data["metadata"]

    with h5py.File(output_path, "w") as f:
        # Format version
        f.create_dataset("formatVersion", data=SNIRF_FORMAT_VERSION)

        # /nirs group
        nirs = f.create_group("nirs")

        # /nirs/data1
        data1 = nirs.create_group("data1")

        # dataTimeSeries: nTime x nChannel
        if HAS_NUMPY:
            ts_array = np.array(fnirs_data["data"], dtype=np.float64).T  # transpose: channels→columns
        else:
            # Manual transpose
            ts_array = [[fnirs_data["data"][ch][t] for ch in range(n_channels)]
                        for t in range(n_time)]
        data1.create_dataset("dataTimeSeries", data=ts_array)

        # time vector
        data1.create_dataset("time", data=fnirs_data["time"])

        # measurementList
        for i, ml in enumerate(meas_list):
            ml_grp = data1.create_group(f"measurementList{i + 1}")
            ml_grp.create_dataset("sourceIndex", data=ml["sourceIndex"])
            ml_grp.create_dataset("detectorIndex", data=ml["detectorIndex"])
            ml_grp.create_dataset("wavelengthIndex", data=ml["wavelengthIndex"])
            ml_grp.create_dataset("dataType", data=ml["dataType"])
            ml_grp.create_dataset("dataTypeIndex", data=ml["dataTypeIndex"])

        # /nirs/probe
        probe = nirs.create_group("probe")
        probe.create_dataset("sourcePos3D", data=fnirs_data["source_pos"])
        probe.create_dataset("detectorPos3D", data=fnirs_data["detector_pos"])
        probe.create_dataset("wavelengths", data=fnirs_data["wavelengths"])

        # /nirs/stim1
        stim = fnirs_data.get("stim")
        if stim and stim.get("data"):
            stim1 = nirs.create_group("stim1")
            stim1.create_dataset("name", data=stim["name"])
            stim1.create_dataset("data", data=stim["data"])

        # /nirs/metaDataTags
        meta = nirs.create_group("metaDataTags")
        for key, value in metadata.items():
            meta.create_dataset(key, data=value)

    print(f"Wrote SNIRF: {output_path} ({n_time} samples, {n_channels} channels)",
          file=sys.stderr)


# =============================================================================
# JSON input loader
# =============================================================================

def load_fnirs_json(input_path: str) -> Dict:
    """Load fNIRS data from JSON file.

    Expected format:
    {
        "time": [0.0, 0.1, ...],
        "data": [[ch0_t0, ch0_t1, ...], [ch1_t0, ...], ...],
        "source_pos": [[x, y, z], ...],
        "detector_pos": [[x, y, z], ...],
        "wavelengths": [660, 860],
        "measurement_list": [...],
        "stim": {"name": "task", "data": [[onset, dur, amp], ...]},
        "metadata": {"SubjectID": "...", ...}
    }

    Args:
        input_path: path to JSON file

    Returns:
        dict compatible with write_snirf()
    """
    with open(input_path, "r") as f:
        data = json.load(f)

    # Compute derived fields if missing
    if "n_time" not in data:
        data["n_time"] = len(data["time"])
    if "n_channels" not in data:
        data["n_channels"] = len(data["data"])
    if "sample_rate" not in data and len(data["time"]) >= 2:
        data["sample_rate"] = 1.0 / (data["time"][1] - data["time"][0])
    if "metadata" not in data:
        data["metadata"] = {
            "SubjectID": "unknown",
            "MeasurementDate": datetime.now().strftime("%Y-%m-%d"),
            "LengthUnit": "mm",
        }

    return data


# =============================================================================
# Main entry point
# =============================================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="SNIRF Export -- write fNIRS data in SNIRF format"
    )
    parser.add_argument("--input", type=str,
                        help="Input fNIRS data file (JSON)")
    parser.add_argument("--output", type=str, required=True,
                        help="Output .snirf file path")
    parser.add_argument("--synthetic", action="store_true",
                        help="Generate synthetic fNIRS data for testing")
    parser.add_argument("--duration", type=float, default=60.0,
                        help="Duration in seconds (synthetic mode, default: 60)")
    parser.add_argument("--sample-rate", type=float, default=10.0,
                        help="Sample rate in Hz (synthetic mode, default: 10)")
    parser.add_argument("--sources", type=int, default=4,
                        help="Number of light sources (synthetic, default: 4)")
    parser.add_argument("--detectors", type=int, default=4,
                        help="Number of detectors (synthetic, default: 4)")

    args = parser.parse_args()

    if args.synthetic:
        fnirs_data = generate_synthetic_fnirs(
            duration=args.duration,
            sample_rate=args.sample_rate,
            n_sources=args.sources,
            n_detectors=args.detectors,
        )
        write_snirf(args.output, fnirs_data)
    elif args.input:
        fnirs_data = load_fnirs_json(args.input)
        write_snirf(args.output, fnirs_data)
    else:
        print("Error: specify --input or --synthetic", file=sys.stderr)
        sys.exit(1)
