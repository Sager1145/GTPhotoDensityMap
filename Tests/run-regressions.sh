#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
heatmap_test_dir=$(mktemp -d /private/tmp/heatmap-tests.XXXXXX)
trap 'rm -rf "$heatmap_test_dir"' EXIT
# Compile the actual app components, without its application entry point.
xcrun swiftc -parse-as-library -swift-version 5 -o "$heatmap_test_dir/HeatmapRegression" \
  PhotoDensityMap/ContentView.swift \
  PhotoDensityMap/Services/PhotoLocationManager.swift \
  PhotoDensityMap/Models/PhotoCluster.swift \
  PhotoDensityMap/ViewModels/MapViewModel.swift \
  Tests/HeatmapRegression.swift
"$heatmap_test_dir/HeatmapRegression"
