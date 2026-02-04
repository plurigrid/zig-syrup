#!/bin/bash
#
# BCI Data Processing Container Entrypoint
# Phased Hypergraph Processing Pipeline for Apple Containerization
#

set -e

# Configuration
LSL_INPUT_NAME="${LSL_INPUT_NAME:-OpenBCI}"
LSL_OUTPUT_NAME="${LSL_OUTPUT_NAME:-BCI-Processed}"
WEBSOCKET_PORT="${WEBSOCKET_PORT:-8080}"
HEALTH_PORT="${HEALTH_PORT:-8081}"
RECORDING_DIR="${RECORDING_DIR:-/app/data/recordings}"
LOG_DIR="${LOG_DIR:-/app/data/logs}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Print banner
echo "========================================"
echo "  BCI Data Processing System"
echo "  Apple Containerization Edition"
echo "========================================"
echo ""

# Create necessary directories
mkdir -p "$RECORDING_DIR" "$LOG_DIR"

# Wait for host network availability
log_info "Checking network connectivity..."
for i in {1..30}; do
    if nc -z host.containers.internal 16571 2>/dev/null || \
       nc -z host.containers.internal 16572 2>/dev/null; then
        log_success "Host network is accessible"
        break
    fi
    
    if [ $i -eq 30 ]; then
        log_warn "Could not verify host network, continuing anyway..."
    else
        echo -n "."
        sleep 1
    fi
done
echo ""

# Check LSL library
log_info "Checking LSL library..."
if python3 -c "import pylsl; print(pylsl.library_version())" 2>/dev/null; then
    LSL_VERSION=$(python3 -c "import pylsl; print(pylsl.library_version())")
    log_success "LSL library loaded (version: $LSL_VERSION)"
else
    log_error "Failed to load LSL library"
    exit 1
fi

# Wait for LSL stream
log_info "Waiting for LSL stream '$LSL_INPUT_NAME'..."
log_info "This may take a few seconds..."

# Environment setup
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1

# Print configuration
echo ""
echo "----------------------------------------"
echo "Configuration:"
echo "  LSL Input:  $LSL_INPUT_NAME"
echo "  LSL Output: $LSL_OUTPUT_NAME"
echo "  WebSocket:  $WEBSOCKET_PORT"
echo "  Health:     $HEALTH_PORT"
echo "  Recordings: $RECORDING_DIR"
echo "  Logs:       $LOG_DIR"
echo "----------------------------------------"
echo ""

# Health check endpoint setup
setup_health_endpoint() {
    log_info "Setting up health check endpoint on port $HEALTH_PORT"
    
    # Simple health check using Python's built-in http.server
    python3 -c "
import http.server
import socketserver
import json
import os
import sys

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress health check logging
        pass
    
    def do_GET(self):
        if self.path == '/health' or self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            status = {
                'status': 'starting',
                'container': 'bci-processor',
                'timestamp': str(__import__('datetime').datetime.now())
            }
            self.wfile.write(json.dumps(status).encode())
        else:
            self.send_response(404)
            self.end_headers()

with socketserver.TCPServer(('0.0.0.0', $HEALTH_PORT), HealthHandler) as httpd:
    httpd.serve_forever()
" &
    HEALTH_PID=$!
    log_success "Health endpoint started (PID: $HEALTH_PID)"
}

# Cleanup function
cleanup() {
    echo ""
    log_info "Received shutdown signal, cleaning up..."
    
    if [ -n "$HEALTH_PID" ]; then
        kill $HEALTH_PID 2>/dev/null || true
    fi
    
    if [ -n "$PROCESSOR_PID" ]; then
        kill $PROCESSOR_PID 2>/dev/null || true
        wait $PROCESSOR_PID 2>/dev/null || true
    fi
    
    log_success "Cleanup complete"
    exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Start health endpoint
setup_health_endpoint

# Start the main processor
log_info "Starting BCI processing pipeline..."
log_info "Phases: Raw → Filter → Features → Classify"
echo ""

python3 /app/container_receiver.py &
PROCESSOR_PID=$!

# Wait for processor
wait $PROCESSOR_PID
PROCESSOR_EXIT=$?

if [ $PROCESSOR_EXIT -eq 0 ]; then
    log_success "Processor exited normally"
else
    log_error "Processor exited with code $PROCESSOR_EXIT"
fi

exit $PROCESSOR_EXIT
