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
        sliderPreviewChecks(location: location, data: data)
        transitionChecks(location: location, data: data)
        nativeViewportChecks(location: location, data: data)
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        guard map.overlays.count == 2, map.overlays.contains(where: { $0 === original }) else {
            fatalError("FAIL: a new snapshot must retain the old overlay during its crossfade")
        }
        print("PASS: snapshot replacement retains the old image during the transition")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
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

    @MainActor
    static func sliderPreviewChecks(location: PhotoLocation, data: HeatmapData) {
        let model = MapViewModel()
        let map = MKMapView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        func view(_ data: HeatmapData, _ appearance: HeatmapAppearance) -> HeatmapMapView {
            HeatmapMapView(mapViewModel: model, photoLocations: [location], heatmapData: data, appearance: appearance)
        }
        var appearance = HeatmapAppearance()
        let coordinator = HeatmapMapView.Coordinator(view(data, appearance), reduceMotion: { false })
        map.delegate = coordinator
        coordinator.updateHeatmap(on: map)
        guard let original = map.overlays.first as? HeatmapOverlay,
              let renderer = coordinator.mapView(map, rendererFor: original) as? HeatmapOverlayRenderer else {
            fatalError("FAIL: preview fixture needs an initial renderer")
        }
        func alphaSum() -> Double {
            let width = 64
            let context = CGContext(data: nil, width: width, height: width,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            let rect = renderer.rect(for: data.mapRect)
            context.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(width) / rect.height)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            renderer.draw(data.mapRect, zoomScale: 1, in: context)
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<(width * width)).reduce(0) { $0 + Double(bytes[$1 * 4 + 3]) }
        }
        let baselineAlpha = alphaSum()
        guard baselineAlpha > 0 else { fatalError("FAIL: preview pixel fixture must contain heat") }
        for opacity in [0.6, 0.4, 0, 0.1, 0.8, 0.7] {
            appearance.opacity = opacity
            coordinator.parent = view(data, appearance)
            coordinator.updateHeatmap(on: map)
            guard map.overlays.count == 1, map.overlays.first === original,
                  coordinator.mapView(map, rendererFor: original) === renderer,
                  renderer.alpha == 1 else {
                fatalError("FAIL: opacity slider must update one renderer without starting a dimming crossfade")
            }
            guard abs(alphaSum() / baselineAlpha - opacity / 0.7) < 0.04 else {
                fatalError("FAIL: preview pixels must follow current opacity without lag or double compositing")
            }
        }
        for intensity in [1.1, 1.4, 2.0, 0.8] {
            appearance.intensity = intensity
            let next = data.restyled(appearance)
            coordinator.parent = view(next, appearance)
            coordinator.updateHeatmap(on: map)
            guard map.overlays.count == 1, map.overlays.first === original,
                  renderer.heatmapImage === next.image, original.heatmapData.id == next.id else {
                fatalError("FAIL: appearance preview must immediately reuse the current renderer and latest raster")
            }
        }
        coordinator.advanceTransition(on: map, at: ProcessInfo.processInfo.systemUptime + 10)
        guard map.overlays.count == 1, map.overlays.first === original else {
            fatalError("FAIL: stale preview transition must not restore an old snapshot")
        }
        let shifted = HeatmapData(grid: data.grid, gridWidth: data.gridWidth, gridHeight: data.gridHeight,
                                  mapRect: MKMapRect(x: data.mapRect.minX + data.mapRect.width * 0.01, y: data.mapRect.minY,
                                                     width: data.mapRect.width, height: data.mapRect.height),
                                  maxDensity: data.maxDensity, cellSizeMapPoints: data.cellSizeMapPoints,
                                  appearance: appearance)
        coordinator.parent = view(shifted, appearance)
        coordinator.updateHeatmap(on: map)
        guard map.overlays.count == 2 else { fatalError("FAIL: fixture must begin a viewport transition") }
        appearance.opacity = 0.3
        coordinator.parent = view(shifted, appearance)
        coordinator.updateHeatmap(on: map)
        coordinator.advanceTransition(on: map, at: ProcessInfo.processInfo.systemUptime + 10)
        guard map.overlays.count == 1,
              (map.overlays.first as? HeatmapOverlay)?.heatmapData.id == shifted.id,
              (map.overlays.first as? HeatmapOverlay)?.appearance.opacity == 0.3 else {
            fatalError("FAIL: settings during a viewport fade must discard pending frames and keep the latest preview")
        }
        HeatmapMapView.dismantleNSView(map, coordinator: coordinator)
        print("PASS: continuous opacity and intensity previews retain one renderer without crossfade dimming")
    }

    @MainActor
    static func nativeViewportChecks(location: PhotoLocation, data: HeatmapData) {
        let model = MapViewModel(reduceMotion: { false })
        let map = MKMapView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let coordinator = HeatmapMapView.Coordinator(HeatmapMapView(
            mapViewModel: model, photoLocations: [location], heatmapData: data))
        map.delegate = coordinator
        model.mapView = map
        var received: MKCoordinateRegion?
        let observation = NotificationCenter.default.publisher(for: .mapRegionChanged).sink {
            received = $0.object as? MKCoordinateRegion
        }
        let globalLibrary = [-135.0, -45.0, 45.0, 135.0].enumerated().map {
            PhotoLocation(id: String($0.offset), coordinate: .init(latitude: 20, longitude: $0.element))
        }
        model.updatePhotoLocations(globalLibrary)
        for _ in 0..<3 { model.zoomIn() }
        model.zoomOut()
        model.zoomOut()
        model.zoomIn()
        model.resetView()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        guard let received, !model.isAnimating,
              abs(received.span.longitudeDelta - map.region.span.longitudeDelta) < 0.000001,
              abs(received.center.longitude - map.region.center.longitude) < 0.000001 else {
            fatalError("FAIL: native All Photos must publish its actual constrained viewport to the heatmap")
        }
        withExtendedLifetime(observation) {}
        HeatmapMapView.dismantleNSView(map, coordinator: coordinator)
        print("PASS: native rapid zoom and All Photos publish the actual viewport for heatmap regeneration")
    }

    @MainActor
    static func transitionChecks(location: PhotoLocation, data: HeatmapData) {
        let model = MapViewModel()
        let map = MKMapView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var now: TimeInterval = 10
        var reducedMotion = false
        func view(_ data: HeatmapData, _ appearance: HeatmapAppearance = .init()) -> HeatmapMapView {
            HeatmapMapView(mapViewModel: model, photoLocations: [location], heatmapData: data, appearance: appearance)
        }
        let coordinator = HeatmapMapView.Coordinator(view(data), clock: { now }, reduceMotion: { reducedMotion })
        map.delegate = coordinator
        coordinator.updateHeatmap(on: map)
        guard let original = map.overlays.first as? HeatmapOverlay else { fatalError("FAIL: initial image missing") }
        var appearance = HeatmapAppearance()
        appearance.palette = .ember
        func viewportData(_ shift: Double, _ appearance: HeatmapAppearance) -> HeatmapData {
            HeatmapData(grid: data.grid, gridWidth: data.gridWidth, gridHeight: data.gridHeight,
                        mapRect: MKMapRect(x: data.mapRect.minX + shift, y: data.mapRect.minY,
                                          width: data.mapRect.width, height: data.mapRect.height),
                        maxDensity: data.maxDensity, cellSizeMapPoints: data.cellSizeMapPoints,
                        appearance: appearance)
        }
        let second = viewportData(data.mapRect.width * 0.01, appearance)
        coordinator.parent = view(second, appearance)
        coordinator.updateHeatmap(on: map)
        guard map.overlays.count == 2, map.overlays.contains(where: { $0 === original }),
              let next = map.overlays.last as? HeatmapOverlay else {
            fatalError("FAIL: replacement removed its outgoing image before the transition")
        }
        let outgoingRenderer = coordinator.mapView(map, rendererFor: original)
        let incomingRenderer = coordinator.mapView(map, rendererFor: next)
        guard outgoingRenderer.alpha == 1, incomingRenderer.alpha == 0 else {
            fatalError("FAIL: transition must start with the old image visible and new image transparent")
        }
        now += 0.11
        coordinator.advanceTransition(on: map, at: now)
        guard abs(outgoingRenderer.alpha - 0.5) < 0.01,
              abs(incomingRenderer.alpha - 0.5) < 0.01,
              (incomingRenderer as? HeatmapOverlayRenderer)?.heatmapImage === second.image else {
            fatalError("FAIL: halfway transition must blend existing cached images")
        }
        coordinator.updateHeatmap(on: map)
        guard map.overlays.count == 2, abs(outgoingRenderer.alpha - 0.5) < 0.01,
              abs(incomingRenderer.alpha - 0.5) < 0.01 else {
            fatalError("FAIL: unchanged view updates must not interrupt an active viewport blend")
        }
        print("PASS: deterministic crossfade retains and blends the cached geographic images")

        appearance.intensity = 1.5
        let skipped = viewportData(data.mapRect.width * 0.02, appearance)
        coordinator.parent = view(skipped, appearance)
        coordinator.updateHeatmap(on: map)
        appearance.intensity = 2
        let latest = viewportData(data.mapRect.width * 0.03, appearance)
        coordinator.parent = view(latest, appearance)
        for _ in 0..<20 { coordinator.updateHeatmap(on: map) }
        guard map.overlays.count == 2 else { fatalError("FAIL: rapid updates accumulated overlays") }
        now += 0.12
        coordinator.advanceTransition(on: map, at: now)
        guard map.overlays.count == 2,
              !map.overlays.contains(where: { ($0 as? HeatmapOverlay)?.heatmapData.id == skipped.id }),
              map.overlays.contains(where: { ($0 as? HeatmapOverlay)?.heatmapData.id == latest.id }) else {
            fatalError("FAIL: a rapid transition must coalesce to the latest pending image")
        }
        now += 0.23
        coordinator.advanceTransition(on: map, at: now)
        guard map.overlays.count == 1, let final = map.overlays.first as? HeatmapOverlay,
              final.heatmapData.id == latest.id,
              coordinator.mapView(map, rendererFor: final).alpha == 1 else {
            fatalError("FAIL: completed transitions must leave only the latest image at full opacity")
        }
        print("PASS: rapid updates stay at two overlays, latest wins, and completion removes old layers")

        coordinator.parent = view(data)
        coordinator.updateHeatmap(on: map)
        let remote = HeatmapData(grid: data.grid, gridWidth: data.gridWidth, gridHeight: data.gridHeight,
                                 mapRect: MKMapRect(x: data.mapRect.maxX + data.mapRect.width,
                                                    y: data.mapRect.minY,
                                                    width: data.mapRect.width, height: data.mapRect.height),
                                 maxDensity: data.maxDensity, cellSizeMapPoints: data.cellSizeMapPoints)
        coordinator.parent = view(remote)
        coordinator.updateHeatmap(on: map)
        guard map.overlays.count == 1,
              (map.overlays.first as? HeatmapOverlay)?.heatmapData.id == remote.id else {
            fatalError("FAIL: jumping outside an active blend must show the new area immediately")
        }
        now += 1
        coordinator.advanceTransition(on: map, at: now)
        guard (map.overlays.first as? HeatmapOverlay)?.heatmapData.id == remote.id else {
            fatalError("FAIL: a canceled cross-area transition restored a stale image")
        }
        print("PASS: cross-area updates interrupt an active blend immediately")

        coordinator.parent = view(data)
        coordinator.updateHeatmap(on: map)
        coordinator.parent = view(second, appearance)
        coordinator.updateHeatmap(on: map)
        reducedMotion = true
        now += 0.01
        coordinator.advanceTransition(on: map, at: now)
        guard map.overlays.count == 1,
              (map.overlays.first as? HeatmapOverlay)?.heatmapData.id == second.id else {
            fatalError("FAIL: Reduce Motion must cancel the blend and show the latest requested image")
        }
        print("PASS: Reduce Motion cancels an active blend and displays the latest image immediately")

        reducedMotion = false
        coordinator.parent = view(data)
        coordinator.updateHeatmap(on: map)
        coordinator.clear(on: map)
        now += 1
        coordinator.advanceTransition(on: map, at: now)
        guard map.overlays.isEmpty else { fatalError("FAIL: cleared data was restored by a stale transition") }
        coordinator.parent = view(latest, appearance)
        coordinator.updateHeatmap(on: map)
        HeatmapMapView.dismantleNSView(map, coordinator: coordinator)
        now += 1
        coordinator.advanceTransition(on: map, at: now)
        guard map.overlays.isEmpty, map.delegate == nil else {
            fatalError("FAIL: dismantling must cancel and remove transition state")
        }
        print("PASS: clearing and dismantling cancel transition cleanup without restoring stale overlays")
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
