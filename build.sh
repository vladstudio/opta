#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../scripts/build-kit.sh
build_app "Opta" \
  --binary opta \
  --bundle .build/release/opta_opta.bundle
