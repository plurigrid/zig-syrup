#!/usr/bin/env python3
"""
Example Host Acquisition Module for BCI Pipeline

Simulates an EEG acquisition device that produces raw data
and streams it via LSL (Lab Streaming Layer) or TCP.
"""

import asyncio
import logging
import numpy as np
import struct
import json
from datetime import datetime
from typing import Optional

# Optional LSL import
try:
    from pylsl import StreamInfo, StreamOutlet
    HAS_LSL = True
except ImportError:
    HAS_LSL = False


class EEGSimulator:
    """
    Simulates an EEG acquisition device.
    
    Generates synthetic EEG-like data with:
    - 8 channels
    - 256 Hz sampling rate
    - Realistic frequency content (alpha, beta, theta bands)
    """
    
    def __init__(
        self,
        channels: int = 8,
        sampling_rate: int = 256,
        buffer_size: int = 1024
    ):
        self.channels = channels
        self.sampling_rate = sampling_rate
        self.buffer_size = buffer_size
        
        self.logger = logging.getLogger('EEGSimulator')
        
        # Frequency bands (Hz)
        self.bands = {
            'delta': (0.5, 4),    # 0.5-4 Hz
            'theta': (4, 8),      # 4-8 Hz
            'alpha': (8, 13),     # 8-13 Hz
            'beta': (13, 30),     # 13-30 Hz
            'gamma': (30, 50)     # 30-50 Hz
        }
        
        # Simulated channel names (10-20 system subset)
        self.channel_names = ['Fp1', 'Fp2', 'C3', 'C4', 'P3', 'P4', 'O1', 'O2'][:channels]
        
        self._running = False
        self.sample_count = 0
    
    def generate_sample(self) -> np.ndarray:
        """Generate a single multi-channel sample"""
        # Time vector for this sample
        t = self.sample_count / self.sampling_rate
        
        sample = np.zeros(self.channels)
        
        for ch in range(self.channels):
            # Mix of frequency components
            # Alpha wave (10 Hz) - dominant
            sample[ch] += 0.5 * np.sin(2 * np.pi * 10 * t + ch * 0.5)
            
            # Beta wave (20 Hz)
            sample[ch] += 0.3 * np.sin(2 * np.pi * 20 * t + ch * 0.3)
            
            # Theta wave (6 Hz)
            sample[ch] += 0.2 * np.sin(2 * np.pi * 6 * t + ch * 0.7)
            
            # Add some noise
            sample[ch] += 0.1 * np.random.randn()
            
            # Channel-specific variation
            sample[ch] *= (1 + 0.1 * ch)
        
        self.sample_count += 1
        return sample.astype(np.float32)
    
    def generate_chunk(self, n_samples: int) -> np.ndarray:
        """Generate a chunk of samples"""
        chunk = np.zeros((n_samples, self.channels), dtype=np.float32)
        for i in range(n_samples):
            chunk[i] = self.generate_sample()
        return chunk


class HostAcquisition:
    """
    Host acquisition module that interfaces with EEG hardware (or simulator)
    and streams data to the pipeline.
    """
    
    def __init__(
        self,
        output_port: int = 16571,
        protocol: str = "lsl",
        channels: int = 8,
        sampling_rate: int = 256
    ):
        self.output_port = output_port
        self.protocol = protocol
        self.channels = channels
        self.sampling_rate = sampling_rate
        
        self.logger = logging.getLogger('HostAcquisition')
        
        # Initialize simulator
        self.simulator = EEGSimulator(channels, sampling_rate)
        
        # LSL outlet (if using LSL)
        self.lsl_outlet: Optional[StreamOutlet] = None
        
        # TCP server state
        self.tcp_clients = []
        self.tcp_server = None
        
        self._running = False
    
    async def start(self):
        """Start the acquisition module"""
        self._running = True
        self.logger.info(f"Starting acquisition on port {self.output_port} ({self.protocol})")
        
        if self.protocol == "lsl" and HAS_LSL:
            self._init_lsl()
        elif self.protocol == "tcp":
            await self._start_tcp_server()
        
        # Start data generation loop
        await self._acquisition_loop()
    
    def _init_lsl(self):
        """Initialize LSL stream"""
        if not HAS_LSL:
            self.logger.error("pylsl not installed. Install with: pip install pylsl")
            return
        
        # Create stream info
        stream_info = StreamInfo(
            name='BCI_Raw_EEG',
            type='EEG',
            channel_count=self.channels,
            nominal_srate=self.sampling_rate,
            channel_format='float32',
            source_id='bci_simulator_001'
        )
        
        # Add channel labels
        channels_xml = stream_info.desc().append_child("channels")
        for name in self.simulator.channel_names:
            channel = channels_xml.append_child("channel")
            channel.append_child_value("label", name)
            channel.append_child_value("unit", "microvolts")
            channel.append_child_value("type", "EEG")
        
        # Create outlet
        self.lsl_outlet = StreamOutlet(stream_info)
        self.logger.info("LSL stream initialized: 'BCI_Raw_EEG'")
    
    async def _start_tcp_server(self):
        """Start TCP server for streaming"""
        self.tcp_server = await asyncio.start_server(
            self._handle_tcp_client,
            '0.0.0.0',
            self.output_port
        )
        self.logger.info(f"TCP server listening on port {self.output_port}")
    
    async def _handle_tcp_client(self, reader, writer):
        """Handle TCP client connection"""
        addr = writer.get_extra_info('peername')
        self.logger.info(f"TCP client connected: {addr}")
        self.tcp_clients.append(writer)
        
        try:
            while self._running:
                await asyncio.sleep(0.1)
        except Exception as e:
            self.logger.error(f"TCP client error: {e}")
        finally:
            self.tcp_clients.remove(writer)
            writer.close()
            self.logger.info(f"TCP client disconnected: {addr}")
    
    async def _acquisition_loop(self):
        """Main acquisition loop"""
        self.logger.info("Starting acquisition loop")
        
        # Samples per chunk (e.g., 8 samples = ~31ms at 256Hz)
        chunk_size = 8
        sleep_interval = chunk_size / self.sampling_rate
        
        samples_sent = 0
        last_log = asyncio.get_event_loop().time()
        
        while self._running:
            # Generate data chunk
            chunk = self.simulator.generate_chunk(chunk_size)
            timestamp = asyncio.get_event_loop().time()
            
            # Send via LSL
            if self.protocol == "lsl" and self.lsl_outlet:
                for sample in chunk:
                    self.lsl_outlet.push_sample(sample)
                samples_sent += len(chunk)
            
            # Send via TCP
            elif self.protocol == "tcp":
                await self._send_tcp_chunk(chunk, timestamp)
                samples_sent += len(chunk)
            
            # Log throughput
            now = asyncio.get_event_loop().time()
            if now - last_log >= 5.0:
                rate = samples_sent / (now - last_log)
                self.logger.info(f"Acquisition rate: {rate:.1f} samples/sec")
                samples_sent = 0
                last_log = now
            
            # Maintain sampling rate
            await asyncio.sleep(sleep_interval)
    
    async def _send_tcp_chunk(self, chunk: np.ndarray, timestamp: float):
        """Send chunk to all TCP clients"""
        # Pack data: header + data
        # Header: timestamp (8 bytes) + sequence (8 bytes) + num_samples (4 bytes) + num_channels (4 bytes)
        # Data: float32 array
        
        n_samples, n_channels = chunk.shape
        header = struct.pack('!dQII', timestamp, self.simulator.sample_count, n_samples, n_channels)
        data_bytes = chunk.tobytes()
        
        packet = header + data_bytes
        
        # Send to all connected clients
        disconnected = []
        for i, writer in enumerate(self.tcp_clients):
            try:
                writer.write(packet)
                await writer.drain()
            except Exception as e:
                self.logger.debug(f"Client write error: {e}")
                disconnected.append(i)
        
        # Remove disconnected clients
        for i in reversed(disconnected):
            self.tcp_clients.pop(i)
    
    async def stop(self):
        """Stop acquisition"""
        self._running = False
        self.logger.info("Stopping acquisition")
        
        if self.tcp_server:
            self.tcp_server.close()
            await self.tcp_server.wait_closed()


async def main():
    """Run the acquisition module"""
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    # Get configuration from environment
    import os
    protocol = os.environ.get('STREAM_RAW_EEG_PROTOCOL', 'tcp').lower()
    port = int(os.environ.get('STREAM_RAW_EEG_PORT', '16571'))
    
    acquisition = HostAcquisition(
        output_port=port,
        protocol=protocol,
        channels=8,
        sampling_rate=256
    )
    
    try:
        await acquisition.start()
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        await acquisition.stop()


if __name__ == "__main__":
    asyncio.run(main())
