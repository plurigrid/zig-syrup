#!/usr/bin/env python3
"""
lsl_bridge.py
Python helper that bridges OpenBCI LSL streams to nushell-friendly formats.

This script receives LSL (Lab Streaming Layer) streams from OpenBCI and outputs
data in formats easily consumable by nushell, including JSON Lines, CSV, and Parquet.

Usage:
    python lsl_bridge.py stream                    # Stream to stdout as JSONL
    python lsl_bridge.py stream --output pipe      # Output to named pipe
    python lsl_bridge.py capture --samples 1000    # Capture N samples
    python lsl_bridge.py list                      # List available LSL streams
    
    # From nushell:
    python lsl_bridge.py stream | lines | each {|e| $e | from json}
    python lsl_bridge.py stream | save eeg_stream.jsonl
"""

import sys
import json
import time
import argparse
import os
import tempfile
from pathlib import Path
from typing import Optional, List, Dict, Any, Iterator
from datetime import datetime
from contextlib import contextmanager

# Optional imports - handle gracefully if not available
try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

try:
    from pylsl import StreamInlet, resolve_stream, local_clock, resolve_byprop
    HAS_LSL = True
except ImportError:
    HAS_LSL = False
    print("Error: pylsl not installed. Run: pip install pylsl", file=sys.stderr)
    sys.exit(1)


# =============================================================================
# Constants
# =============================================================================

DEFAULT_STREAM_NAME = "OpenBCI-EEG"
DEFAULT_STREAM_TYPE = "EEG"
DEFAULT_SOURCE_ID = "openbci-host-001"
DEFAULT_PIPE_NAME = "/tmp/openbci_lsl_pipe"


def get_timestamp() -> float:
    """Get high-precision timestamp."""
    return local_clock()


def format_sample(
    sample: List[float],
    timestamp: float,
    sample_num: int,
    channel_names: List[str],
    aux: Optional[List[float]] = None
) -> Dict[str, Any]:
    """Format a sample as a dictionary matching nushell EEGSample type."""
    # Split channels and aux data (assuming 8 channels + 3 aux for OpenBCI)
    n_channels = len(channel_names) if channel_names else len(sample)
    
    channels = sample[:n_channels]
    aux_data = aux if aux is not None else sample[n_channels:n_channels+3] if len(sample) > n_channels else [0.0, 0.0, 0.0]
    
    return {
        "timestamp": timestamp,
        "sample_num": sample_num,
        "channels": channels,
        "aux": aux_data
    }


# =============================================================================
# LSL Stream Discovery
# =============================================================================

def list_lsl_streams(timeout: float = 2.0) -> List[Dict[str, Any]]:
    """List all available LSL streams."""
    print(f"Searching for LSL streams (timeout={timeout}s)...", file=sys.stderr)
    
    streams = resolve_stream(timeout=timeout)
    
    results = []
    for i, stream in enumerate(streams):
        info = {
            "index": i,
            "name": stream.name(),
            "type": stream.type(),
            "source_id": stream.source_id(),
            "channel_count": stream.channel_count(),
            "nominal_srate": stream.nominal_srate(),
            "hostname": stream.hostname(),
            "uid": stream.uid(),
        }
        results.append(info)
    
    return results


def find_openbci_stream(
    stream_name: Optional[str] = None,
    source_id: Optional[str] = None,
    timeout: float = 5.0
) -> Optional[Any]:
    """Find OpenBCI LSL stream."""
    
    # Try to find by specific criteria
    if stream_name:
        streams = resolve_byprop('name', stream_name, timeout=timeout)
        if streams:
            return streams[0]
    
    if source_id:
        streams = resolve_byprop('source_id', source_id, timeout=timeout)
        if streams:
            return streams[0]
    
    # Try default name
    streams = resolve_byprop('name', DEFAULT_STREAM_NAME, timeout=timeout)
    if streams:
        return streams[0]
    
    # Try any EEG stream
    streams = resolve_byprop('type', 'EEG', timeout=timeout)
    if streams:
        return streams[0]
    
    # Fallback: resolve any stream
    all_streams = resolve_stream(timeout=timeout)
    if all_streams:
        return all_streams[0]
    
    return None


# =============================================================================
# Stream Processing
# =============================================================================

def stream_samples(
    inlet: StreamInlet,
    max_samples: Optional[int] = None,
    timeout: float = 3600.0
) -> Iterator[Dict[str, Any]]:
    """Generator that yields formatted samples from LSL inlet."""
    
    # Get stream info
    info = inlet.info()
    channel_names = []
    try:
        ch = info.desc().child("channels")
        for i in range(info.channel_count()):
            channel = ch.child(i)
            label = channel.child_value("label")
            channel_names.append(label if label else f"Ch{i}")
    except:
        channel_names = [f"Ch{i}" for i in range(info.channel_count())]
    
    sample_num = 0
    start_time = time.time()
    
    while True:
        # Check for max samples or timeout
        if max_samples and sample_num >= max_samples:
            break
        if time.time() - start_time > timeout:
            break
        
        # Pull sample from LSL
        sample, timestamp = inlet.pull_sample(timeout=1.0)
        
        if sample is None:
            continue
        
        formatted = format_sample(
            sample=sample,
            timestamp=timestamp,
            sample_num=sample_num,
            channel_names=channel_names
        )
        
        yield formatted
        sample_num += 1


def stream_to_jsonl(
    inlet: StreamInlet,
    output: Optional[Any] = None,
    max_samples: Optional[int] = None
) -> None:
    """Stream samples as JSON Lines to output."""
    
    for sample in stream_samples(inlet, max_samples):
        json_line = json.dumps(sample, separators=(',', ':'))
        
        if output:
            output.write(json_line + '\n')
            output.flush()
        else:
            print(json_line)


def stream_to_csv(
    inlet: StreamInlet,
    output: Any,
    max_samples: Optional[int] = None
) -> None:
    """Stream samples as CSV to output."""
    
    # Get info for header
    info = inlet.info()
    channel_count = info.channel_count()
    
    # Write CSV header
    header = "timestamp,sample_num," + ",".join([f"ch{i}" for i in range(channel_count)]) + ",aux1,aux2,aux3\n"
    output.write(header)
    
    for sample in stream_samples(inlet, max_samples):
        channels_str = ",".join(str(c) for c in sample["channels"])
        aux_str = ",".join(str(a) for a in sample["aux"])
        line = f"{sample['timestamp']},{sample['sample_num']},{channels_str},{aux_str}\n"
        output.write(line)
        output.flush()


def capture_to_parquet(
    inlet: StreamInlet,
    filepath: str,
    samples: int
) -> None:
    """Capture samples to Parquet file using pandas."""
    
    if not HAS_PANDAS:
        print("Error: pandas required for Parquet output", file=sys.stderr)
        sys.exit(1)
    
    # Collect samples
    data = []
    for sample in stream_samples(inlet, max_samples=samples):
        row = {
            "timestamp": sample["timestamp"],
            "sample_num": sample["sample_num"],
        }
        # Add channels
        for i, ch in enumerate(sample["channels"]):
            row[f"ch{i}"] = ch
        # Add aux
        for i, aux in enumerate(sample["aux"]):
            row[f"aux{i}"] = aux
        
        data.append(row)
    
    # Create DataFrame and save
    df = pd.DataFrame(data)
    df.to_parquet(filepath, index=False)
    print(f"Saved {len(data)} samples to {filepath}", file=sys.stderr)


# =============================================================================
# Named Pipe Support
# =============================================================================

@contextmanager
def named_pipe(pipe_path: str):
    """Context manager for named pipe (FIFO)."""
    import stat
    
    # Create pipe if it doesn't exist
    if not os.path.exists(pipe_path):
        os.mkfifo(pipe_path)
    
    try:
        # Open pipe for writing (non-blocking)
        fd = os.open(pipe_path, os.O_WRONLY | os.O_NONBLOCK)
        with os.fdopen(fd, 'w') as pipe:
            yield pipe
    except OSError as e:
        print(f"Warning: Could not open pipe {pipe_path}: {e}", file=sys.stderr)
        yield sys.stdout
    finally:
        # Clean up
        if os.path.exists(pipe_path):
            os.unlink(pipe_path)


# =============================================================================
# Command Handlers
# =============================================================================

def cmd_list(args: argparse.Namespace) -> int:
    """List available LSL streams."""
    streams = list_lsl_streams(timeout=args.timeout)
    
    if not streams:
        print("No LSL streams found.", file=sys.stderr)
        return 1
    
    # Output as JSON for nushell
    print(json.dumps(streams, indent=2))
    return 0


def cmd_stream(args: argparse.Namespace) -> int:
    """Stream LSL data to output."""
    
    # Find stream
    stream_info = find_openbci_stream(
        stream_name=args.stream_name,
        source_id=args.source_id,
        timeout=args.timeout
    )
    
    if not stream_info:
        print("Error: Could not find OpenBCI LSL stream", file=sys.stderr)
        print("Run 'list' command to see available streams", file=sys.stderr)
        return 1
    
    print(f"Found stream: {stream_info.name()}", file=sys.stderr)
    
    # Create inlet
    inlet = StreamInlet(stream_info)
    print(f"Connected. Sampling at {stream_info.nominal_srate()} Hz", file=sys.stderr)
    
    # Determine output
    if args.output == 'pipe':
        pipe_path = args.pipe_path or DEFAULT_PIPE_NAME
        print(f"Writing to named pipe: {pipe_path}", file=sys.stderr)
        with named_pipe(pipe_path) as pipe:
            stream_to_jsonl(inlet, pipe, max_samples=args.max_samples)
    elif args.output:
        # Write to file
        with open(args.output, 'w') as f:
            if args.format == 'csv':
                stream_to_csv(inlet, f, max_samples=args.max_samples)
            else:
                stream_to_jsonl(inlet, f, max_samples=args.max_samples)
        print(f"Saved to {args.output}", file=sys.stderr)
    else:
        # Stream to stdout
        stream_to_jsonl(inlet, max_samples=args.max_samples)
    
    return 0


def cmd_capture(args: argparse.Namespace) -> int:
    """Capture samples to file."""
    
    # Find stream
    stream_info = find_openbci_stream(
        stream_name=args.stream_name,
        source_id=args.source_id,
        timeout=args.timeout
    )
    
    if not stream_info:
        print("Error: Could not find OpenBCI LSL stream", file=sys.stderr)
        return 1
    
    inlet = StreamInlet(stream_info)
    
    # Determine format and save
    if args.output:
        ext = Path(args.output).suffix.lower()
    else:
        ext = '.jsonl'
    
    if ext == '.parquet' or args.format == 'parquet':
        capture_to_parquet(inlet, args.output or 'eeg_capture.parquet', args.samples)
    elif ext == '.csv' or args.format == 'csv':
        with open(args.output or 'eeg_capture.csv', 'w') as f:
            stream_to_csv(inlet, f, max_samples=args.samples)
        print(f"Saved to {args.output or 'eeg_capture.csv'}", file=sys.stderr)
    else:
        with open(args.output or 'eeg_capture.jsonl', 'w') as f:
            stream_to_jsonl(inlet, f, max_samples=args.samples)
        print(f"Saved to {args.output or 'eeg_capture.jsonl'}", file=sys.stderr)
    
    return 0


def cmd_monitor(args: argparse.Namespace) -> int:
    """Monitor signal quality in real-time."""
    
    stream_info = find_openbci_stream(
        stream_name=args.stream_name,
        source_id=args.source_id,
        timeout=args.timeout
    )
    
    if not stream_info:
        print("Error: Could not find OpenBCI LSL stream", file=sys.stderr)
        return 1
    
    inlet = StreamInlet(stream_info)
    channel_count = stream_info.channel_count()
    
    print(f"Monitoring {channel_count} channels. Press Ctrl+C to stop.", file=sys.stderr)
    
    # Buffer for quality calculation
    buffer = []
    window_size = int(stream_info.nominal_srate() * args.window)
    
    try:
        for sample in stream_samples(inlet):
            buffer.append(sample)
            
            if len(buffer) >= window_size:
                # Calculate quality metrics
                quality = []
                for ch in range(channel_count):
                    values = [s['channels'][ch] for s in buffer]
                    mean = sum(values) / len(values)
                    variance = sum((x - mean) ** 2 for x in values) / len(values)
                    std = variance ** 0.5
                    
                    # Simple quality: reasonable std indicates signal
                    is_good = 0.1 < std < 200
                    quality.append('●' if is_good else '○')
                
                # Print status line
                status = f"\rQuality: {''.join(quality)} | Sample: {sample['sample_num']}"
                print(status, end='', file=sys.stderr, flush=True)
                
                buffer = []
                
    except KeyboardInterrupt:
        print("\nMonitoring stopped.", file=sys.stderr)
    
    return 0


# =============================================================================
# Main Entry Point
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='LSL Bridge for OpenBCI - nushell integration'
    )
    
    # Global options
    parser.add_argument('--stream-name', default=None, help='LSL stream name')
    parser.add_argument('--source-id', default=None, help='LSL source ID')
    parser.add_argument('--timeout', type=float, default=5.0, help='Stream search timeout')
    
    subparsers = parser.add_subparsers(dest='command', help='Available commands')
    
    # List command
    list_parser = subparsers.add_parser('list', help='List available LSL streams')
    
    # Stream command
    stream_parser = subparsers.add_parser('stream', help='Stream data continuously')
    stream_parser.add_argument('--output', '-o', default=None, 
                               help='Output file (or "pipe" for named pipe)')
    stream_parser.add_argument('--pipe-path', default=None, help='Named pipe path')
    stream_parser.add_argument('--format', choices=['jsonl', 'csv'], default='jsonl')
    stream_parser.add_argument('--max-samples', type=int, default=None,
                               help='Maximum samples to stream')
    
    # Capture command
    capture_parser = subparsers.add_parser('capture', help='Capture samples to file')
    capture_parser.add_argument('--samples', '-n', type=int, default=1000,
                                help='Number of samples to capture')
    capture_parser.add_argument('--output', '-o', required=True, help='Output file')
    capture_parser.add_argument('--format', choices=['jsonl', 'csv', 'parquet'],
                                default=None, help='Output format (auto from extension)')
    
    # Monitor command
    monitor_parser = subparsers.add_parser('monitor', help='Monitor signal quality')
    monitor_parser.add_argument('--window', type=float, default=1.0,
                                help='Quality calculation window in seconds')
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return 1
    
    # Route to command handler
    commands = {
        'list': cmd_list,
        'stream': cmd_stream,
        'capture': cmd_capture,
        'monitor': cmd_monitor,
    }
    
    handler = commands.get(args.command)
    if handler:
        return handler(args)
    else:
        parser.print_help()
        return 1


if __name__ == '__main__':
    sys.exit(main())
