import Foundation
import AppKit
import MapKit
import CoreGraphics

@main
@MainActor
struct HeatmapScaleRegression {
    static func main() {
        nativePanReuseRegression()
        // Reintroducing a fixed Gaussian radius in grid cells makes this fail:
        // the two viewports differ by 0.2%, but straddle a power-of-two cell boundary.
        let threshold = 150 * 4096.0 * sqrt(2)
        let lower = region(width: threshold * 0.999)
        let upper = region(width: threshold * 1.001)
        let location = PhotoLocation(id: "origin", coordinate: .init(latitude: 0, longitude: 0))
        let first = calculate(lower, location)
        let second = calculate(upper, location)
        check(second.cellSizeMapPoints == first.cellSizeMapPoints * 2, "fixture must cross the quantized grid boundary")
        let firstSigma = screenSigma(first, region: lower)
        let secondSigma = screenSigma(second, region: upper)
        check(abs(firstSigma - secondSigma) < 0.01,
              "0.2% zoom must preserve Gaussian screen spread: \(firstSigma) vs \(secondSigma) px")
        print("PASS: 0.2% zoom across quantization boundary preserves Gaussian screen spread")
        let firstBlurScale = first.kernelScale * first.cellSizeMapPoints / PhotoLocationManager.projectedRect(for: lower).width
        let secondBlurScale = second.kernelScale * second.cellSizeMapPoints / PhotoLocationManager.projectedRect(for: upper).width
        check(abs(firstBlurScale - secondBlurScale) < 1e-12,
              "raster smoothing must receive the same screen-space scale across the grid boundary")
        var restyledAppearance = HeatmapAppearance()
        restyledAppearance.palette = .ocean
        let restyled = first.restyled(restyledAppearance)
        check(restyled.kernelScale == first.kernelScale && restyled.grid == first.grid,
              "restyling must retain the continuous Gaussian and smoothing scale")
        print("PASS: smoothing scale remains continuous and survives palette restyling")
        let firstRasterSpread = alphaScreenSigma(first, region: lower)
        let secondRasterSpread = alphaScreenSigma(second, region: upper)
        check(abs(secondRasterSpread / firstRasterSpread - 1) < 0.10,
              "final blurred raster spread must remain within 10% across a 0.2% zoom: \(firstRasterSpread) vs \(secondRasterSpread) px")
        print("PASS: final alpha-weighted raster spread \(firstRasterSpread) → \(secondRasterSpread) px (within 10%)")



        let returned = calculate(lower, location)
        check(returned.grid == first.grid && returned.mapRect.origin.x == first.mapRect.origin.x && returned.mapRect.origin.y == first.mapRect.origin.y && returned.mapRect.width == first.mapRect.width && returned.mapRect.height == first.mapRect.height,
              "zooming out and back must recover the original world-anchored density grid")
        var panned = lower
        panned.center.longitude += lower.span.longitudeDelta * 0.05
        let shifted = calculate(panned, location)
        check(abs(screenSigma(shifted, region: panned) - firstSigma) < 0.01,
              "same-scale pan must preserve Gaussian screen spread")
        check(first.canReuse(for: PhotoLocationManager.projectedRect(for: panned), cellSize: first.cellSizeMapPoints, radius: 50),
              "covered same-scale pan must reuse the cached raster")
        var sameBucketZoom = lower
        sameBucketZoom.span.longitudeDelta *= 0.99
        check(PhotoLocationManager.cellSize(for: PhotoLocationManager.projectedRect(for: sameBucketZoom)) == first.cellSizeMapPoints,
              "1% zoom fixture must remain within the same grid bucket")
        check(!first.canReuse(for: PhotoLocationManager.projectedRect(for: sameBucketZoom), cellSize: first.cellSizeMapPoints, radius: 50),
              "1% same-cell-size zoom must refresh the continuous kernel scale")
        print("PASS: zoom round trip and same-scale pan preserve density; same-bucket zoom refreshes scale")
    }

    static func nativePanReuseRegression() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let map = MKMapView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        map.setRegion(MKCoordinateRegion(center: .init(latitude: 55, longitude: 139),
                                        span: .init(latitudeDelta: 10, longitudeDelta: 10)), animated: false)
        let fitted = map.visibleMapRect
        map.setVisibleMapRect(fitted, animated: false)
        let initial = map.visibleMapRect
        let location = PhotoLocation(id: "native-pan", coordinate: map.region.center)
        let data = calculate(map.region, location)
        for axis in ["horizontal", "vertical"] {
            for fraction in [0.01, 0.05] {
                let target = MKMapRect(x: initial.minX + (axis == "horizontal" ? fraction * initial.width : 0),
                                       y: initial.minY + (axis == "vertical" ? fraction * initial.height : 0),
                                       width: initial.width, height: initial.height)
                map.setVisibleMapRect(target, animated: false)
                let actual = map.visibleMapRect
                check(abs(actual.width / initial.width - 1) < 0.0001 && abs(actual.height / initial.height - 1) < 0.0001,
                      "native pan fixture must retain actual MapKit viewport size")
                let rect = PhotoLocationManager.projectedRect(for: map.region)
                let requestedScale = PhotoLocationManager.kernelScale(for: rect, cellSize: data.cellSizeMapPoints)
                let relativeDrift = abs(requestedScale / data.kernelScale - 1)
                check(data.mapRect.contains(rect), "native pan fixture must remain covered by the cached image")
                check(data.canReuse(for: rect, cellSize: PhotoLocationManager.cellSize(for: rect), radius: 50),
                      "native \(axis) pan \(fraction) must reuse raster despite reconstructed scale drift \(relativeDrift * 100)%")
                print("PASS: native \(axis) pan \(fraction) reuses raster; reconstructed scale drift \(relativeDrift * 100)%")
            }
        }
    }

    static func region(width: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
                           span: .init(latitudeDelta: 0.1, longitudeDelta: width / MKMapRect.world.width * 360))
    }

    static func calculate(_ region: MKCoordinateRegion, _ location: PhotoLocation) -> HeatmapData {
        PhotoLocationManager.calculateHeatmapData(locations: [location], region: region, radius: 50)
    }

    static func screenSigma(_ data: HeatmapData, region: MKCoordinateRegion) -> Double {
        var peak = (x: 0, y: 0)
        for x in 0..<data.gridWidth {
            for y in 0..<data.gridHeight where data.grid[x][y] > data.grid[peak.x][peak.y] {
                peak = (x, y)
            }
        }
        let ratio = data.grid[peak.x + 1][peak.y] / data.grid[peak.x][peak.y]
        let sigmaCells = sqrt(-1 / (2 * log(ratio)))
        return sigmaCells * data.cellSizeMapPoints / PhotoLocationManager.projectedRect(for: region).width * 1000
    }

    static func alphaScreenSigma(_ data: HeatmapData, region: MKCoordinateRegion) -> Double {
        guard let image = data.image else {
            fatalError("Core Image must be available to verify the final blurred raster")
        }
        // Redraw to a known RGBA layout. Alpha weighting removes the effect of
        // the world-anchored grid translating the peak between raster pixels.
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var mass = 0.0
        var weightedX = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let alpha = Double(rgba[(y * image.width + x) * 4 + 3])
                mass += alpha
                weightedX += alpha * (Double(x) + 0.5)
            }
        }
        check(mass > 0, "the final heatmap raster must contain visible pixels")
        let mean = weightedX / mass
        var weightedVariance = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let alpha = Double(rgba[(y * image.width + x) * 4 + 3])
                weightedVariance += alpha * pow(Double(x) + 0.5 - mean, 2)
            }
        }
        return sqrt(weightedVariance / mass) / Double(image.width) * data.mapRect.width /
            PhotoLocationManager.projectedRect(for: region).width * 1000
    }

    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }
}
