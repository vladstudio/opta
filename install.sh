#!/bin/bash
set -e

REPO="vladstudio/opta"
APP_NAME="opta"
INSTALL_DIR="/usr/local/bin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1"; exit 1; }

# Check macOS
[[ "$(uname)" == "Darwin" ]] || error "This script only runs on macOS"

# Check Apple Silicon
[[ "$(uname -m)" == "arm64" ]] || error "This app requires Apple Silicon"

# Check macOS version (need 13+)
MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
[[ "$MACOS_VERSION" -ge 13 ]] || error "macOS 13 (Ventura) or later required"

# Check/install brew dependencies
info "Checking dependencies..."
command -v brew &>/dev/null || error "Homebrew is required. https://brew.sh"

MISSING=()
command -v pngquant &>/dev/null || MISSING+=(pngquant)
command -v oxipng &>/dev/null || MISSING+=(oxipng)
command -v cwebp &>/dev/null || MISSING+=(webp)

if [[ ${#MISSING[@]} -gt 0 ]]; then
    info "Installing ${MISSING[*]}..."
    brew install "${MISSING[@]}"
fi

# Get latest release URL
info "Fetching latest release..."
DOWNLOAD_URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*"' | head -1 | cut -d '"' -f 4)

[[ -n "$DOWNLOAD_URL" ]] || error "Could not find release. Check https://github.com/$REPO/releases"

info "Downloading $APP_NAME..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -sL "$DOWNLOAD_URL" -o "$TMP_DIR/$APP_NAME.zip"

info "Installing to $INSTALL_DIR..."
unzip -q "$TMP_DIR/$APP_NAME.zip" -d "$TMP_DIR"
if [[ -w "$INSTALL_DIR" ]]; then
    cp "$TMP_DIR/$APP_NAME" "$INSTALL_DIR/$APP_NAME"
else
    sudo cp "$TMP_DIR/$APP_NAME" "$INSTALL_DIR/$APP_NAME"
fi
chmod +x "$INSTALL_DIR/$APP_NAME"

echo ""
info "$APP_NAME installed! Run with: opta"
