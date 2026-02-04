#!/bin/bash
#
# Run script for Apple Containerization
# Starts BCI data processing container with proper network configuration
#

set -e

# Configuration
IMAGE_NAME="${IMAGE_NAME:-bci-processor}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-bci-processor}"

# Port mappings (host:container)
LSL_PORT_HOST="${LSL_PORT_HOST:-16571}"
LSL_PORT_CONTAINER="${LSL_PORT_CONTAINER:-16571}"
TCP_PORT_HOST="${TCP_PORT_HOST:-16572}"
TCP_PORT_CONTAINER="${TCP_PORT_CONTAINER:-16572}"
WS_PORT_HOST="${WS_PORT_HOST:-8080}"
WS_PORT_CONTAINER="${WS_PORT_CONTAINER:-8080}"
HEALTH_PORT_HOST="${HEALTH_PORT_HOST:-8081}"
HEALTH_PORT_CONTAINER="${HEALTH_PORT_CONTAINER:-8081}"

# Data directories
DATA_DIR="${DATA_DIR:-$PWD/data}"
LOG_DIR="${LOG_DIR:-$PWD/logs}"

# Environment variables for container
LSL_INPUT_NAME="${LSL_INPUT_NAME:-OpenBCI}"
LSL_OUTPUT_NAME="${LSL_OUTPUT_NAME:-BCI-Processed}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[RUN]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Print banner
echo "========================================"
echo "  BCI Processor Container Run"
echo "  Apple Containerization"
echo "========================================"
echo ""

# Check if container command is available
if command -v container &> /dev/null; then
    CONTAINER_CMD="container"
    # Check if we're using apple-containerization
    if $CONTAINER_CMD --help 2>&1 | grep -q "apple"; then
        IS_APPLE_CONTAINER=1
        log_info "Using Apple Containerization"
    else
        IS_APPLE_CONTAINER=0
    fi
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    IS_APPLE_CONTAINER=0
    log_warn "Using podman as fallback"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    IS_APPLE_CONTAINER=0
    log_warn "Using docker as fallback"
else
    log_error "No container runtime found (container/podman/docker)"
    exit 1
fi

# Create data directories
mkdir -p "$DATA_DIR/recordings" "$LOG_DIR"

# Check if container already exists
if $CONTAINER_CMD ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    log_warn "Container '$CONTAINER_NAME' already exists"
    read -p "Remove existing container? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        log_info "Removing existing container..."
        $CONTAINER_CMD rm -f "$CONTAINER_NAME"
    else
        log_error "Cannot continue with existing container"
        exit 1
    fi
fi

# Build run arguments
RUN_ARGS=""

# Platform (Apple Silicon)
RUN_ARGS="$RUN_ARGS --platform linux/arm64"

# Container name
RUN_ARGS="$RUN_ARGS --name $CONTAINER_NAME"

# Port mappings
RUN_ARGS="$RUN_ARGS -p $LSL_PORT_HOST:$LSL_PORT_CONTAINER"
RUN_ARGS="$RUN_ARGS -p $TCP_PORT_HOST:$TCP_PORT_CONTAINER"
RUN_ARGS="$RUN_ARGS -p $WS_PORT_HOST:$WS_PORT_CONTAINER"
RUN_ARGS="$RUN_ARGS -p $HEALTH_PORT_HOST:$HEALTH_PORT_CONTAINER"

# Volume mounts for data persistence
RUN_ARGS="$RUN_ARGS -v $DATA_DIR/recordings:/app/data/recordings"
RUN_ARGS="$RUN_ARGS -v $LOG_DIR:/app/logs"

# Network configuration for Apple Containerization
if [ "$IS_APPLE_CONTAINER" -eq 1 ]; then
    # Apple Containerization specific network settings
    # Allow container to communicate with host services (LSL stream)
    RUN_ARGS="$RUN_ARGS --network host"
else
    # For podman/docker, use host networking or explicit host access
    RUN_ARGS="$RUN_ARGS --add-host=host.containers.internal:host-gateway"
fi

# Environment variables
RUN_ARGS="$RUN_ARGS -e LSL_INPUT_NAME=$LSL_INPUT_NAME"
RUN_ARGS="$RUN_ARGS -e LSL_OUTPUT_NAME=$LSL_OUTPUT_NAME"
RUN_ARGS="$RUN_ARGS -e WEBSOCKET_PORT=$WS_PORT_CONTAINER"
RUN_ARGS="$RUN_ARGS -e HEALTH_PORT=$HEALTH_PORT_CONTAINER"
RUN_ARGS="$RUN_ARGS -e RECORDING_DIR=/app/data/recordings"
RUN_ARGS="$RUN_ARGS -e LOG_DIR=/app/logs"
RUN_ARGS="$RUN_ARGS -e PYTHONUNBUFFERED=1"

# Resource limits (adjust based on your system)
RUN_ARGS="$RUN_ARGS --memory=2g"
RUN_ARGS="$RUN_ARGS --cpus=2"

# Auto-remove on stop (optional, remove for debugging)
# RUN_ARGS="$RUN_ARGS --rm"

# Detached mode (remove -it for production)
INTERACTIVE="${INTERACTIVE:-1}"
if [ "$INTERACTIVE" -eq 1 ]; then
    RUN_ARGS="$RUN_ARGS -it"
else
    RUN_ARGS="$RUN_ARGS -d"
fi

echo ""
echo "Configuration:"
echo "  Image: $IMAGE_NAME:$IMAGE_TAG"
echo "  Container: $CONTAINER_NAME"
echo "  LSL Input: $LSL_INPUT_NAME"
echo "  Ports:"
echo "    LSL:      $LSL_PORT_HOST → $LSL_PORT_CONTAINER"
echo "    TCP:      $TCP_PORT_HOST → $TCP_PORT_CONTAINER"
echo "    WebSocket:$WS_PORT_HOST → $WS_PORT_CONTAINER"
echo "    Health:   $HEALTH_PORT_HOST → $HEALTH_PORT_CONTAINER"
echo "  Data: $DATA_DIR"
echo "  Logs: $LOG_DIR"
echo ""

# Run the container
log_info "Starting BCI processor container..."
echo ""

$CONTAINER_CMD run $RUN_ARGS "$IMAGE_NAME:$IMAGE_TAG"

RUN_EXIT=$?

if [ $RUN_EXIT -eq 0 ]; then
    if [ "$INTERACTIVE" -eq 0 ]; then
        echo ""
        log_success "Container started in detached mode!"
        echo ""
        echo "Container status:"
        $CONTAINER_CMD ps --filter "name=$CONTAINER_NAME" --format "  Status: {{.Status}}\n  ID: {{.ID}}"
        echo ""
        echo "Health check:"
        sleep 2
        curl -s "http://localhost:$HEALTH_PORT_HOST/health" 2>/dev/null || echo "  (Health endpoint not ready yet)"
        echo ""
        echo "View logs:"
        echo "  $CONTAINER_CMD logs -f $CONTAINER_NAME"
        echo ""
        echo "Stop container:"
        echo "  $CONTAINER_CMD stop $CONTAINER_NAME"
    fi
else
    log_error "Failed to start container (exit code: $RUN_EXIT)"
    exit $RUN_EXIT
fi
