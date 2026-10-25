# Regression tests

Run the complete suite from a checkout with Xcode installed:

```bash
bash Tests/run-all.sh
```

The runner executes every committed regression program and stops with a nonzero exit code on failure:

- `run-regressions.sh`: heatmap rendering, immutable raster reuse, geographic anchoring, transition lifecycle, rapid updates, appearance controls, and native viewport notifications; also runs the standalone palette/appearance checks.
- `run-map-navigation.sh`: initial fit, All Photos, date-line bounds, zoom limits, rapid/reverse zoom, Reduce Motion, and native MapKit camera clamping.
- `run-map-pan.sh`: 120 continuous native MapKit viewport movements, hotspot projection tracking, hit testing, and overlay/image identity.

These tests use synthetic photo coordinates and do not request access to the Photos library. The native pan test uses a hidden layout host; it verifies programmatic panning and cached rendering, not physical mouse-event delivery or screen frame rate.

For a clean Release build, use a new DerivedData directory:

```bash
xcodebuild -project GTPhotoDensityMap.xcodeproj -scheme GTPhotoDensityMap \
  -configuration Release -derivedDataPath /tmp/GTPhotoDensityMap-clean-derived \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= clean build
```

When running in an execution sandbox, the Swift compiler and SwiftUI macro plugins may require normal local developer-tool access. If a cloud-synced checkout blocks Xcode file coordination, run the build and tests from a local temporary copy with its own DerivedData directory.
