import AppKit
import MapKit
import SwiftUI

@main
struct MapPanRegression {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let location = PhotoLocation(id: "synthetic-tokyo", coordinate: .init(latitude: 35.68, longitude: 139.69))
        let region = MKCoordinateRegion(center: location.coordinate,
                                        span: .init(latitudeDelta: 1, longitudeDelta: 1))
        let data = PhotoLocationManager.calculateHeatmapData(locations: [location], region: region, radius: 50)
        let model = MapViewModel(reduceMotion: { false })
        model.mapRegionDidChange(region)
        let host = NSHostingView(rootView: HeatmapMapView(
            mapViewModel: model, heatmapData: data))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        pump(0.1)
        guard let map = model.mapView, let original = map.overlays.first as? HeatmapOverlay,
              let image = original.heatmapData.image else { fail("map or initial cached image missing") }
        map.setRegion(region, animated: false)
        pump(0.05)
        check(map.isScrollEnabled, "native map panning must be enabled")
        for fraction in [0.2, 0.5, 0.8] {
            let mapPoint = NSPoint(x: map.bounds.width * fraction, y: map.bounds.height * fraction)
            let hostPoint = host.convert(mapPoint, from: map)
            guard let hit = host.hitTest(hostPoint) else {
                fail("map surface has no hit-test target: host=\(host.frame) map=\(map.frame) point=\(hostPoint)")
            }
            check(hit === map || hit.isDescendant(of: map), "map surface must hit the native map instead of an intercepting view")
        }
        let originalRect = map.visibleMapRect
        let anchor = peak(in: data)
        var previousRect = originalRect
        var previousPoint = map.convert(anchor.coordinate, toPointTo: map)
        var maxProjectionError = 0.0
        var maxStep = 0.0
        var traveled = 0.0
        // Move diagonally, reverse direction, then return to the same viewport.
        // These are real MapKit camera updates, not fabricated currentRegion publications.
        for frame in 1...120 {
            let phase = Double(frame) / 120 * 2 * Double.pi
            let desired = MKMapRect(x: originalRect.minX + sin(phase) * originalRect.width * 0.06,
                                    y: originalRect.minY + sin(phase * 2) * originalRect.height * 0.025,
                                    width: originalRect.width, height: originalRect.height)
            map.setVisibleMapRect(desired, animated: false)
            pump(0.003)
            let actual = map.visibleMapRect
            let point = map.convert(anchor.coordinate, toPointTo: map)
            let expectedDX = -(actual.minX - previousRect.minX) / actual.width * map.bounds.width
            let expectedDY = (map.isFlipped ? -1.0 : 1.0) * (actual.minY - previousRect.minY) / actual.height * map.bounds.height
            let actualDX = point.x - previousPoint.x
            let actualDY = point.y - previousPoint.y
            let error = hypot(actualDX - expectedDX, actualDY - expectedDY)
            maxProjectionError = max(maxProjectionError, error)
            maxStep = max(maxStep, hypot(actualDX, actualDY))
            traveled += hypot(actualDX, actualDY)
            check(error < 0.5, "a geographically fixed hotspot must follow the actual MapKit viewport transform")
            check(map.overlays.count == 1 && map.overlays.first === original,
                  "covered panning must retain the same heatmap overlay")
            check(original.heatmapData.image === image, "covered panning must retain the cached raster")
            check(original.heatmapData.id == data.id, "covered panning must retain snapshot identity")
            previousRect = actual
            previousPoint = point
        }
        check(traveled > 100, "the native map must actually move during the path")
        check(maxStep < 12, "small continuous viewport steps must not cause large hotspot jumps")
        check(abs(model.currentRegion.center.longitude - map.region.center.longitude) < 0.000001,
              "native pan completion must publish the actual viewport")
        let renderer = HeatmapOverlayRenderer(overlay: original)
        check(renderer.heatmapImage === image, "the renderer must use the same precomputed image after panning")
        print("PASS: map hit testing reaches native MKMapView and scrolling is enabled")
        print("PASS: 120 native diagonal/reverse pan steps preserve one overlay, snapshot ID and cached raster")
        print(String(format: "PASS: hotspot projection error max %.6f px; largest step %.3f px; total travel %.1f px", maxProjectionError, maxStep, traveled))
        withExtendedLifetime(window) {}
    }

    static func peak(in data: HeatmapData) -> MKMapPoint {
        var peakX = 0
        var peakY = 0
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
    static func pump(_ interval: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: interval)) }

    static func check(_ condition: Bool, _ message: String) { if !condition { fail(message) } }
    static func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
}

extension Notification.Name {
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let resetView = Notification.Name("resetView")
    static let worldView = Notification.Name("worldView")
}
