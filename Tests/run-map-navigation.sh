#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
map_test_dir=$(mktemp -d /private/tmp/map-navigation.XXXXXX)
trap 'rm -rf "$map_test_dir"' EXIT
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.1-RC.app/Contents/Developer}
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$map_test_dir/modules" \
    PhotoDensityMap/Models/PhotoCluster.swift \
    PhotoDensityMap/ViewModels/MapViewModel.swift \
    Tests/MapNavigationRegression.swift -o "$map_test_dir/MapNavigationRegression"
"$map_test_dir/MapNavigationRegression"
