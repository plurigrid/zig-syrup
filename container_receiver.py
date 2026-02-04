#!/usr/bin/env python3
"""
BCI Data Receiver and Processor for Apple Containerization
Phased Hypergraph Processing Pipeline for Real-time EEG

Phases:
1. Raw data ingestion & buffering
2. Filtering (bandpass 1-50Hz, notch 60Hz)
3. Feature extraction (band powers, Hjorth parameters)
4. Classification/state detection

Outputs:
- LSL output stream (downstream consumers)
- WebSocket server (real-time visualization)
- EDF+ file recording
"""

import asyncio
import json
import logging
import signal
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

import numpy as np
import websockets
from pylsl import StreamInlet, StreamInfo, StreamOutlet, resolve_byprop, resolve_stream

# Import processing modules
from processors.buffer import CircularBuffer
from processors.classifier import EEGClassifier
from processors.features import FeatureExtractor
from processors.filter import RealtimeFilter

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('/app/logs/bci_processor.log')
    ]
)
logger = logging.getLogger('BCI-Processor')


@dataclass
class ProcessingConfig:
    """Configuration for the BCI processing pipeline."""
    # Stream settings
    lsl_input_name: str = "OpenBCI"
    lsl_output_name: str = "BCI-Processed"
    tcp_host: str = "host.containers.internal"
    tcp_port: int = 16572
    
    # Processing parameters
    sample_rate: float = 250.0  # OpenBCI default
    buffer_size: int = 1000
    window_size: int = 250  # 1 second at 250Hz
    overlap: float = 0.5
    
    # Filter parameters
    lowcut: float = 1.0
    highcut: float = 50.0
    notch_freq: float = 60.0
    filter_order: int = 4
    
    # Output settings
    websocket_port: int = 8080
    health_port: int = 8081
    recording_dir: str = "/app/data/recordings"
    
    # Feature extraction
    bands: Dict[str, Tuple[float, float]] = field(default_factory=lambda: {
        'delta': (0.5, 4),
        'theta': (4, 8),
        'alpha': (8, 13),
        'beta': (13, 30),
        'gamma': (30, 50)
    })


class BCIDataProcessor:
    """
    Main BCI Data Processor implementing phased hypergraph processing pipeline.
    
    Phase 1: Raw data ingestion & buffering
    Phase 2: Filtering (bandpass 1-50Hz, notch 60Hz)  
    Phase 3: Feature extraction (band powers, Hjorth parameters)
    Phase 4: Classification/state detection
    """
    
    def __init__(self, config: ProcessingConfig):
        self.config = config
        self.running = False
        self.session_id = str(uuid.uuid4())[:8]
        
        # Phase 1: Buffering
        self.buffer = CircularBuffer(
            size=config.buffer_size,
            n_channels=8  # OpenBCI Cyton has 8 channels
        )
        
        # Phase 2: Filtering
        self.filter = RealtimeFilter(
            lowcut=config.lowcut,
            highcut=config.highcut,
            notch_freq=config.notch_freq,
            fs=config.sample_rate,
            order=config.filter_order
        )
        
        # Phase 3: Feature Extraction
        self.feature_extractor = FeatureExtractor(
            bands=config.bands,
            fs=config.sample_rate
        )
        
        # Phase 4: Classification
        self.classifier = EEGClassifier()
        
        # LSL streams
        self.inlet: Optional[StreamInlet] = None
        self.outlet: Optional[StreamOutlet] = None
        
        # WebSocket clients
        self.websocket_clients: set = set()
        
        # Recording
        self.recording_file: Optional[Path] = None
        self.recording_buffer: List[np.ndarray] = []
        
        # Statistics
        self.samples_processed = 0
        self.start_time: Optional[float] = None
        
        logger.info(f"BCI Processor initialized [session: {self.session_id}]")
        logger.info(f"Config: {config}")
    
    async def connect_lsl(self, timeout: float = 30.0) -> bool:
        """Connect to LSL input stream from host."""
        logger.info(f"Looking for LSL stream '{self.config.lsl_input_name}'...")
        
        try:
            # Resolve stream by name
            streams = resolve_byprop('name', self.config.lsl_input_name, timeout=timeout)
            
            if not streams:
                # Try resolving any EEG stream
                logger.info("No named stream found, looking for any EEG stream...")
                streams = resolve_stream('type', 'EEG', timeout=timeout)
            
            if not streams:
                logger.error("No LSL streams found")
                return False
            
            # Connect to first available stream
            self.inlet = StreamInlet(streams[0])
            
            # Get stream info
            info = self.inlet.info()
            logger.info(f"Connected to LSL stream:")
            logger.info(f"  Name: {info.name()}")
            logger.info(f"  Type: {info.type()}")
            logger.info(f"  Channels: {info.channel_count()}")
            logger.info(f"  Sample Rate: {info.nominal_srate()}")
            
            # Update config with actual stream parameters
            self.config.sample_rate = info.nominal_srate() or 250.0
            
            return True
            
        except Exception as e:
            logger.error(f"Failed to connect to LSL: {e}")
            return False
    
    def create_output_stream(self) -> bool:
        """Create LSL output stream for processed data."""
        try:
            # Create stream info for processed EEG
            info = StreamInfo(
                name=self.config.lsl_output_name,
                type='EEG-Processed',
                channel_count=8,
                nominal_srate=self.config.sample_rate,
                channel_format='float32',
                source_id=f'bci-processor-{self.session_id}'
            )
            
            # Add metadata
            desc = info.desc()
            desc.append_child_value('manufacturer', 'BCI-Processor')
            desc.append_child_value('session', self.session_id)
            
            # Add channel labels
            channels = desc.append_child('channels')
            for i in range(8):
                ch = channels.append_child('channel')
                ch.append_child_value('label', f'Ch{i+1}')
                ch.append_child_value('unit', 'microvolts')
            
            self.outlet = StreamOutlet(info)
            logger.info(f"Created LSL output stream: {self.config.lsl_output_name}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to create output stream: {e}")
            return False
    
    async def websocket_handler(self, websocket, path):
        """Handle WebSocket connections for real-time visualization."""
        self.websocket_clients.add(websocket)
        client_id = id(websocket)
        logger.info(f"WebSocket client {client_id} connected")
        
        try:
            await websocket.wait_closed()
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            self.websocket_clients.discard(websocket)
            logger.info(f"WebSocket client {client_id} disconnected")
    
    async def broadcast_to_websockets(self, data: Dict):
        """Broadcast processed data to all connected WebSocket clients."""
        if not self.websocket_clients:
            return
        
        message = json.dumps(data)
        disconnected = set()
        
        for websocket in self.websocket_clients:
            try:
                await websocket.send(message)
            except websockets.exceptions.ConnectionClosed:
                disconnected.add(websocket)
            except Exception as e:
                logger.warning(f"WebSocket send error: {e}")
                disconnected.add(websocket)
        
        # Remove disconnected clients
        self.websocket_clients -= disconnected
    
    async def start_websocket_server(self):
        """Start WebSocket server for real-time visualization."""
        logger.info(f"Starting WebSocket server on port {self.config.websocket_port}")
        async with websockets.serve(
            self.websocket_handler, 
            '0.0.0.0', 
            self.config.websocket_port,
            ping_interval=20,
            ping_timeout=10
        ):
            await asyncio.Future()  # Run forever
    
    async def health_server(self):
        """Simple HTTP health check server."""
        from aiohttp import web
        
        async def health_handler(request):
            status = {
                'status': 'healthy' if self.running else 'starting',
                'session': self.session_id,
                'samples_processed': self.samples_processed,
                'uptime': time.time() - self.start_time if self.start_time else 0,
                'websocket_clients': len(self.websocket_clients),
                'phase': 'running' if self.running else 'initializing'
            }
            return web.json_response(status)
        
        app = web.Application()
        app.router.add_get('/health', health_handler)
        app.router.add_get('/', health_handler)
        
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, '0.0.0.0', self.config.health_port)
        
        logger.info(f"Health server started on port {self.config.health_port}")
        await site.start()
    
    def start_recording(self, filename: Optional[str] = None):
        """Start recording to EDF+ file."""
        from pyedflib import highlevel
        
        if filename is None:
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            filename = f"bci_recording_{self.session_id}_{timestamp}.edf"
        
        self.recording_file = Path(self.config.recording_dir) / filename
        self.recording_buffer = []
        
        logger.info(f"Started recording to {self.recording_file}")
    
    def stop_recording(self):
        """Stop recording and save EDF+ file."""
        if not self.recording_file or not self.recording_buffer:
            return
        
        try:
            from pyedflib import highlevel
            
            # Convert buffer to numpy array
            data = np.array(self.recording_buffer)
            
            # Channel labels
            channel_names = [f'Ch{i+1}' for i in range(data.shape[1])]
            
            # Write EDF file
            highlevel.write_edf(
                str(self.recording_file),
                data.T,
                fs=self.config.sample_rate,
                ch_names=channel_names
            )
            
            logger.info(f"Saved recording: {self.recording_file}")
            
        except Exception as e:
            logger.error(f"Failed to save recording: {e}")
        finally:
            self.recording_file = None
            self.recording_buffer = []
    
    async def process_sample(self, sample: np.ndarray, timestamp: float):
        """Process a single sample through the phased pipeline."""
        
        # Phase 1: Buffering
        self.buffer.push(sample)
        
        # Phase 2: Filtering (when we have enough data)
        if self.buffer.ready:
            window = self.buffer.get_window(self.config.window_size)
            filtered = self.filter.process(window)
            
            # Phase 3: Feature Extraction
            features = self.feature_extractor.extract(filtered)
            
            # Phase 4: Classification
            classification = self.classifier.classify(features)
            
            # Prepare output
            output = {
                'timestamp': timestamp,
                'session': self.session_id,
                'sample_count': self.samples_processed,
                'raw_sample': sample.tolist(),
                'features': features,
                'classification': classification
            }
            
            # Send to LSL output
            if self.outlet:
                self.outlet.push_sample(filtered[-1].astype(np.float32))
            
            # Broadcast to WebSockets
            await self.broadcast_to_websockets(output)
            
            # Record if enabled
            if self.recording_file is not None:
                self.recording_buffer.append(sample)
            
            return output
        
        return None
    
    async def processing_loop(self):
        """Main processing loop."""
        logger.info("Starting processing loop...")
        self.start_time = time.time()
        self.running = True
        
        while self.running:
            try:
                if self.inlet is None:
                    logger.error("No LSL inlet available")
                    await asyncio.sleep(1)
                    continue
                
                # Pull sample from LSL
                sample, timestamp = self.inlet.pull_sample(timeout=0.01)
                
                if sample is not None:
                    sample = np.array(sample)
                    await self.process_sample(sample, timestamp)
                    self.samples_processed += 1
                    
                    # Log progress periodically
                    if self.samples_processed % 1000 == 0:
                        elapsed = time.time() - self.start_time
                        rate = self.samples_processed / elapsed
                        logger.info(f"Processed {self.samples_processed} samples @ {rate:.1f} Hz")
                
                else:
                    # No data available, yield control
                    await asyncio.sleep(0.001)
                    
            except Exception as e:
                logger.error(f"Processing error: {e}")
                await asyncio.sleep(0.1)
    
    async def run(self):
        """Run the complete BCI processing system."""
        logger.info("=" * 60)
        logger.info("BCI Data Processor Starting")
        logger.info("=" * 60)
        
        # Connect to input stream
        connected = await self.connect_lsl(timeout=60.0)
        if not connected:
            logger.error("Failed to connect to LSL stream. Exiting.")
            return False
        
        # Create output stream
        if not self.create_output_stream():
            logger.warning("Failed to create output stream, continuing...")
        
        # Start services
        tasks = [
            asyncio.create_task(self.health_server()),
            asyncio.create_task(self.start_websocket_server()),
            asyncio.create_task(self.processing_loop())
        ]
        
        # Wait for all tasks
        try:
            await asyncio.gather(*tasks)
        except asyncio.CancelledError:
            logger.info("Tasks cancelled, shutting down...")
        
        return True
    
    def shutdown(self):
        """Graceful shutdown."""
        logger.info("Shutting down BCI Processor...")
        self.running = False
        
        # Stop recording if active
        if self.recording_file:
            self.stop_recording()
        
        # Close LSL streams
        if self.inlet:
            self.inlet.close_stream()
        
        logger.info(f"Total samples processed: {self.samples_processed}")
        logger.info("Shutdown complete")


async def main():
    """Main entry point."""
    # Create default configuration
    config = ProcessingConfig()
    
    # Allow environment variable overrides
    if 'LSL_INPUT_NAME' in os.environ:
        config.lsl_input_name = os.environ['LSL_INPUT_NAME']
    if 'LSL_OUTPUT_NAME' in os.environ:
        config.lsl_output_name = os.environ['LSL_OUTPUT_NAME']
    if 'WEBSOCKET_PORT' in os.environ:
        config.websocket_port = int(os.environ['WEBSOCKET_PORT'])
    
    # Create processor
    processor = BCIDataProcessor(config)
    
    # Setup signal handlers
    def signal_handler(sig, frame):
        logger.info(f"Received signal {sig}")
        processor.shutdown()
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Run processor
    try:
        success = await processor.run()
        sys.exit(0 if success else 1)
    except Exception as e:
        logger.exception("Fatal error in main loop")
        sys.exit(1)


if __name__ == '__main__':
    import os
    asyncio.run(main())
