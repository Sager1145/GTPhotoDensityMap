#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
map_pan_dir=$(mktemp -d /private/tmp/map-pan.XXXXXX)
trap 'rm -rf "$map_pan_dir"' EXIT
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.1-RC.app/Contents/Developer}
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$map_pan_dir/modules" \
  PhotoDensityMap/ContentView.swift \
  PhotoDensityMap/Services/PhotoLocationManager.swift \
  PhotoDensityMap/Services/HeatmapRasterizer.swift \
  PhotoDensityMap/Models/PhotoCluster.swift \
  PhotoDensityMap/Models/HeatmapAppearance.swift \
  PhotoDensityMap/Views/HeatmapOptionsView.swift \
  PhotoDensityMap/ViewModels/MapViewModel.swift \
  Tests/MapPanRegression.swift -o "$map_pan_dir/MapPanRegression"
"$map_pan_dir/MapPanRegression"
