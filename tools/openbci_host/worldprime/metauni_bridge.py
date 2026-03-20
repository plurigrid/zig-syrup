"""
Metauni Bridge: BCI Color Pipeline → Roblox Virtual University

Bridges the SSE color stream (:7070) to Roblox-compatible HTTP endpoints
for Metauni virtual university integration.

Metauni (metauni.org) runs mathematical seminars in Roblox.
This bridge enables:
1. Real-time BCI color visualization on Roblox surfaces
2. Curriculum detection: classify brain state during lecture segments
3. Multi-device: aggregate multiple BCI streams into shared color field

Architecture:
  [BCI SSE :7070] → [this bridge :7071] → [Roblox HttpService GET]

Roblox HttpService constraints:
- GET/POST only (no WebSocket, no SSE)
- Must respond within 10 seconds
- JSON response body
- No streaming — must poll
- HTTPS required in production (HTTP ok for local dev)

So we buffer the latest N color epochs and serve them as JSON on GET.
"""

import json
import sys
import time
import threading
import hashlib
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Dict, List, Optional
from collections import deque
from dataclasses import dataclass, asdict
import urllib.request


# ═══════════════════════════════════════════════════════════════════════════
# Curriculum Detection
# ═══════════════════════════════════════════════════════════════════════════

# Map brain states to curriculum engagement levels
ENGAGEMENT_MAP = {
    "focused": {"level": "deep", "score": 0.9, "emoji": "🧠"},
    "alert": {"level": "active", "score": 0.8, "emoji": "⚡"},
    "meditative": {"level": "contemplative", "score": 0.7, "emoji": "🧘"},
    "relaxed": {"level": "receptive", "score": 0.6, "emoji": "🌊"},
    "stressed": {"level": "overloaded", "score": 0.3, "emoji": "⚠️"},
    "drowsy": {"level": "disengaged", "score": 0.2, "emoji": "😴"},
    "unknown": {"level": "unknown", "score": 0.5, "emoji": "❓"},
}


@dataclass
class CurriculumState:
    """Aggregate curriculum engagement from BCI stream."""
    engagement_level: str
    engagement_score: float
    dominant_state: str
    state_history: List[str]
    color_hex: str
    phi_mean: float
    valence_mean: float
    n_epochs: int
    last_update: float


def compute_curriculum_state(epochs: List[dict], window: int = 10) -> CurriculumState:
    """
    Compute aggregate curriculum engagement from recent epochs.

    Uses a sliding window of the last N epochs to determine
    the dominant brain state and engagement level.
    """
    recent = list(epochs)[-window:]
    if not recent:
        return CurriculumState(
            engagement_level="unknown",
            engagement_score=0.5,
            dominant_state="unknown",
            state_history=[],
            color_hex="#808080",
            phi_mean=0.0,
            valence_mean=0.0,
            n_epochs=0,
            last_update=time.time(),
        )

    states = [ep.get("brain_state", ep.get("state", "unknown")) for ep in recent]
    phis = [ep.get("phi", 0.0) for ep in recent]
    valences = [ep.get("valence", 0.0) for ep in recent]

    # Dominant state by frequency
    from collections import Counter
    state_counts = Counter(states)
    dominant = state_counts.most_common(1)[0][0]

    engagement = ENGAGEMENT_MAP.get(dominant, ENGAGEMENT_MAP["unknown"])

    # Use latest color
    latest_color = recent[-1].get("color", {})
    color_hex = latest_color.get("hex", "#808080") if isinstance(latest_color, dict) else "#808080"

    return CurriculumState(
        engagement_level=engagement["level"],
        engagement_score=engagement["score"],
        dominant_state=dominant,
        state_history=states,
        color_hex=color_hex,
        phi_mean=sum(phis) / len(phis) if phis else 0.0,
        valence_mean=sum(valences) / len(valences) if valences else 0.0,
        n_epochs=len(recent),
        last_update=time.time(),
    )


# ═══════════════════════════════════════════════════════════════════════════
# Multi-Device Aggregation
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class DeviceStream:
    """Track a single BCI device's stream."""
    device_id: str
    epochs: deque  # ring buffer of recent epochs
    last_seen: float
    curriculum: Optional[CurriculumState] = None


class MultiDeviceAggregator:
    """Aggregate multiple BCI device streams into a shared color field."""

    def __init__(self, max_epochs_per_device: int = 50, stale_timeout: float = 30.0):
        self.devices: Dict[str, DeviceStream] = {}
        self.max_epochs = max_epochs_per_device
        self.stale_timeout = stale_timeout
        self.lock = threading.Lock()

    def update(self, device_id: str, epoch: dict):
        """Add an epoch from a device."""
        with self.lock:
            if device_id not in self.devices:
                self.devices[device_id] = DeviceStream(
                    device_id=device_id,
                    epochs=deque(maxlen=self.max_epochs),
                    last_seen=time.time(),
                )
            dev = self.devices[device_id]
            dev.epochs.append(epoch)
            dev.last_seen = time.time()
            dev.curriculum = compute_curriculum_state(list(dev.epochs))

    def get_aggregate(self) -> dict:
        """Get aggregated state across all active devices."""
        with self.lock:
            now = time.time()
            active = {
                did: dev for did, dev in self.devices.items()
                if now - dev.last_seen < self.stale_timeout
            }

            if not active:
                return {
                    "n_devices": 0,
                    "devices": {},
                    "aggregate_engagement": "none",
                    "aggregate_color": "#808080",
                }

            # Aggregate engagement scores
            scores = []
            colors_r, colors_g, colors_b = [], [], []
            device_states = {}

            for did, dev in active.items():
                if dev.curriculum:
                    scores.append(dev.curriculum.engagement_score)

                    # Parse color hex for averaging
                    hex_color = dev.curriculum.color_hex.lstrip("#")
                    if len(hex_color) == 6:
                        colors_r.append(int(hex_color[0:2], 16))
                        colors_g.append(int(hex_color[2:4], 16))
                        colors_b.append(int(hex_color[4:6], 16))

                    device_states[did] = {
                        "engagement": dev.curriculum.engagement_level,
                        "score": dev.curriculum.engagement_score,
                        "state": dev.curriculum.dominant_state,
                        "color": dev.curriculum.color_hex,
                        "phi": dev.curriculum.phi_mean,
                        "valence": dev.curriculum.valence_mean,
                        "n_epochs": dev.curriculum.n_epochs,
                    }

            # Mean engagement
            mean_score = sum(scores) / len(scores) if scores else 0.5

            # Mean color
            if colors_r:
                avg_r = int(sum(colors_r) / len(colors_r))
                avg_g = int(sum(colors_g) / len(colors_g))
                avg_b = int(sum(colors_b) / len(colors_b))
                aggregate_color = f"#{avg_r:02x}{avg_g:02x}{avg_b:02x}"
            else:
                aggregate_color = "#808080"

            # Map mean score to engagement level
            if mean_score >= 0.8:
                agg_level = "deep"
            elif mean_score >= 0.6:
                agg_level = "active"
            elif mean_score >= 0.4:
                agg_level = "receptive"
            else:
                agg_level = "disengaged"

            return {
                "n_devices": len(active),
                "devices": device_states,
                "aggregate_engagement": agg_level,
                "aggregate_score": round(mean_score, 3),
                "aggregate_color": aggregate_color,
                "timestamp": int(now * 1000),
            }


# ═══════════════════════════════════════════════════════════════════════════
# SSE Consumer: Poll the Python color bridge
# ═══════════════════════════════════════════════════════════════════════════

def consume_sse(
    sse_url: str,
    aggregator: MultiDeviceAggregator,
    device_id: str = "local",
):
    """
    Consume SSE events from the color bridge and feed into aggregator.
    Runs in a background thread.
    """
    import urllib.request

    while True:
        try:
            req = urllib.request.Request(sse_url)
            with urllib.request.urlopen(req, timeout=30) as resp:
                buffer = ""
                while True:
                    chunk = resp.read(1).decode("utf-8", errors="replace")
                    if not chunk:
                        break
                    buffer += chunk
                    if buffer.endswith("\n\n"):
                        # Parse SSE event
                        for line in buffer.strip().split("\n"):
                            if line.startswith("data: "):
                                try:
                                    data = json.loads(line[6:])
                                    aggregator.update(device_id, data)
                                except json.JSONDecodeError:
                                    pass
                        buffer = ""
        except Exception as e:
            print(f"  [sse-consumer] reconnecting ({e})")
            time.sleep(2)


# ═══════════════════════════════════════════════════════════════════════════
# HTTP Server for Roblox HttpService
# ═══════════════════════════════════════════════════════════════════════════

class RobloxHandler(BaseHTTPRequestHandler):
    """
    HTTP handler compatible with Roblox HttpService:GetAsync().

    Endpoints:
      GET /color          Latest color epoch (single device)
      GET /curriculum      Curriculum engagement state
      GET /devices         Multi-device aggregate
      GET /health          Health check
    """

    aggregator: MultiDeviceAggregator = None

    def do_GET(self):
        if self.path == "/color":
            self._serve_latest_color()
        elif self.path == "/curriculum":
            self._serve_curriculum()
        elif self.path == "/devices":
            self._serve_devices()
        elif self.path == "/health":
            self._serve_json({"status": "ok", "type": "metauni-bci-bridge"})
        else:
            self.send_response(404)
            self.end_headers()

    def _serve_latest_color(self):
        """Serve latest color epoch from primary device."""
        agg = self.aggregator
        if not agg:
            self._serve_json({"error": "no aggregator"})
            return

        with agg.lock:
            for dev in agg.devices.values():
                if dev.epochs:
                    epoch = dev.epochs[-1]
                    # Simplify for Roblox (flat structure, no nested objects)
                    color = epoch.get("color", {})
                    self._serve_json({
                        "color_hex": color.get("hex", "#808080") if isinstance(color, dict) else "#808080",
                        "color_rgb": color.get("rgb", [128, 128, 128]) if isinstance(color, dict) else [128, 128, 128],
                        "state": epoch.get("brain_state", epoch.get("state", "unknown")),
                        "phi": round(epoch.get("phi", 0.0), 2),
                        "valence": round(epoch.get("valence", 0.0), 2),
                        "trit": epoch.get("trit_sum", epoch.get("trit", 0)),
                        "epoch": epoch.get("epoch", 0),
                        "timestamp": epoch.get("timestamp", 0),
                    })
                    return

        self._serve_json({"error": "no data", "color_hex": "#808080"})

    def _serve_curriculum(self):
        """Serve curriculum engagement state."""
        agg = self.aggregator
        if not agg:
            self._serve_json({"error": "no aggregator"})
            return

        with agg.lock:
            for dev in agg.devices.values():
                if dev.curriculum:
                    self._serve_json({
                        "engagement_level": dev.curriculum.engagement_level,
                        "engagement_score": dev.curriculum.engagement_score,
                        "dominant_state": dev.curriculum.dominant_state,
                        "color_hex": dev.curriculum.color_hex,
                        "phi_mean": round(dev.curriculum.phi_mean, 2),
                        "valence_mean": round(dev.curriculum.valence_mean, 2),
                        "n_epochs": dev.curriculum.n_epochs,
                        "state_history": dev.curriculum.state_history[-5:],
                    })
                    return

        self._serve_json({"engagement_level": "unknown", "color_hex": "#808080"})

    def _serve_devices(self):
        """Serve multi-device aggregate."""
        agg = self.aggregator
        if not agg:
            self._serve_json({"error": "no aggregator"})
            return
        self._serve_json(agg.get_aggregate())

    def _serve_json(self, data: dict):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # suppress logs


# ═══════════════════════════════════════════════════════════════════════════
# Main Bridge
# ═══════════════════════════════════════════════════════════════════════════

def run_bridge(
    sse_url: str = "http://localhost:7070/events",
    bridge_port: int = 7071,
    device_id: str = "local",
):
    """
    Run the Metauni bridge.

    Consumes SSE from the color pipeline and serves HTTP for Roblox.
    """
    aggregator = MultiDeviceAggregator()

    # Start SSE consumer thread
    consumer_thread = threading.Thread(
        target=consume_sse,
        args=(sse_url, aggregator, device_id),
        daemon=True,
    )
    consumer_thread.start()
    print(f"  [sse]    consuming from {sse_url}")

    # Start HTTP server for Roblox
    RobloxHandler.aggregator = aggregator
    server = HTTPServer(("0.0.0.0", bridge_port), RobloxHandler)
    print(f"  [http]   serving on http://0.0.0.0:{bridge_port}")
    print()
    print(f"  Roblox endpoints:")
    print(f"    GET /color       Latest BCI color")
    print(f"    GET /curriculum  Engagement state")
    print(f"    GET /devices     Multi-device aggregate")
    print(f"    GET /health      Health check")
    print()
    print(f"  Roblox Luau usage:")
    print(f"    local HttpService = game:GetService('HttpService')")
    print(f"    local data = HttpService:GetAsync('http://localhost:{bridge_port}/color')")
    print(f"    local color = HttpService:JSONDecode(data)")
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
        print("\n  [done] bridge stopped")


def main():
    if len(sys.argv) < 2:
        print("Usage: python metauni_bridge.py <command> [args...]")
        print()
        print("Commands:")
        print("  serve [--sse URL] [--port PORT] [--device ID]")
        print("    Start the Metauni bridge (SSE consumer + Roblox HTTP server)")
        print()
        print("  test [color.json]")
        print("    Test curriculum detection on pipeline output")
        print()
        print("Architecture:")
        print("  [BCI :7070 SSE] → [this :7071 HTTP] → [Roblox HttpService GET]")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "serve":
        sse_url = "http://localhost:7070/events"
        port = 7071
        device_id = "local"

        for i, arg in enumerate(sys.argv):
            if arg == "--sse" and i + 1 < len(sys.argv):
                sse_url = sys.argv[i + 1]
            elif arg == "--port" and i + 1 < len(sys.argv):
                port = int(sys.argv[i + 1])
            elif arg == "--device" and i + 1 < len(sys.argv):
                device_id = sys.argv[i + 1]

        run_bridge(sse_url=sse_url, bridge_port=port, device_id=device_id)

    elif cmd == "test":
        color_path = sys.argv[2] if len(sys.argv) > 2 else None
        if color_path:
            with open(color_path) as f:
                epochs = json.load(f)
        else:
            # Use synthetic test data
            epochs = [
                {"state": "focused", "phi": 25.0, "valence": -5.5, "confidence": 0.85,
                 "color_hex": "#8a4545", "symmetry_score": 0.8},
                {"state": "focused", "phi": 24.5, "valence": -5.6, "confidence": 0.88,
                 "color_hex": "#8a4555", "symmetry_score": 0.82},
                {"state": "meditative", "phi": 33.0, "valence": -5.9, "confidence": 0.92,
                 "color_hex": "#458a6a", "symmetry_score": 0.95},
                {"state": "meditative", "phi": 34.0, "valence": -5.8, "confidence": 0.95,
                 "color_hex": "#458a7a", "symmetry_score": 0.97},
                {"state": "drowsy", "phi": 24.0, "valence": -6.2, "confidence": 0.7,
                 "color_hex": "#454545", "symmetry_score": 0.6},
            ]

        curriculum = compute_curriculum_state(epochs)
        print(f"  Curriculum state:")
        print(f"    Engagement:  {curriculum.engagement_level} ({curriculum.engagement_score:.2f})")
        print(f"    Dominant:    {curriculum.dominant_state}")
        print(f"    Color:       {curriculum.color_hex}")
        print(f"    Φ mean:      {curriculum.phi_mean:.1f}")
        print(f"    Valence mean: {curriculum.valence_mean:.2f}")
        print(f"    History:     {' → '.join(curriculum.state_history)}")

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
