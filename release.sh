#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Opta"

# Get current version from latest git tag, default to 1.0
CURRENT=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
CURRENT=${CURRENT:-1.0}
# Bump minor: 1.0 -> 1.1
MAJOR=${CURRENT%.*}
MINOR=${CURRENT##*.}
NEW="$MAJOR.$((MINOR + 1))"

echo "==> $CURRENT -> $NEW"

# Update version in Info.plist
plutil -replace CFBundleShortVersionString -string "$NEW" Info.plist
plutil -replace CFBundleVersion -string "$NEW" Info.plist

# Build release
swift build -c release 2>&1 | tail -1

# Assemble .app bundle
APP_DIR="/tmp/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp Info.plist "$APP_DIR/Contents/"
cp .build/release/opta "$APP_DIR/Contents/MacOS/opta"
cp -r .build/release/opta_opta.bundle "$APP_DIR/Contents/Resources/"

# Generate .icns from icon.png
ICONSET="/tmp/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16     icon.png --out "$ICONSET/icon_16x16.png"      > /dev/null
sips -z 32 32     icon.png --out "$ICONSET/icon_16x16@2x.png"   > /dev/null
sips -z 32 32     icon.png --out "$ICONSET/icon_32x32.png"      > /dev/null
sips -z 64 64     icon.png --out "$ICONSET/icon_32x32@2x.png"   > /dev/null
sips -z 128 128   icon.png --out "$ICONSET/icon_128x128.png"    > /dev/null
sips -z 256 256   icon.png --out "$ICONSET/icon_128x128@2x.png" > /dev/null
sips -z 256 256   icon.png --out "$ICONSET/icon_256x256.png"    > /dev/null
sips -z 512 512   icon.png --out "$ICONSET/icon_256x256@2x.png" > /dev/null
sips -z 512 512   icon.png --out "$ICONSET/icon_512x512.png"    > /dev/null
sips -z 1024 1024 icon.png --out "$ICONSET/icon_512x512@2x.png" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Commit, tag, push
git add Package.swift Sources/ install.sh release.sh LICENSE README.md icon.png opta-screenshot.png .gitignore Info.plist
git commit -m "v$NEW" || true
git push

# Zip and release
rm -f /tmp/$APP_NAME.zip
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" /tmp/$APP_NAME.zip
gh release create "v$NEW" /tmp/$APP_NAME.zip --title "v$NEW" --notes ""
echo "==> Released v$NEW"
