//
//  MapViewModel.swift
//  PhotoDensityMap
//
//  Created with Claude
//

import Foundation
import MapKit
import Combine

enum MapStyle: Int, CaseIterable {
    case standard
    case satellite
    case hybrid
    
    var mapType: MKMapType {
        switch self {
        case .standard:
            return .standard
        case .satellite:
            return .satellite
        case .hybrid:
            return .hybrid
        }
    }
}

@MainActor
class MapViewModel: ObservableObject {
    @Published var currentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 360)
    )
    
    @Published var mapStyle: MapStyle = .standard {
        didSet {
            mapView?.mapType = mapStyle.mapType
        }
    }
    
    @Published var isAnimating: Bool = false
    
    weak var mapView: MKMapView? {
        didSet {
            mapView?.mapType = mapStyle.mapType
            mapView?.setRegion(currentRegion, animated: false)
        }
    }

    @Published private(set) var canFitPhotos = false
    private var photoLocations: [PhotoLocation] = []
    private var didFitInitialPhotos = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Observe map style changes
        $mapStyle
            .dropFirst() // Skip the initial value since it's already set
            .sink { [weak self] style in
                self?.mapView?.mapType = style.mapType
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Map Controls
    
    func zoomIn() { zoom(by: 0.5) }

    func zoomOut() { zoom(by: 2) }

    private func zoom(by factor: Double) {
        var region = mapView?.region ?? currentRegion
        region.span.latitudeDelta = min(170, max(0.0001, region.span.latitudeDelta * factor))
        region.span.longitudeDelta = min(360, max(0.0001, region.span.longitudeDelta * factor))
        setRegion(region, animated: true)
    }

    /// Cache the complete loaded library and fit once, without undoing later pans.
    func updatePhotoLocations(_ locations: [PhotoLocation]) {
        photoLocations = locations
        canFitPhotos = !locations.isEmpty
        guard !didFitInitialPhotos, canFitPhotos else { return }
        didFitInitialPhotos = true
        fitToShow(locations: locations, animated: false)
    }

    func resetView() {
        fitToShow(locations: photoLocations)
    }

    func showWorld() {
        setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 360)
        ), animated: true)
    }

    func centerOn(coordinate: CLLocationCoordinate2D, span: MKCoordinateSpan? = nil) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: span ?? MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
        setRegion(region, animated: true)
    }
    
    func fitToShow(locations: [PhotoLocation], animated: Bool = true) {
        let coordinates = locations.map(\.coordinate).filter { CLLocationCoordinate2DIsValid($0) }
        guard !coordinates.isEmpty else { return }

        // The complement of the largest longitude gap is the shortest arc that
        // contains the library, including photos on both sides of the date line.
        let longitudes = coordinates.map { ($0.longitude + 360).truncatingRemainder(dividingBy: 360) }.sorted()
        var largestGap = -Double.infinity
        var arcStart = longitudes[0]
        for index in longitudes.indices {
            let next = index + 1 < longitudes.count ? longitudes[index + 1] : longitudes[0] + 360
            let gap = next - longitudes[index]
            if gap > largestGap {
                largestGap = gap
                arcStart = next.truncatingRemainder(dividingBy: 360)
            }
        }
        let longitudeRange = 360 - largestGap
        let longitudeCenter = (arcStart + longitudeRange / 2 + 180).truncatingRemainder(dividingBy: 360) - 180
        let latitudes = coordinates.map { min(85, max(-85, $0.latitude)) }
        let minLatitude = latitudes.min()!
        let maxLatitude = latitudes.max()!
        let latitudeSpan = min(170, max(0.05, (maxLatitude - minLatitude) * 1.3))
        let latitudeCenter = min(85 - latitudeSpan / 2,
                                 max(-85 + latitudeSpan / 2, (minLatitude + maxLatitude) / 2))
        setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitudeCenter, longitude: longitudeCenter),
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan,
                                   longitudeDelta: min(360, max(0.05, longitudeRange * 1.3)))
        ), animated: animated)
    }

    private func setRegion(_ region: MKCoordinateRegion, animated: Bool) {
        currentRegion = region
        mapView?.setRegion(region, animated: animated)
    }

    // MARK: - Zoom Level Calculation
    
    /// Returns a zoom level from 0 (world) to 20 (building level)
    var currentZoomLevel: Double {
        guard let mapView = mapView else { return 10 }
        
        let longitudeDelta = mapView.region.span.longitudeDelta
        let zoomLevel = log2(360 / longitudeDelta)
        return max(0, min(20, zoomLevel))
    }
    
    /// Clustering radius in meters based on current zoom level
    var clusteringRadius: Double {
        // At zoom level 0 (world view), large radius
        // At zoom level 20 (street level), small radius
        let baseRadius = 50000.0 // 50km at zoom 0
        return baseRadius / pow(2, currentZoomLevel / 2)
    }
}
