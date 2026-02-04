#!/usr/bin/env python3
"""
OpenBCI Host-Side Data Acquisition and Streaming System for macOS

This script provides:
- Auto-detection of OpenBCI boards (Cyton USB / Ganglion BLE)
- BrainFlow-based data acquisition
- Dual streaming: LSL (port 16571) and TCP (port 16572)
- Signal quality monitoring and impedance checking
- Clean shutdown handling

Author: OpenBCI Host Acquisition System
License: MIT
"""

import os
import sys
import time
import json
import socket
import signal
import asyncio
import logging
import argparse
import platform
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Optional, List, Dict, Callable, Any
from concurrent.futures import ThreadPoolExecutor
from collections import deque

import yaml
import numpy as np

# BrainFlow
from brainflow.board_shim import BoardShim, BrainFlowInputParams, BoardIds
from brainflow.data_filter import DataFilter, FilterTypes, DetrendOperations

# LSL
from pylsl import StreamInfo, StreamOutlet, local_clock

# Serial/BLE
import serial.tools.list_ports


# =============================================================================
# Configuration
# =============================================================================

@dataclass
class BoardConfig:
    """Board-specific configuration"""
    board_type: str  # 'cyton' or 'ganglion'
    sampling_rate: int
    num_channels: int
    channel_names: List[str]
    serial_port: Optional[str] = None
    mac_address: Optional[str] = None
    timeout_ms: int = 5000


@dataclass
class LSLConfig:
    """LSL stream configuration"""
    stream_name: str = "OpenBCI-EEG"
    stream_type: str = "EEG"
    source_id: str = "openbci-host-001"
    port: int = 16571


@dataclass
class TCPConfig:
    """TCP socket configuration"""
    host: str = "0.0.0.0"
    port: int = 16572
    max_clients: int = 5


@dataclass
class AcquisitionConfig:
    """Main acquisition configuration"""
    board: BoardConfig
    lsl: LSLConfig
    tcp: TCPConfig
    buffer_size: int = 450000  # 50 seconds at 250Hz
    impedance_check: bool = True
    signal_quality_threshold: float = 0.5


# =============================================================================
# Logging Setup
# =============================================================================

def setup_logging(verbose: bool = False) -> logging.Logger:
    """Configure logging with colored output"""
    level = logging.DEBUG if verbose else logging.INFO
    
    # Custom formatter with colors
    class ColoredFormatter(logging.Formatter):
        COLORS = {
            'DEBUG': '\033[36m',    # Cyan
            'INFO': '\033[32m',     # Green
            'WARNING': '\033[33m',  # Yellow
            'ERROR': '\033[31m',    # Red
            'CRITICAL': '\033[35m', # Magenta
            'RESET': '\033[0m'
        }
        
        def format(self, record):
            color = self.COLORS.get(record.levelname, self.COLORS['RESET'])
            reset = self.COLORS['RESET']
            record.levelname = f"{color}{record.levelname}{reset}"
            return super().format(record)
    
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(ColoredFormatter(
        '%(asctime)s [%(levelname)s] %(message)s',
        datefmt='%H:%M:%S'
    ))
    
    logger = logging.getLogger('openbci_host')
    logger.setLevel(level)
    logger.addHandler(handler)
    
    return logger


logger = logging.getLogger('openbci_host')


# =============================================================================
# Board Detection
# =============================================================================

class BoardDetector:
    """Auto-detect OpenBCI boards (Cyton USB or Ganglion BLE)"""
    
    CYTON_VID_PIDS = [
        (0x0403, 0x6015),  # FT231X (Cyton)
        (0x0403, 0x6001),  # FT232R (older Cyton)
    ]
    
    # Common macOS serial port patterns for FTDI chips
    CYTON_PORT_PATTERNS = [
        '/dev/tty.usbserial',
        '/dev/tty.usbmodem',
        '/dev/cu.usbserial',
        '/dev/cu.usbmodem',
    ]
    
    def __init__(self):
        self.detected_board: Optional[str] = None
        self.port: Optional[str] = None
        self.mac_address: Optional[str] = None
    
    def detect(self) -> Optional[str]:
        """
        Attempt to detect connected OpenBCI board.
        Returns: 'cyton', 'ganglion', or None
        """
        logger.info("🔍 Scanning for OpenBCI boards...")
        
        # Try Cyton USB first
        if self._detect_cyton():
            self.detected_board = 'cyton'
            logger.info(f"✅ Detected Cyton board on {self.port}")
            return 'cyton'
        
        # Try Ganglion BLE
        if self._detect_ganglion():
            self.detected_board = 'ganglion'
            logger.info(f"✅ Detected Ganglion board (BLE MAC: {self.mac_address})")
            return 'ganglion'
        
        logger.warning("❌ No OpenBCI board detected")
        return None
    
    def _detect_cyton(self) -> bool:
        """Detect Cyton board via USB serial"""
        try:
            ports = serial.tools.list_ports.comports()
            
            for port in ports:
                # Check VID:PID match
                if port.vid and port.pid:
                    if (port.vid, port.pid) in self.CYTON_VID_PIDS:
                        self.port = port.device
                        logger.debug(f"Found Cyton at {port.device} ({port.description})")
                        return True
                
                # Check description patterns
                if any(pattern in port.device for pattern in self.CYTON_PORT_PATTERNS):
                    if 'FTDI' in port.description or 'UART' in port.description:
                        self.port = port.device
                        logger.debug(f"Found potential Cyton at {port.device}")
                        return True
            
            return False
        except Exception as e:
            logger.error(f"Error detecting Cyton: {e}")
            return False
    
    def _detect_ganglion(self) -> bool:
        """Detect Ganglion board via Bluetooth LE"""
        try:
            # Try to use bleak for BLE scanning
            try:
                import asyncio
                from bleak import BleakScanner
                
                async def scan():
                    devices = await BleakScanner.discover(timeout=5.0)
                    for device in devices:
                        name = device.name or ""
                        # Ganglion typically has "Ganglion" in name
                        if "Ganglion" in name:
                            self.mac_address = device.address
                            return True
                    return False
                
                return asyncio.run(scan())
            except ImportError:
                logger.debug("Bleak not installed, skipping BLE scan")
                return False
                
        except Exception as e:
            logger.error(f"Error detecting Ganglion: {e}")
            return False
    
    def get_board_id(self) -> int:
        """Get BrainFlow board ID for detected board"""
        if self.detected_board == 'cyton':
            return BoardIds.CYTON_BOARD.value
        elif self.detected_board == 'ganglion':
            return BoardIds.GANGLION_BOARD.value
        else:
            raise ValueError("No board detected")


# =============================================================================
# Signal Quality Monitor
# =============================================================================

class SignalQualityMonitor:
    """Monitor EEG signal quality and impedance"""
    
    def __init__(self, num_channels: int, sampling_rate: int):
        self.num_channels = num_channels
        self.sampling_rate = sampling_rate
        self.channel_stats: Dict[int, Dict] = {}
        self.window_size = int(sampling_rate * 2)  # 2 second window
        self._reset_stats()
    
    def _reset_stats(self):
        """Initialize channel statistics"""
        for ch in range(self.num_channels):
            self.channel_stats[ch] = {
                'rms': 0.0,
                'snr_db': 0.0,
                'noise_floor': 0.0,
                'is_good': False
            }
    
    def update(self, data: np.ndarray) -> Dict[int, Dict]:
        """
        Update signal quality metrics from new data
        
        Args:
            data: Channel data array (channels x samples)
        
        Returns:
            Dictionary of channel quality metrics
        """
        for ch in range(min(self.num_channels, data.shape[0])):
            channel_data = data[ch, :]
            
            # Calculate RMS
            rms = np.sqrt(np.mean(channel_data ** 2))
            
            # Estimate noise floor (using high frequency content)
            # Apply high-pass to isolate noise
            noise_data = np.copy(channel_data)
            DataFilter.perform_highpass(
                noise_data, 
                self.sampling_rate, 
                50.0,  # 50 Hz cutoff
                4, 
                FilterTypes.BUTTERWORTH.value,
                0.0
            )
            noise_floor = np.std(noise_data)
            
            # Estimate SNR (signal in 1-40 Hz vs noise 50+ Hz)
            signal_data = np.copy(channel_data)
            DataFilter.perform_bandpass(
                signal_data,
                self.sampling_rate,
                20.5,  # center freq
                39.0,  # bandwidth (1-40 Hz)
                4,
                FilterTypes.BUTTERWORTH.value,
                0.0
            )
            signal_power = np.mean(signal_data ** 2)
            noise_power = max(noise_floor ** 2, 1e-10)
            snr_db = 10 * np.log10(signal_power / noise_power)
            
            # Determine if channel is good
            # Good: SNR > 10 dB, RMS within reasonable range
            is_good = (snr_db > 10.0) and (1.0 < rms < 100.0)
            
            self.channel_stats[ch] = {
                'rms': float(rms),
                'snr_db': float(snr_db),
                'noise_floor': float(noise_floor),
                'is_good': is_good
            }
        
        return self.channel_stats
    
    def check_impedance(self, board_shim: BoardShim) -> Dict[int, float]:
        """
        Check electrode impedance (if supported by board)
        
        Returns:
            Dictionary of channel impedances in kOhm
        """
        impedances = {}
        
        try:
            # Try to get impedance data from BrainFlow
            # Note: This requires specific board configuration
            for ch in range(self.num_channels):
                try:
                    imp = board_shim.get_impedance(ch)
                    impedances[ch] = imp
                except:
                    impedances[ch] = -1.0  # Not available
        except Exception as e:
            logger.debug(f"Impedance check not available: {e}")
            for ch in range(self.num_channels):
                impedances[ch] = -1.0
        
        return impedances
    
    def get_summary(self) -> str:
        """Get human-readable quality summary"""
        good_channels = sum(1 for stats in self.channel_stats.values() if stats['is_good'])
        total_channels = len(self.channel_stats)
        
        lines = [f"Signal Quality: {good_channels}/{total_channels} channels good"]
        
        for ch, stats in self.channel_stats.items():
            status = "✅" if stats['is_good'] else "⚠️"
            lines.append(
                f"  Ch{ch+1}: {status} SNR={stats['snr_db']:.1f}dB, "
                f"RMS={stats['rms']:.2f}µV"
            )
        
        return "\n".join(lines)


# =============================================================================
# LSL Streamer
# =============================================================================

class LSLStreamer:
    """Stream EEG data via Lab Streaming Layer"""
    
    def __init__(self, config: LSLConfig, board_config: BoardConfig):
        self.config = config
        self.board_config = board_config
        self.outlet: Optional[StreamOutlet] = None
        self.stream_info: Optional[StreamInfo] = None
        self._sample_count = 0
    
    def start(self) -> bool:
        """Initialize and start LSL stream"""
        try:
            # Create stream info
            self.stream_info = StreamInfo(
                name=self.config.stream_name,
                type=self.config.stream_type,
                channel_count=self.board_config.num_channels,
                nominal_srate=self.board_config.sampling_rate,
                channel_format='float32',
                source_id=self.config.source_id
            )
            
            # Add metadata
            desc = self.stream_info.desc()
            channels = desc.append_child("channels")
            for name in self.board_config.channel_names:
                ch = channels.append_child("channel")
                ch.append_child_value("label", name)
                ch.append_child_value("unit", "microvolts")
                ch.append_child_value("type", "EEG")
            
            desc.append_child_value("manufacturer", "OpenBCI")
            desc.append_child_value("board_type", self.board_config.board_type)
            
            # Create outlet
            self.outlet = StreamOutlet(self.stream_info)
            
            logger.info(f"✅ LSL stream started: '{self.config.stream_name}'")
            logger.info(f"   Channels: {self.board_config.num_channels}")
            logger.info(f"   Sampling Rate: {self.board_config.sampling_rate} Hz")
            logger.info(f"   Source ID: {self.config.source_id}")
            
            return True
            
        except Exception as e:
            logger.error(f"Failed to start LSL stream: {e}")
            return False
    
    def push_sample(self, sample: np.ndarray, timestamp: Optional[float] = None):
        """Push a single sample to LSL"""
        if self.outlet is None:
            return
        
        try:
            if timestamp is None:
                timestamp = local_clock()
            
            # Ensure sample is the right shape
            if sample.shape[0] >= self.board_config.num_channels:
                self.outlet.push_sample(sample[:self.board_config.num_channels], timestamp)
                self._sample_count += 1
        except Exception as e:
            logger.error(f"Error pushing LSL sample: {e}")
    
    def push_chunk(self, data: np.ndarray, timestamps: Optional[List[float]] = None):
        """Push multiple samples to LSL"""
        if self.outlet is None:
            return
        
        try:
            # Transpose if needed (samples x channels)
            if data.shape[0] == self.board_config.num_channels:
                data = data.T
            
            self.outlet.push_chunk(data.tolist(), timestamps)
            self._sample_count += data.shape[0]
        except Exception as e:
            logger.error(f"Error pushing LSL chunk: {e}")
    
    def stop(self):
        """Stop LSL stream"""
        if self.outlet:
            logger.info(f"📊 LSL total samples pushed: {self._sample_count}")
            self.outlet = None
            logger.info("✅ LSL stream stopped")


# =============================================================================
# TCP Streamer
# =============================================================================

class TCPStreamer:
    """Raw TCP socket streaming server"""
    
    def __init__(self, config: TCPConfig, board_config: BoardConfig):
        self.config = config
        self.board_config = board_config
        self.server: Optional[socket.socket] = None
        self.clients: List[socket.socket] = []
        self.running = False
        self._executor = ThreadPoolExecutor(max_workers=2)
        self._sample_count = 0
    
    def start(self) -> bool:
        """Start TCP server"""
        try:
            self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.server.bind((self.config.host, self.config.port))
            self.server.listen(self.config.max_clients)
            self.server.setblocking(False)
            
            self.running = True
            
            # Start accept loop in background
            self._executor.submit(self._accept_loop)
            
            logger.info(f"✅ TCP server started on {self.config.host}:{self.config.port}")
            
            return True
            
        except Exception as e:
            logger.error(f"Failed to start TCP server: {e}")
            return False
    
    def _accept_loop(self):
        """Background thread: accept new connections"""
        while self.running:
            try:
                client, addr = self.server.accept()
                client.setblocking(True)
                
                if len(self.clients) >= self.config.max_clients:
                    logger.warning(f"Max clients reached, rejecting {addr}")
                    client.close()
                    continue
                
                self.clients.append(client)
                logger.info(f"📡 TCP client connected: {addr} (total: {len(self.clients)})")
                
                # Send header with stream info
                header = {
                    'type': 'openbci_stream',
                    'version': '1.0',
                    'board_type': self.board_config.board_type,
                    'sampling_rate': self.board_config.sampling_rate,
                    'num_channels': self.board_config.num_channels,
                    'channel_names': self.board_config.channel_names
                }
                header_json = json.dumps(header) + '\n'
                client.send(header_json.encode('utf-8'))
                
            except BlockingIOError:
                time.sleep(0.01)
            except Exception as e:
                if self.running:
                    logger.error(f"Error accepting connection: {e}")
    
    def push_sample(self, sample: np.ndarray, timestamp: float):
        """Push a sample to all connected TCP clients"""
        if not self.clients:
            return
        
        try:
            # Format: JSON line with timestamp and channel values
            data = {
                'ts': timestamp,
                'data': sample[:self.board_config.num_channels].tolist()
            }
            json_line = json.dumps(data) + '\n'
            encoded = json_line.encode('utf-8')
            
            # Send to all clients, remove disconnected ones
            disconnected = []
            for client in self.clients:
                try:
                    client.send(encoded)
                except (BrokenPipeError, ConnectionResetError):
                    disconnected.append(client)
            
            # Remove disconnected clients
            for client in disconnected:
                self._remove_client(client)
            
            self._sample_count += 1
            
        except Exception as e:
            logger.error(f"Error sending TCP data: {e}")
    
    def _remove_client(self, client: socket.socket):
        """Remove a disconnected client"""
        try:
            client.close()
        except:
            pass
        
        if client in self.clients:
            self.clients.remove(client)
            logger.info(f"📡 TCP client disconnected (remaining: {len(self.clients)})")
    
    def stop(self):
        """Stop TCP server"""
        self.running = False
        
        # Close all client connections
        for client in self.clients:
            try:
                client.close()
            except:
                pass
        self.clients.clear()
        
        # Close server
        if self.server:
            try:
                self.server.close()
            except:
                pass
        
        self._executor.shutdown(wait=False)
        
        logger.info(f"📊 TCP total samples pushed: {self._sample_count}")
        logger.info("✅ TCP server stopped")


# =============================================================================
# Main Acquisition System
# =============================================================================

class OpenBCIHostAcquisition:
    """Main OpenBCI host acquisition system"""
    
    def __init__(self, config_path: Optional[str] = None):
        self.config: Optional[AcquisitionConfig] = None
        self.config_path = config_path or self._find_config()
        self.board_shim: Optional[BoardShim] = None
        self.detector = BoardDetector()
        self.quality_monitor: Optional[SignalQualityMonitor] = None
        self.lsl_streamer: Optional[LSLStreamer] = None
        self.tcp_streamer: Optional[TCPStreamer] = None
        self.running = False
        self._shutdown_event = asyncio.Event()
        
        # Statistics
        self._total_samples = 0
        self._start_time: Optional[float] = None
    
    def _find_config(self) -> str:
        """Find configuration file"""
        # Check common locations
        locations = [
            'openbci_config.yaml',
            'tools/openbci_host/openbci_config.yaml',
            os.path.expanduser('~/.config/openbci/openbci_config.yaml'),
            '/etc/openbci/openbci_config.yaml',
        ]
        
        for loc in locations:
            if os.path.exists(loc):
                return loc
        
        return 'openbci_config.yaml'
    
    def load_config(self) -> bool:
        """Load configuration from YAML file"""
        try:
            if not os.path.exists(self.config_path):
                logger.warning(f"Config file not found: {self.config_path}, using defaults")
                self.config = self._default_config()
                return True
            
            with open(self.config_path, 'r') as f:
                data = yaml.safe_load(f)
            
            # Parse board config
            board_data = data.get('board', {})
            board_config = BoardConfig(
                board_type=board_data.get('type', 'cyton'),
                sampling_rate=board_data.get('sampling_rate', 250),
                num_channels=board_data.get('num_channels', 8),
                channel_names=board_data.get('channel_names', [f'Ch{i+1}' for i in range(8)]),
                serial_port=board_data.get('serial_port'),
                mac_address=board_data.get('mac_address'),
                timeout_ms=board_data.get('timeout_ms', 5000)
            )
            
            # Parse LSL config
            lsl_data = data.get('lsl', {})
            lsl_config = LSLConfig(
                stream_name=lsl_data.get('stream_name', 'OpenBCI-EEG'),
                stream_type=lsl_data.get('stream_type', 'EEG'),
                source_id=lsl_data.get('source_id', 'openbci-host-001'),
                port=lsl_data.get('port', 16571)
            )
            
            # Parse TCP config
            tcp_data = data.get('tcp', {})
            tcp_config = TCPConfig(
                host=tcp_data.get('host', '0.0.0.0'),
                port=tcp_data.get('port', 16572),
                max_clients=tcp_data.get('max_clients', 5)
            )
            
            self.config = AcquisitionConfig(
                board=board_config,
                lsl=lsl_config,
                tcp=tcp_config,
                buffer_size=data.get('buffer_size', 450000),
                impedance_check=data.get('impedance_check', True),
                signal_quality_threshold=data.get('signal_quality_threshold', 0.5)
            )
            
            logger.info(f"✅ Loaded configuration from {self.config_path}")
            return True
            
        except Exception as e:
            logger.error(f"Error loading config: {e}")
            self.config = self._default_config()
            return True
    
    def _default_config(self) -> AcquisitionConfig:
        """Create default configuration"""
        return AcquisitionConfig(
            board=BoardConfig(
                board_type='cyton',
                sampling_rate=250,
                num_channels=8,
                channel_names=[f'Ch{i+1}' for i in range(8)]
            ),
            lsl=LSLConfig(),
            tcp=TCPConfig()
        )
    
    def detect_and_configure(self) -> bool:
        """Auto-detect board and update configuration"""
        detected = self.detector.detect()
        
        if detected is None:
            # Try to use manual config
            if self.config.board.serial_port or self.config.board.mac_address:
                logger.info("Using manually configured board settings")
                detected = self.config.board.board_type
            else:
                logger.error("No board detected and no manual configuration provided")
                return False
        
        # Update config with detected settings
        self.config.board.board_type = detected
        
        if detected == 'cyton':
            self.config.board.sampling_rate = 250
            self.config.board.num_channels = 8
            self.config.board.channel_names = [f'Ch{i+1}' for i in range(8)]
            if self.detector.port:
                self.config.board.serial_port = self.detector.port
        
        elif detected == 'ganglion':
            self.config.board.sampling_rate = 200
            self.config.board.num_channels = 4
            self.config.board.channel_names = [f'Ch{i+1}' for i in range(4)]
            if self.detector.mac_address:
                self.config.board.mac_address = self.detector.mac_address
        
        logger.info(f"📋 Board Configuration:")
        logger.info(f"   Type: {self.config.board.board_type}")
        logger.info(f"   Sampling Rate: {self.config.board.sampling_rate} Hz")
        logger.info(f"   Channels: {self.config.board.num_channels}")
        
        return True
    
    def initialize_board(self) -> bool:
        """Initialize BrainFlow board connection"""
        try:
            params = BrainFlowInputParams()
            
            if self.config.board.board_type == 'cyton':
                if self.config.board.serial_port:
                    params.serial_port = self.config.board.serial_port
                else:
                    params.serial_port = '/dev/tty.usbserial-DM00D7PA'  # Default fallback
                board_id = BoardIds.CYTON_BOARD.value
                
            elif self.config.board.board_type == 'ganglion':
                if self.config.board.mac_address:
                    params.mac_address = self.config.board.mac_address
                board_id = BoardIds.GANGLION_BOARD.value
            else:
                raise ValueError(f"Unknown board type: {self.config.board.board_type}")
            
            # Enable logging
            BoardShim.enable_dev_board_logger()
            
            # Create board shim
            self.board_shim = BoardShim(board_id, params)
            
            logger.info(f"🔌 Connecting to {self.config.board.board_type}...")
            self.board_shim.prepare_session()
            
            logger.info("✅ Board session prepared")
            return True
            
        except Exception as e:
            logger.error(f"Failed to initialize board: {e}")
            return False
    
    def start_acquisition(self) -> bool:
        """Start data acquisition and streaming"""
        if self.board_shim is None:
            logger.error("Board not initialized")
            return False
        
        try:
            # Start stream
            self.board_shim.start_stream(self.config.buffer_size)
            logger.info("✅ Board streaming started")
            
            # Initialize quality monitor
            self.quality_monitor = SignalQualityMonitor(
                self.config.board.num_channels,
                self.config.board.sampling_rate
            )
            
            # Initialize LSL streamer
            self.lsl_streamer = LSLStreamer(self.config.lsl, self.config.board)
            if not self.lsl_streamer.start():
                logger.warning("LSL streamer failed to start")
            
            # Initialize TCP streamer
            self.tcp_streamer = TCPStreamer(self.config.tcp, self.config.board)
            if not self.tcp_streamer.start():
                logger.warning("TCP streamer failed to start")
            
            self.running = True
            self._start_time = time.time()
            
            # Print status
            self._print_status()
            
            return True
            
        except Exception as e:
            logger.error(f"Failed to start acquisition: {e}")
            return False
    
    def _print_status(self):
        """Print current system status"""
        logger.info("")
        logger.info("╔══════════════════════════════════════════════════════════╗")
        logger.info("║      OpenBCI Host Acquisition System - RUNNING          ║")
        logger.info("╠══════════════════════════════════════════════════════════╣")
        logger.info(f"║ Board:        {self.config.board.board_type:19} ({self.config.board.num_channels}ch @ {self.config.board.sampling_rate}Hz) ║")
        logger.info(f"║ LSL Stream:   {'Active':19} (port {self.config.lsl.port})        ║")
        logger.info(f"║ TCP Socket:   {'Active':19} (port {self.config.tcp.port})        ║")
        logger.info("╠══════════════════════════════════════════════════════════╣")
        logger.info("║ Press Ctrl+C to stop                                     ║")
        logger.info("╚══════════════════════════════════════════════════════════╝")
        logger.info("")
    
    def run_acquisition_loop(self):
        """Main acquisition loop"""
        quality_update_interval = 5.0  # seconds
        last_quality_update = 0
        
        while self.running:
            try:
                # Get data from board
                data = self.board_shim.get_current_board_data(1)  # Get latest sample
                
                if data.shape[1] > 0:
                    # Extract EEG channels (skip timestamp/other channels)
                    # BrainFlow data format: [timestamp, ch1, ch2, ..., chN, ...]
                    eeg_data = data[1:self.config.board.num_channels+1, :]
                    timestamp = data[0, -1]  # Use board timestamp
                    
                    # Get latest sample
                    sample = eeg_data[:, -1]
                    
                    # Push to LSL
                    if self.lsl_streamer:
                        self.lsl_streamer.push_sample(sample, timestamp)
                    
                    # Push to TCP
                    if self.tcp_streamer:
                        self.tcp_streamer.push_sample(sample, timestamp)
                    
                    self._total_samples += 1
                
                # Periodic quality check
                current_time = time.time()
                if current_time - last_quality_update > quality_update_interval:
                    if eeg_data.shape[1] > 0:
                        self.quality_monitor.update(eeg_data)
                        logger.info("\n" + self.quality_monitor.get_summary())
                        
                        # Check impedance if enabled
                        if self.config.impedance_check:
                            impedances = self.quality_monitor.check_impedance(self.board_shim)
                            if any(v > 0 for v in impedances.values()):
                                logger.info(f"Impedances (kΩ): {impedances}")
                    
                    last_quality_update = current_time
                
                # Small delay to prevent busy-waiting
                time.sleep(0.001)
                
            except KeyboardInterrupt:
                logger.info("Keyboard interrupt received")
                break
            except Exception as e:
                logger.error(f"Error in acquisition loop: {e}")
                time.sleep(0.1)
    
    def shutdown(self):
        """Clean shutdown of all components"""
        logger.info("\n🛑 Shutting down...")
        self.running = False
        
        # Stop streamers
        if self.lsl_streamer:
            self.lsl_streamer.stop()
            self.lsl_streamer = None
        
        if self.tcp_streamer:
            self.tcp_streamer.stop()
            self.tcp_streamer = None
        
        # Stop board
        if self.board_shim:
            try:
                self.board_shim.stop_stream()
                self.board_shim.release_session()
                logger.info("✅ Board session released")
            except Exception as e:
                logger.error(f"Error releasing board: {e}")
            self.board_shim = None
        
        # Print statistics
        if self._start_time:
            duration = time.time() - self._start_time
            rate = self._total_samples / duration if duration > 0 else 0
            logger.info(f"\n📊 Session Statistics:")
            logger.info(f"   Duration: {duration:.1f} seconds")
            logger.info(f"   Total Samples: {self._total_samples}")
            logger.info(f"   Effective Rate: {rate:.1f} Hz")
        
        logger.info("✅ Shutdown complete")
    
    def run(self):
        """Run the complete acquisition system"""
        # Setup signal handlers
        def signal_handler(signum, frame):
            logger.info(f"Received signal {signum}")
            self.shutdown()
            sys.exit(0)
        
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
        
        try:
            # Load configuration
            if not self.load_config():
                return 1
            
            # Detect and configure board
            if not self.detect_and_configure():
                return 1
            
            # Initialize board
            if not self.initialize_board():
                return 1
            
            # Start acquisition
            if not self.start_acquisition():
                return 1
            
            # Run main loop
            self.run_acquisition_loop()
            
        except Exception as e:
            logger.exception("Fatal error")
            return 1
        finally:
            self.shutdown()
        
        return 0


# =============================================================================
# Command Line Interface
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='OpenBCI Host-Side Data Acquisition System for macOS',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                           # Auto-detect and run
  %(prog)s --config myconfig.yaml   # Use custom config
  %(prog)s --board cyton --port /dev/tty.usbserial-XXX  # Manual Cyton
  %(prog)s --board ganglion --mac XX:XX:XX:XX:XX:XX     # Manual Ganglion
  %(prog)s -v                       # Verbose output
        """
    )
    
    parser.add_argument('-c', '--config', 
                        help='Path to configuration file')
    parser.add_argument('-b', '--board', 
                        choices=['cyton', 'ganglion', 'auto'],
                        default='auto',
                        help='Board type (default: auto-detect)')
    parser.add_argument('-p', '--port', 
                        help='Serial port for Cyton (e.g., /dev/tty.usbserial-DM00D7PA)')
    parser.add_argument('-m', '--mac', 
                        help='MAC address for Ganglion BLE')
    parser.add_argument('--lsl-port', type=int, default=16571,
                        help='LSL stream port (default: 16571)')
    parser.add_argument('--tcp-port', type=int, default=16572,
                        help='TCP server port (default: 16572)')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Enable verbose logging')
    parser.add_argument('--version', action='version', version='%(prog)s 1.0.0')
    
    args = parser.parse_args()
    
    # Setup logging
    global logger
    logger = setup_logging(args.verbose)
    
    # Print banner
    logger.info("=" * 60)
    logger.info("  OpenBCI Host Acquisition System v1.0.0")
    logger.info("  Platform: macOS")
    logger.info("=" * 60)
    
    # Create and run acquisition system
    acquisition = OpenBCIHostAcquisition(args.config)
    
    # Override config with command line args
    if args.board != 'auto':
        acquisition.config = acquisition._default_config()
        acquisition.config.board.board_type = args.board
    
    if args.port:
        if acquisition.config is None:
            acquisition.config = acquisition._default_config()
        acquisition.config.board.serial_port = args.port
        acquisition.config.board.board_type = 'cyton'
    
    if args.mac:
        if acquisition.config is None:
            acquisition.config = acquisition._default_config()
        acquisition.config.board.mac_address = args.mac
        acquisition.config.board.board_type = 'ganglion'
    
    if args.lsl_port:
        if acquisition.config is None:
            acquisition.config = acquisition._default_config()
        acquisition.config.lsl.port = args.lsl_port
    
    if args.tcp_port:
        if acquisition.config is None:
            acquisition.config = acquisition._default_config()
        acquisition.config.tcp.port = args.tcp_port
    
    # Run
    return acquisition.run()


if __name__ == '__main__':
    sys.exit(main())
