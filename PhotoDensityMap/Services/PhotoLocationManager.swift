//
//  PhotoLocationManager.swift
//  PhotoDensityMap
//
//  Created with Claude
//

import Foundation
import Photos
import CoreLocation
import Combine
import MapKit

// MARK: - Heatmap Data Model

struct HeatmapData {
    let id = UUID()
    let grid: [[Double]]           // 2D grid of density values
    let gridWidth: Int
    let gridHeight: Int
    let mapRect: MKMapRect
    let maxDensity: Double
    let cellSizeMapPoints: Double
    let image: CGImage?
    let radius: Double
    /// Continuous viewport scale relative to the quantized world grid.
    let kernelScale: Double
    let appearance: HeatmapAppearance

    init(grid: [[Double]], gridWidth: Int, gridHeight: Int, mapRect: MKMapRect,
         maxDensity: Double, cellSizeMapPoints: Double, radius: Double = 50, appearance: HeatmapAppearance = HeatmapAppearance(), kernelScale: Double = 1) {
        self.appearance = appearance
        self.radius = radius
        self.kernelScale = kernelScale
        self.grid = grid
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.mapRect = mapRect
        self.maxDensity = maxDensity
        self.cellSizeMapPoints = cellSizeMapPoints
        // Density calculation and raster preparation both run on the worker.
        self.image = HeatmapRasterizer.makeImage(grid: grid, maxDensity: maxDensity, appearance: appearance, smoothingScale: kernelScale)
    }
    
    func canReuse(for rect: MKMapRect, cellSize: Double, radius: Double) -> Bool {
        let requestedScale = PhotoLocationManager.kernelScale(for: rect, cellSize: cellSize)
        // MapKit's region bounds reconstruct a slightly different projected
        // scale during a constant-scale pan. Allow 0.5% drift: at the default
        // 16px Gaussian sigma on a 1000px viewport this is at most 0.08px.
        return self.radius == radius && cellSizeMapPoints == cellSize &&
            abs(kernelScale - requestedScale) <= kernelScale * 0.005 && mapRect.contains(rect)
    }

    func restyled(_ appearance: HeatmapAppearance) -> HeatmapData {
        HeatmapData(grid: grid, gridWidth: gridWidth, gridHeight: gridHeight,
                    mapRect: mapRect, maxDensity: maxDensity, cellSizeMapPoints: cellSizeMapPoints,
                    radius: radius, appearance: appearance, kernelScale: kernelScale)
    }

    static func empty() -> HeatmapData {
        HeatmapData(
            grid: [],
            gridWidth: 0,
            gridHeight: 0,
            mapRect: .null,
            maxDensity: 0,
            cellSizeMapPoints: 0
        )
    }
}

@MainActor
class PhotoLocationManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var photoLocations: [PhotoLocation] = []
    @Published private(set) var heatmapData: HeatmapData?
    
    @Published private(set) var totalPhotosCount: Int = 0
    @Published private(set) var loadedPhotosCount: Int = 0
    @Published private(set) var totalPhotosWithLocation: Int = 0
    
    /// Controls the radius/spread of heat points (adjustable via UI)
    @Published var heatmapRadius: Double = 50 {
        didSet {
            if heatmapRadius != oldValue { regenerateHeatmap(force: true) }
        }
    }
    
    // MARK: - Private Properties
    
    private var heatmapAppearance = HeatmapAppearance()

    func updateAppearance(_ appearance: HeatmapAppearance) {
        let needsRaster = !heatmapAppearance.hasSameRaster(as: appearance)
        heatmapAppearance = appearance
        if needsRaster { regenerateHeatmap() }
    }

    private let viewportChanges = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var currentHeatmapTask: Task<Void, Never>?
    private var currentMapRegion: MKCoordinateRegion?
    
    // MARK: - Initialization
    
    init() {
        viewportChanges
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.regenerateHeatmap() }
            .store(in: &cancellables)
    }

    /// Remember the actual camera immediately; debounce only expensive work.
    func updateMapRegion(_ region: MKCoordinateRegion) {
        currentMapRegion = region
        viewportChanges.send()
    }

    // MARK: - Authorization
    
    func requestAuthorization() {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = currentStatus
        
        switch currentStatus {
        case .authorized, .limited:
            loadPhotoLocations()
        case .notDetermined:
            Task {
                let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                await MainActor.run {
                    self.authorizationStatus = status
                    if status == .authorized || status == .limited {
                        self.loadPhotoLocations()
                    }
                }
            }
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }
    
    // MARK: - Load Photos
    
    private func loadPhotoLocations() {
        guard !isLoading else { return }
        isLoading = true
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            
            // Fetch all image assets
            let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
            
            await MainActor.run {
                self.totalPhotosCount = assets.count
            }
            
            var locations: [PhotoLocation] = []
            var processedCount = 0
            
            // Process in batches for better performance
            let batchSize = 500
            
            assets.enumerateObjects { asset, index, _ in
                if let location = asset.location {
                    let photoLocation = PhotoLocation(
                        id: asset.localIdentifier,
                        coordinate: location.coordinate,
                        creationDate: asset.creationDate
                    )
                    locations.append(photoLocation)
                }
                
                processedCount += 1
                
                // Update UI periodically
                if processedCount % batchSize == 0 {
                    let currentCount = processedCount
                    let currentLocations = locations.count
                    Task { @MainActor [currentCount, currentLocations] in
                        self.loadedPhotosCount = currentCount
                        self.totalPhotosWithLocation = currentLocations
                    }
                }
            }
            
            // Final update
            await MainActor.run { [processedCount, locations] in
                self.loadedPhotosCount = processedCount
                self.totalPhotosWithLocation = locations.count
                self.photoLocations = locations
                self.currentHeatmapTask?.cancel()
                self.heatmapData = nil
                self.regenerateHeatmap(force: true)
                self.isLoading = false
            }
        }
    }
    
    // MARK: - Heatmap Generation
    
    private func regenerateHeatmap(force: Bool = false) {
        guard !photoLocations.isEmpty, let region = currentMapRegion else { return }
        let visibleRect = Self.projectedRect(for: region)
        if !force, let data = heatmapData,
           data.canReuse(for: visibleRect, cellSize: Self.cellSize(for: visibleRect),
                         radius: heatmapRadius) {
            currentHeatmapTask?.cancel()
            if !data.appearance.hasSameRaster(as: heatmapAppearance) {
                let appearance = heatmapAppearance
                currentHeatmapTask = Task.detached(priority: .userInitiated) { [weak self] in
                    let refreshed = data.restyled(appearance)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        guard !Task.isCancelled else { return }
                        self?.heatmapData = refreshed
                    }
                }
            }
            return
        }
        generateHeatmap(for: region)
    }
    
    private func generateHeatmap(for region: MKCoordinateRegion) {
        // Cancel any pending heatmap generation
        currentHeatmapTask?.cancel()
        
        let locations = photoLocations
        let radius = heatmapRadius
        let appearance = heatmapAppearance
        currentHeatmapTask = Task.detached(priority: .userInitiated) { [weak self] in
            let data = Self.calculateHeatmapData(
                locations: locations,
                region: region,
                radius: radius, appearance: appearance
            )
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.heatmapData = data
            }
        }
    }
    
    nonisolated static func calculateHeatmapData(
        locations: [PhotoLocation],
        region: MKCoordinateRegion,
        radius: Double, appearance: HeatmapAppearance = HeatmapAppearance()
    ) -> HeatmapData {
        
        guard !locations.isEmpty else { return .empty() }
        
        // Use MapKit's projection and a world-anchored grid. Panning must not
        // change the world-space bin of a photo or stretch latitude linearly.
        let visibleRect = projectedRect(for: region)
        let cellSize = cellSize(for: visibleRect)
        let paddedRect = visibleRect.insetBy(dx: -visibleRect.width * 0.25,
                                            dy: -visibleRect.height * 0.25)
        let minX = floor(paddedRect.minX / cellSize) * cellSize
        let minY = floor(paddedRect.minY / cellSize) * cellSize
        let gridWidth = Int(ceil((paddedRect.maxX - minX) / cellSize))
        let gridHeight = Int(ceil((paddedRect.maxY - minY) / cellSize))
        let mapRect = MKMapRect(x: minX, y: minY,
                               width: Double(gridWidth) * cellSize,
                               height: Double(gridHeight) * cellSize)
        var grid = Array(repeating: Array(repeating: 0.0, count: gridHeight), count: gridWidth)
        // Keep the spread continuous when the world grid moves between powers
        // of two. Quantization changes sampling resolution, not visual radius.
        let kernelScale = kernelScale(for: visibleRect, cellSize: cellSize)
        let kernelRadius = (radius / 10 + 1) * kernelScale
        let radiusCells = Int(ceil(kernelRadius))
        let sigma = kernelRadius / 2.5

        // One kernel per snapshot: weights depend on spread and scale, never on
        // the individual photo. Preserve accumulation order for stable pixels.
        let kernel = (-radiusCells...radiusCells).flatMap { dx in
            (-radiusCells...radiusCells).map { dy in
                let distance = sqrt(Double(dx * dx + dy * dy))
                return (dx: dx, dy: dy, weight: exp(-(distance * distance) / (2 * sigma * sigma)))
            }
        }
        for location in locations {
            guard !Task.isCancelled else { return .empty() }
            let point = MKMapPoint(location.coordinate)
            // Choose the copy nearest the viewport when crossing the date line.
            let worldWidth = MKMapRect.world.width
            let x = point.x + round((mapRect.midX - point.x) / worldWidth) * worldWidth
            let gridX = Int(floor((x - minX) / cellSize))
            let gridY = Int(floor((point.y - minY) / cellSize))
            // Include kernels whose centers lie just outside the raster.
            guard gridX >= -radiusCells && gridX < gridWidth + radiusCells &&
                  gridY >= -radiusCells && gridY < gridHeight + radiusCells else {
                continue
            }

            for sample in kernel {
                let nx = gridX + sample.dx
                let ny = gridY + sample.dy
                guard nx >= 0 && nx < gridWidth && ny >= 0 && ny < gridHeight else { continue }
                grid[nx][ny] += sample.weight
            }
        }

        // Find maximum density and calculate adaptive normalization
        var maxDensity = 0.0
        var allValues: [Double] = []
        for row in grid {
            guard !Task.isCancelled else { return .empty() }
            for value in row {
                maxDensity = max(maxDensity, value)
                if value > 0 {
                    allValues.append(value)
                }
            }
        }
        
        // Calculate normalization based on current viewport
        let normalizedMaxDensity: Double
        if allValues.isEmpty {
            normalizedMaxDensity = 1.0
        } else {
            // Sort values to find percentiles
            allValues.sort()
            
            // Use 90th percentile for more responsive normalization
            let percentile90Index = Int(Double(allValues.count) * 0.90)
            let percentile90 = allValues[min(percentile90Index, allValues.count - 1)]
            
            // Also consider median for very sparse areas
            let medianIndex = allValues.count / 2
            let median = allValues[medianIndex]
            
            // Adaptive normalization: use percentile for dense areas, boost for sparse areas
            if allValues.count > 100 {
                // Dense view: use 90th percentile
                normalizedMaxDensity = percentile90
            } else {
                // Sparse view: use a blend to make colors more visible
                normalizedMaxDensity = max(median * 3, maxDensity * 0.25)
            }
        }
        
        return HeatmapData(
            grid: grid,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            mapRect: mapRect,
            maxDensity: normalizedMaxDensity,
            cellSizeMapPoints: cellSize, radius: radius, appearance: appearance, kernelScale: kernelScale
        )
    }
    
    nonisolated static func projectedRect(for region: MKCoordinateRegion) -> MKMapRect {
        let north = min(85.05112878, region.center.latitude + region.span.latitudeDelta / 2)
        let south = max(-85.05112878, region.center.latitude - region.span.latitudeDelta / 2)
        let top = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: region.center.longitude))
        let bottom = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: region.center.longitude))
        let width = max(1, MKMapRect.world.width * min(360, region.span.longitudeDelta) / 360)
        return MKMapRect(x: top.x - width / 2, y: top.y,
                         width: width, height: max(1, bottom.y - top.y))
    }

    nonisolated static func kernelScale(for rect: MKMapRect, cellSize: Double) -> Double {
        max(rect.width, rect.height) / 150 / cellSize
    }

    nonisolated static func cellSize(for rect: MKMapRect) -> Double {
        // Quantized scale keeps the grid resolution stable throughout a pan.
        pow(2, round(log2(max(rect.width, rect.height) / 150)))
    }

}
