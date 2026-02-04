#!/usr/bin/env python3
"""
Example Simple Processor Module for BCI Pipeline

Receives raw EEG data, applies filtering, and extracts features.
Demonstrates the container processing interface.
"""

import asyncio
import logging
import numpy as np
import struct
import json
from typing import Optional, List
from collections import deque


class FilterBank:
    """Simple filter bank for EEG processing"""
    
    def __init__(self, sampling_rate: int = 256):
        self.sampling_rate = sampling_rate
        
        # Filter state (simplified IIR)
        self.state = {}
        
    def bandpass_filter(self, data: np.ndarray, lowcut: float, highcut: float) -> np.ndarray:
        """Apply bandpass filter (simplified)"""
        # This is a simplified placeholder - real implementation would use scipy
        # For now, just return the data (assume pre-filtered or use simple moving average)
        return data
    
    def process(self, chunk: np.ndarray) -> dict:
        """Process chunk through filter bank"""
        # Apply bandpass filters for each band
        bands = {
            'delta': self.bandpass_filter(chunk, 0.5, 4),
            'theta': self.bandpass_filter(chunk, 4, 8),
            'alpha': self.bandpass_filter(chunk, 8, 13),
            'beta': self.bandpass_filter(chunk, 13, 30),
            'gamma': self.bandpass_filter(chunk, 30, 50)
        }
        
        return bands


class FeatureExtractor:
    """Extract features from filtered EEG data"""
    
    def __init__(self, channels: int = 8):
        self.channels = channels
        
    def extract_bandpower(self, data: np.ndarray) -> dict:
        """Extract band power features"""
        # Calculate power (variance) in each channel
        power = np.var(data, axis=0)
        
        return {
            f'ch{i}_power': float(power[i])
            for i in range(min(len(power), self.channels))
        }
    
    def extract_features(self, bands_data: dict) -> dict:
        """Extract features from all bands"""
        features = {}
        
        for band_name, band_data in bands_data.items():
            band_features = self.extract_bandpower(band_data)
            for key, value in band_features.items():
                features[f'{band_name}_{key}'] = value
        
        return features


class SimpleProcessor:
    """
    Simple EEG processor that receives raw data,
    applies filtering, and extracts features.
    """
    
    def __init__(
        self,
        input_port: int = 16571,
        output_filtered_port: int = 16573,
        output_features_port: int = 16574,
        channels: int = 8,
        sampling_rate: int = 256
    ):
        self.input_port = input_port
        self.output_filtered_port = output_filtered_port
        self.output_features_port = output_features_port
        self.channels = channels
        self.sampling_rate = sampling_rate
        
        self.logger = logging.getLogger('SimpleProcessor')
        
        # Processing components
        self.filter_bank = FilterBank(sampling_rate)
        self.feature_extractor = FeatureExtractor(channels)
        
        # Buffers
        self.input_buffer = deque(maxlen=1024)
        self.filtered_buffer = deque(maxlen=1024)
        
        # Output connections
        self.filtered_clients = []
        self.features_clients = []
        
        self._running = False
        self.processed_count = 0
    
    async def start(self):
        """Start the processor"""
        self._running = True
        self.logger.info("Starting simple processor")
        
        # Start input server
        input_server = await asyncio.start_server(
            self._handle_input,
            '0.0.0.0',
            self.input_port
        )
        
        # Start output servers
        filtered_server = await asyncio.start_server(
            self._handle_filtered_client,
            '0.0.0.0',
            self.output_filtered_port
        )
        
        features_server = await asyncio.start_server(
            self._handle_features_client,
            '0.0.0.0',
            self.output_features_port
        )
        
        self.logger.info(f"Listening for input on port {self.input_port}")
        self.logger.info(f"Filtered output on port {self.output_filtered_port}")
        self.logger.info(f"Features output on port {self.output_features_port}")
        
        # Keep running
        try:
            while self._running:
                await asyncio.sleep(1.0)
        finally:
            input_server.close()
            filtered_server.close()
            features_server.close()
    
    async def _handle_input(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        """Handle incoming data from acquisition"""
        addr = writer.get_extra_info('peername')
        self.logger.info(f"Input connection from {addr}")
        
        try:
            while self._running:
                # Read header
                header = await reader.readexactly(24)  # timestamp(8) + sequence(8) + n_samples(4) + n_channels(4)
                if not header:
                    break
                
                timestamp, sequence, n_samples, n_channels = struct.unpack('!dQII', header)
                
                # Read data
                data_size = n_samples * n_channels * 4  # float32 = 4 bytes
                data_bytes = await reader.readexactly(data_size)
                
                # Convert to numpy array
                chunk = np.frombuffer(data_bytes, dtype=np.float32).reshape(n_samples, n_channels)
                
                # Process the chunk
                await self._process_chunk(chunk, timestamp)
                
        except asyncio.IncompleteReadError:
            self.logger.info(f"Input connection closed: {addr}")
        except Exception as e:
            self.logger.error(f"Input error: {e}")
    
    async def _process_chunk(self, chunk: np.ndarray, timestamp: float):
        """Process a data chunk"""
        # Apply filter bank
        bands_data = self.filter_bank.process(chunk)
        
        # Use alpha band as "filtered" output (simplified)
        filtered = bands_data['alpha']
        
        # Extract features
        features = self.feature_extractor.extract_features(bands_data)
        features['timestamp'] = timestamp
        features['sequence'] = int(timestamp * 1000)
        
        # Send to outputs
        await self._send_filtered(filtered, timestamp)
        await self._send_features(features)
        
        self.processed_count += 1
        
        # Log periodically
        if self.processed_count % 100 == 0:
            self.logger.debug(f"Processed {self.processed_count} chunks")
    
    async def _send_filtered(self, data: np.ndarray, timestamp: float):
        """Send filtered data to connected clients"""
        header = struct.pack('!dQII', timestamp, 0, data.shape[0], data.shape[1])
        packet = header + data.tobytes()
        
        disconnected = []
        for i, writer in enumerate(self.filtered_clients):
            try:
                writer.write(packet)
                await writer.drain()
            except:
                disconnected.append(i)
        
        for i in reversed(disconnected):
            self.filtered_clients.pop(i)
    
    async def _send_features(self, features: dict):
        """Send features to connected clients"""
        data = json.dumps(features).encode('utf-8')
        header = struct.pack('!I', len(data))
        packet = header + data
        
        disconnected = []
        for i, writer in enumerate(self.features_clients):
            try:
                writer.write(packet)
                await writer.drain()
            except:
                disconnected.append(i)
        
        for i in reversed(disconnected):
            self.features_clients.pop(i)
    
    async def _handle_filtered_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        """Handle client connection for filtered data"""
        addr = writer.get_extra_info('peername')
        self.logger.info(f"Filtered output client connected: {addr}")
        self.filtered_clients.append(writer)
        
        try:
            while self._running:
                await asyncio.sleep(1.0)
        except:
            pass
        finally:
            if writer in self.filtered_clients:
                self.filtered_clients.remove(writer)
            writer.close()
            self.logger.info(f"Filtered output client disconnected: {addr}")
    
    async def _handle_features_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        """Handle client connection for features"""
        addr = writer.get_extra_info('peername')
        self.logger.info(f"Features output client connected: {addr}")
        self.features_clients.append(writer)
        
        try:
            while self._running:
                await asyncio.sleep(1.0)
        except:
            pass
        finally:
            if writer in self.features_clients:
                self.features_clients.remove(writer)
            writer.close()
            self.logger.info(f"Features output client disconnected: {addr}")
    
    async def stop(self):
        """Stop the processor"""
        self._running = False
        self.logger.info("Stopping processor")


async def main():
    """Run the processor"""
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    # Get configuration from environment
    import os
    input_port = int(os.environ.get('STREAM_RAW_EEG_PORT', '16571'))
    filtered_port = int(os.environ.get('STREAM_FILTERED_EEG_PORT', '16573'))
    features_port = int(os.environ.get('STREAM_FEATURES_PORT', '16574'))
    
    processor = SimpleProcessor(
        input_port=input_port,
        output_filtered_port=filtered_port,
        output_features_port=features_port,
        channels=8,
        sampling_rate=256
    )
    
    try:
        await processor.start()
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        await processor.stop()


if __name__ == "__main__":
    asyncio.run(main())
