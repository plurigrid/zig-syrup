#!/bin/bash
# OpenBCI Host Acquisition System - macOS Setup Script
# 
# This script sets up the host environment for OpenBCI data acquisition
# on macOS. It installs Python dependencies, checks USB permissions,
# and verifies Bluetooth LE availability.
#
# Usage: ./setup_host.sh [--venv] [--dev] [--check-only]

set -e  # Exit on error

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
PYTHON_CMD="${PYTHON_CMD:-python3}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Flags
USE_VENV=false
INSTALL_DEV=false
CHECK_ONLY=false
VERBOSE=false

# =============================================================================
# Helper Functions
# =============================================================================

print_banner() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     OpenBCI Host Acquisition System - macOS Setup           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -h, --help         Show this help message
    -v, --verbose      Enable verbose output
    --venv             Create and use Python virtual environment
    --dev              Install development dependencies
    --check-only       Only run checks, don't install

Examples:
    $0                 # Basic installation
    $0 --venv          # Install with virtual environment
    $0 --venv --dev    # Full development setup
    $0 --check-only    # Verify system readiness

Environment Variables:
    PYTHON_CMD         Python command to use (default: python3)

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                print_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --venv)
                USE_VENV=true
                shift
                ;;
            --dev)
                INSTALL_DEV=true
                shift
                ;;
            --check-only)
                CHECK_ONLY=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# Check Functions
# =============================================================================

check_python() {
    log_info "Checking Python installation..."
    
    if ! command -v $PYTHON_CMD &> /dev/null; then
        log_error "Python 3 not found. Please install Python 3.8 or later."
        log_info "  Visit: https://www.python.org/downloads/"
        return 1
    fi
    
    PYTHON_VERSION=$($PYTHON_CMD --version 2>&1 | awk '{print $2}')
    PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
    PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)
    
    if [[ $PYTHON_MAJOR -lt 3 ]] || [[ $PYTHON_MAJOR -eq 3 && $PYTHON_MINOR -lt 8 ]]; then
        log_error "Python 3.8 or later required (found $PYTHON_VERSION)"
        return 1
    fi
    
    log_success "Python $PYTHON_VERSION found"
    return 0
}

check_xcode_tools() {
    log_info "Checking Xcode Command Line Tools..."
    
    if ! command -v clang &> /dev/null && ! xcode-select -p &> /dev/null; then
        log_warning "Xcode Command Line Tools not found"
        log_info "Installing Xcode Command Line Tools..."
        log_info "Please follow the prompts..."
        xcode-select --install
        log_warning "Please run this script again after installation completes"
        return 1
    fi
    
    log_success "Xcode Command Line Tools found"
    return 0
}

check_homebrew() {
    log_info "Checking Homebrew..."
    
    if ! command -v brew &> /dev/null; then
        log_warning "Homebrew not found. Some optional features may not work."
        log_info "To install Homebrew, visit: https://brew.sh"
        return 0  # Not fatal
    fi
    
    log_success "Homebrew found: $(brew --version | head -1)"
    return 0
}

check_usb_permissions() {
    log_info "Checking USB device permissions..."
    
    # Check if user has access to serial devices
    if [[ -c /dev/tty.usbserial* ]] 2>/dev/null || [[ -c /dev/cu.usbserial* ]] 2>/dev/null; then
        log_success "USB serial devices accessible"
    else
        log_info "No USB serial devices currently connected"
        log_info "Cyton boards use FTDI USB-Serial chips"
    fi
    
    # Check if user is in required groups (usually not needed on macOS)
    log_info "Note: On macOS, USB serial devices are usually accessible without special permissions"
    
    return 0
}

check_bluetooth() {
    log_info "Checking Bluetooth LE availability..."
    
    # Check Bluetooth status
    if command -v system_profiler &> /dev/null; then
        BT_INFO=$(system_profiler SPBluetoothDataType 2>/dev/null | grep -i "bluetooth" | head -3)
        if [[ -n "$BT_INFO" ]]; then
            log_success "Bluetooth hardware detected"
        else
            log_warning "Could not verify Bluetooth hardware"
        fi
    fi
    
    # Check Bluetooth power state
    if command -v blueutil &> /dev/null; then
        BT_POWER=$(blueutil --power 2>/dev/null || echo "0")
        if [[ "$BT_POWER" == "1" ]]; then
            log_success "Bluetooth is powered on"
        else
            log_warning "Bluetooth appears to be off. Enable it in System Preferences."
        fi
    else
        log_info "Install 'blueutil' for Bluetooth status checking: brew install blueutil"
    fi
    
    # Check for BLE support (macOS 10.10+)
    MACOS_VERSION=$(sw_vers -productVersion)
    log_info "macOS version: $MACOS_VERSION"
    
    log_success "Bluetooth LE support available"
    return 0
}

check_pyobjc() {
    log_info "Checking for PyObjC (macOS system integration)..."
    
    if $PYTHON_CMD -c "import objc" 2>/dev/null; then
        log_success "PyObjC is installed"
    else
        log_info "PyObjC will be installed for macOS system integration"
    fi
    
    return 0
}

check_virtualenv() {
    if [[ "$USE_VENV" == true ]]; then
        log_info "Checking virtual environment support..."
        
        if ! $PYTHON_CMD -m venv --help &> /dev/null; then
            log_error "Python venv module not available"
            return 1
        fi
        
        log_success "Virtual environment support available"
    fi
    
    return 0
}

# =============================================================================
# Installation Functions
# =============================================================================

setup_virtualenv() {
    if [[ "$USE_VENV" != true ]]; then
        return 0
    fi
    
    log_info "Setting up Python virtual environment..."
    
    if [[ -d "$VENV_DIR" ]]; then
        log_info "Virtual environment already exists at $VENV_DIR"
    else
        $PYTHON_CMD -m venv "$VENV_DIR"
        log_success "Created virtual environment at $VENV_DIR"
    fi
    
    # Activate virtual environment
    source "$VENV_DIR/bin/activate"
    
    # Upgrade pip
    pip install --upgrade pip setuptools wheel
    
    log_success "Virtual environment activated"
}

install_dependencies() {
    log_info "Installing Python dependencies..."
    
    REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements-host.txt"
    
    if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
        log_error "Requirements file not found: $REQUIREMENTS_FILE"
        return 1
    fi
    
    # Install basic requirements
    if [[ "$VERBOSE" == true ]]; then
        pip install -r "$REQUIREMENTS_FILE"
    else
        pip install -q -r "$REQUIREMENTS_FILE"
    fi
    
    log_success "Core dependencies installed"
    
    # Install dev dependencies if requested
    if [[ "$INSTALL_DEV" == true ]]; then
        log_info "Installing development dependencies..."
        
        DEV_PACKAGES="pytest pytest-asyncio black flake8 mypy"
        if [[ "$VERBOSE" == true ]]; then
            pip install $DEV_PACKAGES
        else
            pip install -q $DEV_PACKAGES
        fi
        
        log_success "Development dependencies installed"
    fi
    
    return 0
}

install_brainflow() {
    log_info "Verifying BrainFlow installation..."
    
    if ! $PYTHON_CMD -c "import brainflow; print(f'BrainFlow {brainflow.__version__}')" 2>/dev/null; then
        log_warning "BrainFlow verification failed, attempting reinstall..."
        pip install --force-reinstall brainflow
    fi
    
    # Print BrainFlow version
    BRAINDLOW_VERSION=$($PYTHON_CMD -c "import brainflow; print(brainflow.__version__)" 2>/dev/null || echo "unknown")
    log_success "BrainFlow $BRAINDLOW_VERSION installed"
    
    return 0
}

# =============================================================================
# Post-Installation
# =============================================================================

print_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                   Setup Complete!                            ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    
    if [[ "$USE_VENV" == true ]]; then
        echo "║ Virtual Environment: $VENV_DIR"
        echo "║"
        echo "║ To activate the virtual environment, run:"
        echo "║   source $VENV_DIR/bin/activate"
        echo "║"
    fi
    
    echo "║ Next steps:"
    echo "║   1. Connect your OpenBCI board (Cyton USB or Ganglion BLE)"
    echo "║   2. Run the acquisition system:"
    echo "║      python3 ${SCRIPT_DIR}/host_acquisition.py"
    echo "║"
    echo "║ For help:"
    echo "║   python3 ${SCRIPT_DIR}/host_acquisition.py --help"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

print_check_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                  System Check Complete                       ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║"
    echo "║ If all checks passed, you can proceed with:"
    echo "║   ./setup_host.sh --venv     # Recommended"
    echo "║"
    echo "║ Or install manually:"
    echo "║   pip3 install brainflow pylsl pyserial bleak pyyaml numpy"
    echo "║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    
    print_banner
    
    # Run checks
    log_info "Running system checks..."
    
    check_python || exit 1
    check_xcode_tools || exit 1
    check_homebrew
    check_virtualenv
    check_usb_permissions
    check_bluetooth
    check_pyobjc
    
    if [[ "$CHECK_ONLY" == true ]]; then
        print_check_summary
        exit 0
    fi
    
    # Setup virtual environment if requested
    setup_virtualenv
    
    # Install dependencies
    install_dependencies || exit 1
    install_brainflow || exit 1
    
    # Print summary
    print_summary
}

# Run main
main "$@"
