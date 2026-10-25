import AppKit
import CoreImage

// Rasterize each immutable snapshot once, before publishing it to the UI.
enum HeatmapRasterizer {
    private static let context = CIContext()
    static func makeImage(grid: [[Double]], maxDensity: Double, appearance: HeatmapAppearance = HeatmapAppearance(), smoothingScale: Double = 1) -> CGImage? {
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
            guard !Task.isCancelled else { return nil }
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
            return appearance.smoothing == 0 ? image : applyBlur(to: image, radius: max(cellWidth, cellHeight) * appearance.smoothing * smoothingScale)
        }
        
        return nil
    }
    
    private static func applyBlur(to image: CGImage, radius: CGFloat) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let ciImage = CIImage(cgImage: image)
        
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(radius, forKey: kCIInputRadiusKey)
        
        guard let outputImage = filter?.outputImage else { return image }
        
        let extent = ciImage.extent
        
        return context.createCGImage(outputImage, from: extent)
    }
    
}

