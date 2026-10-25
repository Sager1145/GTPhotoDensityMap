#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scale_test_dir=$(mktemp -d /private/tmp/heatmap-scale-tests.XXXXXX)
trap 'rm -rf "$scale_test_dir"' EXIT
# Compile the production rasterizer without SwiftUI views or application state.
python3 - "$scale_test_dir/Rasterizer.swift" <<'PYTHON'
import pathlib, sys
source = pathlib.Path("PhotoDensityMap/ContentView.swift").read_text()
rasterizer = source[source.index("enum HeatmapRasterizer {"):source.index("// MARK: - Status Bar View")]
pathlib.Path(sys.argv[1]).write_text('import AppKit\nimport CoreImage\n' + rasterizer + '\nextension Notification.Name { static let mapRegionChanged = Notification.Name("mapRegionChanged") }\n')
PYTHON
xcrun swiftc -module-cache-path /private/tmp/zoom-audit-module-cache -parse-as-library -swift-version 5 -o "$scale_test_dir/HeatmapScaleRegression" \
  "$scale_test_dir/Rasterizer.swift" \
  PhotoDensityMap/Services/PhotoLocationManager.swift \
  PhotoDensityMap/Models/PhotoCluster.swift \
  PhotoDensityMap/Models/HeatmapAppearance.swift \
  Tests/HeatmapScaleRegression.swift
"$scale_test_dir/HeatmapScaleRegression"
