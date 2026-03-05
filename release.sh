#!/bin/bash
set -e
cd "$(dirname "$0")"

# Get current version from latest git tag, default to 1.0
CURRENT=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
CURRENT=${CURRENT:-1.0}
# Bump minor: 1.0 -> 1.1
MAJOR=${CURRENT%.*}
MINOR=${CURRENT##*.}
NEW="$MAJOR.$((MINOR + 1))"

echo "==> $CURRENT -> $NEW"

# Build release
swift build -c release 2>&1 | tail -1

# Commit, tag, push
git add Package.swift Sources/ install.sh release.sh LICENSE README.md icon.png opta-screenshot.png .gitignore
git commit -m "v$NEW" || true
git push

# Zip and release
rm -f /tmp/opta.zip
zip -j /tmp/opta.zip .build/release/opta
gh release create "v$NEW" /tmp/opta.zip --title "v$NEW" --notes ""
echo "==> Released v$NEW"
