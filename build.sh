#!/bin/bash
set -e
cd "$(dirname "$0")"

swift build -c release

APP=/tmp/Opta.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp .build/release/opta "$APP/Contents/MacOS/"
cp -r .build/release/opta_opta.bundle "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/"

pkill -x Opta 2>/dev/null || true
rm -rf /Applications/Opta.app
mv "$APP" /Applications/
touch /Applications/Opta.app
open /Applications/Opta.app
echo "==> Installed Opta.app"
