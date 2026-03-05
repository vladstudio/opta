#!/bin/bash
set -e

APP_NAME="Opta"
INSTALL_DIR="/usr/local/bin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1"; exit 1; }

# Check macOS
[[ "$(uname)" == "Darwin" ]] || error "This script only runs on macOS"

# Check macOS version (need 13+)
MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
[[ "$MACOS_VERSION" -ge 13 ]] || error "macOS 13 (Ventura) or later required"

# Check Swift
command -v swift &>/dev/null || error "Swift is required. Install Xcode or Xcode Command Line Tools."

# Check/install brew dependencies
info "Checking dependencies..."
MISSING=()
command -v pngquant &>/dev/null || MISSING+=(pngquant)
command -v oxipng &>/dev/null || MISSING+=(oxipng)
command -v cwebp &>/dev/null || MISSING+=(webp)

if [[ ${#MISSING[@]} -gt 0 ]]; then
    command -v brew &>/dev/null || error "Homebrew is required to install dependencies. https://brew.sh"
    info "Installing ${MISSING[*]}..."
    brew install "${MISSING[@]}"
fi

# Build
info "Building $APP_NAME (release)..."
swift build -c release 2>&1 | tail -1

# Install
info "Installing to $INSTALL_DIR..."
cp .build/release/opta "$INSTALL_DIR/opta"

echo ""
info "$APP_NAME installed! Run with: opta"
