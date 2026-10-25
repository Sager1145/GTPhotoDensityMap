import AppKit
import MapKit
import SwiftUI

@main
struct HeatmapRegression {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = MapViewModel()
        let location = PhotoLocation(id: "fixture", coordinate: .init(latitude: 35, longitude: 139))
        let data = HeatmapData(
            grid: [[0, 0, 0], [0, 1, 0], [0, 0, 0]],
            gridWidth: 3, gridHeight: 3,
            mapRect: PhotoLocationManager.projectedRect(for: .init(center: location.coordinate,
                               span: .init(latitudeDelta: 10, longitudeDelta: 10))),
            maxDensity: 1, cellSizeMapPoints: 1
        )
        let host = NSHostingView(rootView: HeatmapMapView(
            mapViewModel: model, photoLocations: [location], heatmapData: data))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        pumpEvents()
        guard let map = model.mapView, let original = map.overlays.first else {
            fatalError("FAIL: expected initial heatmap overlay")
        }
        // A pan publishes currentRegion, but does not change the heatmap data.
        model.currentRegion.center.longitude += 1
        host.layoutSubtreeIfNeeded()
        pumpEvents()
        guard map.overlays.count == 1, map.overlays.first === original else {
            fatalError("FAIL: panning recreated the unchanged overlay (causes flicker)")
        }
        print("PASS: panning preserves the existing heatmap overlay")
        let region = MKCoordinateRegion(center: location.coordinate,
                                        span: .init(latitudeDelta: 10, longitudeDelta: 10))
        var panned = region
        panned.center.longitude += 0.025
        panned.center.latitude += 0.025
        let first = PhotoLocationManager.calculateHeatmapData(locations: [location], region: region, radius: 50)
        let second = PhotoLocationManager.calculateHeatmapData(locations: [location], region: panned, radius: 50)
        let firstPeak = peak(first)
        let secondPeak = peak(second)
        guard abs(firstPeak.x - secondPeak.x) < 1, abs(firstPeak.y - secondPeak.y) < 1 else {
            fatalError("FAIL: panning moved the geographic hotspot peak")
        }
        print("PASS: panning keeps the geographic hotspot peak fixed")
        let coveredRect = PhotoLocationManager.projectedRect(for: region)
        guard first.canReuse(for: coveredRect, cellSize: first.cellSizeMapPoints, radius: 50) else {
            fatalError("FAIL: same-scale covered panning should reuse the raster")
        }
        guard !first.canReuse(for: coveredRect, cellSize: first.cellSizeMapPoints, radius: 80) else {
            fatalError("FAIL: a covered pan must not reuse the old intensity setting")
        }
        print("PASS: intensity changes invalidate the cached snapshot")
        // New data must replace the old snapshot, while style changes must not.
        host.rootView = HeatmapMapView(mapViewModel: model, photoLocations: [location], heatmapData: first)
        host.layoutSubtreeIfNeeded()
        pumpEvents()
        guard let refreshedMap = model.mapView,
              refreshedMap.overlays.count == 1,
              let replacement = refreshedMap.overlays.first as? HeatmapOverlay,
              replacement.heatmapData.id == first.id else {
            fatalError("FAIL: new density data did not replace the old overlay exactly once")
        }
        model.mapStyle = .satellite
        pumpEvents()
        guard refreshedMap.overlays.first === replacement else {
            fatalError("FAIL: map style change recreated the heatmap")
        }
        let renderer = HeatmapOverlayRenderer(overlay: replacement)
        guard let image = first.image, renderer.heatmapImage === image else {
            fatalError("FAIL: renderer must reuse the worker-prepared raster")
        }
        print("PASS: new snapshots refresh, style changes retain the cached raster")
        var appearance = HeatmapAppearance()
        appearance.opacity = 0.2
        host.rootView = HeatmapMapView(mapViewModel: model, photoLocations: [location], heatmapData: first, appearance: appearance)
        host.layoutSubtreeIfNeeded()
        pumpEvents()
        guard let translucent = model.mapView?.overlays.first as? HeatmapOverlay,
              translucent.appearance.opacity == 0.2,
              translucent.heatmapData.image === first.image,
              appearance.hasSameRaster(as: HeatmapAppearance()) else {
            fatalError("FAIL: opacity must update drawing while preserving the cached image")
        }
        print("PASS: opacity updates drawing without rasterizing the density grid")
        appearance.palette = .ember
        appearance.intensity = 2
        appearance.smoothing = 0
        let restyled = first.restyled(appearance)
        guard restyled.grid == first.grid, MKMapRectEqualToRect(restyled.mapRect, first.mapRect),
              restyled.radius == first.radius, restyled.id != first.id,
              restyled.appearance == appearance,
              !first.appearance.hasSameRaster(as: appearance),
              let newPixels = restyled.image?.dataProvider?.data,
              let oldPixels = first.image?.dataProvider?.data,
              !CFEqual(newPixels, oldPixels) else {
            fatalError("FAIL: appearance changes must redraw the cached grid with new pixels")
        }
        print("PASS: appearance changes redraw cached density with the selected palette")
        host.rootView = HeatmapMapView(mapViewModel: model, photoLocations: [], heatmapData: nil)
        host.layoutSubtreeIfNeeded()
        pumpEvents()
        guard model.mapView?.overlays.isEmpty == true else { fatalError("FAIL: clearing data left a stale overlay") }
        print("PASS: clearing data removes the overlay")
        withExtendedLifetime(host) {}
    }

    static func peak(_ data: HeatmapData) -> MKMapPoint {
        var peakX = 0, peakY = 0
        for x in 0..<data.gridWidth {
            for y in 0..<data.gridHeight where data.grid[x][y] > data.grid[peakX][peakY] {
                peakX = x
                peakY = y
            }
        }
        return MKMapPoint(x: data.mapRect.minX + (Double(peakX) + 0.5) * data.cellSizeMapPoints,
                          y: data.mapRect.minY + (Double(peakY) + 0.5) * data.cellSizeMapPoints)
    }

    @MainActor
    static func pumpEvents() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    }
}

// Menu command notifications normally declared alongside the app's @main type.
extension Notification.Name {
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let resetView = Notification.Name("resetView")
    static let worldView = Notification.Name("worldView")
}
