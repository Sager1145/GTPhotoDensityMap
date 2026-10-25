#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scale_test_dir=$(mktemp -d /private/tmp/heatmap-scale-tests.XXXXXX)
trap 'rm -rf "$scale_test_dir"' EXIT
# Compile the same production files as the app.
xcrun swiftc -module-cache-path /private/tmp/zoom-audit-module-cache -parse-as-library -swift-version 5 -o "$scale_test_dir/HeatmapScaleRegression" \
  PhotoDensityMap/Services/HeatmapRasterizer.swift \
  PhotoDensityMap/Services/PhotoLocationManager.swift \
  PhotoDensityMap/Models/PhotoCluster.swift \
  PhotoDensityMap/Models/HeatmapAppearance.swift \
  Tests/HeatmapScaleRegression.swift
"$scale_test_dir/HeatmapScaleRegression"
