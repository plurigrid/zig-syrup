#!/usr/bin/env python3
"""
Phase Coordinator for BCI Hypergraph Orchestration

Manages transitions between pipeline phases, handles container startup/shutdown ordering,
health monitoring for each phase, and auto-restart failed containers.
"""

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Callable, Any, Tuple
from enum import Enum, auto
from collections import defaultdict
import json


class TransitionState(Enum):
    """States for phase transitions"""
    IDLE = auto()
    PREPARING = auto()
    STARTING = auto()
    READY = auto()
    ACTIVE = auto()
    PAUSING = auto()
    PAUSED = auto()
    STOPPING = auto()
    COMPLETED = auto()
    FAILED = auto()
    ROLLING_BACK = auto()


class DependencyType(Enum):
    """Types of phase dependencies"""
    REQUIRES = auto()      # Phase requires another to be running
    PRODUCES_FOR = auto()  # Phase produces data for another
    CONSUMES_FROM = auto() # Phase consumes data from another
    SEQUENTIAL = auto()    # Phase must start after another


@dataclass
class PhaseDependency:
    """Represents a dependency between phases"""
    source: str
    target: str
    dep_type: DependencyType
    optional: bool = False
    timeout: float = 60.0


@dataclass
class Transition:
    """Represents a phase transition"""
    phase_name: str
    from_state: TransitionState
    to_state: TransitionState
    timestamp: float
    metadata: Dict[str, Any] = field(default_factory=dict)
    error: Optional[str] = None


@dataclass
class Phase:
    """Represents a managed phase"""
    name: str
    phase_type: str  # 'host_process', 'container', etc.
    state: TransitionState = TransitionState.IDLE
    
    # Runtime info
    instance_ids: List[str] = field(default_factory=list)
    start_time: Optional[float] = None
    end_time: Optional[float] = None
    restart_count: int = 0
    
    # Health info
    health_status: str = "unknown"
    last_health_check: Optional[float] = None
    health_failures: int = 0
    
    # Metrics
    metrics: Dict[str, Any] = field(default_factory=dict)
    
    # Transitions history
    transitions: List[Transition] = field(default_factory=list)


class PhaseCoordinator:
    """
    Coordinates phase transitions and manages the pipeline lifecycle.
    
    Features:
    - Dependency-aware startup/shutdown ordering
    - Health monitoring with auto-restart
    - Transition state machine
    - Rollback on failure
    """
    
    def __init__(self, orchestrator=None):
        self.logger = logging.getLogger('PhaseCoordinator')
        self.orchestrator = orchestrator
        
        # Phase management
        self.phases: Dict[str, Phase] = {}
        self.dependencies: List[PhaseDependency] = []
        self.dependency_graph: Dict[str, Set[str]] = defaultdict(set)
        self.reverse_dependencies: Dict[str, Set[str]] = defaultdict(set)
        
        # State machine
        self._transition_handlers: Dict[Tuple[TransitionState, TransitionState], List[Callable]] = defaultdict(list)
        self._state_callbacks: Dict[TransitionState, List[Callable]] = defaultdict(list)
        
        # Monitoring
        self._health_check_interval: float = 10.0
        self._health_checks: Dict[str, asyncio.Task] = {}
        self._running = False
        self._shutdown_event = asyncio.Event()
        
        # Auto-restart
        self._auto_restart_enabled: bool = True
        self._restart_delays: Dict[str, float] = defaultdict(lambda: 1.0)
        self._max_restarts: int = 5
        self._restart_window: float = 300.0  # 5 minutes
        
        # Concurrency control
        self._phase_locks: Dict[str, asyncio.Lock] = defaultdict(asyncio.Lock)
        self._global_lock = asyncio.Lock()
    
    def register_phase(self, name: str, phase_type: str, 
                       dependencies: Optional[List[PhaseDependency]] = None) -> Phase:
        """Register a phase with the coordinator"""
        phase = Phase(name=name, phase_type=phase_type)
        self.phases[name] = phase
        
        if dependencies:
            for dep in dependencies:
                self.add_dependency(dep)
        
        self.logger.info(f"Registered phase: {name} ({phase_type})")
        return phase
    
    def add_dependency(self, dependency: PhaseDependency):
        """Add a dependency between phases"""
        self.dependencies.append(dependency)
        
        if dependency.dep_type in (DependencyType.REQUIRES, DependencyType.CONSUMES_FROM):
            self.dependency_graph[dependency.target].add(dependency.source)
            self.reverse_dependencies[dependency.source].add(dependency.target)
        elif dependency.dep_type == DependencyType.SEQUENTIAL:
            self.dependency_graph[dependency.target].add(dependency.source)
            self.reverse_dependencies[dependency.source].add(dependency.target)
        
        self.logger.debug(f"Added dependency: {dependency.source} -> {dependency.target} ({dependency.dep_type.name})")
    
    def get_startup_order(self) -> List[str]:
        """Get topological order for startup (respects dependencies)"""
        visited: Set[str] = set()
        order: List[str] = []
        temp_mark: Set[str] = set()
        
        def visit(phase_name: str):
            if phase_name in temp_mark:
                raise ValueError(f"Circular dependency detected involving {phase_name}")
            if phase_name in visited:
                return
            
            temp_mark.add(phase_name)
            
            # Visit all dependencies first
            for dep in self.dependency_graph.get(phase_name, set()):
                visit(dep)
            
            temp_mark.remove(phase_name)
            visited.add(phase_name)
            order.append(phase_name)
        
        for phase_name in self.phases:
            if phase_name not in visited:
                visit(phase_name)
        
        return order
    
    def get_shutdown_order(self) -> List[str]:
        """Get order for shutdown (reverse of startup)"""
        startup_order = self.get_startup_order()
        return list(reversed(startup_order))
    
    async def start_phase(self, phase_name: str, 
                          start_func: Optional[Callable] = None) -> bool:
        """Start a single phase with dependency checking"""
        async with self._phase_locks[phase_name]:
            phase = self.phases.get(phase_name)
            if not phase:
                self.logger.error(f"Unknown phase: {phase_name}")
                return False
            
            if phase.state not in (TransitionState.IDLE, TransitionState.STOPPED, TransitionState.FAILED):
                self.logger.warning(f"Phase {phase_name} is already in state {phase.state.name}")
                return False
            
            # Check dependencies
            deps = self.dependency_graph.get(phase_name, set())
            for dep in deps:
                dep_phase = self.phases.get(dep)
                if not dep_phase or dep_phase.state != TransitionState.ACTIVE:
                    if any(d.target == phase_name and d.source == dep and not d.optional 
                           for d in self.dependencies):
                        self.logger.error(f"Cannot start {phase_name}: dependency {dep} not ready")
                        await self._transition(phase, TransitionState.FAILED, 
                                               error=f"Dependency {dep} not ready")
                        return False
            
            # Transition to starting
            await self._transition(phase, TransitionState.PREPARING)
            
            try:
                await self._transition(phase, TransitionState.STARTING)
                
                # Call start function or orchestrator
                if start_func:
                    if asyncio.iscoroutinefunction(start_func):
                        await start_func(phase_name)
                    else:
                        start_func(phase_name)
                elif self.orchestrator:
                    await self.orchestrator.start_phase(phase_name)
                
                phase.start_time = time.time()
                await self._transition(phase, TransitionState.READY)
                await self._transition(phase, TransitionState.ACTIVE)
                
                # Start health monitoring
                self._start_health_monitoring(phase_name)
                
                self.logger.info(f"Phase {phase_name} started successfully")
                return True
                
            except Exception as e:
                self.logger.error(f"Failed to start phase {phase_name}: {e}")
                await self._transition(phase, TransitionState.FAILED, error=str(e))
                return False
    
    async def stop_phase(self, phase_name: str, 
                         stop_func: Optional[Callable] = None,
                         graceful: bool = True) -> bool:
        """Stop a single phase"""
        async with self._phase_locks[phase_name]:
            phase = self.phases.get(phase_name)
            if not phase:
                return False
            
            if phase.state in (TransitionState.IDLE, TransitionState.STOPPED, TransitionState.STOPPING):
                return True
            
            # Notify dependent phases
            dependents = self.reverse_dependencies.get(phase_name, set())
            for dep in dependents:
                dep_phase = self.phases.get(dep)
                if dep_phase and dep_phase.state == TransitionState.ACTIVE:
                    self.logger.warning(f"Stopping {phase_name} will affect dependent phase {dep}")
            
            await self._transition(phase, TransitionState.STOPPING)
            
            # Stop health monitoring
            self._stop_health_monitoring(phase_name)
            
            try:
                # Call stop function or orchestrator
                if stop_func:
                    if asyncio.iscoroutinefunction(stop_func):
                        await stop_func(phase_name)
                    else:
                        stop_func(phase_name)
                elif self.orchestrator:
                    await self.orchestrator.stop_phase(phase_name, graceful=graceful)
                
                phase.end_time = time.time()
                await self._transition(phase, TransitionState.STOPPED)
                
                self.logger.info(f"Phase {phase_name} stopped")
                return True
                
            except Exception as e:
                self.logger.error(f"Error stopping phase {phase_name}: {e}")
                await self._transition(phase, TransitionState.FAILED, error=str(e))
                return False
    
    async def start_pipeline(self) -> bool:
        """Start the full pipeline in dependency order"""
        self._running = True
        startup_order = self.get_startup_order()
        
        self.logger.info(f"Starting pipeline with order: {startup_order}")
        
        async with self._global_lock:
            for phase_name in startup_order:
                phase = self.phases[phase_name]
                
                # Wait for dependencies to be ready
                deps = self.dependency_graph.get(phase_name, set())
                for dep in deps:
                    dep_phase = self.phases.get(dep)
                    if dep_phase:
                        await self._wait_for_state(dep, TransitionState.ACTIVE, timeout=60.0)
                
                # Start the phase
                success = await self.start_phase(phase_name)
                if not success:
                    self.logger.error(f"Failed to start phase {phase_name}, initiating rollback")
                    await self._rollback(phase_name)
                    return False
                
                # Small delay between phase starts
                await asyncio.sleep(0.5)
        
        self.logger.info("Pipeline started successfully")
        return True
    
    async def stop_pipeline(self, graceful: bool = True) -> bool:
        """Stop the full pipeline in reverse dependency order"""
        self._running = False
        self._shutdown_event.set()
        
        shutdown_order = self.get_shutdown_order()
        
        self.logger.info(f"Stopping pipeline with order: {shutdown_order}")
        
        async with self._global_lock:
            for phase_name in shutdown_order:
                await self.stop_phase(phase_name, graceful=graceful)
                await asyncio.sleep(0.5)
        
        self.logger.info("Pipeline stopped")
        return True
    
    async def pause_phase(self, phase_name: str) -> bool:
        """Pause a phase temporarily"""
        phase = self.phases.get(phase_name)
        if not phase or phase.state != TransitionState.ACTIVE:
            return False
        
        await self._transition(phase, TransitionState.PAUSING)
        # Implementation depends on phase type
        await self._transition(phase, TransitionState.PAUSED)
        return True
    
    async def resume_phase(self, phase_name: str) -> bool:
        """Resume a paused phase"""
        phase = self.phases.get(phase_name)
        if not phase or phase.state != TransitionState.PAUSED:
            return False
        
        await self._transition(phase, TransitionState.STARTING)
        await self._transition(phase, TransitionState.ACTIVE)
        return True
    
    async def restart_phase(self, phase_name: str, 
                            stop_func: Optional[Callable] = None,
                            start_func: Optional[Callable] = None) -> bool:
        """Restart a phase"""
        phase = self.phases.get(phase_name)
        if not phase:
            return False
        
        phase.restart_count += 1
        
        # Stop
        if phase.state == TransitionState.ACTIVE:
            success = await self.stop_phase(phase_name, stop_func)
            if not success:
                return False
        
        # Wait for stop to complete
        await self._wait_for_state(phase_name, (TransitionState.STOPPED, TransitionState.IDLE), timeout=30.0)
        
        # Start
        return await self.start_phase(phase_name, start_func)
    
    async def _transition(self, phase: Phase, new_state: TransitionState, 
                          error: Optional[str] = None):
        """Execute a state transition"""
        old_state = phase.state
        
        # Record transition
        transition = Transition(
            phase_name=phase.name,
            from_state=old_state,
            to_state=new_state,
            timestamp=time.time(),
            error=error
        )
        phase.transitions.append(transition)
        
        # Update state
        phase.state = new_state
        
        # Log transition
        if error:
            self.logger.error(f"Phase {phase.name}: {old_state.name} -> {new_state.name} (Error: {error})")
        else:
            self.logger.info(f"Phase {phase.name}: {old_state.name} -> {new_state.name}")
        
        # Call transition handlers
        handlers = self._transition_handlers.get((old_state, new_state), [])
        for handler in handlers:
            try:
                if asyncio.iscoroutinefunction(handler):
                    await handler(phase, old_state, new_state)
                else:
                    handler(phase, old_state, new_state)
            except Exception as e:
                self.logger.error(f"Transition handler error: {e}")
        
        # Call state callbacks
        callbacks = self._state_callbacks.get(new_state, [])
        for callback in callbacks:
            try:
                if asyncio.iscoroutinefunction(callback):
                    await callback(phase)
                else:
                    callback(phase)
            except Exception as e:
                self.logger.error(f"State callback error: {e}")
    
    async def _rollback(self, failed_phase: str):
        """Rollback pipeline after a failure"""
        self.logger.warning(f"Initiating rollback due to failure in {failed_phase}")
        
        # Stop all started phases in reverse order
        started_phases = [
            name for name, phase in self.phases.items()
            if phase.state in (TransitionState.ACTIVE, TransitionState.READY, TransitionState.STARTING)
        ]
        
        for phase_name in reversed(started_phases):
            phase = self.phases[phase_name]
            await self._transition(phase, TransitionState.ROLLING_BACK)
            await self.stop_phase(phase_name, graceful=False)
    
    async def _wait_for_state(self, phase_name: str, 
                              target_states: TransitionState or Tuple[TransitionState, ...],
                              timeout: float = 60.0) -> bool:
        """Wait for a phase to reach a target state"""
        if isinstance(target_states, TransitionState):
            target_states = (target_states,)
        
        start = time.time()
        while time.time() - start < timeout:
            phase = self.phases.get(phase_name)
            if phase and phase.state in target_states:
                return True
            await asyncio.sleep(0.1)
        
        return False
    
    def _start_health_monitoring(self, phase_name: str):
        """Start health monitoring for a phase"""
        if phase_name in self._health_checks:
            return
        
        task = asyncio.create_task(self._health_check_loop(phase_name))
        self._health_checks[phase_name] = task
    
    def _stop_health_monitoring(self, phase_name: str):
        """Stop health monitoring for a phase"""
        if phase_name in self._health_checks:
            self._health_checks[phase_name].cancel()
            del self._health_checks[phase_name]
    
    async def _health_check_loop(self, phase_name: str):
        """Continuous health checking for a phase"""
        while self._running and not self._shutdown_event.is_set():
            try:
                await self._check_health(phase_name)
                await asyncio.wait_for(
                    self._shutdown_event.wait(),
                    timeout=self._health_check_interval
                )
            except asyncio.TimeoutError:
                continue
            except asyncio.CancelledError:
                break
            except Exception as e:
                self.logger.error(f"Health check error for {phase_name}: {e}")
    
    async def _check_health(self, phase_name: str):
        """Check health of a phase"""
        phase = self.phases.get(phase_name)
        if not phase or phase.state != TransitionState.ACTIVE:
            return
        
        phase.last_health_check = time.time()
        
        # Perform health check
        is_healthy = await self._perform_health_check(phase_name)
        
        if is_healthy:
            phase.health_status = "healthy"
            phase.health_failures = 0
            self._restart_delays[phase_name] = 1.0  # Reset delay
        else:
            phase.health_status = "unhealthy"
            phase.health_failures += 1
            
            self.logger.warning(
                f"Health check failed for {phase_name} "
                f"({phase.health_failures} consecutive failures)"
            )
            
            # Auto-restart if enabled
            if self._auto_restart_enabled and phase.health_failures >= 3:
                if phase.restart_count < self._max_restarts:
                    await self._auto_restart(phase)
                else:
                    self.logger.error(
                        f"Phase {phase_name} exceeded max restarts ({self._max_restarts})"
                    )
                    await self._transition(phase, TransitionState.FAILED)
    
    async def _perform_health_check(self, phase_name: str) -> bool:
        """Perform actual health check (can be overridden)"""
        if self.orchestrator:
            # Use orchestrator's health check
            status = self.orchestrator.get_status()
            phase_status = status.get('phases', {}).get(phase_name, {})
            return phase_status.get('state') == 'HEALTHY'
        
        # Default: assume healthy
        return True
    
    async def _auto_restart(self, phase: Phase):
        """Auto-restart a failed phase with exponential backoff"""
        delay = self._restart_delays[phase.name]
        
        self.logger.info(f"Auto-restarting phase {phase.name} in {delay}s (restart #{phase.restart_count + 1})")
        
        await asyncio.sleep(delay)
        
        # Exponential backoff
        self._restart_delays[phase.name] = min(delay * 2, 60.0)
        
        await self.restart_phase(phase.name)
    
    def register_transition_handler(self, from_state: TransitionState, 
                                     to_state: TransitionState,
                                     handler: Callable):
        """Register a handler for state transitions"""
        self._transition_handlers[(from_state, to_state)].append(handler)
    
    def register_state_callback(self, state: TransitionState, callback: Callable):
        """Register a callback for state entry"""
        self._state_callbacks[state].append(callback)
    
    def get_phase_status(self, phase_name: str) -> Optional[Dict[str, Any]]:
        """Get status of a specific phase"""
        phase = self.phases.get(phase_name)
        if not phase:
            return None
        
        uptime = None
        if phase.start_time and phase.state == TransitionState.ACTIVE:
            uptime = time.time() - phase.start_time
        
        return {
            'name': phase.name,
            'type': phase.phase_type,
            'state': phase.state.name,
            'health': phase.health_status,
            'uptime_seconds': uptime,
            'restart_count': phase.restart_count,
            'health_failures': phase.health_failures,
            'dependencies': list(self.dependency_graph.get(phase_name, set())),
            'dependents': list(self.reverse_dependencies.get(phase_name, set()))
        }
    
    def get_all_status(self) -> Dict[str, Any]:
        """Get status of all phases"""
        return {
            name: self.get_phase_status(name)
            for name in self.phases
        }
    
    def get_pipeline_dag(self) -> Dict[str, Any]:
        """Get the pipeline dependency graph"""
        return {
            'phases': list(self.phases.keys()),
            'dependencies': [
                {
                    'source': d.source,
                    'target': d.target,
                    'type': d.dep_type.name,
                    'optional': d.optional
                }
                for d in self.dependencies
            ],
            'startup_order': self.get_startup_order(),
            'shutdown_order': self.get_shutdown_order()
        }


class RollingUpdateCoordinator:
    """Coordinates rolling updates for zero-downtime deployments"""
    
    def __init__(self, coordinator: PhaseCoordinator):
        self.coordinator = coordinator
        self.logger = logging.getLogger('RollingUpdateCoordinator')
    
    async def rolling_update(self, phase_name: str, 
                             new_version_func: Callable,
                             batch_size: int = 1) -> bool:
        """Perform a rolling update of a phase"""
        phase = self.coordinator.phases.get(phase_name)
        if not phase:
            return False
        
        self.logger.info(f"Starting rolling update for {phase_name}")
        
        # Get instances
        instance_ids = phase.instance_ids.copy()
        
        for i in range(0, len(instance_ids), batch_size):
            batch = instance_ids[i:i + batch_size]
            
            # Stop batch
            for instance_id in batch:
                await self._stop_instance(phase_name, instance_id)
            
            # Start new version
            for instance_id in batch:
                await self._start_new_version(phase_name, instance_id, new_version_func)
            
            # Wait for health check
            await asyncio.sleep(2)
            healthy = await self._check_batch_health(phase_name, batch)
            
            if not healthy:
                self.logger.error(f"Rolling update failed for batch {batch}")
                return False
        
        self.logger.info(f"Rolling update completed for {phase_name}")
        return True
    
    async def _stop_instance(self, phase_name: str, instance_id: str):
        """Stop a specific instance"""
        self.logger.debug(f"Stopping instance {instance_id}")
        # Implementation depends on orchestrator
    
    async def _start_new_version(self, phase_name: str, instance_id: str, 
                                  new_version_func: Callable):
        """Start new version of an instance"""
        self.logger.debug(f"Starting new version of {instance_id}")
        # Implementation depends on orchestrator
    
    async def _check_batch_health(self, phase_name: str, instance_ids: List[str]) -> bool:
        """Check health of a batch of instances"""
        # Implementation depends on orchestrator
        return True


# Example usage
async def example():
    """Example usage of phase coordinator"""
    logging.basicConfig(level=logging.INFO)
    
    coordinator = PhaseCoordinator()
    
    # Register phases
    coordinator.register_phase("acquisition", "host_process")
    coordinator.register_phase("preprocessing", "container")
    coordinator.register_phase("analysis", "container")
    coordinator.register_phase("visualizer", "container")
    
    # Add dependencies
    coordinator.add_dependency(PhaseDependency(
        source="acquisition",
        target="preprocessing",
        dep_type=DependencyType.CONSUMES_FROM
    ))
    coordinator.add_dependency(PhaseDependency(
        source="preprocessing",
        target="analysis",
        dep_type=DependencyType.CONSUMES_FROM
    ))
    coordinator.add_dependency(PhaseDependency(
        source="analysis",
        target="visualizer",
        dep_type=DependencyType.PRODUCES_FOR,
        optional=True
    ))
    
    # Print startup order
    print("Startup order:", coordinator.get_startup_order())
    print("Shutdown order:", coordinator.get_shutdown_order())
    print("Pipeline DAG:", json.dumps(coordinator.get_pipeline_dag(), indent=2))


if __name__ == "__main__":
    asyncio.run(example())
