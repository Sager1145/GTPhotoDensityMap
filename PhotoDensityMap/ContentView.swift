//
//  ContentView.swift
//  PhotoDensityMap
//
//  Created with Claude
//

import SwiftUI
import MapKit
import Photos

struct ContentView: View {
    @EnvironmentObject var photoManager: PhotoLocationManager
    @StateObject private var mapViewModel = MapViewModel()
    @State private var heatmapAppearance = HeatmapAppearance()
    
    var body: some View {
        ZStack {
            HeatmapMapView(
                mapViewModel: mapViewModel,
                heatmapData: photoManager.heatmapData,
                appearance: heatmapAppearance,
                onRegionChange: photoManager.updateMapRegion
            )

            if photoManager.authorizationStatus == .notDetermined ||
               photoManager.authorizationStatus == .denied ||
               photoManager.authorizationStatus == .restricted ||
               photoManager.isLoading {
                AuthorizationOverlay(photoManager: photoManager)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 16) {
                StatusBarView(photoManager: photoManager)
                Spacer(minLength: 12)
                if !photoManager.photoLocations.isEmpty {
                    HeatmapLegendView(palette: heatmapAppearance.palette)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                MapControlsView(mapViewModel: mapViewModel, photoManager: photoManager, appearance: $heatmapAppearance)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: heatmapAppearance) { _, appearance in
            photoManager.updateAppearance(appearance)
        }
        .onAppear {
            photoManager.requestAuthorization()
        }
        .onReceive(photoManager.$photoLocations) { locations in
            mapViewModel.updatePhotoLocations(locations)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in
            mapViewModel.zoomIn()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in
            mapViewModel.zoomOut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetView)) { _ in
            mapViewModel.resetView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .worldView)) { _ in
            mapViewModel.showWorld()
        }
    }
}

// MARK: - Heatmap Map View (AppKit wrapper)

struct HeatmapMapView: NSViewRepresentable {
    @ObservedObject var mapViewModel: MapViewModel
    let heatmapData: HeatmapData?
    var appearance: HeatmapAppearance = HeatmapAppearance()
    var onRegionChange: (MKCoordinateRegion) -> Void = { _ in }
    
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsCompass = true
        mapView.showsZoomControls = false
        mapView.showsScale = true
        
        mapViewModel.mapView = mapView
        context.coordinator.installInteractionMonitor(on: mapView)

        return mapView
    }
    
    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateHeatmap(on: mapView)
    }

    static func dismantleNSView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.clear(on: mapView)
        coordinator.removeInteractionMonitor()
        mapView.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    @MainActor
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: HeatmapMapView
        private var displayed: HeatmapOverlay?
        private var incoming: HeatmapOverlay?
        private var pending: (data: HeatmapData, appearance: HeatmapAppearance)?
        private var renderers: [ObjectIdentifier: HeatmapOverlayRenderer] = [:]
        private var transitionTimer: Timer?
        private var transitionStart: TimeInterval = 0
        private let transitionDuration: TimeInterval = 0.22
        private let clock: () -> TimeInterval
        private let reduceMotion: () -> Bool
        private var interactionMonitor: Any?

        init(_ parent: HeatmapMapView,
             clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
             reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
            self.parent = parent
            self.clock = clock
            self.reduceMotion = reduceMotion
        }

        deinit {
            transitionTimer?.invalidate()
            if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
        }

        func installInteractionMonitor(on mapView: MKMapView) {
            removeInteractionMonitor()
            // Only direct map interactions cancel a pending camera destination.
            // Programmatic regionWillChange callbacks also occur during zooms.
            interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel, .magnify, .rotate]) {
                [weak self, weak mapView] event in
                if let mapView, mapView.window != nil, event.window === mapView.window,
                   mapView.bounds.contains(mapView.convert(event.locationInWindow, from: nil)) {
                    self?.parent.mapViewModel.mapInteractionBegan()
                }
                return event
            }
        }

        func removeInteractionMonitor() {
            if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
            interactionMonitor = nil
        }

        func updateHeatmap(on mapView: MKMapView) {
            guard let data = parent.heatmapData else {
                clear(on: mapView)
                return
            }
            let appearance = parent.appearance
            // Settings previews change pixels, not geography. Keep the native
            // renderer installed: crossfading translucent copies dims their
            // overlap, and queuing fades makes sliders lag behind the pointer.
            if let target = incoming ?? displayed,
               MKMapRectEqualToRect(target.boundingMapRect, data.mapRect),
               target.heatmapData.cellSizeMapPoints == data.cellSizeMapPoints,
               ((target.heatmapData.id == data.id && target.appearance.opacity != appearance.opacity) ||
                !target.heatmapData.appearance.hasSameRaster(as: data.appearance) ||
                target.heatmapData.radius != data.radius) {
                transitionTimer?.invalidate()
                transitionTimer = nil
                pending = nil
                let targetRenderer = renderer(for: target)
                target.updatePreview(data: data, appearance: appearance)
                targetRenderer.updatePreview(image: data.image, opacity: appearance.opacity)
                targetRenderer.alpha = 1
                mapView.removeOverlays(mapView.overlays.filter { $0 is HeatmapOverlay && $0 !== target })
                renderers = [ObjectIdentifier(target): targetRenderer]
                displayed = target
                incoming = nil
                return
            }
            if reduceMotion() {
                replaceImmediately(on: mapView, data: data, appearance: appearance)
                return
            }
            // Compare against the latest destination, never the first overlay:
            // that overlay deliberately remains visible during a crossfade.
            if let pending {
                guard !matches(pending.data, pending.appearance, data, appearance) else { return }
            } else if let target = incoming ?? displayed,
                      matches(target.heatmapData, target.appearance, data, appearance) {
                return
            }
            if let incoming {
                // A jump to a disjoint area has no visible old image to blend.
                // Do not hold its new snapshot behind an unrelated transition.
                guard data.image != nil,
                      [displayed, incoming].compactMap({ $0 }).contains(where: {
                          $0.heatmapData.image != nil && $0.boundingMapRect.intersects(data.mapRect)
                      }) else {
                    replaceImmediately(on: mapView, data: data, appearance: appearance)
                    return
                }
                // Finish this short blend, coalescing any intermediate updates.
                // Dropping a partly visible layer here would cause a brightness
                // jump; one latest pending snapshot keeps overlay count at two.
                pending = (data, appearance)
                return
            }
            beginTransition(on: mapView, data: data, appearance: appearance, at: clock())
        }

        private func matches(_ first: HeatmapData, _ firstAppearance: HeatmapAppearance,
                             _ second: HeatmapData, _ secondAppearance: HeatmapAppearance) -> Bool {
            first.id == second.id && firstAppearance.opacity == secondAppearance.opacity
        }

        private func renderer(for overlay: HeatmapOverlay) -> HeatmapOverlayRenderer {
            let key = ObjectIdentifier(overlay)
            if let renderer = renderers[key] { return renderer }
            let renderer = HeatmapOverlayRenderer(overlay: overlay)
            renderers[key] = renderer
            return renderer
        }

        private func beginTransition(on mapView: MKMapView, data: HeatmapData,
                                     appearance: HeatmapAppearance, at time: TimeInterval) {
            guard let displayed, displayed.heatmapData.image != nil, data.image != nil,
                  displayed.boundingMapRect.intersects(data.mapRect) else {
                replaceImmediately(on: mapView, data: data, appearance: appearance)
                return
            }
            let next = HeatmapOverlay(heatmapData: data, appearance: appearance)
            incoming = next
            transitionStart = time
            renderer(for: next).alpha = 0
            mapView.addOverlay(next, level: .aboveRoads)
            // All pixels already exist, so progress never depends on an optional
            // MapKit renderer callback for an offscreen or not-yet-visible tile.
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak mapView] _ in
                // This timer is installed exclusively on RunLoop.main.
                MainActor.assumeIsolated {
                    guard let self, let mapView else { return }
                    self.advanceTransition(on: mapView, at: self.clock())
                }
            }
            transitionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func advanceTransition(on mapView: MKMapView, at time: TimeInterval) {
            guard let incoming, let displayed else { return }
            if reduceMotion() {
                let target = pending ?? (incoming.heatmapData, incoming.appearance)
                replaceImmediately(on: mapView, data: target.data, appearance: target.appearance)
                return
            }
            let progress = max(0, min(1, (time - transitionStart) / transitionDuration))
            let eased = progress * progress * (3 - 2 * progress)
            renderer(for: displayed).alpha = CGFloat(1 - eased)
            renderer(for: incoming).alpha = CGFloat(eased)
            if progress >= 1 {
                transitionTimer?.invalidate()
                transitionTimer = nil
                mapView.removeOverlay(displayed)
                renderers.removeValue(forKey: ObjectIdentifier(displayed))
                self.displayed = incoming
                self.incoming = nil
                if let target = pending {
                    pending = nil
                    guard !matches(incoming.heatmapData, incoming.appearance, target.data, target.appearance) else { return }
                    beginTransition(on: mapView, data: target.data, appearance: target.appearance, at: time)
                }
            }
        }

        private func replaceImmediately(on mapView: MKMapView, data: HeatmapData,
                                        appearance: HeatmapAppearance) {
            transitionTimer?.invalidate()
            transitionTimer = nil
            pending = nil
            let existing = mapView.overlays.compactMap { $0 as? HeatmapOverlay }
            let target = existing.first { matches($0.heatmapData, $0.appearance, data, appearance) }
                ?? HeatmapOverlay(heatmapData: data, appearance: appearance)
            let targetRenderer = renderer(for: target)
            targetRenderer.alpha = 1
            if !existing.contains(where: { $0 === target }) {
                mapView.addOverlay(target, level: .aboveRoads)
            }
            mapView.removeOverlays(existing.filter { $0 !== target })
            renderers = [ObjectIdentifier(target): targetRenderer]
            displayed = target
            incoming = nil
        }

        func clear(on mapView: MKMapView) {
            transitionTimer?.invalidate()
            transitionTimer = nil
            pending = nil
            displayed = nil
            incoming = nil
            mapView.removeOverlays(mapView.overlays.filter { $0 is HeatmapOverlay })
            renderers.removeAll()
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let overlay = overlay as? HeatmapOverlay { return renderer(for: overlay) }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // MapKit may fit or constrain the requested region. Its current
            // viewport is authoritative, independent of camera-target bookkeeping.
            // Read it when this deferred update runs so an interrupted animation
            // cannot enqueue an older viewport after a newer camera command.
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView, mapView.delegate === self else { return }
                let actualRegion = mapView.region
                self.parent.mapViewModel.mapRegionDidChange(actualRegion)
                self.parent.onRegionChange(actualRegion)
            }
        }
    }
}

// MARK: - Heatmap Overlay

class HeatmapOverlay: NSObject, MKOverlay {
    // Preview metadata is updated only by the main-actor coordinator. Tile
    // drawing reads the renderer's synchronized snapshot and fixed mapRect.
    private(set) var heatmapData: HeatmapData
    private(set) var appearance: HeatmapAppearance
    private let mapRect: MKMapRect
    
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    var boundingMapRect: MKMapRect { mapRect }

    init(heatmapData: HeatmapData, appearance: HeatmapAppearance = HeatmapAppearance()) {
        self.heatmapData = heatmapData
        self.appearance = appearance
        self.mapRect = heatmapData.mapRect
        super.init()
    }

    @MainActor
    func updatePreview(data: HeatmapData, appearance: HeatmapAppearance) {
        precondition(MKMapRectEqualToRect(mapRect, data.mapRect))
        heatmapData = data
        self.appearance = appearance
    }
}

// MARK: - Heatmap Overlay Renderer

class HeatmapOverlayRenderer: MKOverlayRenderer {
    // MapKit can draw multiple tiles concurrently while the main thread
    // publishes a preview. Read image and opacity together under the same lock.
    private let snapshotLock = NSLock()
    private var snapshot: (image: CGImage?, opacity: Double)

    var heatmapImage: CGImage? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot.image
    }

    override init(overlay: MKOverlay) {
        let heatmap = overlay as? HeatmapOverlay
        snapshot = (heatmap?.heatmapData.image, heatmap?.appearance.opacity ?? 0.7)
        super.init(overlay: overlay)
    }

    @MainActor
    func updatePreview(image: CGImage?, opacity: Double) {
        snapshotLock.lock()
        snapshot = (image, opacity)
        snapshotLock.unlock()
        setNeedsDisplay()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard overlay is HeatmapOverlay else { return }
        
        let overlayRect = overlay.boundingMapRect
        
        // Calculate the drawing rect
        let drawRect = rect(for: overlayRect)
        
        // Draw the heatmap
        context.saveGState()
        snapshotLock.lock()
        let frame = snapshot
        snapshotLock.unlock()
        context.setAlpha(frame.opacity)
        
        context.interpolationQuality = .high
        if let image = frame.image {
            context.draw(image, in: drawRect)
        }
        
        context.restoreGState()
    }
    
}

// MARK: - Status Bar View

struct StatusBarView: View {
    @ObservedObject var photoManager: PhotoLocationManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .foregroundStyle(.secondary)
            if photoManager.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading photo locations…")
            } else if photoManager.authorizationStatus == .denied || photoManager.authorizationStatus == .restricted {
                Text("Photo access unavailable")
            } else if photoManager.photoLocations.isEmpty {
                Text("No photos with location")
            } else {
                Text("\(photoManager.totalPhotosWithLocation.formatted()) photos with location")
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .help("Only photos with saved GPS locations appear on the map. Location data is processed on this Mac.")
    }
}

// MARK: - Map Controls View

struct MapControlsView: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var photoManager: PhotoLocationManager
    @Binding var appearance: HeatmapAppearance
    @State private var showsHeatmapSettings = false

    var body: some View {
        HStack(spacing: 12) {
            Picker("Map Style", selection: $mapViewModel.mapStyle) {
                Text("Standard").tag(MapStyle.standard)
                Text("Satellite").tag(MapStyle.satellite)
                Text("Hybrid").tag(MapStyle.hybrid)
            }
            .frame(width: 150)
            .help("Choose the map background")

            ControlGroup {
                Button { mapViewModel.zoomOut() } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom out (⌘−)")
                Button { mapViewModel.zoomIn() } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom in (⌘+)")
            }
            .labelStyle(.iconOnly)

            Button { mapViewModel.resetView() } label: {
                Label("All Photos", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(!mapViewModel.canFitPhotos)
            .help("Fit all photos with location in the map (⌘0)")

            Button { showsHeatmapSettings.toggle() } label: {
                Label("Hotspots", systemImage: "slider.horizontal.3")
            }
            .help("Adjust hotspot appearance (⌘⇧H)")
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .popover(isPresented: $showsHeatmapSettings, arrowEdge: .bottom) {
                HeatmapOptionsView(photoManager: photoManager, appearance: $appearance)
            }
        }
    }
}

// MARK: - Heatmap Legend View

struct HeatmapLegendView: View {
    let palette: HeatmapPalette
    
    var body: some View {
        HStack(spacing: 16) {
            Text("Photo density:")
                .foregroundColor(.secondary)
                .font(.caption)
            
            // Gradient bar
            HeatmapGradientBar(palette: palette)
                .frame(width: 90, height: 8)
                .clipShape(Capsule())
            
            HStack(spacing: 4) {
                Text("Low")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("—")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("High")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .help("Relative photo density in the current map view: low to high")
    }
}

struct HeatmapGradientBar: View {
    let palette: HeatmapPalette

    var body: some View {
        LinearGradient(
            colors: palette.stops.dropFirst().map {
                Color(red: $0.red, green: $0.green, blue: $0.blue)
            },
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Authorization Overlay

struct AuthorizationOverlay: View {
    @ObservedObject var photoManager: PhotoLocationManager
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                if photoManager.isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        
                        Text("Loading photo locations...")
                            .font(.title2)
                            .foregroundColor(.white)
                        
                        Text("\(photoManager.loadedPhotosCount) of \(photoManager.totalPhotosCount) photos processed")
                            .foregroundColor(.white.opacity(0.7))
                        
                        ProgressView(value: Double(photoManager.loadedPhotosCount), total: Double(max(1, photoManager.totalPhotosCount)))
                            .progressViewStyle(.linear)
                            .frame(width: 300)
                        
                        if photoManager.totalPhotosWithLocation > 0 {
                            Text("\(photoManager.totalPhotosWithLocation) photos with GPS data found")
                                .foregroundColor(.green.opacity(0.8))
                                .font(.caption)
                        }
                    }
                } else if photoManager.authorizationStatus == .denied || photoManager.authorizationStatus == .restricted {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 60))
                            .foregroundColor(.yellow)
                        
                        Text("Photo Access Required")
                            .font(.title)
                            .foregroundColor(.white)
                        
                        Text("Please allow access to your photos in System Settings to use this app.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.8))
                            .frame(maxWidth: 400)
                        
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        
                        Text("Requesting photo access...")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(PhotoLocationManager())
}
