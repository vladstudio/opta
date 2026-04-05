#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../mac-scripts/build-kit.sh
build_app "Opta" \
  --binary opta \
  --resources "AppIcon.icns" \
  --bundle .build/release/opta_opta.bundle
