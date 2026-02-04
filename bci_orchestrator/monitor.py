#!/usr/bin/env python3
"""
Monitoring Dashboard for BCI Hypergraph Orchestration

Real-time hypergraph visualization with:
- ASCII dashboard for terminal
- Web dashboard (optional) for browser-based monitoring
- Stream throughput metrics
- Container resource usage
- Phase latency measurements
"""

import asyncio
import json
import time
import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Any, Tuple
from collections import defaultdict, deque
from datetime import datetime
import sys


@dataclass
class MetricSample:
    """Single metric sample"""
    timestamp: float
    value: float
    labels: Dict[str, str] = field(default_factory=dict)


class MetricHistory:
    """Ring buffer for metric history"""
    
    def __init__(self, max_samples: int = 1000):
        self.max_samples = max_samples
        self.samples: deque = deque(maxlen=max_samples)
    
    def add(self, value: float, labels: Optional[Dict[str, str]] = None):
        """Add a sample"""
        self.samples.append(MetricSample(
            timestamp=time.time(),
            value=value,
            labels=labels or {}
        ))
    
    def get_latest(self) -> Optional[MetricSample]:
        """Get most recent sample"""
        return self.samples[-1] if self.samples else None
    
    def get_average(self, window_seconds: float = 60.0) -> float:
        """Get average over time window"""
        cutoff = time.time() - window_seconds
        values = [s.value for s in self.samples if s.timestamp >= cutoff]
        return sum(values) / len(values) if values else 0.0
    
    def get_rate(self, window_seconds: float = 60.0) -> float:
        """Get rate of change"""
        cutoff = time.time() - window_seconds
        recent = [s for s in self.samples if s.timestamp >= cutoff]
        if len(recent) < 2:
            return 0.0
        
        first, last = recent[0], recent[-1]
        time_diff = last.timestamp - first.timestamp
        if time_diff == 0:
            return 0.0
        
        return (last.value - first.value) / time_diff


class MetricsCollector:
    """Collects and stores metrics from the pipeline"""
    
    def __init__(self):
        self.logger = logging.getLogger('MetricsCollector')
        
        # Metric storage
        self.metrics: Dict[str, MetricHistory] = defaultdict(lambda: MetricHistory())
        
        # Phase metrics
        self.phase_metrics: Dict[str, Dict[str, MetricHistory]] = defaultdict(
            lambda: defaultdict(lambda: MetricHistory())
        )
        
        # Stream metrics
        self.stream_metrics: Dict[str, Dict[str, MetricHistory]] = defaultdict(
            lambda: defaultdict(lambda: MetricHistory())
        )
        
        self._running = False
    
    def record(self, metric_name: str, value: float, labels: Optional[Dict[str, str]] = None):
        """Record a metric value"""
        self.metrics[metric_name].add(value, labels)
    
    def record_phase_metric(self, phase: str, metric: str, value: float):
        """Record a phase-specific metric"""
        self.phase_metrics[phase][metric].add(value)
    
    def record_stream_metric(self, stream: str, metric: str, value: float):
        """Record a stream-specific metric"""
        self.stream_metrics[stream][metric].add(value)
    
    def get_metric(self, name: str) -> Optional[MetricHistory]:
        """Get metric history"""
        return self.metrics.get(name)
    
    def get_all_metrics(self) -> Dict[str, Any]:
        """Get all current metrics"""
        result = {
            'global': {},
            'phases': {},
            'streams': {},
            'timestamp': time.time()
        }
        
        for name, history in self.metrics.items():
            latest = history.get_latest()
            if latest:
                result['global'][name] = {
                    'current': latest.value,
                    'avg_1m': history.get_average(60),
                    'rate': history.get_rate(60)
                }
        
        for phase, metrics in self.phase_metrics.items():
            result['phases'][phase] = {
                metric: {
                    'current': hist.get_latest().value if hist.get_latest() else 0,
                    'avg': hist.get_average(60)
                }
                for metric, hist in metrics.items()
            }
        
        for stream, metrics in self.stream_metrics.items():
            result['streams'][stream] = {
                metric: {
                    'current': hist.get_latest().value if hist.get_latest() else 0,
                    'avg': hist.get_average(60)
                }
                for metric, hist in metrics.items()
            }
        
        return result


class AsciiDashboard:
    """ASCII-based terminal dashboard"""
    
    def __init__(self, metrics_collector: MetricsCollector):
        self.metrics = metrics_collector
        self.logger = logging.getLogger('AsciiDashboard')
        self._running = False
        self.update_interval = 1.0
    
    def _clear_screen(self):
        """Clear terminal screen"""
        sys.stdout.write('\033[2J\033[H')
        sys.stdout.flush()
    
    def _hide_cursor(self):
        """Hide cursor"""
        sys.stdout.write('\033[?25l')
        sys.stdout.flush()
    
    def _show_cursor(self):
        """Show cursor"""
        sys.stdout.write('\033[?25h')
        sys.stdout.flush()
    
    def _draw_box(self, x: int, y: int, width: int, height: int, 
                  title: str = "", border_color: str = ""):
        """Draw a box with optional title"""
        # Top border
        line = "┌" + "─" * (width - 2) + "┐"
        if title:
            title_str = f" {title} "
            line = "┌" + title_str + "─" * (width - 2 - len(title_str)) + "┐"
        print(f"\033[{y};{x}H{line}")
        
        # Sides
        for i in range(1, height - 1):
            print(f"\033[{y+i};{x}H│")
            print(f"\033[{y+i};{x+width-1}H│")
        
        # Bottom border
        print(f"\033[{y+height-1};{x}H└" + "─" * (width - 2) + "┘")
    
    def _draw_text(self, x: int, y: int, text: str):
        """Draw text at position"""
        print(f"\033[{y};{x}H{text}")
    
    def _draw_bar(self, x: int, y: int, width: int, value: float, 
                  max_value: float, color: str = ""):
        """Draw a progress bar"""
        if max_value == 0:
            filled = 0
        else:
            filled = int((value / max_value) * width)
        
        filled = min(filled, width)
        
        bar = "█" * filled + "░" * (width - filled)
        print(f"\033[{y};{x}H[{bar}]")
    
    def _draw_sparkline(self, history: MetricHistory, width: int = 50) -> str:
        """Draw ASCII sparkline"""
        samples = list(history.samples)[-width:]
        if not samples:
            return " " * width
        
        values = [s.value for s in samples]
        min_val, max_val = min(values), max(values)
        
        if max_val == min_val:
            return "─" * len(samples)
        
        chars = " ▁▂▃▄▅▆▇█"
        result = ""
        for v in values:
            idx = int((v - min_val) / (max_val - min_val) * (len(chars) - 1))
            result += chars[idx]
        
        return result
    
    def render(self, orchestrator_status: Optional[Dict] = None):
        """Render the dashboard"""
        self._clear_screen()
        
        # Header
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print("╔══════════════════════════════════════════════════════════════════════════════╗")
        print(f"║  🧠 BCI Hypergraph Monitor                                    {now}   ║")
        print("╠══════════════════════════════════════════════════════════════════════════════╣")
        
        # Get metrics
        metrics = self.metrics.get_all_metrics()
        
        # Pipeline Overview
        if orchestrator_status:
            running = orchestrator_status.get('running', False)
            status = "🟢 RUNNING" if running else "🔴 STOPPED"
            print(f"║  Pipeline Status: {status:67} ║")
            print("║                                                                              ║")
            
            # Phases section
            print("║  ┌─ Phase Status ─────────────────────────────────────────────────────────┐  ║")
            for name, info in orchestrator_status.get('phases', {}).items():
                state = info.get('state', 'UNKNOWN')
                replicas = info.get('running_replicas', 0)
                target = info.get('target_replicas', 0)
                
                state_icon = {
                    'HEALTHY': '🟢', 'RUNNING': '🟢',
                    'STARTING': '🟡', 'STOPPING': '🟠',
                    'STOPPED': '⚪', 'FAILED': '🔴'
                }.get(state, '⚪')
                
                line = f"│  {state_icon} {name:15} [{state:12}] {replicas}/{target} replicas"
                line = line.ljust(76) + "│"
                print(f"║  {line}  ║")
            print("║  └────────────────────────────────────────────────────────────────────────┘  ║")
            print("║                                                                              ║")
        
        # Stream Metrics
        print("║  ┌─ Stream Throughput ────────────────────────────────────────────────────┐  ║")
        for stream_name, stream_data in metrics.get('streams', {}).items():
            throughput = stream_data.get('throughput', {}).get('current', 0)
            line = f"│  📡 {stream_name:20} {throughput:10.1f} packets/s"
            line = line.ljust(76) + "│"
            print(f"║  {line}  ║")
        print("║  └────────────────────────────────────────────────────────────────────────┘  ║")
        print("║                                                                              ║")
        
        # Resource Usage
        print("║  ┌─ Resource Usage ───────────────────────────────────────────────────────┐  ║")
        for phase_name, phase_data in metrics.get('phases', {}).items():
            cpu = phase_data.get('cpu_percent', {}).get('current', 0)
            mem = phase_data.get('memory_mb', {}).get('current', 0)
            
            cpu_bar = self._render_bar(cpu, 100, 20)
            line = f"│  {phase_name:15} CPU: [{cpu_bar}] {cpu:5.1f}%  MEM: {mem:6.1f} MB"
            line = line.ljust(76) + "│"
            print(f"║  {line}  ║")
        print("║  └────────────────────────────────────────────────────────────────────────┘  ║")
        print("║                                                                              ║")
        
        # Latency Metrics
        print("║  ┌─ Latency Measurements ─────────────────────────────────────────────────┐  ║")
        for phase_name, phase_data in metrics.get('phases', {}).items():
            latency = phase_data.get('latency_ms', {}).get('current', 0)
            sparkline = ""
            if phase_name in self.metrics.phase_metrics and 'latency_ms' in self.metrics.phase_metrics[phase_name]:
                sparkline = self._draw_sparkline(self.metrics.phase_metrics[phase_name]['latency_ms'], 30)
            
            line = f"│  {phase_name:15} {latency:6.2f}ms  {sparkline}"
            line = line.ljust(76) + "│"
            print(f"║  {line}  ║")
        print("║  └────────────────────────────────────────────────────────────────────────┘  ║")
        
        # Footer
        print("║                                                                              ║")
        print("║  Press Ctrl+C to exit                                                        ║")
        print("╚══════════════════════════════════════════════════════════════════════════════╝")
    
    def _render_bar(self, value: float, max_val: float, width: int) -> str:
        """Render a simple progress bar"""
        if max_val == 0:
            filled = 0
        else:
            filled = int((value / max_val) * width)
        
        filled = max(0, min(filled, width))
        return "█" * filled + "░" * (width - filled)
    
    async def run(self, orchestrator=None, update_interval: float = 1.0):
        """Run the dashboard"""
        self._running = True
        self.update_interval = update_interval
        
        self._hide_cursor()
        
        try:
            while self._running:
                status = None
                if orchestrator:
                    try:
                        status = orchestrator.get_status()
                    except:
                        pass
                
                self.render(status)
                await asyncio.sleep(update_interval)
                
        except asyncio.CancelledError:
            pass
        finally:
            self._show_cursor()
    
    def stop(self):
        """Stop the dashboard"""
        self._running = False


class WebDashboard:
    """Web-based monitoring dashboard (optional)"""
    
    def __init__(self, metrics_collector: MetricsCollector, port: int = 8080):
        self.metrics = metrics_collector
        self.port = port
        self.logger = logging.getLogger('WebDashboard')
        self._running = False
        self.app = None
    
    async def start(self):
        """Start web dashboard"""
        try:
            from aiohttp import web
            
            self.app = web.Application()
            self.app.router.add_get('/', self._handle_index)
            self.app.router.add_get('/api/metrics', self._handle_metrics)
            self.app.router.add_get('/api/status', self._handle_status)
            self.app.router.add_get('/ws', self._handle_websocket)
            
            runner = web.AppRunner(self.app)
            await runner.setup()
            
            site = web.TCPSite(runner, '0.0.0.0', self.port)
            await site.start()
            
            self._running = True
            self.logger.info(f"Web dashboard started at http://localhost:{self.port}")
            
            # Start metrics broadcaster
            asyncio.create_task(self._broadcast_metrics())
            
        except ImportError:
            self.logger.error("aiohttp not installed. Web dashboard unavailable.")
            raise
    
    async def _handle_index(self, request):
        """Serve main page"""
        html = """
<!DOCTYPE html>
<html>
<head>
    <title>BCI Hypergraph Monitor</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Courier New', monospace;
            background: #1a1a2e;
            color: #eee;
            padding: 20px;
        }
        h1 { color: #00d4aa; margin-bottom: 20px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
        .panel {
            background: #16213e;
            border: 1px solid #0f3460;
            border-radius: 8px;
            padding: 15px;
        }
        .panel h2 { color: #e94560; margin-bottom: 10px; font-size: 14px; }
        .metric { display: flex; justify-content: space-between; margin: 5px 0; }
        .metric-name { color: #a0a0a0; }
        .metric-value { color: #00d4aa; font-weight: bold; }
        .status-running { color: #00ff88; }
        .status-stopped { color: #ff4444; }
        .sparkline { font-family: monospace; color: #00d4aa; }
        .phase-item {
            display: flex;
            align-items: center;
            padding: 5px 0;
            border-bottom: 1px solid #0f3460;
        }
        .phase-icon { margin-right: 10px; }
        .bar-container {
            width: 100%;
            height: 8px;
            background: #0f3460;
            border-radius: 4px;
            overflow: hidden;
            margin-top: 5px;
        }
        .bar-fill {
            height: 100%;
            background: linear-gradient(90deg, #00d4aa, #00ff88);
            transition: width 0.3s ease;
        }
    </style>
</head>
<body>
    <h1>🧠 BCI Hypergraph Monitor</h1>
    <div class="grid">
        <div class="panel">
            <h2>Pipeline Status</h2>
            <div id="pipeline-status">Connecting...</div>
        </div>
        <div class="panel">
            <h2>Phase Health</h2>
            <div id="phase-health">Loading...</div>
        </div>
        <div class="panel">
            <h2>Stream Throughput</h2>
            <div id="stream-metrics">Loading...</div>
        </div>
        <div class="panel">
            <h2>Resource Usage</h2>
            <div id="resource-usage">Loading...</div>
        </div>
    </div>
    <script>
        const ws = new WebSocket(`ws://${window.location.host}/ws`);
        ws.onmessage = (event) => {
            const data = JSON.parse(event.data);
            updateDashboard(data);
        };
        
        function updateDashboard(data) {
            // Update pipeline status
            const statusDiv = document.getElementById('pipeline-status');
            const running = data.global?.pipeline_running?.current;
            statusDiv.innerHTML = `<span class="${running ? 'status-running' : 'status-stopped'}">${running ? '🟢 RUNNING' : '🔴 STOPPED'}</span>`;
            
            // Update phase health
            const phaseDiv = document.getElementById('phase-health');
            phaseDiv.innerHTML = Object.entries(data.phases || {}).map(([name, metrics]) => {
                const cpu = metrics.cpu_percent?.current || 0;
                return `<div class="phase-item">
                    <span class="phase-icon">🟢</span>
                    <span>${name}</span>
                    <span>${cpu.toFixed(1)}% CPU</span>
                </div>`;
            }).join('');
            
            // Update stream metrics
            const streamDiv = document.getElementById('stream-metrics');
            streamDiv.innerHTML = Object.entries(data.streams || {}).map(([name, metrics]) => {
                const throughput = metrics.throughput?.current || 0;
                return `<div class="metric">
                    <span class="metric-name">${name}</span>
                    <span class="metric-value">${throughput.toFixed(1)} pkt/s</span>
                </div>`;
            }).join('');
        }
    </script>
</body>
</html>
"""
        from aiohttp import web
        return web.Response(text=html, content_type='text/html')
    
    async def _handle_metrics(self, request):
        """API endpoint for metrics"""
        from aiohttp import web
        metrics = self.metrics.get_all_metrics()
        return web.json_response(metrics)
    
    async def _handle_status(self, request):
        """API endpoint for status"""
        from aiohttp import web
        return web.json_response({
            'running': self._running,
            'timestamp': time.time()
        })
    
    async def _handle_websocket(self, request):
        """WebSocket endpoint for real-time updates"""
        from aiohttp import web, WSMsgType
        
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        
        self.logger.info("WebSocket client connected")
        
        try:
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    # Send current metrics
                    metrics = self.metrics.get_all_metrics()
                    await ws.send_json(metrics)
                elif msg.type == WSMsgType.ERROR:
                    self.logger.error(f"WebSocket error: {ws.exception()}")
        finally:
            self.logger.info("WebSocket client disconnected")
        
        return ws
    
    async def _broadcast_metrics(self):
        """Broadcast metrics to all WebSocket clients"""
        while self._running:
            # This would broadcast to connected WebSocket clients
            await asyncio.sleep(1.0)
    
    async def stop(self):
        """Stop web dashboard"""
        self._running = False


class Monitor:
    """Main monitoring system combining all dashboards"""
    
    def __init__(self, config_path: str = "hypergraph_config.yaml"):
        self.config_path = config_path
        self.logger = logging.getLogger('Monitor')
        
        self.metrics = MetricsCollector()
        self.ascii_dashboard = AsciiDashboard(self.metrics)
        self.web_dashboard: Optional[WebDashboard] = None
        
        self._running = False
        self._orchestrator = None
    
    def enable_web(self, port: int = 8080):
        """Enable web dashboard"""
        self.web_dashboard = WebDashboard(self.metrics, port)
    
    async def start(self, ascii_mode: bool = True, web_mode: bool = False,
                    orchestrator=None):
        """Start monitoring"""
        self._running = True
        self._orchestrator = orchestrator
        
        tasks = []
        
        if ascii_mode:
            tasks.append(asyncio.create_task(
                self.ascii_dashboard.run(orchestrator, update_interval=1.0)
            ))
        
        if web_mode and self.web_dashboard:
            await self.web_dashboard.start()
        
        # Start metrics collection
        tasks.append(asyncio.create_task(self._collect_metrics()))
        
        try:
            await asyncio.gather(*tasks)
        except asyncio.CancelledError:
            pass
        finally:
            await self.stop()
    
    async def _collect_metrics(self):
        """Collect metrics from orchestrator and routers"""
        while self._running:
            try:
                # Collect from orchestrator
                if self._orchestrator:
                    status = self._orchestrator.get_status()
                    self.metrics.record('pipeline_running', 
                                       1.0 if status.get('running') else 0.0)
                    
                    # Phase metrics
                    for phase_name, phase_info in status.get('phases', {}).items():
                        replicas = phase_info.get('running_replicas', 0)
                        self.metrics.record_phase_metric(
                            phase_name, 'replicas', float(replicas)
                        )
                
                # Simulate some metrics for demo
                import random
                for phase in ['acquisition', 'preprocessing', 'analysis', 'visualizer']:
                    self.metrics.record_phase_metric(
                        phase, 'cpu_percent', random.uniform(10, 80)
                    )
                    self.metrics.record_phase_metric(
                        phase, 'memory_mb', random.uniform(100, 500)
                    )
                    self.metrics.record_phase_metric(
                        phase, 'latency_ms', random.uniform(1, 50)
                    )
                
                for stream in ['raw_eeg', 'filtered_eeg', 'features', 'classification']:
                    self.metrics.record_stream_metric(
                        stream, 'throughput', random.uniform(100, 1000)
                    )
                
                await asyncio.sleep(1.0)
                
            except Exception as e:
                self.logger.error(f"Metrics collection error: {e}")
                await asyncio.sleep(5.0)
    
    async def stop(self):
        """Stop monitoring"""
        self._running = False
        self.ascii_dashboard.stop()
        
        if self.web_dashboard:
            await self.web_dashboard.stop()


async def main():
    """Run monitor standalone"""
    import argparse
    
    parser = argparse.ArgumentParser(description='BCI Hypergraph Monitor')
    parser.add_argument('--ascii', action='store_true', default=True,
                        help='Enable ASCII dashboard (default)')
    parser.add_argument('--web', action='store_true',
                        help='Enable web dashboard')
    parser.add_argument('--web-port', type=int, default=8080,
                        help='Web dashboard port (default: 8080)')
    parser.add_argument('-c', '--config', default='hypergraph_config.yaml',
                        help='Configuration file')
    
    args = parser.parse_args()
    
    logging.basicConfig(level=logging.INFO)
    
    monitor = Monitor(args.config)
    
    if args.web:
        monitor.enable_web(args.web_port)
    
    try:
        await monitor.start(
            ascii_mode=args.ascii,
            web_mode=args.web
        )
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        await monitor.stop()


if __name__ == "__main__":
    asyncio.run(main())
