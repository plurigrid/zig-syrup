#!/usr/bin/env python3
"""
ble_bridge.py - Bluetooth LE Bridge for OpenBCI Ganglion

This script acts as a proxy between the host's BLE hardware and a VM/container.
It reads data from the Ganglion board using bleak (on the host) and forwards
the data to the VM via TCP or virtual serial port.

Usage:
    # Host (has BLE hardware access)
    python3 ble_bridge.py --mode server --port 12345
    
    # VM/container (connects to bridge)
    python3 ble_bridge.py --mode client --host <host-ip> --port 12345

Requirements:
    pip install bleak numpy asyncio

Author: OpenBCI Host Tools
"""

import asyncio
import argparse
import json
import logging
import socket
import struct
import sys
import time
from dataclasses import dataclass, asdict
from typing import Optional, Callable, List, Dict, Any
from enum import Enum

# Optional BLE support
try:
    from bleak import BleakClient, BleakScanner
    from bleak.backends.characteristic import BleakGATTCharacteristic
    BLE_AVAILABLE = True
except ImportError:
    BLE_AVAILABLE = False
    logging.warning("bleak not installed. BLE functionality disabled.")

# Optional numpy for signal processing
try:
    import numpy as np
    NUMPY_AVAILABLE = True
except ImportError:
    NUMPY_AVAILABLE = False


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('ble_bridge')


# OpenBCI Ganglion BLE UUIDs
GANGLION_SERVICE_UUID = "fe84"
GANGLION_TX_UUID = "2d30c082-f39f-4ce6-923f-3484ea480596"
GANGLION_RX_UUID = "2d30c083-f39f-4ce6-923f-3484ea480596"

# Ganglion constants
GANGLION_SAMPLING_RATE = 200  # Hz
GANGLION_NUM_CHANNELS = 4
GANGLION_SCALE_FACTOR = 1.2 * (8388607.0 * 1.5 * 51.0) / 24.0  # Convert to microvolts


class SampleType(Enum):
    """Ganglion sample types."""
    STD = 0  # Standard 18-bit compression
    AUX = 1  # AUX data (accelerometer)
    USER = 2  # User-defined


@dataclass
class EEGSample:
    """Represents a single EEG sample from Ganglion."""
    timestamp: float
    channel_data: List[float]  # 4 channels in microvolts
    sample_number: int
    packet_type: str
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'timestamp': self.timestamp,
            'channel_data': self.channel_data,
            'sample_number': self.sample_number,
            'packet_type': self.packet_type
        }
    
    def to_json(self) -> str:
        return json.dumps(self.to_dict())
    
    def to_openbci_format(self) -> str:
        """Format as OpenBCI GUI compatible string."""
        ch_str = ','.join(f'{ch:.2f}' for ch in self.channel_data)
        return f"{self.sample_number},{ch_str},{self.timestamp}"


class GanglionParser:
    """Parser for Ganglion BLE data packets."""
    
    def __init__(self):
        self.sample_counter = 0
        self.last_timestamp = 0.0
        
    def parse_standard_packet(self, data: bytes) -> Optional[EEGSample]:
        """
        Parse standard 20-byte Ganglion packet.
        
        Packet format:
        - Byte 0: Sample counter (0-255)
        - Bytes 1-18: 4 channels × 18-bit compressed data
        - Byte 19: Stop byte (0xCX where X is packet type)
        """
        if len(data) < 20:
            logger.warning(f"Packet too short: {len(data)} bytes")
            return None
        
        sample_num = data[0]
        stop_byte = data[19]
        
        # Parse 18-bit compressed data
        # Each channel is 18 bits, packed into bytes
        channels = []
        
        try:
            # Unpack 18-bit values (this is a simplified version)
            # Real implementation would use proper bit manipulation
            for i in range(4):
                start_bit = 8 + i * 18
                start_byte = start_bit // 8
                end_byte = (start_bit + 17) // 8
                
                if end_byte >= 19:
                    break
                
                # Extract 18-bit value
                raw = int.from_bytes(data[start_byte:end_byte+1], 'big')
                shift = 16 - (start_bit % 8)
                value = (raw >> shift) & 0x3FFFF
                
                # Sign extend if negative (18-bit two's complement)
                if value & 0x20000:
                    value -= 0x40000
                
                # Convert to microvolts
                voltage = value * GANGLION_SCALE_FACTOR
                channels.append(voltage)
            
            # Ensure we have 4 channels
            while len(channels) < 4:
                channels.append(0.0)
            
            self.sample_counter += 1
            timestamp = time.time()
            self.last_timestamp = timestamp
            
            # Determine packet type from stop byte
            packet_type = "standard"
            if (stop_byte & 0xF0) == 0xC0:
                packet_type = f"type_{stop_byte & 0x0F}"
            
            return EEGSample(
                timestamp=timestamp,
                channel_data=channels[:4],
                sample_number=sample_num,
                packet_type=packet_type
            )
            
        except Exception as e:
            logger.error(f"Error parsing packet: {e}")
            return None
    
    def parse_impedance_packet(self, data: bytes) -> Optional[Dict[str, Any]]:
        """Parse impedance measurement packet."""
        if len(data) < 2:
            return None
        
        # Impedance data format
        channel = data[0]
        impedance = int.from_bytes(data[1:3], 'big') if len(data) >= 3 else 0
        
        return {
            'type': 'impedance',
            'channel': channel,
            'impedance_ohms': impedance,
            'timestamp': time.time()
        }


class GanglionBLEInterface:
    """Interface to Ganglion board via BLE."""
    
    def __init__(self, device_address: Optional[str] = None):
        self.device_address = device_address
        self.client: Optional[BleakClient] = None
        self.parser = GanglionParser()
        self.sample_callbacks: List[Callable[[EEGSample], None]] = []
        self.connected = False
        self.streaming = False
        
    def on_sample(self, callback: Callable[[EEGSample], None]):
        """Register a callback for new samples."""
        self.sample_callbacks.append(callback)
        
    async def scan(self, timeout: float = 10.0) -> List[Dict[str, Any]]:
        """Scan for Ganglion devices."""
        if not BLE_AVAILABLE:
            logger.error("BLE not available. Install bleak: pip install bleak")
            return []
        
        logger.info(f"Scanning for Ganglion devices ({timeout}s)...")
        devices = await BleakScanner.discover(timeout=timeout)
        
        ganglion_devices = []
        for device in devices:
            name = device.name or "Unknown"
            # Ganglion devices typically start with "Ganglion-"
            if "ganglion" in name.lower():
                ganglion_devices.append({
                    'name': name,
                    'address': device.address,
                    'rssi': device.rssi
                })
        
        return ganglion_devices
    
    async def connect(self, address: Optional[str] = None) -> bool:
        """Connect to Ganglion device."""
        if not BLE_AVAILABLE:
            logger.error("BLE not available")
            return False
        
        target = address or self.device_address
        if not target:
            # Try to auto-discover
            devices = await self.scan(timeout=5.0)
            if not devices:
                logger.error("No Ganglion devices found")
                return False
            target = devices[0]['address']
            logger.info(f"Auto-selected: {devices[0]['name']}")
        
        logger.info(f"Connecting to {target}...")
        
        try:
            self.client = BleakClient(target)
            await self.client.connect()
            
            if self.client.is_connected:
                self.connected = True
                self.device_address = target
                logger.info("Connected successfully")
                
                # Start notification handler
                await self.client.start_notify(
                    GANGLION_TX_UUID,
                    self._notification_handler
                )
                return True
            else:
                logger.error("Connection failed")
                return False
                
        except Exception as e:
            logger.error(f"Connection error: {e}")
            return False
    
    async def disconnect(self):
        """Disconnect from device."""
        if self.client and self.client.is_connected:
            await self.client.disconnect()
        self.connected = False
        self.streaming = False
        logger.info("Disconnected")
    
    def _notification_handler(self, sender: BleakGATTCharacteristic, data: bytearray):
        """Handle incoming BLE notifications."""
        sample = self.parser.parse_standard_packet(bytes(data))
        if sample:
            for callback in self.sample_callbacks:
                try:
                    callback(sample)
                except Exception as e:
                    logger.error(f"Callback error: {e}")
    
    async def start_streaming(self):
        """Start data streaming."""
        if not self.connected:
            logger.error("Not connected")
            return False
        
        # Send start command to RX characteristic
        # 'b' = start streaming with accel
        # 's' = start streaming without accel
        start_cmd = b's'
        
        try:
            await self.client.write_gatt_char(GANGLION_RX_UUID, start_cmd)
            self.streaming = True
            logger.info("Streaming started")
            return True
        except Exception as e:
            logger.error(f"Failed to start streaming: {e}")
            return False
    
    async def stop_streaming(self):
        """Stop data streaming."""
        if not self.connected:
            return
        
        # Send stop command
        stop_cmd = b'h'  # 'h' = halt
        
        try:
            await self.client.write_gatt_char(GANGLION_RX_UUID, stop_cmd)
            self.streaming = False
            logger.info("Streaming stopped")
        except Exception as e:
            logger.error(f"Failed to stop streaming: {e}")
    
    async def query_impedance(self, channel: int):
        """Query impedance for a channel (0-4, 0 = all)."""
        if not self.connected:
            return
        
        # Impedance command format
        cmd = bytes([0x7A, channel])  # 'z' + channel
        
        try:
            await self.client.write_gatt_char(GANGLION_RX_UUID, cmd)
            logger.info(f"Impedance query sent for channel {channel}")
        except Exception as e:
            logger.error(f"Failed to query impedance: {e}")


class TCPServer:
    """TCP server for forwarding samples to VM."""
    
    def __init__(self, host: str = "0.0.0.0", port: int = 12345):
        self.host = host
        self.port = port
        self.clients: List[socket.socket] = []
        self.server: Optional[socket.socket] = None
        self.running = False
        
    def start(self):
        """Start TCP server."""
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((self.host, self.port))
        self.server.listen(5)
        self.running = True
        
        logger.info(f"TCP server listening on {self.host}:{self.port}")
        
        # Accept clients in background thread
        import threading
        self.accept_thread = threading.Thread(target=self._accept_clients)
        self.accept_thread.daemon = True
        self.accept_thread.start()
    
    def _accept_clients(self):
        """Accept incoming client connections."""
        while self.running:
            try:
                self.server.settimeout(1.0)
                client, addr = self.server.accept()
                logger.info(f"Client connected from {addr}")
                self.clients.append(client)
            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    logger.error(f"Accept error: {e}")
    
    def broadcast(self, data: str):
        """Send data to all connected clients."""
        message = (data + '\n').encode('utf-8')
        disconnected = []
        
        for client in self.clients:
            try:
                client.send(message)
            except Exception as e:
                logger.warning(f"Client send error: {e}")
                disconnected.append(client)
        
        # Remove disconnected clients
        for client in disconnected:
            self.clients.remove(client)
            try:
                client.close()
            except:
                pass
    
    def stop(self):
        """Stop TCP server."""
        self.running = False
        
        for client in self.clients:
            try:
                client.close()
            except:
                pass
        
        if self.server:
            self.server.close()
        
        logger.info("TCP server stopped")


class TCPClient:
    """TCP client for receiving samples in VM."""
    
    def __init__(self, host: str, port: int = 12345):
        self.host = host
        self.port = port
        self.socket: Optional[socket.socket] = None
        self.connected = False
        self.sample_callbacks: List[Callable[[EEGSample], None]] = []
        
    def on_sample(self, callback: Callable[[EEGSample], None]):
        """Register callback for received samples."""
        self.sample_callbacks.append(callback)
    
    def connect(self) -> bool:
        """Connect to TCP server."""
        try:
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.connect((self.host, self.port))
            self.connected = True
            logger.info(f"Connected to {self.host}:{self.port}")
            
            # Start receive thread
            import threading
            self.receive_thread = threading.Thread(target=self._receive_loop)
            self.receive_thread.daemon = True
            self.receive_thread.start()
            
            return True
        except Exception as e:
            logger.error(f"Connection failed: {e}")
            return False
    
    def _receive_loop(self):
        """Background receive loop."""
        buffer = ""
        
        while self.connected:
            try:
                data = self.socket.recv(4096).decode('utf-8')
                if not data:
                    logger.info("Server disconnected")
                    self.connected = False
                    break
                
                buffer += data
                
                # Process complete lines
                while '\n' in buffer:
                    line, buffer = buffer.split('\n', 1)
                    self._process_line(line)
                    
            except Exception as e:
                if self.connected:
                    logger.error(f"Receive error: {e}")
                self.connected = False
                break
    
    def _process_line(self, line: str):
        """Process received line."""
        try:
            data = json.loads(line)
            sample = EEGSample(
                timestamp=data['timestamp'],
                channel_data=data['channel_data'],
                sample_number=data['sample_number'],
                packet_type=data['packet_type']
            )
            
            for callback in self.sample_callbacks:
                callback(sample)
                
        except json.JSONDecodeError:
            # Try parsing as CSV format
            parts = line.split(',')
            if len(parts) >= 5:
                try:
                    sample = EEGSample(
                        timestamp=float(parts[-1]),
                        channel_data=[float(p) for p in parts[1:5]],
                        sample_number=int(parts[0]),
                        packet_type="csv"
                    )
                    for callback in self.sample_callbacks:
                        callback(sample)
                except ValueError:
                    pass
        except Exception as e:
            logger.error(f"Error processing line: {e}")
    
    def disconnect(self):
        """Disconnect from server."""
        self.connected = False
        if self.socket:
            self.socket.close()


async def server_mode(args):
    """Run as BLE-to-TCP bridge server."""
    logger.info("Starting BLE Bridge Server mode")
    
    # Start TCP server
    tcp_server = TCPServer(args.host, args.port)
    tcp_server.start()
    
    # Connect to Ganglion
    ganglion = GanglionBLEInterface(args.device)
    
    def on_sample(sample: EEGSample):
        """Forward sample to TCP clients."""
        if args.format == 'json':
            tcp_server.broadcast(sample.to_json())
        elif args.format == 'csv':
            tcp_server.broadcast(sample.to_openbci_format())
        else:
            tcp_server.broadcast(sample.to_json())
        
        # Also log periodically
        if sample.sample_number % GANGLION_SAMPLING_RATE == 0:
            logger.info(f"Sample {sample.sample_number}: "
                       f"{[f'{ch:.1f}' for ch in sample.channel_data]}")
    
    ganglion.on_sample(on_sample)
    
    if not await ganglion.connect():
        logger.error("Failed to connect to Ganglion")
        tcp_server.stop()
        return 1
    
    # Start streaming
    await ganglion.start_streaming()
    
    logger.info("Bridge running. Press Ctrl+C to stop.")
    
    try:
        while True:
            await asyncio.sleep(1)
    except KeyboardInterrupt:
        logger.info("Shutting down...")
    finally:
        await ganglion.stop_streaming()
        await ganglion.disconnect()
        tcp_server.stop()
    
    return 0


def client_mode(args):
    """Run as TCP client (in VM)."""
    logger.info("Starting BLE Bridge Client mode")
    
    client = TCPClient(args.host, args.port)
    
    def on_sample(sample: EEGSample):
        """Process received sample."""
        if args.output:
            # Write to file
            with open(args.output, 'a') as f:
                f.write(sample.to_openbci_format() + '\n')
        
        # Log to console
        if args.verbose:
            print(f"Sample {sample.sample_number}: "
                  f"{[f'{ch:.1f}' for ch in sample.channel_data]}")
    
    client.on_sample(on_sample)
    
    if not client.connect():
        logger.error("Failed to connect to server")
        return 1
    
    logger.info(f"Connected. Receiving data from {args.host}:{args.port}")
    
    try:
        while client.connected:
            time.sleep(0.1)
    except KeyboardInterrupt:
        logger.info("Shutting down...")
    finally:
        client.disconnect()
    
    return 0


def scan_mode(args):
    """Scan for Ganglion devices."""
    if not BLE_AVAILABLE:
        logger.error("BLE not available. Install: pip install bleak")
        return 1
    
    async def do_scan():
        ganglion = GanglionBLEInterface()
        devices = await ganglion.scan(timeout=args.timeout)
        
        if not devices:
            print("No Ganglion devices found.")
            return 1
        
        print(f"\nFound {len(devices)} Ganglion device(s):\n")
        print(f"{'Name':<20} {'Address':<20} {'RSSI':<10}")
        print("-" * 50)
        for dev in devices:
            print(f"{dev['name']:<20} {dev['address']:<20} {dev['rssi']:<10}")
        print()
        return 0
    
    return asyncio.run(do_scan())


def main():
    parser = argparse.ArgumentParser(
        description='BLE Bridge for OpenBCI Ganglion - Proxy BLE data to VM'
    )
    parser.add_argument('--mode', choices=['server', 'client', 'scan'],
                       default='server',
                       help='Operating mode (default: server)')
    parser.add_argument('--host', default='0.0.0.0',
                       help='Host IP (server: bind address, client: server address)')
    parser.add_argument('--port', type=int, default=12345,
                       help='TCP port (default: 12345)')
    parser.add_argument('--device', default=None,
                       help='Ganglion BLE address (auto-detect if not specified)')
    parser.add_argument('--format', choices=['json', 'csv'], default='json',
                       help='Data format for transmission')
    parser.add_argument('--output', default=None,
                       help='Output file (client mode only)')
    parser.add_argument('--timeout', type=float, default=10.0,
                       help='Scan timeout in seconds')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Verbose output')
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    if args.mode == 'server':
        return asyncio.run(server_mode(args))
    elif args.mode == 'client':
        return client_mode(args)
    elif args.mode == 'scan':
        return scan_mode(args)
    
    return 0


if __name__ == '__main__':
    sys.exit(main())
