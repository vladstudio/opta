#!/bin/bash
set -e
cd "$(dirname "$0")"

CURRENT=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
VERSION=${1:-${CURRENT%.*}.$((${CURRENT##*.} + 1))}
echo "==> $CURRENT -> $VERSION"

plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
plutil -replace CFBundleVersion -string "$VERSION" Info.plist

swift build -c release

APP=/tmp/Opta.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp .build/release/opta "$APP/Contents/MacOS/"
cp -r .build/release/opta_opta.bundle "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"

git add Info.plist
git commit -m "v$VERSION"
git tag "v$VERSION"
git push --tags

ditto -c -k --sequesterRsrc --keepParent "$APP" /tmp/Opta.zip
gh release create "v$VERSION" /tmp/Opta.zip --title "v$VERSION" --notes ""
echo "==> Released v$VERSION"
