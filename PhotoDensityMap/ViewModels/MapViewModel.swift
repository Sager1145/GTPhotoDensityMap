//
//  MapViewModel.swift
//  PhotoDensityMap
//
//  Created with Claude
//

import Foundation
import MapKit
import Combine
import AppKit

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
    private var photoRegion: MKCoordinateRegion?
    private var didFitInitialPhotos = false
    private var pendingZoomRegion: MKCoordinateRegion?
    private var lastZoomInputTime: TimeInterval?
    private let reduceMotion: () -> Bool
    private let clock: () -> TimeInterval

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.reduceMotion = reduceMotion
        self.clock = clock
    }
    
    // MARK: - Map Controls
    
    func zoomIn() { zoom(by: 0.5) }

    func zoomOut() { zoom(by: 2) }

    private func zoom(by factor: Double) {
        // Accumulate only a short burst of inputs. MapKit may clamp its final
        // camera differently from regionThatFits, so targets cannot determine
        // when an animation has finished or remain the basis of future zooms.
        let now = clock()
        let continuesBurst = lastZoomInputTime.map { now - $0 < 0.35 } ?? false
        var region = (continuesBurst ? pendingZoomRegion : nil) ?? mapView?.region ?? currentRegion
        region.span.latitudeDelta = min(170, max(0.0001, region.span.latitudeDelta * factor))
        region.span.longitudeDelta = min(360, max(0.0001, region.span.longitudeDelta * factor))
        setRegion(region, animated: true)
        pendingZoomRegion = mapView?.regionThatFits(region) ?? region
        lastZoomInputTime = now
    }

    /// Cache the library fit once per update, without undoing later pans.
    func updatePhotoLocations(_ locations: [PhotoLocation]) {
        photoRegion = Self.fittedRegion(for: locations)
        canFitPhotos = photoRegion != nil
        guard !didFitInitialPhotos, canFitPhotos else { return }
        didFitInitialPhotos = true
        if let photoRegion { setRegion(photoRegion, animated: false) }
    }

    func resetView() {
        if let photoRegion { setRegion(photoRegion, animated: true) }
    }

    func showWorld() {
        setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 360)
        ), animated: true)
    }

    private static func fittedRegion(for locations: [PhotoLocation]) -> MKCoordinateRegion? {
        let coordinates = locations.map(\.coordinate).filter { CLLocationCoordinate2DIsValid($0) }
        guard !coordinates.isEmpty else { return nil }

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
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitudeCenter, longitude: longitudeCenter),
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan,
                                   longitudeDelta: min(360, max(0.05, longitudeRange * 1.3)))
        )
    }

    private func setRegion(_ region: MKCoordinateRegion, animated: Bool) {
        pendingZoomRegion = nil
        lastZoomInputTime = nil
        currentRegion = region
        let shouldAnimate = animated && !reduceMotion()
        isAnimating = shouldAnimate && mapView != nil
        mapView?.setRegion(region, animated: shouldAnimate)
    }

    /// Call when a user starts dragging, scrolling, or gesturing on the map.
    func mapInteractionBegan() {
        pendingZoomRegion = nil
        lastZoomInputTime = nil
        isAnimating = false
    }

    /// Reconcile MapKit's fitted viewport when its camera transition finishes.
    func mapRegionDidChange(_ region: MKCoordinateRegion) {
        // Delegate completion describes the actual legal camera, including
        // MapKit's constraints. It must never wait for a predicted span match.
        // Keep the short input burst independent of interrupted completions.
        isAnimating = false
        currentRegion = region
    }

}
