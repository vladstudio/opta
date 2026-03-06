#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Opta"
APP_DIR="/tmp/$APP_NAME.app"

rm -rf "$APP_DIR" .build
swift build -c release 2>&1 | tail -1

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp Info.plist "$APP_DIR/Contents/"
cp .build/release/opta "$APP_DIR/Contents/MacOS/opta"
cp -r .build/release/opta_opta.bundle "$APP_DIR/Contents/Resources/"

# Generate .icns from icon.png
ICONSET="/tmp/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
    sips -z $size $size icon.png --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
done
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

touch "$APP_DIR"

rm -rf "/Applications/$APP_NAME.app"
mv "$APP_DIR" /Applications/
open "/Applications/$APP_NAME.app"
echo "==> Installed $APP_NAME.app"
