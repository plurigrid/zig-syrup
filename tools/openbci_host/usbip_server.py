#!/usr/bin/env python3
"""
usbip_server.py - USB/IP Server for OpenBCI Device Sharing

This script implements a USB/IP server that allows sharing USB devices
(such as the OpenBCI Cyton dongle) from the host macOS to a VM or
another machine on the network.

USB/IP is a protocol for sharing USB devices over IP networks. This
implementation provides a simplified server for OpenBCI serial devices.

Requirements:
    pip install pyserial pyusb
    # On macOS: brew install libusb

Usage:
    # List available USB devices
    python3 usbip_server.py --list
    
    # Share specific device
    python3 usbip_server.py --device /dev/cu.usbserial-* --port 3240
    
    # Auto-detect OpenBCI device
    python3 usbip_server.py --auto --port 3240

Security Note:
    This server exposes USB devices over the network. Use only on
    trusted networks or with proper firewall rules.

Author: OpenBCI Host Tools
"""

import argparse
import asyncio
import json
import logging
import struct
import sys
import threading
import time
from dataclasses import dataclass
from typing import Optional, Dict, List, Tuple
from enum import IntEnum

# Serial support
try:
    import serial
    import serial.tools.list_ports
    SERIAL_AVAILABLE = True
except ImportError:
    SERIAL_AVAILABLE = False

# USB support
try:
    import usb.core
    import usb.util
    USB_AVAILABLE = True
except ImportError:
    USB_AVAILABLE = False

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('usbip_server')


# USB/IP Protocol Constants
USBIP_VERSION = 0x0111  # USB/IP version 1.1

# Command codes
OP_REQ_DEVLIST = 0x8005
OP_REP_DEVLIST = 0x0005
OP_REQ_IMPORT = 0x8003
OP_REP_IMPORT = 0x0003

# USB device states
USBIP_DEV_ST_AVAILABLE = 0x00
USBIP_DEV_ST_USED = 0x01
USBIP_DEV_ST_ERROR = 0x02

# USB/IP speed codes
USBIP_SPEED_UNKNOWN = 0
USBIP_SPEED_LOW = 1
USBIP_SPEED_FULL = 2
USBIP_SPEED_HIGH = 3
USBIP_SPEED_WIRELESS = 4
USBIP_SPEED_SUPER = 5


@dataclass
class USBDevice:
    """Represents a USB device for USB/IP protocol."""
    path: str
    busnum: int
    devnum: int
    speed: int
    idVendor: int
    idProduct: int
    bcdDevice: int
    bDeviceClass: int
    bDeviceSubClass: int
    bDeviceProtocol: int
    bConfigurationValue: int
    bNumConfigurations: int
    bNumInterfaces: int
    serial: str = ""
    manufacturer: str = ""
    product: str = ""
    
    def to_bytes(self) -> bytes:
        """Serialize device to USB/IP format."""
        # USB/IP device record format
        path_bytes = self.path.encode('utf-8').ljust(256, b'\x00')
        
        data = struct.pack(
            '>256s H H I H H H B B B B B B B',
            path_bytes,
            self.busnum,
            self.devnum,
            self.speed,
            self.idVendor,
            self.idProduct,
            self.bcdDevice,
            self.bDeviceClass,
            self.bDeviceSubClass,
            self.bDeviceProtocol,
            self.bConfigurationValue,
            self.bNumConfigurations,
            self.bNumInterfaces
        )
        return data


class USBIPDeviceManager:
    """Manages local USB devices for sharing."""
    
    # OpenBCI device USB IDs
    OPENBCI_DEVICES = {
        # FT232R USB UART (Cyton dongle)
        (0x0403, 0x6001): "OpenBCI Cyton (FT232R)",
        # FT231X USB UART
        (0x0403, 0x6015): "OpenBCI USB Dongle (FT231X)",
        # Generic FTDI
        (0x0403, None): "FTDI Device (Generic)",
    }
    
    def __init__(self):
        self.devices: Dict[str, USBDevice] = {}
        self.serial_connections: Dict[str, serial.Serial] = {}
        
    def scan_devices(self) -> List[USBDevice]:
        """Scan for available USB serial devices."""
        devices = []
        
        if not SERIAL_AVAILABLE:
            logger.error("pyserial not installed. Install: pip install pyserial")
            return devices
        
        # Scan serial ports
        ports = serial.tools.list_ports.comports()
        
        for i, port in enumerate(ports):
            # Check if it's an OpenBCI-related device
            device_info = self._identify_device(port)
            
            if device_info:
                logger.debug(f"Found: {device_info} at {port.device}")
                
                device = USBDevice(
                    path=port.device,
                    busnum=0,  # Not used for serial devices
                    devnum=i + 1,
                    speed=USBIP_SPEED_FULL,
                    idVendor=port.vid or 0,
                    idProduct=port.pid or 0,
                    bcdDevice=0x0100,
                    bDeviceClass=0xFF,  # Vendor specific
                    bDeviceSubClass=0x00,
                    bDeviceProtocol=0x00,
                    bConfigurationValue=1,
                    bNumConfigurations=1,
                    bNumInterfaces=1,
                    serial=port.serial_number or "",
                    manufacturer=port.manufacturer or "",
                    product=port.product or device_info
                )
                
                devices.append(device)
                self.devices[port.device] = device
        
        return devices
    
    def _identify_device(self, port) -> Optional[str]:
        """Identify device type from port info."""
        vid_pid = (port.vid, port.pid)
        vid_any = (port.vid, None)
        
        # Check exact match
        if vid_pid in self.OPENBCI_DEVICES:
            return self.OPENBCI_DEVICES[vid_pid]
        
        # Check VID-only match
        if vid_any in self.OPENBCI_DEVICES:
            return self.OPENBCI_DEVICES[vid_any]
        
        # Check description for FTDI/serial indicators
        desc = (port.description or "").lower()
        if "ftdi" in desc or "ft232" in desc or "usb serial" in desc:
            return f"Serial Device: {port.description}"
        
        return None
    
    def get_device(self, path: str) -> Optional[USBDevice]:
        """Get device by path."""
        return self.devices.get(path)
    
    def open_serial(self, path: str, baudrate: int = 115200) -> bool:
        """Open serial connection to device."""
        if not SERIAL_AVAILABLE:
            return False
        
        try:
            ser = serial.Serial(
                port=path,
                baudrate=baudrate,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.1
            )
            self.serial_connections[path] = ser
            logger.info(f"Opened serial connection: {path} @ {baudrate}")
            return True
        except Exception as e:
            logger.error(f"Failed to open {path}: {e}")
            return False
    
    def close_serial(self, path: str):
        """Close serial connection."""
        if path in self.serial_connections:
            try:
                self.serial_connections[path].close()
            except:
                pass
            del self.serial_connections[path]
            logger.info(f"Closed serial connection: {path}")
    
    def read_data(self, path: str, size: int = 1024) -> bytes:
        """Read data from serial device."""
        if path not in self.serial_connections:
            return b''
        
        try:
            return self.serial_connections[path].read(size)
        except Exception as e:
            logger.error(f"Read error: {e}")
            return b''
    
    def write_data(self, path: str, data: bytes) -> int:
        """Write data to serial device."""
        if path not in self.serial_connections:
            return 0
        
        try:
            return self.serial_connections[path].write(data)
        except Exception as e:
            logger.error(f"Write error: {e}")
            return 0


class USBIPServer:
    """
    Simplified USB/IP server for OpenBCI devices.
    
    Note: This is a partial implementation focused on serial device sharing.
    Full USB/IP would require kernel-level USB device capture.
    """
    
    def __init__(self, host: str = "0.0.0.0", port: int = 3240):
        self.host = host
        self.port = port
        self.device_manager = USBIPDeviceManager()
        self.server = None
        self.running = False
        self.clients: Dict[asyncio.Transport, 'USBIPClientHandler'] = {}
        
    async def start(self):
        """Start the USB/IP server."""
        self.running = True
        
        # Scan devices
        devices = self.device_manager.scan_devices()
        logger.info(f"Found {len(devices)} device(s)")
        for dev in devices:
            logger.info(f"  - {dev.product} @ {dev.path}")
        
        # Start server
        loop = asyncio.get_event_loop()
        self.server = await loop.create_server(
            lambda: USBIPProtocol(self.device_manager, self),
            self.host, self.port
        )
        
        logger.info(f"USB/IP server listening on {self.host}:{self.port}")
        
        async with self.server:
            await self.server.serve_forever()
    
    def stop(self):
        """Stop the server."""
        self.running = False
        if self.server:
            self.server.close()


class USBIPProtocol(asyncio.Protocol):
    """USB/IP protocol handler."""
    
    def __init__(self, device_manager: USBIPDeviceManager, server: USBIPServer):
        self.device_manager = device_manager
        self.server = server
        self.transport: Optional[asyncio.Transport] = None
        self.buffer = b''
        self.imported_device: Optional[str] = None
        self.device_path: Optional[str] = None
        
    def connection_made(self, transport: asyncio.Transport):
        self.transport = transport
        peer = transport.get_extra_info('peername')
        logger.info(f"Client connected: {peer}")
        self.server.clients[transport] = self
        
    def connection_lost(self, exc: Optional[Exception]):
        logger.info("Client disconnected")
        if self.transport in self.server.clients:
            del self.server.clients[self.transport]
        
        # Close imported device
        if self.device_path:
            self.device_manager.close_serial(self.device_path)
    
    def data_received(self, data: bytes):
        self.buffer += data
        
        # Process USB/IP commands
        while len(self.buffer) >= 8:
            # Check for command header
            version, command, status = struct.unpack('>HHI', self.buffer[:8])
            
            if version != USBIP_VERSION:
                logger.error(f"Unsupported USB/IP version: {version}")
                self.transport.close()
                return
            
            if command == OP_REQ_DEVLIST:
                self._handle_devlist_request()
                self.buffer = self.buffer[8:]
                
            elif command == OP_REQ_IMPORT:
                if len(self.buffer) >= 264:  # Header + 256-byte busid
                    self._handle_import_request()
                    self.buffer = self.buffer[264:]
                else:
                    break
            else:
                # Pass through to device or ignore
                if self.imported_device:
                    self._forward_to_device(data)
                self.buffer = b''
                break
    
    def _handle_devlist_request(self):
        """Handle device list request."""
        devices = self.device_manager.scan_devices()
        
        # Build response
        # Header: version, reply code, status, number of devices
        header = struct.pack('>HHI', USBIP_VERSION, OP_REP_DEVLIST, 0)
        header += struct.pack('>I', len(devices))
        
        # Device list
        device_data = b''
        for dev in devices:
            device_data += dev.to_bytes()
        
        self.transport.write(header + device_data)
        logger.debug(f"Sent device list: {len(devices)} devices")
    
    def _handle_import_request(self):
        """Handle device import request."""
        # Extract busid (device path)
        busid = self.buffer[8:264].rstrip(b'\x00').decode('utf-8')
        logger.info(f"Import request for: {busid}")
        
        device = self.device_manager.get_device(busid)
        
        if device:
            # Success response
            header = struct.pack('>HHI', USBIP_VERSION, OP_REP_IMPORT, 0)
            self.transport.write(header + device.to_bytes())
            
            self.imported_device = busid
            self.device_path = busid
            
            # Open serial connection
            self.device_manager.open_serial(busid)
            
            # Start data forwarding
            asyncio.create_task(self._device_reader())
            
            logger.info(f"Device imported: {busid}")
        else:
            # Error response
            header = struct.pack('>HHI', USBIP_VERSION, OP_REP_IMPORT, 1)
            self.transport.write(header + b'\x00' * 256)  # Empty device record
            logger.warning(f"Device not found: {busid}")
    
    def _forward_to_device(self, data: bytes):
        """Forward data to the imported USB device."""
        if self.device_path:
            self.device_manager.write_data(self.device_path, data)
    
    async def _device_reader(self):
        """Read data from device and forward to client."""
        while self.transport and not self.transport.is_closing():
            if self.device_path:
                data = self.device_manager.read_data(self.device_path)
                if data:
                    self.transport.write(data)
            await asyncio.sleep(0.001)  # 1ms polling interval


def list_devices():
    """List available USB devices."""
    print("\nAvailable USB Serial Devices:")
    print("=" * 60)
    
    if not SERIAL_AVAILABLE:
        print("ERROR: pyserial not installed. Run: pip install pyserial")
        return 1
    
    manager = USBIPDeviceManager()
    devices = manager.scan_devices()
    
    if not devices:
        print("No USB serial devices found.")
        print("\nMake sure your OpenBCI dongle is connected.")
        return 0
    
    for i, dev in enumerate(devices, 1):
        print(f"\n{i}. {dev.product}")
        print(f"   Path: {dev.path}")
        print(f"   Vendor ID: 0x{dev.idVendor:04X}")
        print(f"   Product ID: 0x{dev.idProduct:04X}")
        print(f"   Serial: {dev.serial or 'N/A'}")
    
    print("\n" + "=" * 60)
    print(f"Total: {len(devices)} device(s)")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description='USB/IP Server for OpenBCI Device Sharing'
    )
    parser.add_argument('--list', '-l', action='store_true',
                       help='List available USB devices')
    parser.add_argument('--host', default='0.0.0.0',
                       help='Host to bind to (default: 0.0.0.0)')
    parser.add_argument('--port', '-p', type=int, default=3240,
                       help='Port to listen on (default: 3240)')
    parser.add_argument('--device', '-d', default=None,
                       help='Specific device path to share')
    parser.add_argument('--auto', '-a', action='store_true',
                       help='Auto-detect and share OpenBCI device')
    parser.add_argument('--baudrate', '-b', type=int, default=115200,
                       help='Serial baudrate (default: 115200)')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Verbose logging')
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    if args.list:
        return list_devices()
    
    # Start server
    print(f"\n{'='*60}")
    print("USB/IP Server for OpenBCI")
    print(f"{'='*60}\n")
    
    if not SERIAL_AVAILABLE:
        print("ERROR: pyserial not installed.")
        print("Install: pip install pyserial")
        return 1
    
    server = USBIPServer(args.host, args.port)
    
    try:
        asyncio.run(server.start())
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.stop()
    
    return 0


if __name__ == '__main__':
    sys.exit(main())
