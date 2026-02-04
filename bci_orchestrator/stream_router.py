#!/usr/bin/env python3
"""
Stream Router for BCI Hypergraph Orchestration

Receives single input stream and multicasts to multiple consumers (hypergraph edges).
Implements backpressure handling and stream synchronization for multi-modal data.
"""

import asyncio
import logging
import struct
import json
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Callable, Any, Tuple
from enum import Enum, auto
from collections import defaultdict, deque
import numpy as np
from datetime import datetime


class BackpressureStrategy(Enum):
    """Backpressure handling strategies"""
    DROP_NEWEST = auto()      # Drop newest data when buffer full
    DROP_OLDEST = auto()      # Drop oldest data when buffer full
    BLOCK = auto()            # Block producer until space available
    THROTTLE = auto()         # Reduce producer rate


class StreamProtocol(Enum):
    """Supported stream protocols"""
    LSL = "lsl"
    TCP = "tcp"
    WEBSOCKET = "websocket"
    UDP = "udp"


@dataclass
class StreamPacket:
    """Represents a single packet in a data stream"""
    timestamp: float
    sequence_num: int
    data: bytes
    metadata: Dict[str, Any] = field(default_factory=dict)
    
    def to_bytes(self) -> bytes:
        """Serialize packet to bytes"""
        header = struct.pack('!dQ', self.timestamp, self.sequence_num)
        meta_bytes = json.dumps(self.metadata).encode('utf-8')
        meta_len = struct.pack('!I', len(meta_bytes))
        return header + meta_len + meta_bytes + self.data
    
    @classmethod
    def from_bytes(cls, data: bytes) -> Tuple['StreamPacket', bytes]:
        """Deserialize packet from bytes, returns packet and remaining data"""
        if len(data) < 16:
            raise ValueError("Insufficient data for header")
        
        timestamp, sequence_num = struct.unpack('!dQ', data[:16])
        offset = 16
        
        if len(data) < offset + 4:
            raise ValueError("Insufficient data for metadata length")
        
        meta_len = struct.unpack('!I', data[offset:offset+4])[0]
        offset += 4
        
        if len(data) < offset + meta_len:
            raise ValueError("Insufficient data for metadata")
        
        metadata = json.loads(data[offset:offset+meta_len].decode('utf-8'))
        offset += meta_len
        
        packet_data = data[offset:]
        
        return cls(timestamp, sequence_num, packet_data, metadata), b''


@dataclass
class Consumer:
    """Represents a stream consumer"""
    id: str
    protocol: StreamProtocol
    host: str
    port: int
    buffer_size: int = 1024
    backpressure: BackpressureStrategy = BackpressureStrategy.DROP_OLDEST
    priority: int = 0
    
    # Runtime state
    queue: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(maxsize=1024))
    connection: Optional[Any] = None
    bytes_sent: int = 0
    packets_sent: int = 0
    dropped_packets: int = 0
    latency_ms: float = 0.0
    connected: bool = False
    last_activity: Optional[float] = None


@dataclass
class StreamRouterConfig:
    """Configuration for a stream router"""
    name: str
    protocol: StreamProtocol
    port: int
    buffer_size: int = 1024
    multicast: bool = True
    backpressure: BackpressureStrategy = BackpressureStrategy.DROP_OLDEST
    max_latency_ms: float = 50.0
    sync_enabled: bool = True


class StreamRouter:
    """
    Stream Router handles multicast distribution of data streams.
    
    Features:
    - Single input to multiple outputs (hypergraph edges)
    - Backpressure handling per consumer
    - Stream synchronization for multi-modal data
    - Protocol abstraction (LSL, TCP, WebSocket)
    """
    
    def __init__(self, config: StreamRouterConfig):
        self.config = config
        self.logger = logging.getLogger(f'StreamRouter.{config.name}')
        
        # Consumer management
        self.consumers: Dict[str, Consumer] = {}
        self.consumer_groups: Dict[str, Set[str]] = defaultdict(set)
        
        # Server state
        self.server: Optional[asyncio.Server] = None
        self.websocket_server: Optional[Any] = None
        self.running = False
        
        # Input handling
        self.input_buffer: deque = deque(maxlen=config.buffer_size)
        self.sequence_counter = 0
        
        # Synchronization
        self.sync_buffer: Dict[str, List[StreamPacket]] = defaultdict(list)
        self.sync_timestamps: Dict[str, float] = {}
        self.sync_window_ms: float = 10.0  # Sync window for multi-modal
        
        # Metrics
        self.metrics = {
            'packets_received': 0,
            'packets_routed': 0,
            'packets_dropped': 0,
            'bytes_received': 0,
            'bytes_routed': 0,
            'consumer_count': 0,
            'avg_latency_ms': 0.0,
            'max_latency_ms': 0.0
        }
        
        # Rate limiting
        self.rate_limiter = asyncio.Semaphore(1000)  # Max 1000 concurrent sends
        
        self._shutdown_event = asyncio.Event()
    
    async def start(self):
        """Start the stream router"""
        self.running = True
        
        if self.config.protocol == StreamProtocol.TCP:
            self.server = await asyncio.start_server(
                self._handle_tcp_connection,
                '0.0.0.0',
                self.config.port
            )
            self.logger.info(f"TCP StreamRouter '{self.config.name}' listening on port {self.config.port}")
        
        elif self.config.protocol == StreamProtocol.WEBSOCKET:
            try:
                import websockets
                self.websocket_server = await websockets.serve(
                    self._handle_websocket,
                    '0.0.0.0',
                    self.config.port
                )
                self.logger.info(f"WebSocket StreamRouter '{self.config.name}' listening on port {self.config.port}")
            except ImportError:
                self.logger.error("websockets library not installed")
                raise
        
        elif self.config.protocol == StreamProtocol.LSL:
            # LSL uses pylsl for input
            asyncio.create_task(self._lsl_input_loop())
            self.logger.info(f"LSL StreamRouter '{self.config.name}' started")
        
        elif self.config.protocol == StreamProtocol.UDP:
            # UDP multicast
            self.server = await asyncio.start_server(
                self._handle_udp_input,
                '0.0.0.0',
                self.config.port
            )
            self.logger.info(f"UDP StreamRouter '{self.config.name}' listening on port {self.config.port}")
        
        # Start distribution loop
        asyncio.create_task(self._distribution_loop())
        asyncio.create_task(self._metrics_loop())
        
        if self.config.sync_enabled:
            asyncio.create_task(self._synchronization_loop())
    
    async def stop(self):
        """Stop the stream router"""
        self.running = False
        self._shutdown_event.set()
        
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        
        if self.websocket_server:
            self.websocket_server.close()
            await self.websocket_server.wait_closed()
        
        # Disconnect all consumers
        for consumer in self.consumers.values():
            await self._disconnect_consumer(consumer)
        
        self.logger.info(f"StreamRouter '{self.config.name}' stopped")
    
    def add_consumer(self, consumer: Consumer) -> str:
        """Add a consumer to the router"""
        consumer_id = f"{consumer.host}:{consumer.port}_{id(consumer)}"
        consumer.id = consumer_id
        self.consumers[consumer_id] = consumer
        self.metrics['consumer_count'] = len(self.consumers)
        
        # Start consumer connection
        asyncio.create_task(self._connect_consumer(consumer))
        
        self.logger.info(f"Added consumer {consumer_id} (protocol: {consumer.protocol.value})")
        return consumer_id
    
    def remove_consumer(self, consumer_id: str):
        """Remove a consumer"""
        if consumer_id in self.consumers:
            consumer = self.consumers[consumer_id]
            asyncio.create_task(self._disconnect_consumer(consumer))
            del self.consumers[consumer_id]
            self.metrics['consumer_count'] = len(self.consumers)
            self.logger.info(f"Removed consumer {consumer_id}")
    
    async def _connect_consumer(self, consumer: Consumer):
        """Establish connection to a consumer"""
        try:
            if consumer.protocol in (StreamProtocol.TCP, StreamProtocol.UDP):
                reader, writer = await asyncio.wait_for(
                    asyncio.open_connection(consumer.host, consumer.port),
                    timeout=5.0
                )
                consumer.connection = (reader, writer)
                consumer.connected = True
                consumer.last_activity = asyncio.get_event_loop().time()
                
                # Start consumer writer loop
                asyncio.create_task(self._consumer_writer_loop(consumer))
                
            elif consumer.protocol == StreamProtocol.WEBSOCKET:
                try:
                    import websockets
                    uri = f"ws://{consumer.host}:{consumer.port}"
                    websocket = await websockets.connect(uri)
                    consumer.connection = websocket
                    consumer.connected = True
                    consumer.last_activity = asyncio.get_event_loop().time()
                except ImportError:
                    self.logger.error("websockets library not installed")
                    
            self.logger.info(f"Connected to consumer {consumer.id}")
            
        except Exception as e:
            self.logger.error(f"Failed to connect to consumer {consumer.id}: {e}")
            consumer.connected = False
    
    async def _disconnect_consumer(self, consumer: Consumer):
        """Disconnect a consumer"""
        consumer.connected = False
        
        try:
            if consumer.protocol in (StreamProtocol.TCP, StreamProtocol.UDP):
                if consumer.connection:
                    _, writer = consumer.connection
                    writer.close()
                    await writer.wait_closed()
            elif consumer.protocol == StreamProtocol.WEBSOCKET:
                if consumer.connection:
                    await consumer.connection.close()
        except Exception as e:
            self.logger.error(f"Error disconnecting consumer {consumer.id}: {e}")
    
    async def _handle_tcp_connection(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        """Handle incoming TCP connection (input)"""
        addr = writer.get_extra_info('peername')
        self.logger.info(f"TCP input connection from {addr}")
        
        try:
            while self.running:
                # Read packet header
                header_data = await reader.readexactly(16)
                if not header_data:
                    break
                
                timestamp, sequence_num = struct.unpack('!dQ', header_data)
                
                # Read metadata length
                meta_len_data = await reader.readexactly(4)
                meta_len = struct.unpack('!I', meta_len_data)[0]
                
                # Read metadata
                meta_data = await reader.readexactly(meta_len)
                metadata = json.loads(meta_data.decode('utf-8'))
                
                # Read actual data (variable length, look for delimiter or fixed size)
                # For now, read available data
                data = await reader.read(4096)
                
                packet = StreamPacket(
                    timestamp=timestamp,
                    sequence_num=sequence_num,
                    data=data,
                    metadata=metadata
                )
                
                await self._route_packet(packet)
                
        except asyncio.IncompleteReadError:
            self.logger.info(f"Input connection from {addr} closed")
        except Exception as e:
            self.logger.error(f"Error handling TCP input: {e}")
        finally:
            writer.close()
            await writer.wait_closed()
    
    async def _handle_websocket(self, websocket, path):
        """Handle WebSocket connection"""
        self.logger.info(f"WebSocket connection from {websocket.remote_address}")
        
        try:
            async for message in websocket:
                # Parse message
                packet = StreamPacket(
                    timestamp=asyncio.get_event_loop().time(),
                    sequence_num=self._next_sequence(),
                    data=message if isinstance(message, bytes) else message.encode(),
                    metadata={'protocol': 'websocket'}
                )
                
                await self._route_packet(packet)
                
        except Exception as e:
            self.logger.error(f"WebSocket error: {e}")
    
    async def _lsl_input_loop(self):
        """Handle LSL input stream"""
        try:
            from pylsl import StreamInlet, resolve_stream
            
            self.logger.info("Resolving LSL stream...")
            streams = resolve_stream('name', self.config.name)
            
            if not streams:
                self.logger.error(f"No LSL stream found with name '{self.config.name}'")
                return
            
            inlet = StreamInlet(streams[0])
            self.logger.info("LSL stream connected")
            
            while self.running:
                sample, timestamp = inlet.pull_sample(timeout=0.0)
                if sample:
                    # Convert sample to bytes
                    data = np.array(sample).tobytes()
                    
                    packet = StreamPacket(
                        timestamp=timestamp,
                        sequence_num=self._next_sequence(),
                        data=data,
                        metadata={'source': 'lsl', 'channels': len(sample)}
                    )
                    
                    await self._route_packet(packet)
                else:
                    await asyncio.sleep(0.001)  # Small sleep to prevent busy waiting
                    
        except ImportError:
            self.logger.error("pylsl not installed. Install with: pip install pylsl")
        except Exception as e:
            self.logger.error(f"LSL input error: {e}")
    
    async def _handle_udp_input(self, data: bytes, addr: Tuple[str, int]):
        """Handle UDP input"""
        packet = StreamPacket(
            timestamp=asyncio.get_event_loop().time(),
            sequence_num=self._next_sequence(),
            data=data,
            metadata={'source_addr': addr}
        )
        
        await self._route_packet(packet)
    
    async def _route_packet(self, packet: StreamPacket):
        """Route a packet to all consumers"""
        self.sequence_counter += 1
        packet.sequence_num = self.sequence_counter
        
        self.metrics['packets_received'] += 1
        self.metrics['bytes_received'] += len(packet.data)
        
        # Add to synchronization buffer if enabled
        if self.config.sync_enabled:
            self.sync_buffer[self.config.name].append(packet)
        
        # Route to each consumer
        for consumer in self.consumers.values():
            if not consumer.connected:
                continue
            
            success = await self._send_to_consumer(consumer, packet)
            if success:
                self.metrics['packets_routed'] += 1
                self.metrics['bytes_routed'] += len(packet.data)
            else:
                self.metrics['packets_dropped'] += 1
    
    async def _send_to_consumer(self, consumer: Consumer, packet: StreamPacket) -> bool:
        """Send packet to a single consumer with backpressure handling"""
        try:
            # Check queue size based on backpressure strategy
            queue_size = consumer.queue.qsize()
            
            if queue_size >= consumer.buffer_size:
                if consumer.backpressure == BackpressureStrategy.DROP_OLDEST:
                    # Remove oldest packet
                    try:
                        consumer.queue.get_nowait()
                        consumer.dropped_packets += 1
                    except asyncio.QueueEmpty:
                        pass
                elif consumer.backpressure == BackpressureStrategy.DROP_NEWEST:
                    # Drop this packet
                    consumer.dropped_packets += 1
                    return False
                elif consumer.backpressure == BackpressureStrategy.BLOCK:
                    # Wait for space (will block producer)
                    pass
                elif consumer.backpressure == BackpressureStrategy.THROTTLE:
                    # Apply dynamic throttling
                    await asyncio.sleep(0.001 * queue_size)
            
            # Add packet to consumer queue
            await consumer.queue.put(packet)
            return True
            
        except Exception as e:
            self.logger.debug(f"Failed to queue packet for {consumer.id}: {e}")
            return False
    
    async def _consumer_writer_loop(self, consumer: Consumer):
        """Write packets to a consumer connection"""
        while consumer.connected and self.running:
            try:
                packet = await asyncio.wait_for(
                    consumer.queue.get(),
                    timeout=1.0
                )
                
                start_time = asyncio.get_event_loop().time()
                
                if consumer.protocol in (StreamProtocol.TCP, StreamProtocol.UDP):
                    _, writer = consumer.connection
                    writer.write(packet.to_bytes())
                    await writer.drain()
                    
                elif consumer.protocol == StreamProtocol.WEBSOCKET:
                    await consumer.connection.send(packet.data)
                
                # Update metrics
                consumer.packets_sent += 1
                consumer.bytes_sent += len(packet.data)
                consumer.last_activity = asyncio.get_event_loop().time()
                
                latency = (asyncio.get_event_loop().time() - start_time) * 1000
                consumer.latency_ms = latency
                
            except asyncio.TimeoutError:
                continue
            except Exception as e:
                self.logger.error(f"Error writing to consumer {consumer.id}: {e}")
                consumer.connected = False
                break
    
    async def _distribution_loop(self):
        """Main distribution loop for buffered data"""
        while self.running and not self._shutdown_event.is_set():
            await asyncio.sleep(0.001)  # Small sleep to prevent busy waiting
    
    async def _synchronization_loop(self):
        """Synchronize multi-modal data streams"""
        while self.running and not self._shutdown_event.is_set():
            try:
                await self._synchronize_streams()
                await asyncio.sleep(self.sync_window_ms / 1000)
            except Exception as e:
                self.logger.error(f"Synchronization error: {e}")
    
    async def _synchronize_streams(self):
        """Synchronize packets from different streams within time window"""
        if not self.sync_buffer:
            return
        
        # Find packets within sync window
        current_time = asyncio.get_event_loop().time()
        sync_threshold = current_time - (self.sync_window_ms / 1000)
        
        synchronized_groups = []
        
        for stream_name, packets in list(self.sync_buffer.items()):
            # Remove old packets
            packets[:] = [p for p in packets if p.timestamp >= sync_threshold]
        
        # Group packets by timestamp proximity
        # This is a simplified version - real implementation would use more sophisticated matching
    
    async def _metrics_loop(self):
        """Periodically update and log metrics"""
        while self.running and not self._shutdown_event.is_set():
            await asyncio.sleep(5.0)
            
            # Calculate aggregate metrics
            total_latency = sum(c.latency_ms for c in self.consumers.values())
            if self.consumers:
                self.metrics['avg_latency_ms'] = total_latency / len(self.consumers)
                self.metrics['max_latency_ms'] = max(
                    (c.latency_ms for c in self.consumers.values()),
                    default=0
                )
            
            self.logger.debug(f"Router '{self.config.name}' metrics: {self.metrics}")
    
    def _next_sequence(self) -> int:
        """Get next sequence number"""
        self.sequence_counter += 1
        return self.sequence_counter
    
    def get_consumer_stats(self) -> Dict[str, Any]:
        """Get statistics for all consumers"""
        return {
            cid: {
                'packets_sent': c.packets_sent,
                'bytes_sent': c.bytes_sent,
                'dropped_packets': c.dropped_packets,
                'latency_ms': c.latency_ms,
                'connected': c.connected,
                'queue_size': c.queue.qsize()
            }
            for cid, c in self.consumers.items()
        }
    
    def get_metrics(self) -> Dict[str, Any]:
        """Get router metrics"""
        return dict(self.metrics)


class MultiStreamRouter:
    """Manages multiple stream routers for the entire pipeline"""
    
    def __init__(self):
        self.routers: Dict[str, StreamRouter] = {}
        self.logger = logging.getLogger('MultiStreamRouter')
    
    def create_router(self, config: StreamRouterConfig) -> StreamRouter:
        """Create and register a new stream router"""
        router = StreamRouter(config)
        self.routers[config.name] = router
        return router
    
    async def start_all(self):
        """Start all routers"""
        for name, router in self.routers.items():
            await router.start()
            self.logger.info(f"Started router: {name}")
    
    async def stop_all(self):
        """Stop all routers"""
        for name, router in self.routers.items():
            await router.stop()
            self.logger.info(f"Stopped router: {name}")
    
    def get_router(self, name: str) -> Optional[StreamRouter]:
        """Get router by name"""
        return self.routers.get(name)
    
    def connect_routers(self, source_name: str, target_name: str):
        """Connect two routers (fan-out)"""
        source = self.routers.get(source_name)
        target = self.routers.get(target_name)
        
        if not source or not target:
            raise ValueError(f"Router not found: {source_name} or {target_name}")
        
        # Create consumer in source that feeds into target
        consumer = Consumer(
            id=f"bridge_{source_name}_to_{target_name}",
            protocol=target.config.protocol,
            host='localhost',
            port=target.config.port,
            backpressure=BackpressureStrategy.DROP_OLDEST
        )
        
        source.add_consumer(consumer)
        self.logger.info(f"Connected router {source_name} -> {target_name}")


async def example_usage():
    """Example usage of stream router"""
    logging.basicConfig(level=logging.INFO)
    
    # Create router for raw EEG
    config = StreamRouterConfig(
        name="raw_eeg",
        protocol=StreamProtocol.TCP,
        port=16571,
        multicast=True,
        backpressure=BackpressureStrategy.DROP_OLDEST
    )
    
    router = StreamRouter(config)
    
    # Add consumers
    consumer1 = Consumer(
        id="filter_processor",
        protocol=StreamProtocol.TCP,
        host="localhost",
        port=16573,
        backpressure=BackpressureStrategy.DROP_OLDEST
    )
    
    consumer2 = Consumer(
        id="visualizer",
        protocol=StreamProtocol.TCP,
        host="localhost",
        port=16577,
        backpressure=BackpressureStrategy.THROTTLE
    )
    
    router.add_consumer(consumer1)
    router.add_consumer(consumer2)
    
    # Start router
    await router.start()
    
    try:
        while True:
            await asyncio.sleep(1)
            metrics = router.get_metrics()
            print(f"Router metrics: {metrics}")
    except KeyboardInterrupt:
        pass
    finally:
        await router.stop()


if __name__ == "__main__":
    asyncio.run(example_usage())
