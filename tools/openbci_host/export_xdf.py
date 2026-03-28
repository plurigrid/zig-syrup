#!/usr/bin/env python3
"""XDF Export -- write multi-stream recordings in Extensible Data Format.

Captures multiple synchronized streams (EEG, fNIRS, eye tracking, pose)
into a single XDF file compatible with pyxdf, EEGLAB, and MNE-Python.

XDF format: binary with typed chunks (file header, stream header, samples,
clock offset, stream footer, file footer).

Usage:
    python export_xdf.py --input recording.json --output recording.xdf
    python export_xdf.py --synthetic --output test.xdf
"""

import sys
import json
import struct
import math
import argparse
from datetime import datetime
from typing import Dict, List, Optional, Tuple, BinaryIO

# =============================================================================
# Optional imports
# =============================================================================

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

# =============================================================================
# XDF Constants
# =============================================================================

# XDF magic bytes
XDF_MAGIC = b"XDF:"

# Chunk tag codes
TAG_FILE_HEADER = 1
TAG_STREAM_HEADER = 2
TAG_SAMPLES = 3
TAG_CLOCK_OFFSET = 4
TAG_STREAM_FOOTER = 5
TAG_FILE_FOOTER = 6  # not in spec but some readers expect it

# Channel format strings → format codes
CHANNEL_FORMATS = {
    "float32": 1,
    "double64": 2,
    "string": 3,
    "int32": 4,
    "int16": 5,
    "int8": 6,
    "int64": 7,
}

# Format code → struct pack character
FORMAT_PACK = {
    1: "<f",   # float32
    2: "<d",   # double64
    4: "<i",   # int32
    5: "<h",   # int16
    6: "<b",   # int8
    7: "<q",   # int64
}

# Format code → byte size
FORMAT_SIZE = {
    1: 4,
    2: 8,
    4: 4,
    5: 2,
    6: 1,
    7: 8,
}


# =============================================================================
# XDF Writer
# =============================================================================

class XDFWriter:
    """Write multi-stream data in XDF format.

    XDF file structure:
      [magic "XDF:"]
      [FileHeader chunk]
      [StreamHeader chunk (stream 1)]
      [StreamHeader chunk (stream 2)]
      ...
      [Samples chunk (stream 1, batch)]
      [Samples chunk (stream 2, batch)]
      [ClockOffset chunk (stream 1)]
      ...
      [StreamFooter chunk (stream 1)]
      [StreamFooter chunk (stream 2)]

    All multi-byte integers are little-endian.
    """

    def __init__(self, file: BinaryIO):
        self._file = file
        self._stream_ids: List[int] = []
        self._sample_counts: Dict[int, int] = {}
        self._first_timestamps: Dict[int, float] = {}
        self._last_timestamps: Dict[int, float] = {}

    def _write_chunk_length(self, length: int):
        """Write variable-length chunk size (1 or 5 bytes).

        If length < 256: write 1 byte
        Otherwise: write 0xFF marker + 4-byte LE uint32
        """
        if length < 256:
            self._file.write(struct.pack("<B", length))
        else:
            self._file.write(b"\xff")
            self._file.write(struct.pack("<I", length))

    def _write_chunk(self, tag: int, stream_id: Optional[int], content: bytes):
        """Write a complete XDF chunk.

        Chunk format:
          [length (var)]  — length of tag + stream_id (if present) + content
          [tag: u16]
          [stream_id: u32]  (only for stream-specific chunks)
          [content: bytes]
        """
        if stream_id is not None:
            total = 2 + 4 + len(content)  # tag(2) + stream_id(4) + content
        else:
            total = 2 + len(content)      # tag(2) + content

        self._write_chunk_length(total)
        self._file.write(struct.pack("<H", tag))
        if stream_id is not None:
            self._file.write(struct.pack("<I", stream_id))
        self._file.write(content)

    def write_file_header(self, version: str = "1.0"):
        """Write XDF file magic and file header chunk."""
        self._file.write(XDF_MAGIC)
        xml = (
            f'<?xml version="1.0"?>'
            f'<info>'
            f'<version>{version}</version>'
            f'</info>'
        ).encode("utf-8")
        self._write_chunk(TAG_FILE_HEADER, None, xml)

    def write_stream_header(
        self,
        stream_id: int,
        name: str,
        stream_type: str,
        channel_count: int,
        nominal_srate: float,
        channel_format: str = "float32",
        source_id: str = "",
        channel_labels: Optional[List[str]] = None,
    ):
        """Write a stream header chunk.

        Args:
            stream_id: unique integer ID for this stream
            name: stream name (e.g., "EEG", "fNIRS")
            stream_type: stream type (e.g., "EEG", "NIRS", "Mocap")
            channel_count: number of channels
            nominal_srate: nominal sampling rate in Hz
            channel_format: data format ("float32", "double64", "int16", etc.)
            source_id: source identifier string
            channel_labels: optional list of channel label strings
        """
        self._stream_ids.append(stream_id)
        self._sample_counts[stream_id] = 0

        # Build channels XML
        channels_xml = ""
        if channel_labels:
            channels_xml = "<channels>"
            for label in channel_labels:
                channels_xml += f'<channel><label>{label}</label></channel>'
            channels_xml += "</channels>"

        xml = (
            f'<?xml version="1.0"?>'
            f'<info>'
            f'<name>{name}</name>'
            f'<type>{stream_type}</type>'
            f'<channel_count>{channel_count}</channel_count>'
            f'<nominal_srate>{nominal_srate}</nominal_srate>'
            f'<channel_format>{channel_format}</channel_format>'
            f'<source_id>{source_id}</source_id>'
            f'<created_at>{datetime.now().isoformat()}</created_at>'
            f'{channels_xml}'
            f'</info>'
        ).encode("utf-8")
        self._write_chunk(TAG_STREAM_HEADER, stream_id, xml)

    def write_samples(
        self,
        stream_id: int,
        timestamps: List[float],
        data: List[List[float]],
        channel_format: str = "float32",
    ):
        """Write a batch of samples for a stream.

        Each sample: [timestamp: f64][values: channel_format * n_channels]

        Args:
            stream_id: stream ID
            timestamps: list of timestamps (one per sample)
            data: list of samples, each a list of channel values
            channel_format: data format string
        """
        if not timestamps or not data:
            return

        fmt_code = CHANNEL_FORMATS.get(channel_format, 1)
        pack_char = FORMAT_PACK.get(fmt_code, "<f")
        n_channels = len(data[0]) if data else 0

        buf = bytearray()
        # Number of samples (4 bytes LE)
        buf.extend(struct.pack("<I", len(timestamps)))
        # Number of channels (4 bytes LE, XDF extension for batch)
        # Actually XDF uses per-sample format, but we pack per spec:

        for i, ts in enumerate(timestamps):
            sample_vals = data[i] if i < len(data) else [0.0] * n_channels
            # Timestamp (8 bytes, double)
            buf.extend(struct.pack("<d", ts))
            # Channel values
            for val in sample_vals:
                buf.extend(struct.pack(pack_char, val))

        self._write_chunk(TAG_SAMPLES, stream_id, bytes(buf))

        # Update bookkeeping
        count = len(timestamps)
        self._sample_counts[stream_id] = self._sample_counts.get(stream_id, 0) + count
        if stream_id not in self._first_timestamps:
            self._first_timestamps[stream_id] = timestamps[0]
        self._last_timestamps[stream_id] = timestamps[-1]

    def write_clock_offset(self, stream_id: int, collection_time: float, offset: float):
        """Write a clock offset chunk for temporal synchronization.

        Args:
            stream_id: stream ID
            collection_time: time at which offset was measured
            offset: clock offset in seconds (remote - local)
        """
        content = struct.pack("<dd", collection_time, offset)
        self._write_chunk(TAG_CLOCK_OFFSET, stream_id, content)

    def write_stream_footer(self, stream_id: int):
        """Write stream footer with summary statistics."""
        sample_count = self._sample_counts.get(stream_id, 0)
        first_ts = self._first_timestamps.get(stream_id, 0.0)
        last_ts = self._last_timestamps.get(stream_id, 0.0)

        xml = (
            f'<?xml version="1.0"?>'
            f'<info>'
            f'<first_timestamp>{first_ts}</first_timestamp>'
            f'<last_timestamp>{last_ts}</last_timestamp>'
            f'<sample_count>{sample_count}</sample_count>'
            f'</info>'
        ).encode("utf-8")
        self._write_chunk(TAG_STREAM_FOOTER, stream_id, xml)


# =============================================================================
# Synthetic data generator
# =============================================================================

def generate_synthetic_xdf(
    duration: float = 30.0,
    eeg_rate: float = 250.0,
    fnirs_rate: float = 10.0,
    pose_rate: float = 30.0,
    eeg_channels: int = 8,
    fnirs_channels: int = 16,
    pose_channels: int = 12,
) -> Dict:
    """Generate synthetic multi-stream data for XDF export testing.

    Creates three synchronized streams:
    1. EEG (8 channels, 250 Hz)
    2. fNIRS (16 channels, 10 Hz)
    3. Pose/Body tracking (12 channels, 30 Hz)

    Args:
        duration: recording duration in seconds
        eeg_rate: EEG sampling rate
        fnirs_rate: fNIRS sampling rate
        pose_rate: pose tracking rate
        eeg_channels: number of EEG channels
        fnirs_channels: number of fNIRS channels
        pose_channels: number of pose channels

    Returns:
        dict with streams list
    """
    streams = []

    # EEG channel labels (10-20 system)
    eeg_labels = ["Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2"][:eeg_channels]

    # Generate EEG data
    eeg_n = int(duration * eeg_rate)
    eeg_dt = 1.0 / eeg_rate
    eeg_timestamps = [i * eeg_dt for i in range(eeg_n)]
    eeg_data = []
    for i in range(eeg_n):
        t = eeg_timestamps[i]
        sample = []
        for ch in range(eeg_channels):
            # Alpha oscillation + noise
            alpha = 20.0 * math.sin(2 * math.pi * 10.0 * t + ch * 0.5)
            beta = 5.0 * math.sin(2 * math.pi * 22.0 * t + ch * 0.3)
            noise = 2.0 * math.sin(t * 97.3 + ch * 13.1)
            sample.append(alpha + beta + noise)
        eeg_data.append(sample)

    streams.append({
        "stream_id": 1,
        "name": "OpenBCI-EEG",
        "type": "EEG",
        "channel_count": eeg_channels,
        "nominal_srate": eeg_rate,
        "channel_format": "float32",
        "source_id": "openbci-cyton-001",
        "channel_labels": eeg_labels,
        "timestamps": eeg_timestamps,
        "data": eeg_data,
    })

    # Generate fNIRS data
    fnirs_n = int(duration * fnirs_rate)
    fnirs_dt = 1.0 / fnirs_rate
    fnirs_timestamps = [i * fnirs_dt for i in range(fnirs_n)]
    fnirs_data = []
    for i in range(fnirs_n):
        t = fnirs_timestamps[i]
        sample = []
        for ch in range(fnirs_channels):
            baseline = 1.0
            hrf = 0.01 * math.sin(2 * math.pi * 0.05 * t + ch * 0.2)
            cardiac = 0.005 * math.sin(2 * math.pi * 1.1 * t)
            sample.append(baseline + hrf + cardiac)
        fnirs_data.append(sample)

    fnirs_labels = [f"S{s+1}-D{d+1}" for s in range(4) for d in range(4)][:fnirs_channels]
    streams.append({
        "stream_id": 2,
        "name": "PLUX-fNIRS",
        "type": "NIRS",
        "channel_count": fnirs_channels,
        "nominal_srate": fnirs_rate,
        "channel_format": "float32",
        "source_id": "plux-fnirs-001",
        "channel_labels": fnirs_labels,
        "timestamps": fnirs_timestamps,
        "data": fnirs_data,
    })

    # Generate pose data (joint angles in degrees)
    pose_n = int(duration * pose_rate)
    pose_dt = 1.0 / pose_rate
    pose_timestamps = [i * pose_dt for i in range(pose_n)]
    pose_data = []
    pose_labels = [
        "L_Shoulder", "R_Shoulder", "L_Elbow", "R_Elbow",
        "L_Wrist", "R_Wrist", "L_Hip", "R_Hip",
        "L_Knee", "R_Knee", "L_Ankle", "R_Ankle",
    ][:pose_channels]

    for i in range(pose_n):
        t = pose_timestamps[i]
        sample = []
        for ch in range(pose_channels):
            # Simulate slow posture changes with micro-sway
            base_angle = 90.0 + 20.0 * math.sin(2 * math.pi * 0.1 * t + ch * 0.5)
            sway = 1.0 * math.sin(2 * math.pi * 0.5 * t + ch * 0.3)
            sample.append(base_angle + sway)
        pose_data.append(sample)

    streams.append({
        "stream_id": 3,
        "name": "BodyTracking",
        "type": "Mocap",
        "channel_count": pose_channels,
        "nominal_srate": pose_rate,
        "channel_format": "float32",
        "source_id": "pose-tracker-001",
        "channel_labels": pose_labels,
        "timestamps": pose_timestamps,
        "data": pose_data,
    })

    return {"streams": streams}


# =============================================================================
# Write XDF from structured data
# =============================================================================

def write_xdf(output_path: str, recording: Dict):
    """Write multi-stream recording to XDF file.

    Args:
        output_path: path to output .xdf file
        recording: dict with "streams" list, each stream having:
            stream_id, name, type, channel_count, nominal_srate,
            channel_format, source_id, channel_labels, timestamps, data
    """
    streams = recording["streams"]

    with open(output_path, "wb") as f:
        writer = XDFWriter(f)

        # File header
        writer.write_file_header()

        # Stream headers
        for stream in streams:
            writer.write_stream_header(
                stream_id=stream["stream_id"],
                name=stream["name"],
                stream_type=stream["type"],
                channel_count=stream["channel_count"],
                nominal_srate=stream["nominal_srate"],
                channel_format=stream.get("channel_format", "float32"),
                source_id=stream.get("source_id", ""),
                channel_labels=stream.get("channel_labels"),
            )

        # Clock offsets (all streams assumed synchronized, offset=0)
        for stream in streams:
            if stream["timestamps"]:
                writer.write_clock_offset(
                    stream["stream_id"],
                    collection_time=stream["timestamps"][0],
                    offset=0.0,
                )

        # Write samples in batches (interleave streams)
        batch_size = 1000
        for stream in streams:
            ts = stream["timestamps"]
            data = stream["data"]
            fmt = stream.get("channel_format", "float32")

            for start in range(0, len(ts), batch_size):
                end = min(start + batch_size, len(ts))
                writer.write_samples(
                    stream["stream_id"],
                    ts[start:end],
                    data[start:end],
                    channel_format=fmt,
                )

        # Stream footers
        for stream in streams:
            writer.write_stream_footer(stream["stream_id"])

    total_samples = sum(len(s["timestamps"]) for s in streams)
    print(f"Wrote XDF: {output_path} ({len(streams)} streams, {total_samples} total samples)",
          file=sys.stderr)


# =============================================================================
# JSON input loader
# =============================================================================

def load_recording_json(input_path: str) -> Dict:
    """Load multi-stream recording from JSON file.

    Expected format:
    {
        "streams": [
            {
                "stream_id": 1,
                "name": "EEG",
                "type": "EEG",
                "channel_count": 8,
                "nominal_srate": 250.0,
                "channel_format": "float32",
                "timestamps": [0.0, 0.004, ...],
                "data": [[ch0, ch1, ...], ...]
            },
            ...
        ]
    }

    Args:
        input_path: path to JSON file

    Returns:
        dict compatible with write_xdf()
    """
    with open(input_path, "r") as f:
        return json.load(f)


# =============================================================================
# Main entry point
# =============================================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="XDF Export -- write multi-stream recordings in XDF format"
    )
    parser.add_argument("--input", type=str,
                        help="Input recording file (JSON)")
    parser.add_argument("--output", type=str, required=True,
                        help="Output .xdf file path")
    parser.add_argument("--synthetic", action="store_true",
                        help="Generate synthetic multi-stream data for testing")
    parser.add_argument("--duration", type=float, default=30.0,
                        help="Duration in seconds (synthetic mode, default: 30)")

    args = parser.parse_args()

    if args.synthetic:
        recording = generate_synthetic_xdf(duration=args.duration)
        write_xdf(args.output, recording)
    elif args.input:
        recording = load_recording_json(args.input)
        write_xdf(args.output, recording)
    else:
        print("Error: specify --input or --synthetic", file=sys.stderr)
        sys.exit(1)
