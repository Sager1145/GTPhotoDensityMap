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
        print("PASS: fit before attachment, single photo, date line, zoom, empty input, initial fit, pan preservation, cached reset, zoom limits")
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }
}
