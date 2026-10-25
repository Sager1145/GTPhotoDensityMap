#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
bash Tests/run-regressions.sh
bash Tests/run-map-navigation.sh
bash Tests/run-map-pan.sh
