"""
BCI Hypergraph Orchestration System

A hypergraph-based orchestration system for managing phased BCI (Brain-Computer Interface)
processing pipelines with container lifecycle management.

Key Components:
- HypergraphOrchestrator: Manages pipeline phases as hypergraph nodes
- StreamRouter: Handles multicast data distribution (hypergraph edges)
- PhaseCoordinator: Manages phase transitions and dependencies
- Monitor: Real-time dashboard and metrics collection
- CLI: Command-line interface for pipeline control

Architecture:
    ┌─────────────────┐
    │  acquisition    │ (host_process)
    │   (hardware)    │
    └────────┬────────┘
             │ raw_eeg
             ▼
    ┌─────────────────────────────────────────┐
    │         Hypergraph Edge                 │
    │    (multicast: preprocessing,           │
    │     visualizer, storage)                │
    └─────────────────────────────────────────┘
             │
     ┌───────┴───────┐
     ▼               ▼
┌──────────┐   ┌──────────┐
│preprocess│   │visualizer│
│(container│   │(container│
└────┬─────┘   └──────────┘
     │ filtered_eeg, features
     ▼
┌──────────┐
│ analysis │ (container)
│(ML model)│
└────┬─────┘
     │ classification
     ▼
   [storage] (persistent)

Stream Protocols:
- LSL (Lab Streaming Layer): 16571
- TCP: 16573-16578
- WebSocket: 16575

Usage:
    from bci_orchestrator import HypergraphOrchestrator
    
    orchestrator = HypergraphOrchestrator("hypergraph_config.yaml")
    await orchestrator.start_pipeline()
"""

__version__ = "1.0.0"
__author__ = "BCI Hypergraph Team"

from .hypergraph_orchestrator import (
    HypergraphOrchestrator,
    PhaseState,
    PhaseConfig,
    PhaseInstance,
    StreamConfig,
    Hyperedge
)

from .stream_router import (
    StreamRouter,
    StreamRouterConfig,
    Consumer,
    StreamPacket,
    BackpressureStrategy,
    StreamProtocol,
    MultiStreamRouter
)

from .phase_coordinator import (
    PhaseCoordinator,
    Phase,
    PhaseDependency,
    DependencyType,
    TransitionState,
    Transition,
    RollingUpdateCoordinator
)

from .monitor import (
    Monitor,
    MetricsCollector,
    MetricHistory,
    AsciiDashboard,
    WebDashboard
)

__all__ = [
    # Orchestrator
    'HypergraphOrchestrator',
    'PhaseState',
    'PhaseConfig',
    'PhaseInstance',
    'StreamConfig',
    'Hyperedge',
    
    # Stream Router
    'StreamRouter',
    'StreamRouterConfig',
    'Consumer',
    'StreamPacket',
    'BackpressureStrategy',
    'StreamProtocol',
    'MultiStreamRouter',
    
    # Phase Coordinator
    'PhaseCoordinator',
    'Phase',
    'PhaseDependency',
    'DependencyType',
    'TransitionState',
    'Transition',
    'RollingUpdateCoordinator',
    
    # Monitoring
    'Monitor',
    'MetricsCollector',
    'MetricHistory',
    'AsciiDashboard',
    'WebDashboard',
]
