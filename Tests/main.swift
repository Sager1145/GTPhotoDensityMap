import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

// Regressions: ignoring intensity, losing transparent empty cells, or using
// different palette stops for rendering and the legend must fail these checks.
let defaults = HeatmapAppearance()
check(defaults.opacity == 0.7, "Preserve the original overlay opacity")
check(defaults.smoothing == 1.5, "Preserve the original blur")
check(defaults.normalizedDensity(0.25) == 0.25, "Default density must remain unchanged")
var stronger = defaults
stronger.intensity = 2
check(stronger.normalizedDensity(0.25) == 0.5, "Intensity must boost the color response")
check(stronger.normalizedDensity(0.75) == 1, "Intensity must saturate at the palette endpoint")
for palette in HeatmapPalette.allCases {
    check(palette.color(at: 0).alpha == 0, "Empty cells must stay transparent")
    check(palette.color(at: -1) == palette.color(at: 0), "Clamp below the palette range")
    check(palette.color(at: 2) == palette.color(at: 1), "Clamp above the palette range")
    check(palette.color(at: 1) == palette.stops.last!, "The high-density legend and renderer must match")
    let middle = palette.color(at: 0.5)
    check((0...1).contains(middle.alpha), "Interpolated alpha must remain valid")
}
check(HeatmapPalette.classic.color(at: 1) != HeatmapPalette.ember.color(at: 1), "Palette changes must affect rendered colors")
var changed = defaults
changed.opacity = 0.1
check(changed.hasSameRaster(as: defaults), "Opacity must preserve raster cache reuse")
changed = defaults
changed.intensity = 2
check(!changed.hasSameRaster(as: defaults), "Intensity must invalidate the raster cache")
changed = defaults
changed.smoothing = 0
check(!changed.hasSameRaster(as: defaults), "Smoothing must invalidate the raster cache")
changed = defaults
changed.palette = .ocean
check(!changed.hasSameRaster(as: defaults), "Palette must invalidate the raster cache")
print("Heatmap appearance checks passed")
