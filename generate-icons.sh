#!/bin/bash
set -e
cd "$(dirname "$0")"
ICONSET=/tmp/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size icon.png --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
  sips -z $((size*2)) $((size*2)) icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET"
echo "==> Generated AppIcon.icns"
