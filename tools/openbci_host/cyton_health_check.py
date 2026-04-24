#!/usr/bin/env python3
"""
Low-level OpenBCI Cyton health check for reverse-engineering prep.

This script talks directly to the Cyton USB dongle over serial so you can:
- detect the most likely Cyton serial port,
- query radio status and channel,
- optionally autoscan channels if the host and board are out of sync,
- capture a short raw packet window, and
- classify per-channel signal quality from packet statistics.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

try:
    import serial
    import serial.tools.list_ports
except ModuleNotFoundError:
    serial = None


SCALE_UV = 4.5 / (24 * ((2**23) - 1)) * 1e6
DEFAULT_BAUD = 115200
DEFAULT_STREAM_SECONDS = 4.0
DEFAULT_STATUS_WAIT = 0.75
DEFAULT_VERSION_WAIT = 2.5
DEFAULT_DAISY_WAIT = 1.0
CYTON_VID_PIDS = {
    (0x0403, 0x6015),  # FT231X
    (0x0403, 0x6001),  # FT232R
}
CYTON_PORT_PATTERNS = (
    "/dev/cu.usbserial",
    "/dev/tty.usbserial",
    "/dev/cu.usbmodem",
    "/dev/tty.usbmodem",
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def parse_24bit(b0: int, b1: int, b2: int) -> int:
    value = (b0 << 16) | (b1 << 8) | b2
    return value - 0x1000000 if value >= 0x800000 else value


def safe_decode(data: bytes) -> str:
    return data.decode("utf-8", errors="ignore").strip()


def normalize_text(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def read_available(
    ser: serial.Serial,
    *,
    initial_sleep: float = 0.0,
    settle_seconds: float = 0.4,
    max_bytes: int = 8192,
) -> bytes:
    if initial_sleep > 0:
        time.sleep(initial_sleep)
    chunks = []  # type: List[bytes]
    deadline = time.time() + settle_seconds
    while time.time() < deadline:
        waiting = ser.in_waiting
        if waiting:
            chunks.append(ser.read(min(waiting, max_bytes)))
            deadline = time.time() + 0.15
        else:
            time.sleep(0.02)
    return b"".join(chunks)


def send_and_read_text(
    ser: serial.Serial,
    payload: bytes,
    *,
    initial_sleep: float,
    settle_seconds: float = 0.4,
) -> str:
    ser.reset_input_buffer()
    ser.write(payload)
    ser.flush()
    return normalize_text(
        safe_decode(
            read_available(
                ser,
                initial_sleep=initial_sleep,
                settle_seconds=settle_seconds,
            )
        )
    )


def parse_channel_number(text: str) -> Optional[int]:
    match = re.search(r"Channel number:\s*(\d+)", text, flags=re.IGNORECASE)
    return int(match.group(1)) if match else None


def status_is_up(text: str) -> bool:
    lowered = text.lower()
    return "system is up" in lowered or "success: system is up" in lowered


def status_is_down(text: str) -> bool:
    lowered = text.lower()
    return "system is down" in lowered or "failure: system is down" in lowered


def daisy_present(version_text: str, daisy_text: str) -> bool:
    haystack = f"{version_text}\n{daisy_text}".lower()
    return "on daisy ads1299 device id" in haystack or "daisy" in haystack


@dataclass
class ChannelSummary:
    channel: int
    sample_count: int
    mean_uv: Optional[float]
    std_uv: Optional[float]
    min_uv: Optional[float]
    max_uv: Optional[float]
    status: str


def classify_channel(values: List[float]) -> ChannelSummary:
    channel = -1
    if not values:
        raise ValueError("classify_channel requires at least one value")
    mean_uv = statistics.fmean(values)
    std_uv = statistics.pstdev(values) if len(values) > 1 else 0.0
    if len(values) < 10:
        status = "NO DATA"
    elif abs(mean_uv) > 187000:
        status = "RAILED"
    elif std_uv < 1:
        status = "FLAT"
    elif std_uv > 200:
        status = "BAD CONTACT"
    elif std_uv > 100:
        status = "NOISY"
    elif std_uv < 50:
        status = "CLEAN"
    else:
        status = "OK"
    return ChannelSummary(
        channel=channel,
        sample_count=len(values),
        mean_uv=round(mean_uv, 3),
        std_uv=round(std_uv, 3),
        min_uv=round(min(values), 3),
        max_uv=round(max(values), 3),
        status=status,
    )


def candidate_ports() -> List[serial.tools.list_ports_common.ListPortInfo]:
    if serial is None:
        return []
    ports = list(serial.tools.list_ports.comports())
    matches = []
    for port in ports:
        vid_pid_match = (
            port.vid is not None
            and port.pid is not None
            and (port.vid, port.pid) in CYTON_VID_PIDS
        )
        name_match = any(port.device.startswith(prefix) for prefix in CYTON_PORT_PATTERNS)
        desc = (port.description or "").lower()
        desc_match = "ftdi" in desc or "uart" in desc or "usb serial" in desc
        if vid_pid_match or (name_match and desc_match):
            matches.append(port)
    return matches


def autodetect_port() -> Optional[str]:
    matches = candidate_ports()
    if not matches:
        return None
    preferred = sorted(matches, key=lambda p: (not p.device.startswith("/dev/cu."), p.device))
    return preferred[0].device


def extract_packets(buffer: bytearray) -> Tuple[List[bytes], int]:
    packets: List[bytes] = []
    skipped = 0
    index = 0
    max_index = len(buffer) - 33
    while index <= max_index:
        start_byte = buffer[index]
        stop_byte = buffer[index + 32]
        if start_byte == 0xA0 and (stop_byte & 0xF0) == 0xC0:
            packets.append(bytes(buffer[index : index + 33]))
            index += 33
        else:
            skipped += 1
            index += 1
    if index:
        del buffer[:index]
    return packets, skipped


def analyze_stream_packets(packets: Iterable[bytes], *, use_daisy: bool) -> Dict[str, object]:
    channels = {index: [] for index in range(1, 17 if use_daisy else 9)}
    packet_count = 0
    framing_skips = 0
    previous_sample = None  # type: Optional[int]
    dropped_packets = 0
    duplicate_packets = 0

    for packet in packets:
        if len(packet) != 33:
            framing_skips += 1
            continue
        packet_count += 1
        sample_number = packet[1]
        if previous_sample is not None:
            delta = (sample_number - previous_sample) % 256
            if delta == 0:
                duplicate_packets += 1
            elif delta > 1:
                dropped_packets += delta - 1
        previous_sample = sample_number

        packet_is_daisy = use_daisy and (sample_number % 2 == 0)
        channel_offset = 8 if packet_is_daisy else 0
        for channel_index in range(8):
            offset = 2 + channel_index * 3
            raw_value = parse_24bit(packet[offset], packet[offset + 1], packet[offset + 2])
            channels[channel_index + channel_offset + 1].append(raw_value * SCALE_UV)

    summaries = []  # type: List[Dict[str, object]]
    for channel_number, values in channels.items():
        if values:
            summary = classify_channel(values)
            summary.channel = channel_number
            summaries.append(asdict(summary))
        else:
            summaries.append(
                asdict(
                    ChannelSummary(
                        channel=channel_number,
                        sample_count=0,
                        mean_uv=None,
                        std_uv=None,
                        min_uv=None,
                        max_uv=None,
                        status="NO DATA",
                    )
                )
            )

    return {
        "packet_count": packet_count,
        "dropped_packets": dropped_packets,
        "duplicate_packets": duplicate_packets,
        "framing_skips": framing_skips,
        "channels": summaries,
    }


def recommendations_from_report(report: Dict[str, object]) -> List[str]:
    recommendations = []  # type: List[str]
    issues = report["overall"]["issues"]
    if report["status"]["system_up"] is False:
        recommendations.append(
            "Run with --autoscan-if-down or use the GUI STATUS, GET CHANNEL, "
            "and AUTOSCAN flow to re-sync the dongle and board."
        )
    if "no_stream_packets" in issues:
        recommendations.append(
            "Verify dongle switch position, battery charge, Cyton power switch "
            "(PC mode), and serial port selection before retrying."
        )
    if "sample_rate_out_of_range" in issues:
        recommendations.append(
            "Inspect USB stability and radio quality. Packet rate drift usually "
            "means link loss, a port mismatch, or a stalled board."
        )
    noisy_channels = [
        channel["channel"]
        for channel in report["stream"].get("channels", [])
        if channel["status"] in {"NOISY", "BAD CONTACT", "RAILED", "FLAT"}
    ]
    if noisy_channels:
        recommendations.append(
            "Re-seat reference and ground first, then re-seat channels "
            + ", ".join(str(channel) for channel in noisy_channels)
            + "."
        )
    if not recommendations:
        recommendations.append(
            "No blocking issues detected. This board looks ready for a deeper "
            "reverse-engineering or acquisition session."
        )
    return recommendations


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run a low-level health check against an OpenBCI Cyton dongle."
    )
    parser.add_argument(
        "--port",
        help="Serial port for the Cyton dongle. Defaults to auto-detection.",
    )
    parser.add_argument(
        "--baud",
        type=int,
        default=DEFAULT_BAUD,
        help=f"Baud rate for the dongle (default: {DEFAULT_BAUD}).",
    )
    parser.add_argument(
        "--autoscan-if-down",
        action="store_true",
        help="Override the dongle across channels 0-25 if STATUS reports down.",
    )
    parser.add_argument(
        "--skip-stream",
        action="store_true",
        help="Skip the binary packet capture phase.",
    )
    parser.add_argument(
        "--stream-seconds",
        type=float,
        default=DEFAULT_STREAM_SECONDS,
        help=f"Duration for the packet-quality check (default: {DEFAULT_STREAM_SECONDS}).",
    )
    parser.add_argument(
        "--json-out",
        help="Write the report JSON to this path.",
    )
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    if serial is None:
        print(
            "pyserial is not installed. Install the host requirements first:",
            file=sys.stderr,
        )
        print("  python3 -m pip install -r requirements-host.txt", file=sys.stderr)
        return 2
    port = args.port or autodetect_port()
    if not port:
        print("No likely Cyton dongle serial port found.", file=sys.stderr)
        print(
            "Pass --port /dev/cu.usbserial-... explicitly after connecting the dongle.",
            file=sys.stderr,
        )
        return 2

    report = {
        "timestamp": utc_now(),
        "port": port,
        "baud": args.baud,
        "autoscanned": False,
        "status": {
            "system_up": None,
            "status_text": "",
            "channel_text": "",
            "host_channel": None,
            "device_channel": None,
            "autoscan_found_channel": None,
        },
        "firmware": {
            "version_text": "",
            "daisy_text": "",
            "daisy_present": False,
        },
        "stream": {},
        "overall": {
            "pass": False,
            "issues": [],
            "recommendations": [],
        },
    }

    try:
        with serial.Serial(port, args.baud, timeout=0.25) as ser:
            time.sleep(2.0)

            status_text = send_and_read_text(
                ser,
                bytes([0xF0, 0x07]),
                initial_sleep=DEFAULT_STATUS_WAIT,
            )
            channel_text = send_and_read_text(
                ser,
                bytes([0xF0, 0x00]),
                initial_sleep=DEFAULT_STATUS_WAIT,
            )

            report["status"]["status_text"] = status_text
            report["status"]["channel_text"] = channel_text
            report["status"]["system_up"] = (
                True if status_is_up(status_text) else False if status_is_down(status_text) else None
            )
            host_channel = parse_channel_number(channel_text)
            report["status"]["host_channel"] = host_channel
            if report["status"]["system_up"]:
                report["status"]["device_channel"] = host_channel

            if report["status"]["system_up"] is False and args.autoscan_if_down:
                for channel in range(26):
                    _ = send_and_read_text(
                        ser,
                        bytes([0xF0, 0x02, channel]),
                        initial_sleep=0.3,
                    )
                    attempt_text = send_and_read_text(
                        ser,
                        bytes([0xF0, 0x07]),
                        initial_sleep=0.5,
                    )
                    if status_is_up(attempt_text):
                        report["autoscanned"] = True
                        report["status"]["status_text"] = attempt_text
                        report["status"]["system_up"] = True
                        report["status"]["autoscan_found_channel"] = channel
                        report["status"]["host_channel"] = channel
                        report["status"]["device_channel"] = channel
                        break

            version_text = send_and_read_text(
                ser,
                b"v",
                initial_sleep=DEFAULT_VERSION_WAIT,
                settle_seconds=0.8,
            )
            daisy_text = send_and_read_text(
                ser,
                b"D",
                initial_sleep=DEFAULT_DAISY_WAIT,
                settle_seconds=0.5,
            )
            report["firmware"]["version_text"] = version_text
            report["firmware"]["daisy_text"] = daisy_text
            report["firmware"]["daisy_present"] = daisy_present(version_text, daisy_text)

            if not args.skip_stream:
                use_daisy = report["firmware"]["daisy_present"]
                ser.reset_input_buffer()
                ser.write(b"b")
                ser.flush()
                time.sleep(0.5)
                ser.reset_input_buffer()

                start_time = time.time()
                buffer = bytearray()
                parsed_packets = []  # type: List[bytes]
                framing_skips = 0

                while time.time() - start_time < args.stream_seconds:
                    waiting = ser.in_waiting
                    if waiting:
                        buffer.extend(ser.read(waiting))
                        packets, skipped = extract_packets(buffer)
                        parsed_packets.extend(packets)
                        framing_skips += skipped
                    else:
                        time.sleep(0.01)

                ser.write(b"s")
                ser.flush()
                time.sleep(0.25)

                stream_report = analyze_stream_packets(parsed_packets, use_daisy=use_daisy)
                elapsed = max(time.time() - start_time, 0.001)
                packet_rate_hz = stream_report["packet_count"] / elapsed
                stream_report.update(
                    {
                        "duration_seconds": round(elapsed, 3),
                        "packet_rate_hz": round(packet_rate_hz, 3),
                        "expected_packet_rate_hz": 250.0,
                        "effective_channel_sample_rate_hz": 125.0 if use_daisy else 250.0,
                        "framing_skips": stream_report["framing_skips"] + framing_skips,
                    }
                )
                report["stream"] = stream_report

    except serial.SerialException as exc:
        report["overall"]["issues"].append("serial_open_failed")
        report["overall"]["recommendations"] = [
            "Verify the dongle is present and not already claimed by the GUI or another process."
        ]
        report["overall"]["error"] = str(exc)
        print(json.dumps(report, indent=2))
        return 1

    if report["status"]["system_up"] is not True:
        report["overall"]["issues"].append("system_down")
    if not report["firmware"]["version_text"]:
        report["overall"]["issues"].append("missing_version_response")
    if report["stream"]:
        packet_count = report["stream"]["packet_count"]
        packet_rate_hz = report["stream"]["packet_rate_hz"]
        if packet_count == 0:
            report["overall"]["issues"].append("no_stream_packets")
        if packet_count > 0 and not (200.0 <= packet_rate_hz <= 300.0):
            report["overall"]["issues"].append("sample_rate_out_of_range")
        if report["stream"]["dropped_packets"] > 0:
            report["overall"]["issues"].append("dropped_packets_detected")
        if any(
            channel["status"] in {"RAILED", "BAD CONTACT", "FLAT"}
            for channel in report["stream"]["channels"]
        ):
            report["overall"]["issues"].append("electrode_quality_issues")

    report["overall"]["pass"] = not report["overall"]["issues"]
    report["overall"]["recommendations"] = recommendations_from_report(report)

    json_payload = json.dumps(report, indent=2)
    print(json_payload)

    if args.json_out:
        output_path = Path(args.json_out)
    else:
        output_path = Path(
            f"cyton-health-check-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
        )
    if not args.json_out:
        output_path = Path.cwd() / output_path
    output_path.write_text(json_payload + "\n", encoding="utf-8")
    print(f"\nSaved report to {output_path}", file=sys.stderr)
    return 0 if report["overall"]["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
