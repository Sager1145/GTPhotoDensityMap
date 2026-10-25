import Foundation
import MapKit

@main
struct MapNavigationRegression {
    @MainActor
    static func main() {
        let model = MapViewModel()
        let tokyo = PhotoLocation(id: "tokyo", coordinate: .init(latitude: 35.68, longitude: 139.69))
        model.fitToShow(locations: [tokyo])
        check(abs(model.currentRegion.center.latitude - 35.68) < 0.01,
              "Fit All must update the requested viewport even before the map is attached")
        check(model.currentRegion.span.latitudeDelta > 0 && model.currentRegion.span.latitudeDelta < 1,
              "One photo must have a useful nonzero city-scale viewport")
        let pacific = [
            PhotoLocation(id: "east", coordinate: .init(latitude: 10, longitude: 179)),
            PhotoLocation(id: "west", coordinate: .init(latitude: 11, longitude: -179))
        ]
        model.fitToShow(locations: pacific)
        check(model.currentRegion.span.longitudeDelta < 10,
              "Photos across the date line must fit locally instead of spanning the world")
        model.zoomIn()
        let zoomedSpan = model.currentRegion.span.longitudeDelta
        model.zoomOut()
        check(model.currentRegion.span.longitudeDelta > zoomedSpan, "Zoom controls must change the viewport")
        let previous = model.currentRegion
        model.fitToShow(locations: [])
        check(model.currentRegion.center.latitude == previous.center.latitude,
              "An empty photo set must leave the viewport alone")
        let library = MapViewModel()
        library.updatePhotoLocations([])
        check(!library.canFitPhotos, "An empty library must disable All Photos")
        library.updatePhotoLocations([tokyo])
        check(library.canFitPhotos && abs(library.currentRegion.center.latitude - 35.68) < 0.01,
              "The first nonempty library must fit automatically")
        library.centerOn(coordinate: .init(latitude: 48, longitude: 2))
        library.updatePhotoLocations(pacific)
        check(library.currentRegion.center.latitude == 48,
              "Later library updates must preserve the user's map position")
        library.resetView()
        check(library.currentRegion.span.longitudeDelta < 10 && abs(library.currentRegion.center.longitude) > 170,
              "All Photos must return to the latest cached library, not the world")
        for _ in 0..<30 { library.zoomOut() }
        check(library.currentRegion.span.latitudeDelta <= 170 && library.currentRegion.span.longitudeDelta <= 360,
              "Repeated zoom out must remain within valid map spans")
        for _ in 0..<60 { library.zoomIn() }
        check(library.currentRegion.span.latitudeDelta > 0 && library.currentRegion.span.longitudeDelta > 0,
              "Repeated zoom in must never collapse to zero")
        let laggingMap = LaggingMapView(frame: .zero)
        var cameraTime: TimeInterval = 10
        let camera = MapViewModel(reduceMotion: { false }, clock: { cameraTime })
        camera.mapView = laggingMap
        laggingMap.displayedRegion = MKCoordinateRegion(
            center: .init(latitude: 48, longitude: 2),
            span: .init(latitudeDelta: 8, longitudeDelta: 16)
        )
        camera.zoomIn()
        camera.zoomIn()
        check(laggingMap.requests.last!.region.span.longitudeDelta == 4,
              "Rapid zoom clicks must accumulate while the displayed camera lags")
        camera.zoomOut()
        check(laggingMap.requests.last!.region.span.longitudeDelta == 8,
              "Reversing zoom must step back from the pending target")
        camera.mapRegionDidChange(MKCoordinateRegion(
            center: .init(latitude: 48, longitude: 2),
            span: .init(latitudeDelta: 4, longitudeDelta: 8.5)
        ))
        camera.zoomIn()
        check(laggingMap.requests.last!.region.span.longitudeDelta == 4,
              "A completion from an interrupted animation must not erase the newer target")
        check(laggingMap.requests.last!.animated,
              "Zoom should use MapKit animation when Reduce Motion is off")
        camera.mapInteractionBegan()
        laggingMap.displayedRegion = MKCoordinateRegion(
            center: .init(latitude: 51, longitude: -1),
            span: .init(latitudeDelta: 12, longitudeDelta: 24)
        )
        camera.zoomIn()
        check(laggingMap.requests.last!.region.center.latitude == 51 &&
              laggingMap.requests.last!.region.span.longitudeDelta == 12,
              "User interaction must cancel the old zoom target and use the visible camera")
        var settledRegion = laggingMap.requests.last!.region
        settledRegion.span.longitudeDelta = 12.001
        camera.mapRegionDidChange(settledRegion)
        laggingMap.displayedRegion = camera.currentRegion
        cameraTime += 0.36
        camera.zoomOut()
        check(abs(laggingMap.requests.last!.region.span.longitudeDelta - 24.002) < 0.00001,
              "After the input burst expires, zoom must use MapKit's actual viewport")
        camera.centerOn(coordinate: .init(latitude: 35, longitude: 139))
        laggingMap.displayedRegion = MKCoordinateRegion(
            center: .init(latitude: 35, longitude: 139),
            span: .init(latitudeDelta: 2, longitudeDelta: 4)
        )
        camera.zoomIn()
        check(laggingMap.requests.last!.region.center.longitude == 139 &&
              laggingMap.requests.last!.region.span.longitudeDelta == 2,
              "An absolute camera command must discard the previous zoom burst immediately")
        var prefersReducedMotion = true
        let accessibleCamera = MapViewModel(reduceMotion: { prefersReducedMotion })
        let accessibleMap = LaggingMapView(frame: .zero)
        accessibleCamera.mapView = accessibleMap
        accessibleCamera.zoomIn()
        check(!accessibleMap.requests.last!.animated && !accessibleCamera.isAnimating,
              "Reduce Motion must apply zoom immediately without animation")
        accessibleCamera.centerOn(coordinate: .init(latitude: 1, longitude: 2))
        check(!accessibleMap.requests.last!.animated,
              "Reduce Motion must also apply to other camera controls")
        prefersReducedMotion = false
        accessibleCamera.zoomOut()
        check(accessibleMap.requests.last!.animated,
              "Camera controls must respect changes to Reduce Motion without recreating the model")
        let nativeMap = MKMapView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        let nativeCamera = MapViewModel(reduceMotion: { false })
        let observer = NativeNavigationObserver(nativeCamera)
        nativeMap.delegate = observer
        nativeCamera.mapView = nativeMap
        let globalLibrary = [-135.0, -45.0, 45.0, 135.0].enumerated().map {
            PhotoLocation(id: String($0.offset), coordinate: .init(latitude: 20, longitude: $0.element))
        }
        nativeCamera.updatePhotoLocations(globalLibrary)
        for _ in 0..<4 { nativeCamera.zoomIn() }
        let previousCompletionCount = observer.completionCount
        nativeCamera.resetView()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(observer.completionCount > previousCompletionCount && !nativeCamera.isAnimating,
              "Native All Photos completion must settle even when MapKit clamps its fitted destination")
        check(abs(nativeCamera.currentRegion.span.longitudeDelta - nativeMap.region.span.longitudeDelta) < 0.000001,
              "The recorded viewport must reflect MapKit's actual All Photos destination")
        nativeCamera.showWorld()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(!nativeCamera.isAnimating,
              "Native world completion must settle without requiring an exact regionThatFits match")
        print("PASS: native All Photos and world camera clamps release animation state")
        print("PASS: accumulated zoom, reverse zoom, native animation, pan interruption, camera completion, live Reduce Motion")
        print("PASS: fit before attachment, single photo, date line, zoom, empty input, initial fit, pan preservation, cached reset, zoom limits")
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }
}

@MainActor
final class NativeNavigationObserver: NSObject, MKMapViewDelegate {
    let model: MapViewModel
    var completionCount = 0

    init(_ model: MapViewModel) { self.model = model }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        completionCount += 1
        model.mapRegionDidChange(mapView.region)
    }
}

/// Keep the displayed camera stationary to reproduce a native animation in flight.
@MainActor
final class LaggingMapView: MKMapView {
    var displayedRegion = MKCoordinateRegion(
        center: .init(latitude: 0, longitude: 0),
        span: .init(latitudeDelta: 8, longitudeDelta: 16)
    )
    var requests: [(region: MKCoordinateRegion, animated: Bool)] = []

    override var region: MKCoordinateRegion {
        get { displayedRegion }
        set { displayedRegion = newValue }
    }

    override func setRegion(_ region: MKCoordinateRegion, animated: Bool) {
        requests.append((region, animated))
    }

    override func regionThatFits(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        region
    }
}
