#!/usr/bin/env python3
"""LSL Bridge -- streams LSL data as newline-delimited JSON to stdout.

Bridges Lab Streaming Layer streams into the zig-syrup BCI pipeline.
Output is NDJSON consumed by the Zig eeg binary or bci_receiver via stdin.

Usage:
    python lsl_bridge.py --type EEG              # find first EEG stream
    python lsl_bridge.py --name "DSI-24"         # find by name
    python lsl_bridge.py --type EEG --type NIRS  # multiple streams
    python lsl_bridge.py --synthetic             # generate test sine waves
    python lsl_bridge.py --synthetic --channels 24 --rate 300  # DSI-24 sim

From nushell:
    python lsl_bridge.py --type EEG | lines | each {|e| $e | from json}

Output format (one JSON object per line):
    {"ts": 1234.567, "channels": [0.1, 0.2, ...], "stream": "DSI-24", "type": "EEG"}
"""

import sys
import json
import time
import math
import signal
import argparse
import threading
from typing import Optional, List, Dict, Any

# =============================================================================
# Optional imports
# =============================================================================

try:
    from pylsl import (
        StreamInlet,
        StreamInfo,
        StreamOutlet,
        resolve_byprop,
        resolve_streams,
        local_clock,
    )
    HAS_LSL = True
except ImportError:
    HAS_LSL = False


# =============================================================================
# Globals
# =============================================================================

_shutdown = threading.Event()


def _signal_handler(signum, frame):
    """Handle SIGINT/SIGTERM for graceful shutdown."""
    print(f"\n# lsl_bridge: received signal {signum}, shutting down...", file=sys.stderr)
    _shutdown.set()


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


# =============================================================================
# Synthetic stream generator
# =============================================================================

class SyntheticStream:
    """Generate synthetic sine-wave EEG data for testing without hardware.

    Produces multi-channel sinusoidal signals at configurable frequencies.
    Default: 3 channels at 10Hz, 20Hz, 40Hz (alpha, beta, gamma analogs).
    """

    def __init__(
        self,
        name: str = "Synthetic-EEG",
        stream_type: str = "EEG",
        channels: int = 3,
        rate: float = 250.0,
        frequencies: Optional[List[float]] = None,
        amplitudes: Optional[List[float]] = None,
    ):
        self.name = name
        self.stream_type = stream_type
        self.channels = channels
        self.rate = rate
        self.frequencies = frequencies or self._default_freqs(channels)
        self.amplitudes = amplitudes or [10.0] * channels
        self._sample_idx = 0
        self._start_time = time.monotonic()

    @staticmethod
    def _default_freqs(n: int) -> List[float]:
        """Generate default test frequencies covering EEG bands."""
        base_freqs = [2.0, 6.0, 10.0, 20.0, 40.0]  # delta, theta, alpha, beta, gamma
        return [base_freqs[i % len(base_freqs)] for i in range(n)]

    def pull_sample(self) -> Dict[str, Any]:
        """Generate one synthetic sample."""
        t = self._sample_idx / self.rate
        channels = []
        for ch in range(self.channels):
            freq = self.frequencies[ch % len(self.frequencies)]
            amp = self.amplitudes[ch % len(self.amplitudes)]
            # Add slight noise for realism
            noise = math.sin(t * 60.0 * (ch + 1)) * 0.5  # 60Hz line noise analog
            value = amp * math.sin(2.0 * math.pi * freq * t) + noise
            channels.append(round(value, 6))

        self._sample_idx += 1
        return {
            "ts": round(time.monotonic() - self._start_time, 6),
            "channels": channels,
            "stream": self.name,
            "type": self.stream_type,
        }

    def stream(self):
        """Yield samples at the configured rate."""
        interval = 1.0 / self.rate
        next_time = time.monotonic()
        while not _shutdown.is_set():
            now = time.monotonic()
            if now >= next_time:
                yield self.pull_sample()
                next_time += interval
                # If we fell behind, catch up without busy-waiting
                if time.monotonic() > next_time + interval:
                    next_time = time.monotonic() + interval
            else:
                # Sleep until next sample, but wake on shutdown
                _shutdown.wait(timeout=max(0, next_time - now))


# =============================================================================
# LSL stream discovery
# =============================================================================

def discover_streams(
    stream_types: Optional[List[str]] = None,
    stream_names: Optional[List[str]] = None,
    timeout: float = 5.0,
) -> List[Any]:
    """Discover LSL streams matching the given criteria.

    Args:
        stream_types: List of LSL type strings to search for (e.g., ["EEG", "NIRS"])
        stream_names: List of stream names to search for (e.g., ["DSI-24"])
        timeout: Search timeout in seconds

    Returns:
        List of pylsl StreamInfo objects
    """
    if not HAS_LSL:
        print("Error: pylsl not installed. Run: pip install pylsl", file=sys.stderr)
        return []

    found = []

    if stream_names:
        for name in stream_names:
            print(f"Searching for stream name='{name}' (timeout={timeout}s)...", file=sys.stderr)
            results = resolve_byprop("name", name, timeout=timeout)
            for r in results:
                found.append(r)
                print(f"  Found: {r.name()} [{r.type()}] "
                      f"{r.channel_count()}ch @ {r.nominal_srate()}Hz", file=sys.stderr)

    if stream_types:
        for stype in stream_types:
            print(f"Searching for stream type='{stype}' (timeout={timeout}s)...", file=sys.stderr)
            results = resolve_byprop("type", stype, timeout=timeout)
            for r in results:
                # Avoid duplicates (same uid)
                if not any(r.uid() == f.uid() for f in found):
                    found.append(r)
                    print(f"  Found: {r.name()} [{r.type()}] "
                          f"{r.channel_count()}ch @ {r.nominal_srate()}Hz", file=sys.stderr)

    if not stream_types and not stream_names:
        print(f"Searching for all streams (timeout={timeout}s)...", file=sys.stderr)
        results = resolve_streams(timeout)
        for r in results:
            found.append(r)
            print(f"  Found: {r.name()} [{r.type()}] "
                  f"{r.channel_count()}ch @ {r.nominal_srate()}Hz", file=sys.stderr)

    return found


# =============================================================================
# LSL inlet streaming
# =============================================================================

def stream_inlet(
    info: Any,
    output_lock: threading.Lock,
) -> None:
    """Pull samples from a single LSL inlet and write NDJSON to stdout.

    Runs in a thread (one per stream) with shared stdout access via lock.
    """
    inlet = StreamInlet(info)
    stream_name = info.name()
    stream_type = info.type()
    n_channels = info.channel_count()

    print(f"Connected to '{stream_name}' [{stream_type}] "
          f"{n_channels}ch @ {info.nominal_srate()}Hz", file=sys.stderr)

    while not _shutdown.is_set():
        sample, timestamp = inlet.pull_sample(timeout=1.0)
        if sample is None:
            continue

        record = {
            "ts": round(timestamp, 6),
            "channels": [round(v, 6) for v in sample],
            "stream": stream_name,
            "type": stream_type,
        }

        line = json.dumps(record, separators=(",", ":"))
        with output_lock:
            try:
                sys.stdout.write(line + "\n")
                sys.stdout.flush()
            except BrokenPipeError:
                _shutdown.set()
                return


# =============================================================================
# List command
# =============================================================================

def cmd_list(args: argparse.Namespace) -> int:
    """List all available LSL streams as JSON."""
    if not HAS_LSL:
        print("Error: pylsl not installed. Run: pip install pylsl", file=sys.stderr)
        return 1

    streams = resolve_streams(args.timeout)
    results = []
    for s in streams:
        results.append({
            "name": s.name(),
            "type": s.type(),
            "channel_count": s.channel_count(),
            "nominal_srate": s.nominal_srate(),
            "source_id": s.source_id(),
            "hostname": s.hostname(),
            "uid": s.uid(),
        })

    print(json.dumps(results, indent=2))
    return 0


# =============================================================================
# Stream command
# =============================================================================

def cmd_stream(args: argparse.Namespace) -> int:
    """Stream LSL data as NDJSON to stdout."""

    # Synthetic mode: no pylsl needed
    if args.synthetic:
        freqs = None
        if args.frequencies:
            freqs = [float(f) for f in args.frequencies.split(",")]

        synth = SyntheticStream(
            name=args.synth_name or "Synthetic-EEG",
            stream_type=args.synth_type or "EEG",
            channels=args.channels,
            rate=args.rate,
            frequencies=freqs,
        )

        print(f"Synthetic stream: {synth.name} [{synth.stream_type}] "
              f"{synth.channels}ch @ {synth.rate}Hz", file=sys.stderr)
        print(f"Frequencies: {synth.frequencies}", file=sys.stderr)

        for sample in synth.stream():
            line = json.dumps(sample, separators=(",", ":"))
            try:
                sys.stdout.write(line + "\n")
                sys.stdout.flush()
            except BrokenPipeError:
                break

        return 0

    # Real LSL mode
    if not HAS_LSL:
        print("Error: pylsl not installed. Run: pip install pylsl", file=sys.stderr)
        print("Use --synthetic for testing without pylsl.", file=sys.stderr)
        return 1

    infos = discover_streams(
        stream_types=args.type,
        stream_names=args.name,
        timeout=args.timeout,
    )

    if not infos:
        print("No matching LSL streams found.", file=sys.stderr)
        print("Use --synthetic for testing without hardware.", file=sys.stderr)
        return 1

    # Multi-stream: one thread per inlet, interleaved output
    output_lock = threading.Lock()
    threads = []

    for info in infos:
        t = threading.Thread(
            target=stream_inlet,
            args=(info, output_lock),
            daemon=True,
        )
        t.start()
        threads.append(t)

    print(f"Streaming {len(threads)} stream(s). Press Ctrl+C to stop.", file=sys.stderr)

    # Wait for shutdown signal
    try:
        while not _shutdown.is_set():
            _shutdown.wait(timeout=1.0)
    except KeyboardInterrupt:
        _shutdown.set()

    # Wait for threads to finish
    for t in threads:
        t.join(timeout=2.0)

    print(f"Stopped.", file=sys.stderr)
    return 0


# =============================================================================
# Main
# =============================================================================

def main() -> int:
    parser = argparse.ArgumentParser(
        description="LSL Bridge -- stream LSL data as newline-delimited JSON to stdout.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    subparsers = parser.add_subparsers(dest="command")

    # -- list --
    list_parser = subparsers.add_parser("list", help="List available LSL streams")
    list_parser.add_argument("--timeout", type=float, default=3.0,
                             help="Search timeout in seconds (default: 3)")

    # -- stream (default) --
    stream_parser = subparsers.add_parser("stream", help="Stream LSL data as NDJSON")
    stream_parser.add_argument("--type", action="append", metavar="TYPE",
                               help="LSL stream type to find (e.g., EEG, NIRS, Gaze). "
                                    "Can be specified multiple times.")
    stream_parser.add_argument("--name", action="append", metavar="NAME",
                               help="LSL stream name to find (e.g., DSI-24). "
                                    "Can be specified multiple times.")
    stream_parser.add_argument("--timeout", type=float, default=5.0,
                               help="Stream search timeout in seconds (default: 5)")
    stream_parser.add_argument("--synthetic", action="store_true",
                               help="Generate synthetic test data instead of reading LSL")
    stream_parser.add_argument("--channels", type=int, default=3,
                               help="Number of synthetic channels (default: 3)")
    stream_parser.add_argument("--rate", type=float, default=250.0,
                               help="Synthetic sample rate in Hz (default: 250)")
    stream_parser.add_argument("--frequencies", type=str, default=None,
                               help="Comma-separated sine frequencies for synthetic mode "
                                    "(e.g., '10,20,40')")
    stream_parser.add_argument("--synth-name", type=str, default=None,
                               help="Synthetic stream name (default: Synthetic-EEG)")
    stream_parser.add_argument("--synth-type", type=str, default=None,
                               help="Synthetic stream type (default: EEG)")

    args = parser.parse_args()

    # Default to stream if no subcommand
    if args.command is None:
        # Re-parse with stream as default
        args = stream_parser.parse_args()
        args.command = "stream"

    if args.command == "list":
        return cmd_list(args)
    elif args.command == "stream":
        return cmd_stream(args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
