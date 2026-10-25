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
                photoLocations: photoManager.photoLocations,
                heatmapData: photoManager.heatmapData,
                appearance: heatmapAppearance
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
        .onChange(of: photoManager.photoLocations.count, initial: true) { _, _ in
            mapViewModel.updatePhotoLocations(photoManager.photoLocations)
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
    let photoLocations: [PhotoLocation]
    let heatmapData: HeatmapData?
    var appearance: HeatmapAppearance = HeatmapAppearance()
    
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsCompass = true
        mapView.showsZoomControls = false
        mapView.showsScale = true
        
        mapViewModel.mapView = mapView
        
        return mapView
    }
    
    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        // Region/style publications do not invalidate the geographic overlay.
        // Keep both it and its renderer alive while MapKit pans the map.
        let existing = mapView.overlays.compactMap { $0 as? HeatmapOverlay }
        guard let heatmapData, !photoLocations.isEmpty else {
            mapView.removeOverlays(existing)
            return
        }
        guard existing.first?.heatmapData.id != heatmapData.id || existing.first?.appearance.opacity != appearance.opacity else { return }
        let overlay = HeatmapOverlay(heatmapData: heatmapData, appearance: appearance)
        mapView.addOverlay(overlay, level: .aboveRoads)
        mapView.removeOverlays(existing)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: HeatmapMapView
        
        init(_ parent: HeatmapMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let heatmapOverlay = overlay as? HeatmapOverlay {
                return HeatmapOverlayRenderer(overlay: heatmapOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Dispatch updates asynchronously to avoid publishing changes during view updates
            DispatchQueue.main.async {
                self.parent.mapViewModel.currentRegion = mapView.region
                
                // Trigger heatmap recalculation based on new zoom level
                NotificationCenter.default.post(
                    name: .mapRegionChanged,
                    object: mapView.region
                )
            }
        }
    }
}

// MARK: - Heatmap Overlay

class HeatmapOverlay: NSObject, MKOverlay {
    let heatmapData: HeatmapData
    let appearance: HeatmapAppearance
    
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    var boundingMapRect: MKMapRect { heatmapData.mapRect }

    init(heatmapData: HeatmapData, appearance: HeatmapAppearance = HeatmapAppearance()) {
        self.heatmapData = heatmapData
        self.appearance = appearance
        super.init()
    }
}

// MARK: - Heatmap Overlay Renderer

class HeatmapOverlayRenderer: MKOverlayRenderer {
    // Immutable after initialization: MapKit may draw tiles concurrently.
    let heatmapImage: CGImage?

    override init(overlay: MKOverlay) {
        if let heatmap = overlay as? HeatmapOverlay {
            heatmapImage = heatmap.heatmapData.image
        } else {
            heatmapImage = nil
        }
        super.init(overlay: overlay)
    }
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let heatmapOverlay = overlay as? HeatmapOverlay else { return }
        
        let overlayRect = overlay.boundingMapRect
        
        // Calculate the drawing rect
        let drawRect = rect(for: overlayRect)
        
        // Draw the heatmap
        context.saveGState()
        context.setAlpha(heatmapOverlay.appearance.opacity)
        
        context.interpolationQuality = .high
        if let image = heatmapImage {
            context.draw(image, in: drawRect)
        }
        
        context.restoreGState()
    }
    
}

// Rasterize each immutable snapshot once, before publishing it to the UI.
enum HeatmapRasterizer {
    static func makeImage(grid: [[Double]], maxDensity: Double, appearance: HeatmapAppearance = HeatmapAppearance()) -> CGImage? {
        let gridWidth = grid.count
        let gridHeight = grid.first?.count ?? 0
        guard gridWidth > 0, gridHeight > 0 else { return nil }
        // Resolution belongs to the grid, not a changing map-space draw rect.
        let width = gridWidth * 4
        let height = gridHeight * 4
        
        // Create bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        // Clear background
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        
        let cellWidth = CGFloat(width) / CGFloat(gridWidth)
        let cellHeight = CGFloat(height) / CGFloat(gridHeight)
        
        // Draw each cell with interpolated colors
        for x in 0..<gridWidth {
            for y in 0..<gridHeight {
                let density = grid[x][y]
                if density > 0 {
                    let color = appearance.palette.color(at: appearance.normalizedDensity(density / max(maxDensity, .leastNonzeroMagnitude)))
                    context.setFillColor(CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
                    
                    // Draw cell with slight overlap for smoother appearance
                    let rect = CGRect(
                        x: CGFloat(x) * cellWidth - 1,
                        y: CGFloat(y) * cellHeight - 1,
                        width: cellWidth + 2,
                        height: cellHeight + 2
                    )
                    context.fillEllipse(in: rect.insetBy(dx: -cellWidth * 0.5, dy: -cellHeight * 0.5))
                }
            }
        }
        
        // Apply Gaussian blur for smooth gradient effect
        if let image = context.makeImage() {
            return appearance.smoothing == 0 ? image : applyBlur(to: image, radius: max(cellWidth, cellHeight) * appearance.smoothing)
        }
        
        return context.makeImage()
    }
    
    private static func applyBlur(to image: CGImage, radius: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(radius, forKey: kCIInputRadiusKey)
        
        guard let outputImage = filter?.outputImage else { return image }
        
        let ciContext = CIContext()
        let extent = ciImage.extent
        
        return ciContext.createCGImage(outputImage, from: extent)
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

// MARK: - Notification Extension

extension Notification.Name {
    static let mapRegionChanged = Notification.Name("mapRegionChanged")
}

#Preview {
    ContentView()
        .environmentObject(PhotoLocationManager())
}
