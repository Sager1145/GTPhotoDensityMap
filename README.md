# PhotoDensityMap

A macOS app that visualizes the geographic distribution of your photo library as a smooth, continuous heatmap overlay on Apple Maps.

## Features

- **Continuous gradient heatmap** — No bubbles or markers, just a smooth color gradient showing photo density
- **Color scheme** — From blue (low density) through cyan, green, yellow, orange to red (high density)
- **Dynamic detail** — Heatmap recalculates as you zoom and pan, showing more detail at higher zoom levels
- **Heatmap options** — Adjust spread (applied on slider release), opacity, intensity, smoothing, and Classic / Ember / Ocean colors; restore the original defaults in one click
- **Multiple map styles** — Standard, satellite, and hybrid views
- **Privacy-first** — All processing happens locally on your Mac

## Screenshot

<img width="1312" height="912" alt="image" src="https://github.com/user-attachments/assets/29cbcaf5-43c2-407d-ae31-84b4217b8217" />

## How It Works

1. Reads GPS metadata from your Photos library using PhotoKit
2. Creates a density grid using Gaussian distribution for each photo location
3. Applies Gaussian blur for smooth gradient transitions
4. Renders as a semi-transparent `MKOverlay` on MapKit

## Requirements

- macOS 14.0+
- Xcode 15+
- Photos library access permission

## Installation

1. Clone the repository
   ```bash
   git clone https://github.com/getangar/GTPhotoDensityMap.git
   ```
2. Open `GTPhotoDensityMap.xcodeproj` in Xcode
3. Set your Development Team in Signing & Capabilities
4. Build and run (⌘R)
5. Grant photo library access when prompted

## Building from Source

```bash
git clone https://github.com/getangar/GTPhotoDensityMap.git
cd GTPhotoDensityMap
open GTPhotoDensityMap.xcodeproj
```

Then build using Xcode or via command line:

```bash
xcodebuild -scheme GTPhotoDensityMap -configuration Release
```

## Privacy

PhotoDensityMap requires read-only access to your photo library to extract GPS coordinates. No data is uploaded or shared — all processing happens entirely on your device.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## Acknowledgments

- Built with SwiftUI, MapKit, and PhotoKit

## Heatmap options

Use **Hotspots** in the map toolbar to open the options panel. Spread is relative to the current viewport, not a distance in meters or a fixed pixel radius. Its scale stays continuous when the density grid changes resolution during zooming. Opacity, intensity, smoothing, and colors preview through the existing map renderer without reading the photo library again. Opacity reuses the current raster; intensity, smoothing, and colors rasterize the cached density grid in the background. The legend follows the selected palette. Defaults preserve the original appearance: spread 50, opacity 70%, intensity 1×, smoothing 1×, and Classic colors.

See [the heatmap options research](docs/heatmap-options-research.md) for the Leaflet.heat, MapLibre, and Kepler.gl references.

Standalone appearance checks (no Photos access required):

```bash
xcrun swiftc PhotoDensityMap/Models/HeatmapAppearance.swift Tests/main.swift -o /tmp/heatmap-appearance-tests
/tmp/heatmap-appearance-tests
```

## Map controls

The native toolbar provides map styles, zoom controls, **All Photos**, and **Hotspots**. The first loaded photo library fits automatically; subsequent updates preserve your map position. The bottom status bar shows the photo count and selected density palette.

- **⌘+ / ⌘−**: Zoom in / out
- **⌘0**: Show all photos
- **⌘⇧0**: Show the world
- **⌘⇧H**: Open hotspot options

Run `Tests/run-regressions.sh` for rendering and appearance checks and `Tests/run-map-navigation.sh` for viewport and navigation checks with Xcode selected.

## Architecture and feature coverage

See [the interface inventory, architecture review, and verification record](docs/architecture-review.md) for canonical implementations, data ownership, and the requested feature checklist.
