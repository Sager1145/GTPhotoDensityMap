import Foundation

/// Rendering choices are independent of the photo library and density grid.
struct HeatmapAppearance: Equatable, Sendable {
    var opacity: Double = 0.7
    var intensity: Double = 1
    var smoothing: Double = 1.5
    var palette: HeatmapPalette = .classic

    func hasSameRaster(as other: HeatmapAppearance) -> Bool {
        intensity == other.intensity && smoothing == other.smoothing && palette == other.palette
    }

    func normalizedDensity(_ density: Double) -> Double {
        min(1, max(0, density * intensity))
    }
}

struct HeatmapColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

enum HeatmapPalette: String, CaseIterable, Identifiable, Sendable {
    case classic, ember, ocean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .ember: return "Ember"
        case .ocean: return "Ocean"
        }
    }

    /// Shared by the renderer and legend, ordered from low to high density.
    var stops: [HeatmapColor] {
        let values: [(Double, Double, Double, Double)]
        switch self {
        case .classic:
            values = [(0, 0, 1, 0), (0, 0.4, 1, 0.4), (0, 0.8, 1, 0.5),
                      (0, 1, 0.5, 0.6), (0.5, 1, 0, 0.7), (1, 1, 0, 0.75),
                      (1, 0.6, 0, 0.8), (1, 0, 0, 0.85)]
        case .ember:
            values = [(0.18, 0.03, 0.28, 0), (0.38, 0.08, 0.48, 0.4),
                      (0.72, 0.16, 0.35, 0.6), (0.95, 0.4, 0.15, 0.75),
                      (1, 0.9, 0.45, 0.85)]
        case .ocean:
            values = [(0.08, 0.08, 0.35, 0), (0.12, 0.22, 0.65, 0.4),
                      (0.05, 0.55, 0.75, 0.6), (0.12, 0.8, 0.65, 0.75),
                      (0.85, 1, 0.7, 0.85)]
        }
        return values.map { HeatmapColor(red: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) }
    }

    func color(at normalizedDensity: Double) -> HeatmapColor {
        let colors = stops
        if normalizedDensity <= 0 { return colors[0] }
        if normalizedDensity >= 1 { return colors[colors.count - 1] }
        let position = normalizedDensity * Double(colors.count - 1)
        let index = min(Int(position), colors.count - 2)
        let fraction = position - Double(index)
        let lower = colors[index]
        let upper = colors[index + 1]
        return HeatmapColor(
            red: lower.red + (upper.red - lower.red) * fraction,
            green: lower.green + (upper.green - lower.green) * fraction,
            blue: lower.blue + (upper.blue - lower.blue) * fraction,
            alpha: lower.alpha + (upper.alpha - lower.alpha) * fraction
        )
    }
}
