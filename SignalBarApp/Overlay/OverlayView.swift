import AppKit
import SignalBarCore
import SwiftUI

/// The overlay's content: one entry per enabled metric, label then value,
/// always light-on-dark so it reads over any wallpaper or game.
///
/// Built to redraw cheaply once a second: no animation, no `Chart` or
/// `Canvas` (the sparklines are plain shapes), and every value sits in a
/// box sized by a fixed template so "9%" becoming "10%" never changes the
/// panel's width, which would shift a right-anchored panel left and right.
struct OverlayView: View {
    let model: OverlayViewModel
    let configuration: OverlayConfiguration
    let onSizeChange: (CGSize) -> Void

    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue

    private var factor: CGFloat { configuration.scale.factor }

    private struct Row: Identifiable {
        let metric: OverlayMetric
        let reading: OverlayReading
        var id: OverlayMetric { metric }
    }

    private var rows: [Row] {
        configuration.metrics.compactMap { metric in
            OverlayFormatter.reading(metric, in: model.sample).map { Row(metric: metric, reading: $0) }
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8 * factor, style: .continuous)
        content
            .font(.system(size: 12 * factor, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            // Without a background the text needs its own edge to stay
            // readable over a white window.
            .shadow(color: .black.opacity(configuration.background == .none ? 0.9 : 0), radius: 1.2)
            .padding(.horizontal, 10 * factor)
            .padding(.vertical, 7 * factor)
            .background { background(shape) }
            .overlay {
                if model.isUnlocked {
                    shape.strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
            .environment(\.colorScheme, .dark)
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
            .fixedSize()
            .transaction { $0.animation = nil }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }

    @ViewBuilder
    private var content: some View {
        switch configuration.layout {
        case .vertical:
            Grid(alignment: .leading, horizontalSpacing: 10 * factor, verticalSpacing: 2) {
                ForEach(rows) { row in
                    GridRow {
                        label(row.metric)
                        value(row).gridColumnAlignment(.trailing)
                        if configuration.sparklines {
                            sparkline(row.metric)
                        }
                    }
                }
            }
        case .horizontal:
            HStack(spacing: 12 * factor) {
                ForEach(rows) { row in
                    HStack(spacing: 5 * factor) {
                        label(row.metric)
                        // Leading here: trailing alignment inside the
                        // fixed-width box left a gap between label and value.
                        value(row, alignment: .leading)
                        // Only where there is a trend; an empty box per
                        // metric would just be dead space in a single line.
                        if configuration.sparklines, OverlayViewModel.historyMetrics.contains(row.metric) {
                            sparkline(row.metric)
                        }
                    }
                }
            }
        }
    }

    private func label(_ metric: OverlayMetric) -> some View {
        Text(metric.overlayLabel).foregroundStyle(.white.opacity(0.65))
    }

    private func value(_ row: Row, alignment: Alignment = .trailing) -> some View {
        ZStack(alignment: alignment) {
            Text(verbatim: row.metric.widthTemplate).hidden()
            Text(verbatim: row.reading.value).foregroundStyle(row.reading.level.color)
        }
    }

    /// Always takes its space when sparklines are on, even for a metric
    /// without one, so the columns line up.
    private func sparkline(_ metric: OverlayMetric) -> some View {
        OverlaySparkline(
            values: model.histories[metric]?.values ?? [],
            capacity: OverlayRing().capacity,
            // Percentages share a fixed 0–100 scale; network has no natural
            // ceiling and scales to its own recent peak.
            upperBound: metric == .network ? nil : 100
        )
        .frame(width: 40 * factor, height: 10 * factor)
    }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        switch configuration.background {
        case .translucent: OverlayMaterial().clipShape(shape)
        case .solid: shape.fill(Color.black)
        case .none: Color.clear
        }
    }
}

/// One stroked path over the last minute, newest on the right. The line
/// starts from the right edge so a history still filling up grows leftward
/// instead of stretching across the whole width.
///
/// A `Shape` rather than a `Canvas`: measured in the test host, switching
/// sparklines on with `Canvas` added 106 MB to the process footprint (its
/// separate renderer), while a shape is drawn by the same layer tree as the
/// text around it.
private struct OverlaySparkline: View {
    let values: [Double]
    let capacity: Int
    let upperBound: Double?

    var body: some View {
        SparklineShape(values: values, capacity: capacity, upperBound: upperBound)
            .stroke(.white.opacity(0.75), lineWidth: 1)
    }
}

private struct SparklineShape: Shape {
    let values: [Double]
    let capacity: Int
    let upperBound: Double?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, capacity > 1 else { return path }
        let top = upperBound ?? max(values.max() ?? 1, 1)
        let step = rect.width / CGFloat(capacity - 1)
        let start = rect.maxX - step * CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(
                x: start + step * CGFloat(index),
                y: rect.minY + rect.height * (1 - CGFloat(min(max(value / top, 0), 1)))
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

/// A dark behind-window blur that stays "active" in a panel that is never
/// key. SwiftUI's own materials follow the window's key state and turn flat
/// grey in a non-key window.
private struct OverlayMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension OverlayLevel {
    var color: Color {
        switch self {
        case .normal: .white
        case .warning: .yellow
        case .critical: .red
        }
    }
}

extension OverlayCorner {
    var label: LocalizedStringKey {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

extension OverlayMetric {
    var overlayLabel: LocalizedStringKey {
        switch self {
        case .cpu: "CPU"
        case .cpuTemp: "CPU Temp"
        case .gpu: "GPU"
        case .gpuTemp: "GPU Temp"
        case .gpuMemory: "GPU Memory"
        case .memory: "RAM"
        case .swap: "Swap"
        case .network: "Network"
        case .fan: "Fan"
        case .battery: "Battery"
        case .power: "Power"
        case .display: "Display"
        case .uptime: "Uptime"
        }
    }

    /// The widest value this row normally prints, which sets its column
    /// width. Digits are monospaced, so any digit stands for all of them.
    var widthTemplate: String {
        switch self {
        case .cpu, .gpu: "100%"
        case .cpuTemp, .gpuTemp: "100°C"
        case .gpuMemory, .swap: "99.9 GB"
        case .memory: "99.9/128 GB"
        // Above 100 MB/s the panel widens for as long as that lasts.
        case .network: "↓99.9 MB/s ↑99.9 MB/s"
        case .fan: "9999/9999 rpm"
        case .battery: "100% ⚡︎"
        case .power: "99.9 W"
        case .display: "120 Hz"
        case .uptime: "99d 23h"
        }
    }
}
