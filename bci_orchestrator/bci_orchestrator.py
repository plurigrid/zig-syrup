#!/usr/bin/env python3
"""
BCI Orchestrator CLI Tool

Command-line interface for managing the BCI hypergraph orchestration pipeline.

Commands:
    start   - Launch full pipeline
    stop    - Graceful shutdown
    status  - Show phase states
    scale   - Run multiple instances
    logs    - Show phase logs
    restart - Restart a phase
    config  - Show/edit configuration
"""

import asyncio
import argparse
import json
import sys
import signal
from pathlib import Path
from typing import Optional, List
import yaml

from hypergraph_orchestrator import HypergraphOrchestrator, PhaseState
from phase_coordinator import PhaseCoordinator, PhaseDependency, DependencyType
from stream_router import MultiStreamRouter, StreamRouterConfig, StreamProtocol


class BciOrchestratorCli:
    """CLI for BCI Hypergraph Orchestrator"""
    
    def __init__(self, config_path: str = "hypergraph_config.yaml"):
        self.config_path = Path(config_path)
        self.orchestrator: Optional[HypergraphOrchestrator] = None
        self.coordinator: Optional[PhaseCoordinator] = None
        self.stream_router: Optional[MultiStreamRouter] = None
        self._shutdown_event = asyncio.Event()
    
    async def start(self, phases: Optional[List[str]] = None, 
                    foreground: bool = False):
        """Start the full pipeline or specific phases"""
        print("🧠 BCI Hypergraph Orchestrator - Starting...")
        
        # Initialize components
        self.orchestrator = HypergraphOrchestrator(self.config_path)
        self.coordinator = PhaseCoordinator(self.orchestrator)
        self.stream_router = MultiStreamRouter()
        
        # Set up stream routers from config
        await self._setup_stream_routers()
        
        # Set up phase coordinator
        await self._setup_coordinator()
        
        # Handle signals
        def signal_handler():
            print("\n⚠️  Received shutdown signal")
            asyncio.create_task(self.stop())
        
        loop = asyncio.get_event_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, signal_handler)
        
        try:
            # Start stream routers
            await self.stream_router.start_all()
            
            # Start pipeline
            if phases:
                for phase in phases:
                    await self.coordinator.start_phase(phase)
            else:
                success = await self.coordinator.start_pipeline()
                if not success:
                    print("❌ Failed to start pipeline")
                    return 1
            
            print("✅ Pipeline started successfully")
            print(self.orchestrator.visualize_hypergraph())
            
            if foreground:
                # Keep running and show status updates
                await self._foreground_loop()
            
            return 0
            
        except Exception as e:
            print(f"❌ Error starting pipeline: {e}")
            await self.stop()
            return 1
    
    async def stop(self, graceful: bool = True, timeout: float = 60.0):
        """Stop the pipeline"""
        print("🛑 Stopping BCI pipeline...")
        
        try:
            if self.coordinator:
                await self.coordinator.stop_pipeline(graceful=graceful)
            
            if self.stream_router:
                await self.stream_router.stop_all()
            
            if self.orchestrator:
                await self.orchestrator.stop_pipeline(graceful=graceful)
            
            self._shutdown_event.set()
            print("✅ Pipeline stopped")
            
        except Exception as e:
            print(f"⚠️  Error during shutdown: {e}")
    
    async def status(self, watch: bool = False, interval: float = 2.0):
        """Show current pipeline status"""
        if not self.orchestrator:
            # Try to load from saved state
            self.orchestrator = HypergraphOrchestrator(self.config_path)
        
        status_data = self.orchestrator.get_status()
        
        if watch:
            try:
                while True:
                    self._clear_screen()
                    self._print_status(status_data)
                    await asyncio.sleep(interval)
                    status_data = self.orchestrator.get_status()
            except KeyboardInterrupt:
                pass
        else:
            self._print_status(status_data)
        
        return status_data
    
    async def scale(self, phase: str, replicas: int):
        """Scale a phase to target number of replicas"""
        if not self.orchestrator:
            print("❌ Orchestrator not running. Start pipeline first.")
            return 1
        
        print(f"📊 Scaling phase '{phase}' to {replicas} replicas...")
        
        try:
            success = await self.orchestrator.scale_phase(phase, replicas)
            if success:
                print(f"✅ Phase '{phase}' scaled to {replicas} replicas")
                return 0
            else:
                print(f"❌ Failed to scale phase '{phase}'")
                return 1
        except Exception as e:
            print(f"❌ Error scaling phase: {e}")
            return 1
    
    async def restart(self, phase: str, replica_id: Optional[int] = None):
        """Restart a phase"""
        if not self.coordinator:
            print("❌ Coordinator not running. Start pipeline first.")
            return 1
        
        print(f"🔄 Restarting phase '{phase}'...")
        
        try:
            success = await self.coordinator.restart_phase(phase)
            if success:
                print(f"✅ Phase '{phase}' restarted")
                return 0
            else:
                print(f"❌ Failed to restart phase '{phase}'")
                return 1
        except Exception as e:
            print(f"❌ Error restarting phase: {e}")
            return 1
    
    async def logs(self, phase: str, follow: bool = False, 
                   lines: int = 100, replica_id: Optional[int] = None):
        """Show logs for a phase"""
        print(f"📜 Logs for phase '{phase}':")
        
        if self.orchestrator and phase in self.orchestrator.instances:
            instances = self.orchestrator.instances[phase]
            if replica_id is not None:
                instances = [i for i in instances if i.replica_id == replica_id]
            
            for instance in instances:
                print(f"\n--- Instance {phase}:{instance.replica_id} ---")
                print(f"State: {instance.state.name}")
                print(f"Start time: {instance.start_time}")
                print(f"Restarts: {instance.restart_count}")
        else:
            print("No instances found (orchestrator not running)")
    
    async def config_show(self):
        """Show current configuration"""
        with open(self.config_path, 'r') as f:
            config = yaml.safe_load(f)
        
        print("📋 Configuration:")
        print(json.dumps(config, indent=2))
    
    async def config_validate(self):
        """Validate configuration"""
        print("🔍 Validating configuration...")
        
        try:
            orchestrator = HypergraphOrchestrator(self.config_path)
            
            # Check for cycles in dependencies
            startup_order = orchestrator.get_startup_order()
            
            # Check stream connectivity
            for stream_name in orchestrator.streams:
                producer = orchestrator.get_stream_producer(stream_name)
                consumers = orchestrator.get_stream_consumers(stream_name)
                
                if not producer:
                    print(f"⚠️  Stream '{stream_name}' has no producer")
                if not consumers:
                    print(f"⚠️  Stream '{stream_name}' has no consumers")
            
            # Check all phases have required configs
            for phase_name, phase in orchestrator.phases.items():
                if phase.phase_type == 'container' and not phase.image:
                    print(f"⚠️  Container phase '{phase_name}' has no image")
                if phase.phase_type == 'host_process' and not phase.command:
                    print(f"⚠️  Host process phase '{phase_name}' has no command")
            
            print("✅ Configuration valid")
            return 0
            
        except Exception as e:
            print(f"❌ Configuration error: {e}")
            return 1
    
    async def viz(self):
        """Visualize hypergraph"""
        if not self.orchestrator:
            self.orchestrator = HypergraphOrchestrator(self.config_path)
        
        print(self.orchestrator.visualize_hypergraph())
    
    async def _setup_stream_routers(self):
        """Set up stream routers from configuration"""
        for stream_name, stream_config in self.orchestrator.streams.items():
            config = StreamRouterConfig(
                name=stream_name,
                protocol=stream_config.protocol,
                port=stream_config.port,
                buffer_size=stream_config.buffer_size,
                multicast=True,
                backpressure=None,  # Use default
                sync_enabled=True
            )
            
            router = self.stream_router.create_router(config)
            
            # Add consumers based on hyperedges
            for edge in self.orchestrator.hyperedges.values():
                if stream_name in edge.streams:
                    for target in edge.targets:
                        if target in self.orchestrator.phases:
                            target_phase = self.orchestrator.phases[target]
                            # Find input port for this stream
                            for input_stream in target_phase.inputs:
                                if input_stream == stream_name:
                                    # Create consumer
                                    from stream_router import Consumer, BackpressureStrategy
                                    consumer = Consumer(
                                        id=f"{target}_{stream_name}",
                                        protocol=stream_config.protocol,
                                        host='localhost',
                                        port=stream_config.port,
                                        backpressure=BackpressureStrategy.DROP_OLDEST
                                    )
                                    router.add_consumer(consumer)
    
    async def _setup_coordinator(self):
        """Set up phase coordinator from configuration"""
        # Register all phases
        for phase_name, phase_config in self.orchestrator.phases.items():
            self.coordinator.register_phase(
                name=phase_name,
                phase_type=phase_config.phase_type
            )
        
        # Add dependencies from hyperedges
        for edge in self.orchestrator.hyperedges.values():
            for target in edge.targets:
                self.coordinator.add_dependency(PhaseDependency(
                    source=edge.source,
                    target=target,
                    dep_type=DependencyType.CONSUMES_FROM
                ))
    
    async def _foreground_loop(self):
        """Main loop for foreground mode"""
        while not self._shutdown_event.is_set():
            self._clear_screen()
            print(self.orchestrator.visualize_hypergraph())
            
            # Show metrics
            status = self.orchestrator.get_status()
            print("\n📊 Stream Metrics:")
            for stream_name, stream_info in status.get('streams', {}).items():
                print(f"  {stream_name}: producer={stream_info['producer']}, "
                      f"consumers={len(stream_info['consumers'])}")
            
            try:
                await asyncio.wait_for(self._shutdown_event.wait(), timeout=2.0)
            except asyncio.TimeoutError:
                pass
    
    def _print_status(self, status: dict):
        """Print formatted status"""
        print("╔══════════════════════════════════════════════════════════════════════╗")
        print("║                    BCI Pipeline Status                               ║")
        print("╠══════════════════════════════════════════════════════════════════════╣")
        
        running = status.get('running', False)
        status_icon = "🟢 RUNNING" if running else "🔴 STOPPED"
        print(f"║  Pipeline: {status_icon:57} ║")
        print("║                                                                      ║")
        
        # Phase status
        print("║  Phases:                                                             ║")
        for name, info in status.get('phases', {}).items():
            state = info.get('state', 'UNKNOWN')
            replicas = info.get('running_replicas', 0)
            target = info.get('target_replicas', 0)
            
            state_icon = {
                'HEALTHY': '🟢',
                'RUNNING': '🟢',
                'STARTING': '🟡',
                'STOPPING': '🟠',
                'STOPPED': '⚪',
                'FAILED': '🔴',
            }.get(state, '⚪')
            
            print(f"║    {state_icon} {name:15} [{state:12}] {replicas}/{target} replicas      ║")
        
        print("║                                                                      ║")
        
        # Stream status
        print("║  Active Streams:                                                     ║")
        for name, info in status.get('streams', {}).items():
            protocol = info.get('protocol', 'unknown')
            port = info.get('port', 0)
            consumers = len(info.get('consumers', []))
            print(f"║    📡 {name:20} ({protocol:4}:{port}) → {consumers} consumers          ║")
        
        print("╚══════════════════════════════════════════════════════════════════════╝")
    
    def _clear_screen(self):
        """Clear terminal screen"""
        import os
        os.system('cls' if sys.platform == 'win32' else 'clear')


def create_parser() -> argparse.ArgumentParser:
    """Create argument parser"""
    parser = argparse.ArgumentParser(
        description='BCI Hypergraph Orchestrator CLI',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s start                    # Start full pipeline
  %(prog)s start --foreground       # Start and watch status
  %(prog)s stop                     # Stop pipeline
  %(prog)s status                   # Show current status
  %(prog)s status --watch           # Watch status continuously
  %(prog)s scale preprocessing 3    # Scale preprocessing to 3 replicas
  %(prog)s restart analysis         # Restart analysis phase
  %(prog)s logs acquisition         # Show acquisition logs
  %(prog)s config validate          # Validate configuration
  %(prog)s viz                      # Visualize hypergraph
        """
    )
    
    parser.add_argument(
        '-c', '--config',
        default='hypergraph_config.yaml',
        help='Path to configuration file (default: hypergraph_config.yaml)'
    )
    
    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='Enable verbose logging'
    )
    
    subparsers = parser.add_subparsers(dest='command', help='Available commands')
    
    # start command
    start_parser = subparsers.add_parser('start', help='Start the pipeline')
    start_parser.add_argument(
        'phases',
        nargs='*',
        help='Specific phases to start (default: all)'
    )
    start_parser.add_argument(
        '-f', '--foreground',
        action='store_true',
        help='Run in foreground with status display'
    )
    
    # stop command
    stop_parser = subparsers.add_parser('stop', help='Stop the pipeline')
    stop_parser.add_argument(
        '--force',
        action='store_true',
        help='Force immediate shutdown'
    )
    stop_parser.add_argument(
        '--timeout',
        type=float,
        default=60.0,
        help='Shutdown timeout in seconds (default: 60)'
    )
    
    # status command
    status_parser = subparsers.add_parser('status', help='Show pipeline status')
    status_parser.add_argument(
        '-w', '--watch',
        action='store_true',
        help='Watch status continuously'
    )
    status_parser.add_argument(
        '-i', '--interval',
        type=float,
        default=2.0,
        help='Update interval for watch mode (default: 2)'
    )
    
    # scale command
    scale_parser = subparsers.add_parser('scale', help='Scale a phase')
    scale_parser.add_argument('phase', help='Phase name to scale')
    scale_parser.add_argument('replicas', type=int, help='Target number of replicas')
    
    # restart command
    restart_parser = subparsers.add_parser('restart', help='Restart a phase')
    restart_parser.add_argument('phase', help='Phase name to restart')
    restart_parser.add_argument(
        '--replica',
        type=int,
        help='Specific replica ID to restart'
    )
    
    # logs command
    logs_parser = subparsers.add_parser('logs', help='Show phase logs')
    logs_parser.add_argument('phase', help='Phase name')
    logs_parser.add_argument(
        '-f', '--follow',
        action='store_true',
        help='Follow log output'
    )
    logs_parser.add_argument(
        '-n', '--lines',
        type=int,
        default=100,
        help='Number of lines to show (default: 100)'
    )
    logs_parser.add_argument(
        '--replica',
        type=int,
        help='Specific replica ID'
    )
    
    # config command
    config_parser = subparsers.add_parser('config', help='Configuration management')
    config_subparsers = config_parser.add_subparsers(dest='config_cmd')
    config_subparsers.add_parser('show', help='Show current configuration')
    config_subparsers.add_parser('validate', help='Validate configuration')
    
    # viz command
    subparsers.add_parser('viz', help='Visualize hypergraph')
    
    return parser


async def main():
    """Main entry point"""
    parser = create_parser()
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return 1
    
    # Setup logging
    import logging
    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    cli = BciOrchestratorCli(args.config)
    
    if args.command == 'start':
        return await cli.start(
            phases=args.phases or None,
            foreground=args.foreground
        )
    
    elif args.command == 'stop':
        await cli.stop(
            graceful=not args.force,
            timeout=args.timeout
        )
        return 0
    
    elif args.command == 'status':
        await cli.status(
            watch=args.watch,
            interval=args.interval
        )
        return 0
    
    elif args.command == 'scale':
        return await cli.scale(args.phase, args.replicas)
    
    elif args.command == 'restart':
        return await cli.restart(args.phase, args.replica)
    
    elif args.command == 'logs':
        await cli.logs(
            args.phase,
            follow=args.follow,
            lines=args.lines,
            replica_id=args.replica
        )
        return 0
    
    elif args.command == 'config':
        if args.config_cmd == 'show':
            await cli.config_show()
        elif args.config_cmd == 'validate':
            return await cli.config_validate()
        else:
            config_parser = parser._subparsers._group_actions[0].choices['config']
            config_parser.print_help()
        return 0
    
    elif args.command == 'viz':
        await cli.viz()
        return 0
    
    return 0


if __name__ == "__main__":
    exit_code = asyncio.run(main())
    sys.exit(exit_code)
