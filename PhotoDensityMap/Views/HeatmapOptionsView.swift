import SwiftUI

struct HeatmapOptionsView: View {
    @ObservedObject var photoManager: PhotoLocationManager
    @Binding var appearance: HeatmapAppearance
    @State private var spread: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Heatmap Options").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                valueLabel("Spread", value: "\(Int(spread))")
                Slider(value: $spread, in: 10...100, step: 10) { editing in
                    if !editing { photoManager.heatmapRadius = spread }
                }
                .accessibilityLabel("Heatmap spread")
                Text("Small keeps locations distinct; large blends nearby photos. Applied when you release the slider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                valueLabel("Opacity", value: "\(Int((appearance.opacity * 100).rounded()))%")
                Slider(value: $appearance.opacity, in: 0...1, step: 0.05)
                    .accessibilityLabel("Heatmap opacity")
            }
            VStack(alignment: .leading, spacing: 6) {
                valueLabel("Intensity", value: String(format: "%.1f×", appearance.intensity))
                Slider(value: $appearance.intensity, in: 0.5...3, step: 0.1)
                    .accessibilityLabel("Heatmap intensity")
                Text("Increase to make low-density areas more visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                valueLabel("Smoothing", value: appearance.smoothing == 0 ? "Off" : String(format: "%.1f×", appearance.smoothing / 1.5))
                Slider(value: $appearance.smoothing, in: 0...3, step: 0.15)
                    .accessibilityLabel("Heatmap smoothing")
            }
            Picker("Colors", selection: $appearance.palette) {
                ForEach(HeatmapPalette.allCases) { palette in
                    Text(palette.title).tag(palette)
                }
            }
            .pickerStyle(.menu)
            HeatmapGradientBar(palette: appearance.palette)
                .frame(height: 10).clipShape(Capsule())
                .accessibilityLabel("Selected colors from low to high density")
            Button("Restore Defaults") {
                appearance = HeatmapAppearance()
                spread = 50
                photoManager.heatmapRadius = spread
            }
        }
        .padding(20).frame(width: 300)
        .onAppear { spread = photoManager.heatmapRadius }
    }

    private func valueLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
