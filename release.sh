#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../mac-scripts/release-kit.sh
release_app "Opta"
