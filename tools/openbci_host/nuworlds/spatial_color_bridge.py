"""
Spatial Color Bridge: BCI Brainwave Entropy → Spatial Propagator Colors

Reads BCI color epochs (from SSE :7070 or synthetic data) and feeds
Φ/valence/fisher/trit into the Zig spatial propagator via ctypes C ABI.

The spatial propagator applies golden-angle HSL projection per-node,
so each split pane gets a unique color derived from the same brainwave
state — dispersed by spatial_index.

Usage:
    # With live SSE from nats_color_bridge.py
    python spatial_color_bridge.py --sse http://localhost:7070/events

    # With synthetic BCI data
    python spatial_color_bridge.py --synthetic

    # One-shot demo
    python spatial_color_bridge.py --demo
"""

import ctypes
import os
import sys
import json
import struct
import time
from pathlib import Path
from dataclasses import dataclass
from typing import Optional, List, Tuple

# Find the shared library
LIB_SEARCH_PATHS = [
    Path(__file__).parent.parent.parent.parent / "zig-out" / "lib" / "libspatial_propagator.dylib",
    Path(__file__).parent.parent.parent.parent / ".zig-cache" / "o" / "*" / "libspatial_propagator.dylib",
    Path("/usr/local/lib/libspatial_propagator.dylib"),
]


def find_lib() -> str:
    for p in LIB_SEARCH_PATHS:
        if "*" in str(p):
            import glob
            matches = sorted(glob.glob(str(p)), key=os.path.getmtime, reverse=True)
            if matches:
                return matches[0]
        elif p.exists():
            return str(p)
    raise FileNotFoundError(
        "libspatial_propagator.dylib not found. Run `zig build` in zig-syrup first."
    )


# C ABI bindings
class SpatialPropagator:
    """Python wrapper around the Zig spatial propagator C ABI."""

    def __init__(self, lib_path: Optional[str] = None):
        path = lib_path or find_lib()
        self.lib = ctypes.CDLL(path)
        self._setup_prototypes()
        self.handle = self.lib.propagator_init()
        if not self.handle:
            raise RuntimeError("propagator_init returned NULL")

    def _setup_prototypes(self):
        L = self.lib

        L.propagator_init.restype = ctypes.c_void_p
        L.propagator_init.argtypes = []

        L.propagator_deinit.restype = None
        L.propagator_deinit.argtypes = [ctypes.c_void_p]

        L.propagator_add_node.restype = ctypes.c_int32
        L.propagator_add_node.argtypes = [
            ctypes.c_void_p,  # handle
            ctypes.c_uint32,  # window_id
            ctypes.c_uint32,  # space_id
            ctypes.c_uint32,  # depth
            ctypes.c_int32,   # x
            ctypes.c_int32,   # y
            ctypes.c_uint32,  # w
            ctypes.c_uint32,  # h
        ]

        L.propagator_connect.restype = None
        L.propagator_connect.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32]

        L.propagator_detect_adjacency.restype = None
        L.propagator_detect_adjacency.argtypes = [ctypes.c_void_p]

        L.propagator_assign_colors.restype = None
        L.propagator_assign_colors.argtypes = [ctypes.c_void_p]

        L.propagator_assign_colors_bci.restype = None
        L.propagator_assign_colors_bci.argtypes = [
            ctypes.c_void_p,  # handle
            ctypes.c_float,   # phi
            ctypes.c_float,   # valence
            ctypes.c_float,   # fisher
            ctypes.c_int32,   # trit
        ]

        L.propagator_set_node_color.restype = None
        L.propagator_set_node_color.argtypes = [
            ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32
        ]

        L.propagator_set_focus.restype = None
        L.propagator_set_focus.argtypes = [ctypes.c_void_p, ctypes.c_uint32]

        L.propagator_get_spatial_colors.restype = ctypes.c_size_t
        L.propagator_get_spatial_colors.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t
        ]

        L.propagator_ingest_topology.restype = ctypes.c_int32
        L.propagator_ingest_topology.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t
        ]

    def add_node(self, window_id: int, space_id: int = 0, depth: int = 0,
                 x: int = 0, y: int = 0, w: int = 100, h: int = 100) -> int:
        return self.lib.propagator_add_node(
            self.handle, window_id, space_id, depth, x, y, w, h
        )

    def connect(self, a: int, b: int):
        self.lib.propagator_connect(self.handle, a, b)

    def detect_adjacency(self):
        self.lib.propagator_detect_adjacency(self.handle)

    def assign_colors(self):
        self.lib.propagator_assign_colors(self.handle)

    def assign_colors_bci(self, phi: float, valence: float, fisher: float, trit: int):
        """Assign colors from BCI brainwave entropy."""
        self.lib.propagator_assign_colors_bci(
            self.handle,
            ctypes.c_float(phi),
            ctypes.c_float(valence),
            ctypes.c_float(fisher),
            ctypes.c_int32(trit),
        )

    def set_node_color(self, node_id: int, fg: int, bg: int):
        self.lib.propagator_set_node_color(self.handle, node_id, fg, bg)

    def set_focus(self, node_id: int):
        self.lib.propagator_set_focus(self.handle, node_id)

    def get_spatial_colors(self) -> List[Tuple[int, int, int]]:
        """Returns list of (node_id, fg_argb, bg_argb) tuples."""
        buf = ctypes.create_string_buffer(1024)
        written = self.lib.propagator_get_spatial_colors(self.handle, buf, 1024)
        result = []
        for offset in range(0, written, 12):
            node_id = struct.unpack_from("<I", buf, offset)[0]
            fg = struct.unpack_from("<I", buf, offset + 4)[0]
            bg = struct.unpack_from("<I", buf, offset + 8)[0]
            result.append((node_id, fg, bg))
        return result

    def __del__(self):
        if hasattr(self, "handle") and self.handle:
            self.lib.propagator_deinit(self.handle)
            self.handle = None


def argb_to_hex(argb: int) -> str:
    """Convert ARGB u32 to #RRGGBB hex string."""
    r = (argb >> 16) & 0xFF
    g = (argb >> 8) & 0xFF
    b = argb & 0xFF
    return f"#{r:02x}{g:02x}{b:02x}"


def demo_synthetic():
    """Demo with synthetic BCI data matching Go SyntheticBCI."""
    from synthetic_bci import generate_synthetic_eeg, generate_state_sequence
    from valence_bridge import process_epoch, EEGEpoch
    import numpy as np

    prop = SpatialPropagator()

    # Simulate 6 Ghostty split panes in a 3x2 grid
    panes = [
        (1, 0, 0, 640, 480),    # top-left
        (2, 640, 0, 640, 480),  # top-center
        (3, 1280, 0, 640, 480), # top-right
        (4, 0, 480, 640, 480),  # bottom-left
        (5, 640, 480, 640, 480),  # bottom-center
        (6, 1280, 480, 640, 480), # bottom-right
    ]
    for wid, x, y, w, h in panes:
        prop.add_node(window_id=wid, x=x, y=y, w=w, h=h, depth=2)

    prop.detect_adjacency()
    prop.set_focus(1)

    # Generate BCI data
    states = generate_state_sequence(total_seconds=30)
    samples = generate_synthetic_eeg(states)

    # Process in epochs of 250 samples (1 second)
    epoch_size = 250
    num_channels = 8
    epoch_id = 0

    print("BCI Entropy → Spatial Color Bridge")
    print("=" * 60)

    for start in range(0, len(samples) - epoch_size * num_channels, epoch_size * num_channels):
        chunk = samples[start:start + epoch_size * num_channels]
        data = np.array(chunk).reshape(epoch_size, num_channels)

        epoch = EEGEpoch(epoch_id=epoch_id, data=data, sample_rate=250)
        color_epoch = process_epoch(epoch)

        # Feed BCI entropy into spatial propagator
        prop.assign_colors_bci(
            phi=color_epoch.phi,
            valence=color_epoch.valence,
            fisher=color_epoch.mean_fisher,
            trit=color_epoch.trit,
        )

        # Read back spatial colors
        colors = prop.get_spatial_colors()

        state = color_epoch.state
        phi = color_epoch.phi
        valence = color_epoch.valence

        print(f"\nEpoch {epoch_id:3d} | {state:12s} | Φ={phi:6.2f} val={valence:6.2f} trit={color_epoch.trit:+d}")
        for node_id, fg, bg in colors:
            print(f"  pane {node_id}: fg={argb_to_hex(fg)} bg={argb_to_hex(bg)}")

        epoch_id += 1
        time.sleep(0.1)  # Simulate real-time

    print(f"\n{'=' * 60}")
    print(f"Processed {epoch_id} epochs across {len(panes)} spatial panes")


def demo_quick():
    """Quick demo without numpy/scipy dependencies."""
    prop = SpatialPropagator()

    # 4 panes in 2x2 grid
    prop.add_node(window_id=1, x=0, y=0, w=100, h=100, depth=2)
    prop.add_node(window_id=2, x=100, y=0, w=100, h=100, depth=2)
    prop.add_node(window_id=3, x=0, y=100, w=100, h=100, depth=2)
    prop.add_node(window_id=4, x=100, y=100, w=100, h=100, depth=2)

    prop.detect_adjacency()
    prop.set_focus(1)

    # Simulate brain states
    brain_states = [
        ("focused",    25.0, -3.0, 1.5,  0),
        ("resting",    33.0, -2.0, 0.8,  0),
        ("meditative", 34.0, -1.5, 0.5,  1),
        ("stressed",   27.0, -5.0, 2.0, -1),
        ("drowsy",     31.0, -4.0, 0.3,  0),
        ("alert",      24.0, -2.5, 1.8,  1),
    ]

    print("BCI Entropy → Spatial Color Bridge (quick demo)")
    print("=" * 60)

    for state, phi, valence, fisher, trit in brain_states:
        prop.assign_colors_bci(phi, valence, fisher, trit)
        colors = prop.get_spatial_colors()

        print(f"\n{state:12s} | Φ={phi:5.1f} val={valence:5.1f} fish={fisher:4.1f} trit={trit:+d}")
        for node_id, fg, bg in colors:
            print(f"  pane {node_id}: fg={argb_to_hex(fg)} bg={argb_to_hex(bg)}")

    print(f"\n{'=' * 60}")


def stream_sse(url: str):
    """Stream BCI color epochs from SSE endpoint and update spatial colors."""
    import urllib.request

    prop = SpatialPropagator()

    # Start with a default 2x2 topology (will be updated by SSE data)
    prop.add_node(window_id=1, x=0, y=0, w=960, h=540, depth=1)
    prop.add_node(window_id=2, x=960, y=0, w=960, h=540, depth=1)
    prop.add_node(window_id=3, x=0, y=540, w=960, h=540, depth=1)
    prop.add_node(window_id=4, x=960, y=540, w=960, h=540, depth=1)
    prop.detect_adjacency()
    prop.set_focus(1)

    print(f"Connecting to SSE: {url}")

    req = urllib.request.Request(url)
    with urllib.request.urlopen(req) as response:
        buffer = ""
        for line in response:
            line = line.decode("utf-8").strip()
            if line.startswith("data:"):
                data_str = line[5:].strip()
                try:
                    data = json.loads(data_str)
                    phi = data.get("phi", 25.0)
                    valence = data.get("valence", -3.0)
                    fisher = data.get("mean_fisher", 1.0)
                    trit = data.get("trit", 0)

                    prop.assign_colors_bci(phi, valence, fisher, trit)
                    colors = prop.get_spatial_colors()

                    state = data.get("state", "?")
                    print(f"\r{state:12s} Φ={phi:5.1f} ", end="")
                    for node_id, fg, _ in colors:
                        print(f"[{node_id}:{argb_to_hex(fg)}]", end=" ")
                    print("", end="", flush=True)

                except (json.JSONDecodeError, KeyError):
                    pass


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--synthetic":
        demo_synthetic()
    elif len(sys.argv) > 1 and sys.argv[1] == "--sse":
        url = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:7070/events"
        stream_sse(url)
    else:
        demo_quick()
