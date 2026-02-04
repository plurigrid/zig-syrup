#!/usr/bin/env python3
"""
Hypergraph Orchestrator for BCI Processing Pipeline

Manages data flow between acquisition -> processing -> analysis phases
using a hypergraph structure where:
- Nodes represent processing phases (host or container)
- Hyperedges represent multicast data streams
"""

import asyncio
import logging
import subprocess
import yaml
import json
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Any, Callable
from enum import Enum, auto
from pathlib import Path
from collections import defaultdict
import signal


class PhaseState(Enum):
    """States for pipeline phases"""
    PENDING = auto()
    STARTING = auto()
    RUNNING = auto()
    HEALTHY = auto()
    DEGRADED = auto()
    STOPPING = auto()
    STOPPED = auto()
    FAILED = auto()
    RESTARTING = auto()


class StreamProtocol(Enum):
    """Supported stream protocols"""
    LSL = "lsl"
    TCP = "tcp"
    WEBSOCKET = "websocket"


@dataclass
class StreamConfig:
    """Configuration for a data stream"""
    name: str
    protocol: StreamProtocol
    port: int
    format: str
    channels: Optional[int] = None
    sampling_rate: Optional[int] = None
    buffer_size: int = 1024
    schema: Optional[str] = None


@dataclass
class PhaseConfig:
    """Configuration for a pipeline phase"""
    name: str
    phase_type: str  # 'host_process' or 'container'
    command: Optional[str] = None
    image: Optional[str] = None
    inputs: List[str] = field(default_factory=list)
    outputs: List[str] = field(default_factory=list)
    containerization: Optional[str] = None
    resources: Dict[str, Any] = field(default_factory=dict)
    replicas: int = 1
    scaling: Optional[Dict[str, Any]] = None
    volumes: List[str] = field(default_factory=list)
    health_check: Optional[Dict[str, Any]] = None


@dataclass
class Hyperedge:
    """Hyperedge connecting multiple nodes (multicast)"""
    name: str
    source: str
    targets: List[str]
    stream: Optional[str] = None
    streams: List[str] = field(default_factory=list)
    multicast: bool = True
    qos: str = "best_effort"
    
    def __post_init__(self):
        if self.stream:
            self.streams = [self.stream]


@dataclass
class PhaseInstance:
    """Runtime instance of a phase"""
    config: PhaseConfig
    replica_id: int
    state: PhaseState = PhaseState.PENDING
    process: Optional[subprocess.Popen] = None
    container_id: Optional[str] = None
    pid: Optional[int] = None
    start_time: Optional[float] = None
    restart_count: int = 0
    last_restart: Optional[float] = None
    health_status: Dict[str, Any] = field(default_factory=dict)
    metrics: Dict[str, Any] = field(default_factory=dict)


class HypergraphOrchestrator:
    """
    Main orchestrator managing the BCI pipeline as a hypergraph.
    
    Nodes = Processing phases (acquisition, preprocessing, etc.)
    Hyperedges = Data streams connecting multiple phases (multicast)
    """
    
    def __init__(self, config_path: str = "hypergraph_config.yaml"):
        self.config_path = Path(config_path)
        self.config: Dict[str, Any] = {}
        self.phases: Dict[str, PhaseConfig] = {}
        self.streams: Dict[str, StreamConfig] = {}
        self.hyperedges: Dict[str, Hyperedge] = {}
        self.instances: Dict[str, List[PhaseInstance]] = defaultdict(list)
        self.state: Dict[str, PhaseState] = {}
        self._running = False
        self._shutdown_event = asyncio.Event()
        self._lock = asyncio.Lock()
        self._callbacks: Dict[PhaseState, List[Callable]] = defaultdict(list)
        
        # Apple Containerization CLI
        self.container_cli = "container"
        
        self._setup_logging()
        self._load_config()
    
    def _setup_logging(self):
        """Configure logging"""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
        )
        self.logger = logging.getLogger('HypergraphOrchestrator')
    
    def _load_config(self):
        """Load configuration from YAML file"""
        if not self.config_path.exists():
            raise FileNotFoundError(f"Config file not found: {self.config_path}")
        
        with open(self.config_path, 'r') as f:
            self.config = yaml.safe_load(f)
        
        # Parse phases
        for phase_dict in self.config.get('phases', []):
            phase = PhaseConfig(
                name=phase_dict['name'],
                phase_type=phase_dict['type'],
                command=phase_dict.get('command'),
                image=phase_dict.get('image'),
                inputs=phase_dict.get('inputs', []),
                outputs=phase_dict.get('outputs', []),
                containerization=phase_dict.get('containerization'),
                resources=phase_dict.get('resources', {}),
                replicas=phase_dict.get('replicas', 1),
                scaling=phase_dict.get('scaling'),
                volumes=phase_dict.get('volumes', []),
                health_check=phase_dict.get('health_check')
            )
            self.phases[phase.name] = phase
            self.state[phase.name] = PhaseState.PENDING
        
        # Parse streams
        for name, stream_dict in self.config.get('streams', {}).items():
            protocol = StreamProtocol(stream_dict['protocol'])
            stream = StreamConfig(
                name=name,
                protocol=protocol,
                port=stream_dict['port'],
                format=stream_dict['format'],
                channels=stream_dict.get('channels'),
                sampling_rate=stream_dict.get('sampling_rate'),
                buffer_size=stream_dict.get('buffer_size', 1024),
                schema=stream_dict.get('schema')
            )
            self.streams[name] = stream
        
        # Parse hyperedges
        for edge_dict in self.config.get('hyperedges', []):
            edge = Hyperedge(
                name=edge_dict['name'],
                source=edge_dict['source'],
                targets=edge_dict['targets'],
                stream=edge_dict.get('stream'),
                streams=edge_dict.get('streams', []),
                multicast=edge_dict.get('multicast', True),
                qos=edge_dict.get('qos', 'best_effort')
            )
            self.hyperedges[edge.name] = edge
        
        self.logger.info(f"Loaded {len(self.phases)} phases, {len(self.streams)} streams, {len(self.hyperedges)} hyperedges")
    
    def get_adjacency(self) -> Dict[str, List[str]]:
        """
        Build adjacency list from hypergraph structure.
        Returns mapping from phase -> list of downstream phases.
        """
        adjacency = defaultdict(list)
        for edge in self.hyperedges.values():
            for target in edge.targets:
                if target not in adjacency[edge.source]:
                    adjacency[edge.source].append(target)
        return dict(adjacency)
    
    def get_reverse_adjacency(self) -> Dict[str, List[str]]:
        """
        Build reverse adjacency (upstream dependencies).
        """
        reverse_adj = defaultdict(list)
        for edge in self.hyperedges.values():
            for target in edge.targets:
                reverse_adj[target].append(edge.source)
        return dict(reverse_adj)
    
    def get_stream_consumers(self, stream_name: str) -> List[str]:
        """Get all phases that consume a specific stream"""
        consumers = []
        for edge in self.hyperedges.values():
            if stream_name in edge.streams:
                consumers.extend(edge.targets)
        return consumers
    
    def get_stream_producer(self, stream_name: str) -> Optional[str]:
        """Get the phase that produces a specific stream"""
        for edge in self.hyperedges.values():
            if stream_name in edge.streams:
                return edge.source
        return None
    
    async def start_phase(self, phase_name: str, replica_id: int = 0) -> PhaseInstance:
        """Start a single phase instance"""
        async with self._lock:
            phase = self.phases.get(phase_name)
            if not phase:
                raise ValueError(f"Unknown phase: {phase_name}")
            
            instance = PhaseInstance(
                config=phase,
                replica_id=replica_id,
                state=PhaseState.STARTING
            )
            
            instance_id = f"{phase_name}_{replica_id}"
            self.instances[phase_name].append(instance)
            self.state[phase_name] = PhaseState.STARTING
            
            try:
                if phase.phase_type == 'host_process':
                    await self._start_host_process(instance)
                elif phase.phase_type == 'container':
                    await self._start_container(instance)
                else:
                    raise ValueError(f"Unknown phase type: {phase.phase_type}")
                
                instance.state = PhaseState.RUNNING
                instance.start_time = time.time()
                self.state[phase_name] = PhaseState.RUNNING
                
                self.logger.info(f"Started {instance_id} (PID: {instance.pid}, Container: {instance.container_id})")
                
                # Trigger callbacks
                await self._trigger_callbacks(PhaseState.RUNNING, phase_name, instance)
                
            except Exception as e:
                instance.state = PhaseState.FAILED
                self.state[phase_name] = PhaseState.FAILED
                self.logger.error(f"Failed to start {instance_id}: {e}")
                await self._trigger_callbacks(PhaseState.FAILED, phase_name, instance)
                raise
            
            return instance
    
    async def _start_host_process(self, instance: PhaseInstance):
        """Start a host process phase"""
        phase = instance.config
        
        # Set up environment with stream endpoints
        env = {
            **os.environ,
            'PHASE_NAME': phase.name,
            'REPLICA_ID': str(instance.replica_id),
            'OUTPUT_STREAMS': json.dumps(phase.outputs),
            'INPUT_STREAMS': json.dumps(phase.inputs)
        }
        
        # Add stream endpoint info
        for stream_name in phase.outputs + phase.inputs:
            if stream_name in self.streams:
                stream = self.streams[stream_name]
                env[f'STREAM_{stream_name.upper()}_PORT'] = str(stream.port)
                env[f'STREAM_{stream_name.upper()}_PROTOCOL'] = stream.protocol.value
        
        process = subprocess.Popen(
            phase.command.split() if phase.command else [],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            preexec_fn=os.setsid
        )
        
        instance.process = process
        instance.pid = process.pid
        
        # Start log forwarding
        asyncio.create_task(self._forward_logs(instance))
    
    async def _start_container(self, instance: PhaseInstance):
        """Start a container phase using Apple Containerization CLI"""
        phase = instance.config
        
        container_name = f"bci-{phase.name}-{instance.replica_id}"
        
        # Build container command
        cmd = [self.container_cli, 'run', '-d', '--name', container_name]
        
        # Add port mappings for streams
        for stream_name in phase.outputs + phase.inputs:
            if stream_name in self.streams:
                stream = self.streams[stream_name]
                cmd.extend(['-p', f"{stream.port}:{stream.port}"])
        
        # Add volume mounts
        for vol in phase.volumes:
            cmd.extend(['-v', vol])
        
        # Add resource limits
        if 'cpu_limit' in phase.resources:
            cmd.extend(['--cpus', str(phase.resources['cpu_limit'])])
        if 'memory_limit' in phase.resources:
            cmd.extend(['--memory', phase.resources['memory_limit']])
        
        # Add environment variables
        cmd.extend(['-e', f"PHASE_NAME={phase.name}"])
        cmd.extend(['-e', f"REPLICA_ID={instance.replica_id}"])
        
        for stream_name in phase.outputs + phase.inputs:
            if stream_name in self.streams:
                stream = self.streams[stream_name]
                cmd.extend(['-e', f"STREAM_{stream_name.upper()}_PORT={stream.port}"])
                cmd.extend(['-e', f"STREAM_{stream_name.upper()}_PROTOCOL={stream.protocol.value}"])
        
        cmd.append(phase.image)
        
        # Start container
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"Container start failed: {result.stderr}")
        
        instance.container_id = result.stdout.strip()
        instance.pid = None  # Container doesn't have direct PID
    
    async def _forward_logs(self, instance: PhaseInstance):
        """Forward process logs to logger"""
        if not instance.process:
            return
        
        phase_name = instance.config.name
        replica_id = instance.replica_id
        
        async def read_stream(stream, level):
            while True:
                line = await asyncio.get_event_loop().run_in_executor(
                    None, stream.readline
                )
                if not line:
                    break
                msg = line.decode('utf-8').strip()
                if level == 'stdout':
                    self.logger.info(f"[{phase_name}:{replica_id}] {msg}")
                else:
                    self.logger.error(f"[{phase_name}:{replica_id}] {msg}")
        
        await asyncio.gather(
            read_stream(instance.process.stdout, 'stdout'),
            read_stream(instance.process.stderr, 'stderr')
        )
    
    async def stop_phase(self, phase_name: str, replica_id: Optional[int] = None, 
                         graceful: bool = True) -> bool:
        """Stop a phase or specific replica"""
        async with self._lock:
            if phase_name not in self.instances:
                return False
            
            instances = self.instances[phase_name]
            if replica_id is not None:
                instances = [i for i in instances if i.replica_id == replica_id]
            
            for instance in instances:
                instance.state = PhaseState.STOPPING
                await self._stop_instance(instance, graceful)
                instance.state = PhaseState.STOPPED
            
            # Update overall state
            if all(i.state == PhaseState.STOPPED for i in self.instances[phase_name]):
                self.state[phase_name] = PhaseState.STOPPED
            
            return True
    
    async def _stop_instance(self, instance: PhaseInstance, graceful: bool = True):
        """Stop a single instance"""
        phase = instance.config
        
        try:
            if phase.phase_type == 'host_process' and instance.process:
                if graceful:
                    instance.process.terminate()
                    try:
                        await asyncio.wait_for(
                            asyncio.get_event_loop().run_in_executor(
                                None, instance.process.wait
                            ),
                            timeout=10.0
                        )
                    except asyncio.TimeoutError:
                        self.logger.warning(f"Force killing {phase.name}:{instance.replica_id}")
                        instance.process.kill()
                else:
                    instance.process.kill()
                    instance.process.wait()
            
            elif phase.phase_type == 'container' and instance.container_id:
                cmd = [self.container_cli, 'stop']
                if not graceful:
                    cmd.append('-t0')
                cmd.append(instance.container_id)
                subprocess.run(cmd, capture_output=True)
                
                # Remove container
                subprocess.run(
                    [self.container_cli, 'rm', instance.container_id],
                    capture_output=True
                )
            
            self.logger.info(f"Stopped {phase.name}:{instance.replica_id}")
            
        except Exception as e:
            self.logger.error(f"Error stopping {phase.name}:{instance.replica_id}: {e}")
    
    async def start_pipeline(self):
        """Start the full pipeline in dependency order"""
        self._running = True
        startup_order = self.config.get('orchestration', {}).get('startup_order', [])
        
        self.logger.info(f"Starting pipeline with phases: {startup_order}")
        
        for phase_name in startup_order:
            phase = self.phases[phase_name]
            
            # Start replicas
            for replica_id in range(phase.replicas):
                await self.start_phase(phase_name, replica_id)
                await asyncio.sleep(0.5)  # Stagger starts
            
            # Wait for phase to be healthy before starting dependents
            await self._wait_for_healthy(phase_name)
        
        self.logger.info("Pipeline started successfully")
        
        # Start monitoring
        asyncio.create_task(self._monitoring_loop())
    
    async def _wait_for_healthy(self, phase_name: str, timeout: float = 60.0):
        """Wait for a phase to become healthy"""
        start = time.time()
        while time.time() - start < timeout:
            instances = self.instances.get(phase_name, [])
            if instances and all(i.state == PhaseState.RUNNING for i in instances):
                self.state[phase_name] = PhaseState.HEALTHY
                return True
            await asyncio.sleep(0.5)
        return False
    
    async def stop_pipeline(self, graceful: bool = True):
        """Stop the full pipeline in reverse dependency order"""
        self._running = False
        self._shutdown_event.set()
        
        shutdown_order = self.config.get('orchestration', {}).get('shutdown_order', [])
        
        self.logger.info(f"Stopping pipeline with phases: {shutdown_order}")
        
        for phase_name in shutdown_order:
            await self.stop_phase(phase_name, graceful=graceful)
            await asyncio.sleep(0.5)
        
        self.logger.info("Pipeline stopped")
    
    async def scale_phase(self, phase_name: str, target_replicas: int) -> bool:
        """Scale a phase to target number of replicas"""
        async with self._lock:
            if phase_name not in self.phases:
                return False
            
            phase = self.phases[phase_name]
            current_instances = self.instances.get(phase_name, [])
            current_count = len(current_instances)
            
            if target_replicas > current_count:
                # Scale up
                for replica_id in range(current_count, target_replicas):
                    await self.start_phase(phase_name, replica_id)
            elif target_replicas < current_count:
                # Scale down
                for instance in current_instances[target_replicas:]:
                    await self._stop_instance(instance)
                self.instances[phase_name] = current_instances[:target_replicas]
            
            phase.replicas = target_replicas
            self.logger.info(f"Scaled {phase_name} from {current_count} to {target_replicas} replicas")
            return True
    
    async def restart_phase(self, phase_name: str, replica_id: Optional[int] = None):
        """Restart a phase"""
        await self.stop_phase(phase_name, replica_id)
        await asyncio.sleep(1)
        
        if replica_id is not None:
            await self.start_phase(phase_name, replica_id)
        else:
            phase = self.phases[phase_name]
            for rid in range(phase.replicas):
                await self.start_phase(phase_name, rid)
    
    async def _monitoring_loop(self):
        """Background monitoring loop"""
        interval = self.config.get('orchestration', {}).get('monitoring', {}).get('metrics_interval', 5)
        
        while self._running and not self._shutdown_event.is_set():
            try:
                await self._check_health()
                await asyncio.sleep(interval)
            except Exception as e:
                self.logger.error(f"Monitoring error: {e}")
    
    async def _check_health(self):
        """Check health of all running instances"""
        restart_policy = self.config.get('orchestration', {}).get('restart_policy', {})
        max_restarts = restart_policy.get('max_restarts', 5)
        restart_window = restart_policy.get('restart_window', 300)
        
        for phase_name, instances in self.instances.items():
            for instance in instances:
                if instance.state != PhaseState.RUNNING:
                    continue
                
                is_healthy = await self._is_instance_healthy(instance)
                
                if not is_healthy:
                    instance.state = PhaseState.DEGRADED
                    
                    # Check restart policy
                    now = time.time()
                    if instance.restart_count < max_restarts:
                        if instance.last_restart is None or (now - instance.last_restart) > restart_window:
                            self.logger.warning(f"Restarting unhealthy instance {phase_name}:{instance.replica_id}")
                            instance.state = PhaseState.RESTARTING
                            instance.restart_count += 1
                            instance.last_restart = now
                            await self.restart_phase(phase_name, instance.replica_id)
    
    async def _is_instance_healthy(self, instance: PhaseInstance) -> bool:
        """Check if an instance is healthy"""
        phase = instance.config
        
        if phase.phase_type == 'host_process' and instance.process:
            return instance.process.poll() is None
        elif phase.phase_type == 'container' and instance.container_id:
            result = subprocess.run(
                [self.container_cli, 'inspect', '--format={{.State.Running}}', instance.container_id],
                capture_output=True, text=True
            )
            return result.returncode == 0 and result.stdout.strip() == 'true'
        
        return False
    
    def get_status(self) -> Dict[str, Any]:
        """Get current pipeline status"""
        status = {
            'running': self._running,
            'phases': {},
            'streams': {},
            'hyperedges': {}
        }
        
        for phase_name, phase in self.phases.items():
            instances = self.instances.get(phase_name, [])
            status['phases'][phase_name] = {
                'type': phase.phase_type,
                'target_replicas': phase.replicas,
                'running_replicas': len([i for i in instances if i.state == PhaseState.RUNNING]),
                'state': self.state[phase_name].name,
                'inputs': phase.inputs,
                'outputs': phase.outputs
            }
        
        for stream_name, stream in self.streams.items():
            producer = self.get_stream_producer(stream_name)
            consumers = self.get_stream_consumers(stream_name)
            status['streams'][stream_name] = {
                'protocol': stream.protocol.value,
                'port': stream.port,
                'producer': producer,
                'consumers': consumers
            }
        
        for edge_name, edge in self.hyperedges.items():
            status['hyperedges'][edge_name] = {
                'source': edge.source,
                'targets': edge.targets,
                'streams': edge.streams,
                'multicast': edge.multicast
            }
        
        return status
    
    def register_callback(self, state: PhaseState, callback: Callable):
        """Register a callback for phase state changes"""
        self._callbacks[state].append(callback)
    
    async def _trigger_callbacks(self, state: PhaseState, phase_name: str, instance: PhaseInstance):
        """Trigger registered callbacks for a state change"""
        for callback in self._callbacks.get(state, []):
            try:
                if asyncio.iscoroutinefunction(callback):
                    await callback(phase_name, instance)
                else:
                    callback(phase_name, instance)
            except Exception as e:
                self.logger.error(f"Callback error: {e}")
    
    def visualize_hypergraph(self) -> str:
        """Generate ASCII visualization of the hypergraph"""
        lines = ["╔══════════════════════════════════════════════════════════════════════╗"]
        lines.append("║              BCI Hypergraph Orchestration Pipeline                    ║")
        lines.append("╠══════════════════════════════════════════════════════════════════════╣")
        
        # Build visualization
        for phase_name in self.config.get('orchestration', {}).get('startup_order', []):
            phase = self.phases[phase_name]
            state_icon = "●" if self.state.get(phase_name) == PhaseState.HEALTHY else "○"
            state_color = self._state_color(self.state.get(phase_name))
            
            lines.append(f"║  {state_icon} {phase_name:15} [{phase.phase_type:12}]                     ║")
            
            # Show outputs and their connections
            for output in phase.outputs:
                consumers = self.get_stream_consumers(output)
                if consumers:
                    lines.append(f"║    └─► {output:20} ──► {', '.join(consumers):25} ║")
                else:
                    lines.append(f"║    └─► {output:20}                          ║")
        
        lines.append("╚══════════════════════════════════════════════════════════════════════╝")
        return '\n'.join(lines)
    
    def _state_color(self, state: Optional[PhaseState]) -> str:
        """Get color code for state (for terminal output)"""
        colors = {
            PhaseState.PENDING: "⚪",
            PhaseState.STARTING: "🟡",
            PhaseState.RUNNING: "🔵",
            PhaseState.HEALTHY: "🟢",
            PhaseState.DEGRADED: "🟠",
            PhaseState.FAILED: "🔴",
            PhaseState.STOPPING: "⚫",
            PhaseState.STOPPED: "⚪",
        }
        return colors.get(state, "⚪")


import os


async def main():
    """Example usage"""
    orchestrator = HypergraphOrchestrator()
    
    print(orchestrator.visualize_hypergraph())
    
    # Handle signals
    def signal_handler():
        asyncio.create_task(orchestrator.stop_pipeline())
    
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, signal_handler)
    
    # Start pipeline
    await orchestrator.start_pipeline()
    
    try:
        while orchestrator._running:
            await asyncio.sleep(1)
            print(orchestrator.visualize_hypergraph())
    except asyncio.CancelledError:
        pass
    finally:
        await orchestrator.stop_pipeline()


if __name__ == "__main__":
    asyncio.run(main())
