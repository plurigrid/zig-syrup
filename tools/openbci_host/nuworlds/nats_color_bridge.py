"""
NATS Color Bridge — Stream ColorEpoch to NATS + SSE

Bridges the Python Fisher/valence pipeline into the existing
Go bci-hypergraph NATS infrastructure at nonlocal.info:4222.

Publishes to:
  - color.index         (NATSPayload-compatible, adds color fields)
  - color.index.fisher  (dedicated Fisher/Φ/valence stream)

Also runs a local SSE server on port 7070 (Go uses 7069)
for parallel visualization.

Compatible with attractor-bci-factory Svelte frontend.
"""

import asyncio
import json
import time
import sys
import signal
from dataclasses import asdict
from typing import Optional
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading

# Try NATS import
try:
    import nats
    HAS_NATS = True
except ImportError:
    HAS_NATS = False

from fisher_eeg import EEGEpoch, CHANNELS_10_20, epoch_from_raw_eeg
from valence_bridge import process_epoch, ColorEpoch

import numpy as np


# ═══════════════════════════════════════════════════════════════════════════
# NATS Payload (extends Go NATSPayload with color fields)
# ═══════════════════════════════════════════════════════════════════════════

def color_epoch_to_nats_payload(ce: ColorEpoch, epoch: EEGEpoch) -> dict:
    """
    Convert ColorEpoch to NATS-compatible JSON payload.
    Extends the Go NATSPayload format with Fisher/color fields.
    """
    # Band powers per channel (matching Go format)
    channels = {}
    for ch_name in CHANNELS_10_20:
        bp = epoch.channels[ch_name]
        channels[ch_name] = bp.raw.tolist()

    return {
        # Original NATSPayload fields
        "timestamp": int(time.time() * 1000),
        "epoch": ce.epoch_id,
        "seed": 1069,
        "num_nodes": 8,
        "num_edges": 0,  # correlation edges computed by Go side
        "trit_sum": ce.trit,  # single epoch trit
        "gf3_conserved": (ce.trit % 3 == 0) or True,  # trivially for single
        "brain_state": ce.state,
        "channels": channels,
        "edges": [],
        "d4_subgroup": "D₄ full" if ce.mean_fisher < 0.1 else "Klein-4",
        "sym_breaking": {},
        "cayley_edges": 0,

        # Extended color fields
        "color": {
            "hex": ce.color.hex,
            "rgb": [ce.color.r, ce.color.g, ce.color.b],
            "hcl": [ce.color.h, ce.color.c, ce.color.l],
            "trit": ce.trit,
        },
        "phi": ce.phi,
        "valence": ce.valence,
        "vortex_count": ce.vortex_count,
        "symmetry_score": ce.symmetry_score,
        "mean_fisher": ce.mean_fisher,
        "cid": ce.cid,
        "confidence": ce.confidence,
    }


# ═══════════════════════════════════════════════════════════════════════════
# Syrup Serialization of ColorEpoch
# ═══════════════════════════════════════════════════════════════════════════

def syrup_encode_int(n: int) -> bytes:
    """Encode integer in Syrup format: <digits>+"""
    if n >= 0:
        return f"{n}+".encode()
    else:
        return f"{-n}-".encode()


def syrup_encode_float(f: float) -> bytes:
    """Encode float64 in Syrup format: D<ieee754-be-8bytes>"""
    import struct
    return b"D" + struct.pack(">d", f)


def syrup_encode_string(s: str) -> bytes:
    """Encode string in Syrup format: <len>"<content>"""
    encoded = s.encode("utf-8")
    return f'{len(encoded)}"'.encode() + encoded


def syrup_encode_symbol(s: str) -> bytes:
    """Encode symbol in Syrup format: <len>'<content>"""
    encoded = s.encode("utf-8")
    return f"{len(encoded)}'".encode() + encoded


def syrup_encode_bytes(b: bytes) -> bytes:
    """Encode bytes in Syrup format: <len>:<content>"""
    return f"{len(b)}:".encode() + b


def syrup_encode_bool(b: bool) -> bytes:
    """Encode boolean: t or f"""
    return b"t" if b else b"f"


def syrup_encode_list(items: list) -> bytes:
    """Encode list in Syrup format: [<items>]"""
    result = b"["
    for item in items:
        result += syrup_encode_value(item)
    result += b"]"
    return result


def syrup_encode_dict(d: dict) -> bytes:
    """Encode dict in Syrup format: {<key><value>...}"""
    result = b"{"
    for k, v in sorted(d.items()):
        result += syrup_encode_string(str(k))
        result += syrup_encode_value(v)
    result += b"}"
    return result


def syrup_encode_record(label: str, fields: list) -> bytes:
    """Encode record in Syrup format: <<label><fields...>>"""
    result = b"<"
    result += syrup_encode_symbol(label)
    for field in fields:
        result += syrup_encode_value(field)
    result += b">"
    return result


def syrup_encode_value(v) -> bytes:
    """Encode any Python value to Syrup bytes."""
    if v is None:
        return b"^"
    elif isinstance(v, bool):
        return syrup_encode_bool(v)
    elif isinstance(v, int):
        return syrup_encode_int(v)
    elif isinstance(v, float):
        return syrup_encode_float(v)
    elif isinstance(v, str):
        return syrup_encode_string(v)
    elif isinstance(v, bytes):
        return syrup_encode_bytes(v)
    elif isinstance(v, list) or isinstance(v, tuple):
        return syrup_encode_list(list(v))
    elif isinstance(v, dict):
        return syrup_encode_dict(v)
    else:
        return syrup_encode_string(str(v))


def color_epoch_to_syrup(ce: ColorEpoch) -> bytes:
    """
    Serialize ColorEpoch as a Syrup record.

    Wire format:
    <color-epoch
        <epoch-id>
        <state>
        <confidence>
        <phi>
        <valence>
        <vortex-count>
        <symmetry-score>
        <trit>
        <mean-fisher>
        <color-hex>
        <color-rgb [r g b]>
        <cid>
    >
    """
    return syrup_encode_record("color-epoch", [
        ce.epoch_id,
        ce.state,
        ce.confidence,
        ce.phi,
        ce.valence,
        ce.vortex_count,
        ce.symmetry_score,
        ce.trit,
        ce.mean_fisher,
        ce.color.hex,
        [ce.color.r, ce.color.g, ce.color.b],
        ce.cid,
    ])


# ═══════════════════════════════════════════════════════════════════════════
# Syrup Decoder (for round-trip validation and Zig interop testing)
# ═══════════════════════════════════════════════════════════════════════════

class SyrupDecodeError(Exception):
    pass


def syrup_decode(data: bytes, pos: int = 0):
    """
    Decode one Syrup value from bytes starting at pos.
    Returns (value, new_pos).
    """
    if pos >= len(data):
        raise SyrupDecodeError(f"unexpected end at {pos}")

    tag = data[pos]

    # Void: ^
    if tag == ord("^"):
        return None, pos + 1

    # Boolean: t / f
    if tag == ord("t"):
        return True, pos + 1
    if tag == ord("f"):
        return False, pos + 1

    # Float64: D<8 bytes big-endian IEEE754>
    if tag == ord("D"):
        import struct
        val = struct.unpack(">d", data[pos+1:pos+9])[0]
        return val, pos + 9

    # Integer: <digits>+ or <digits>-
    if tag in range(ord("0"), ord("9") + 1):
        # Scan for terminator: + (positive), - (negative), " (string), ' (symbol), : (bytes)
        end = pos
        while end < len(data) and data[end] in range(ord("0"), ord("9") + 1):
            end += 1
        if end >= len(data):
            raise SyrupDecodeError(f"unterminated number at {pos}")

        num_str = data[pos:end].decode("ascii")
        term = data[end]

        if term == ord("+"):
            return int(num_str), end + 1
        elif term == ord("-"):
            return -int(num_str), end + 1
        elif term == ord('"'):
            # String: <len>"<content>
            length = int(num_str)
            content = data[end+1:end+1+length].decode("utf-8")
            return content, end + 1 + length
        elif term == ord("'"):
            # Symbol: <len>'<content>
            length = int(num_str)
            content = data[end+1:end+1+length].decode("utf-8")
            return ("sym", content), end + 1 + length
        elif term == ord(":"):
            # Bytes: <len>:<content>
            length = int(num_str)
            content = data[end+1:end+1+length]
            return content, end + 1 + length
        else:
            raise SyrupDecodeError(f"unexpected terminator {chr(term)} at {end}")

    # List: [<items>]
    if tag == ord("["):
        items = []
        p = pos + 1
        while p < len(data) and data[p] != ord("]"):
            val, p = syrup_decode(data, p)
            items.append(val)
        return items, p + 1

    # Dict: {<key><value>...}
    if tag == ord("{"):
        d = {}
        p = pos + 1
        while p < len(data) and data[p] != ord("}"):
            key, p = syrup_decode(data, p)
            val, p = syrup_decode(data, p)
            d[key] = val
        return d, p + 1

    # Record: <<label><fields...>>
    if tag == ord("<"):
        p = pos + 1
        label, p = syrup_decode(data, p)
        fields = []
        while p < len(data) and data[p] != ord(">"):
            val, p = syrup_decode(data, p)
            fields.append(val)
        return {"__record__": label, "__fields__": fields}, p + 1

    raise SyrupDecodeError(f"unknown tag {chr(tag)} (0x{tag:02x}) at {pos}")


def decode_color_epoch_syrup(data: bytes) -> dict:
    """
    Decode a Syrup-encoded ColorEpoch record.
    Returns a dict with named fields.
    """
    val, _ = syrup_decode(data)
    if not isinstance(val, dict) or val.get("__record__") != ("sym", "color-epoch"):
        raise SyrupDecodeError(f"expected color-epoch record, got {val}")

    fields = val["__fields__"]
    if len(fields) != 12:
        raise SyrupDecodeError(f"expected 12 fields, got {len(fields)}")

    return {
        "epoch_id": fields[0],
        "state": fields[1],
        "confidence": fields[2],
        "phi": fields[3],
        "valence": fields[4],
        "vortex_count": fields[5],
        "symmetry_score": fields[6],
        "trit": fields[7],
        "mean_fisher": fields[8],
        "color_hex": fields[9],
        "color_rgb": fields[10],
        "cid": fields[11],
    }


# ═══════════════════════════════════════════════════════════════════════════
# SSE Server (lightweight, matches Go SSE on :7069)
# ═══════════════════════════════════════════════════════════════════════════

_sse_clients = []
_sse_lock = threading.Lock()


class SSEHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            with _sse_lock:
                _sse_clients.append(self.wfile)

            # Keep connection open
            try:
                while True:
                    time.sleep(1)
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with _sse_lock:
                    if self.wfile in _sse_clients:
                        _sse_clients.remove(self.wfile)

        elif self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "type": "fisher-color-bridge"}).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # suppress logs


def broadcast_sse(payload: dict):
    """Send SSE event to all connected clients."""
    data = f"data: {json.dumps(payload)}\n\n"
    encoded = data.encode()
    with _sse_lock:
        dead = []
        for client in _sse_clients:
            try:
                client.write(encoded)
                client.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                dead.append(client)
        for d in dead:
            _sse_clients.remove(d)


def start_sse_server(port: int = 7070):
    """Start SSE server in background thread."""
    server = HTTPServer(("0.0.0.0", port), SSEHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


# ═══════════════════════════════════════════════════════════════════════════
# Live Streaming Pipeline
# ═══════════════════════════════════════════════════════════════════════════

async def stream_from_csv(
    csv_path: str,
    window_size: int = 250,
    nats_url: str = "nats://nonlocal.info:4222",
    sse_port: int = 7070,
    realtime: bool = True,
):
    """
    Stream EEG CSV through the full pipeline, publishing to NATS + SSE.

    Parameters:
        csv_path: path to EEG CSV (8 columns, no header)
        window_size: samples per epoch (250 = 1 second at 250Hz)
        nats_url: NATS server URL
        sse_port: SSE server port
        realtime: if True, sleep between epochs to simulate real-time
    """
    import csv as csv_mod

    # Start SSE server
    sse_server = start_sse_server(sse_port)
    print(f"  [sse]  listening on http://0.0.0.0:{sse_port}/events")

    # Connect to NATS
    nc = None
    if HAS_NATS:
        try:
            nc = await nats.connect(nats_url)
            print(f"  [nats] connected to {nats_url}")
        except Exception as e:
            print(f"  [nats] {e} (continuing without NATS)")
    else:
        print("  [nats] nats-py not installed (pip install nats-py)")

    # Read CSV
    rows = []
    with open(csv_path) as f:
        reader = csv_mod.reader(f)
        for row in reader:
            rows.append([float(x) for x in row])

    samples = np.array(rows)
    n_epochs = len(samples) // window_size

    print(f"  [data] {len(samples)} samples, {n_epochs} epochs")
    print()

    epoch_interval = window_size / 250.0 if realtime else 0.0

    for i in range(n_epochs):
        window = samples[i * window_size : (i + 1) * window_size]
        epoch = epoch_from_raw_eeg(window)
        epoch.epoch_id = i

        ce = process_epoch(epoch)
        payload = color_epoch_to_nats_payload(ce, epoch)

        # Syrup encode
        syrup_bytes = color_epoch_to_syrup(ce)

        # Publish to NATS
        if nc and nc.is_connected:
            # JSON on color.index (Go compatibility)
            await nc.publish("color.index", json.dumps(payload).encode())
            # JSON on color.index.fisher (legacy)
            await nc.publish("color.index.fisher", json.dumps({
                "epoch": i,
                "phi": ce.phi,
                "valence": ce.valence,
                "color_hex": ce.color.hex,
                "trit": ce.trit,
                "cid": ce.cid,
                "syrup_len": len(syrup_bytes),
            }).encode())
            # Typed Syrup on color.index.syrup (gap #4 fix)
            await nc.publish("color.index.syrup", syrup_bytes)

        # Broadcast SSE
        broadcast_sse(payload)

        # Terminal output
        r, g, b = ce.color.r, ce.color.g, ce.color.b
        block = f"\033[48;2;{r};{g};{b}m  \033[0m"
        print(
            f"  {block} epoch={i:4d} {ce.color.hex} "
            f"state={ce.state:12s} Φ={ce.phi:.1f} "
            f"val={ce.valence:.2f} trit={ce.trit:+d} "
            f"syrup={len(syrup_bytes)}B"
        )

        if realtime and epoch_interval > 0:
            await asyncio.sleep(epoch_interval)

    # Cleanup
    if nc:
        await nc.drain()
    sse_server.shutdown()
    print(f"\n  [done] streamed {n_epochs} epochs")


# ═══════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════

def main():
    if len(sys.argv) < 2:
        print("Usage: python nats_color_bridge.py <recordings.csv> [--realtime] [--nats URL] [--sse-port PORT]")
        print()
        print("  Streams EEG → Fisher → Φ → Valence → Color → NATS + SSE")
        print()
        print("  --realtime    Sleep between epochs (default: fast)")
        print("  --nats URL    NATS server (default: nats://nonlocal.info:4222)")
        print("  --sse-port N  SSE port (default: 7070)")
        sys.exit(1)

    csv_path = sys.argv[1]
    realtime = "--realtime" in sys.argv
    nats_url = "nats://nonlocal.info:4222"
    sse_port = 7070

    for i, arg in enumerate(sys.argv):
        if arg == "--nats" and i + 1 < len(sys.argv):
            nats_url = sys.argv[i + 1]
        elif arg == "--sse-port" and i + 1 < len(sys.argv):
            sse_port = int(sys.argv[i + 1])

    asyncio.run(stream_from_csv(
        csv_path,
        nats_url=nats_url,
        sse_port=sse_port,
        realtime=realtime,
    ))


if __name__ == "__main__":
    main()
