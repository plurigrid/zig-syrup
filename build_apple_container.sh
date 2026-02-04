#!/bin/bash
#
# Build script for Apple Containerization
# Creates container image for BCI data processing
#

set -e

# Configuration
IMAGE_NAME="${IMAGE_NAME:-bci-processor}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTAINERFILE="${CONTAINERFILE:-Containerfile.bci-processor}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[BUILD]${NC} $1"
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
echo "  BCI Processor Container Build"
echo "  Apple Containerization"
echo "========================================"
echo ""

# Check if container command is available
if command -v container &> /dev/null; then
    CONTAINER_CMD="container"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    log_warn "Using podman as fallback"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    log_warn "Using docker as fallback"
else
    log_error "No container runtime found (container/podman/docker)"
    exit 1
fi

log_info "Using container runtime: $CONTAINER_CMD"

# Check if Containerfile exists
if [ ! -f "$CONTAINERFILE" ]; then
    log_error "Containerfile not found: $CONTAINERFILE"
    exit 1
fi

# Build arguments for Apple Silicon optimization
BUILD_ARGS=""
BUILD_ARGS="$BUILD_ARGS --platform linux/arm64"
BUILD_ARGS="$BUILD_ARGS --build-arg TARGETARCH=arm64"

# Optional: Use BuildKit for better caching
export DOCKER_BUILDKIT=1

# Build the container
log_info "Building container image: $IMAGE_NAME:$IMAGE_TAG"
echo "  Containerfile: $CONTAINERFILE"
echo "  Platform: linux/arm64"
echo ""

$CONTAINER_CMD build \
    -f "$CONTAINERFILE" \
    -t "$IMAGE_NAME:$IMAGE_TAG" \
    $BUILD_ARGS \
    .

BUILD_EXIT=$?

if [ $BUILD_EXIT -eq 0 ]; then
    echo ""
    log_success "Container built successfully!"
    echo ""
    echo "Image details:"
    $CONTAINER_CMD images "$IMAGE_NAME:$IMAGE_TAG" --format "  Name: {{.Repository}}:{{.Tag}}\n  Size: {{.Size}}\n  ID: {{.ID}}" 2>/dev/null || \
        $CONTAINER_CMD images | grep "$IMAGE_NAME"
    echo ""
    echo "To run the container:"
    echo "  ./run_apple_container.sh"
else
    log_error "Build failed with exit code $BUILD_EXIT"
    exit $BUILD_EXIT
fi
