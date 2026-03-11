#!/bin/bash
set -e

brew install pngquant oxipng webp ffmpeg

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

URL=$(curl -sL https://api.github.com/repos/vladstudio/opta/releases/latest \
  | grep browser_download_url | head -1 | cut -d'"' -f4)
curl -sL "$URL" -o "$TMP/Opta.zip"
unzip -q "$TMP/Opta.zip" -d "$TMP"

pkill -x Opta 2>/dev/null || true
rm -rf /Applications/Opta.app
mv "$TMP/Opta.app" /Applications/
xattr -dr com.apple.quarantine /Applications/Opta.app 2>/dev/null || true
open /Applications/Opta.app
echo "==> Installed Opta"
