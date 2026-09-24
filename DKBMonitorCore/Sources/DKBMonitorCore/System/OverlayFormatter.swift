import CoreGraphics
import Foundation

public enum OverlayLevel: Sendable, Equatable {
    case normal, warning, critical
}

/// A row's value as the overlay prints it, and how alarming it is.
public struct OverlayReading: Sendable, Equatable {
    public let value: String
    public let level: OverlayLevel

    public init(_ value: String, _ level: OverlayLevel = .normal) {
        self.value = value
        self.level = level
    }
}

/// Turns a sample into the overlay's text. Only numbers and units — the row
/// labels are localized by the app.
///
/// Thresholds match the menu bar popover (`MenuBarContentView`): load
/// 70/90 %, temperature 70/85 °C, so the same value is never yellow in one
/// place and blue in the other.
public enum OverlayFormatter {
    /// `nil` when this Mac has no reading for the metric; the row is hidden.
    public static func reading(_ metric: OverlayMetric, in sample: OverlaySample) -> OverlayReading? {
        switch metric {
        case .cpu:
            return sample.cpuPercent.map(percent)
        case .gpu:
            return sample.gpuPercent.map(percent)
        case .cpuTemp:
            return sample.cpuTempCelsius.map(temperature)
        case .gpuTemp:
            return sample.gpuTempCelsius.map(temperature)
        case .gpuMemory:
            return sample.gpuMemoryMB.map { OverlayReading(megabytes($0)) }
        case .memory:
            guard let used = sample.ramUsedMB, let total = sample.ramTotalMB, total > 0 else { return nil }
            let level: OverlayLevel = switch sample.memoryPressureLevel {
            case 4: .critical
            case 2: .warning
            default: .normal
            }
            return OverlayReading(String(format: "%.1f/%.0f GB", Double(used) / 1024, Double(total) / 1024), level)
        case .swap:
            return sample.swapUsedMB.map { OverlayReading(megabytes($0)) }
        case .network:
            guard let down = sample.downloadKbps, let up = sample.uploadKbps else { return nil }
            return OverlayReading("↓\(rate(down)) ↑\(rate(up))")
        case .fan:
            guard !sample.fanRPMs.isEmpty else { return nil }
            return OverlayReading(sample.fanRPMs.map { String(Int($0.rounded())) }.joined(separator: "/") + " rpm")
        case .battery:
            guard let battery = sample.batteryPercent else { return nil }
            let rounded = Int(battery.rounded())
            let charging = sample.batteryCharging == true
            let level: OverlayLevel = charging ? .normal : rounded <= 10 ? .critical : rounded <= 20 ? .warning : .normal
            return OverlayReading("\(rounded)%" + (charging ? " ⚡︎" : ""), level)
        case .power:
            return sample.systemPowerWatts.map { OverlayReading(String(format: "%.1f W", $0)) }
        case .display:
            return sample.displayHz.map { OverlayReading("\($0) Hz") }
        case .uptime:
            return sample.uptimeSecs.map { OverlayReading(uptime($0)) }
        }
    }

    private static func percent(_ value: Double) -> OverlayReading {
        let clamped = min(max(value, 0), 100)
        return OverlayReading("\(Int(clamped.rounded()))%", clamped >= 90 ? .critical : clamped >= 70 ? .warning : .normal)
    }

    private static func temperature(_ celsius: Double) -> OverlayReading {
        OverlayReading("\(Int(celsius.rounded()))°C", celsius >= 85 ? .critical : celsius >= 70 ? .warning : .normal)
    }

    private static func megabytes(_ mb: UInt64) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }

    /// KB/s below 1000, MB/s above, so the row keeps roughly the same width.
    private static func rate(_ kbps: Double) -> String {
        kbps >= 1000 ? String(format: "%.1f MB/s", kbps / 1024) : "\(Int(max(kbps, 0).rounded())) KB/s"
    }

    private static func uptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3600
        let minutes = seconds % 3600 / 60
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(minutes)m"
    }
}

/// Where the overlay panel goes on a screen. Pure geometry so it can be
/// tested without a screen; AppKit coordinates (origin bottom-left).
public enum OverlayPlacement {
    /// `visibleFrame` is the screen minus the menu bar and Dock, so the panel
    /// never covers either. A panel larger than the space left after the
    /// offset is pulled back inside rather than pushed off-screen.
    public static func frame(
        size: CGSize, corner: OverlayCorner, offsetX: Int, offsetY: Int, in visibleFrame: CGRect
    ) -> CGRect {
        let dx = CGFloat(offsetX), dy = CGFloat(offsetY)
        let x: CGFloat = switch corner {
        case .topLeft, .bottomLeft: visibleFrame.minX + dx
        case .topRight, .bottomRight: visibleFrame.maxX - dx - size.width
        }
        let y: CGFloat = switch corner {
        case .bottomLeft, .bottomRight: visibleFrame.minY + dy
        case .topLeft, .topRight: visibleFrame.maxY - dy - size.height
        }
        let clampedX = min(max(x, visibleFrame.minX), max(visibleFrame.maxX - size.width, visibleFrame.minX))
        let clampedY = min(max(y, visibleFrame.minY), max(visibleFrame.maxY - size.height, visibleFrame.minY))
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: size)
    }

    /// Which of the connected screens the overlay goes on, given their names
    /// and frames in `NSScreen.screens` order (the first is the one with the
    /// menu bar). A named screen that is not connected, or a pointer outside
    /// every screen, falls back to that first screen.
    public static func screenIndex(
        for display: OverlayDisplay, names: [String], frames: [CGRect], mouse: CGPoint
    ) -> Int {
        switch display {
        case .main:
            return 0
        case .mouse:
            // `contains` excludes the max edges, and the pointer can sit on
            // the top edge of a screen, so the edges count too.
            return frames.firstIndex { $0.insetBy(dx: -0.5, dy: -0.5).contains(mouse) } ?? 0
        case .named(let name):
            return names.firstIndex(of: name) ?? 0
        }
    }

    /// The corner and offsets that reproduce `frame` on a screen, for saving
    /// where the user dragged the overlay. The nearest corner is the one on
    /// the frame's side of the screen's centre on each axis, so the overlay
    /// keeps its place relative to that corner when its size changes later.
    public static func anchor(of frame: CGRect, in visibleFrame: CGRect) -> (corner: OverlayCorner, offsetX: Int, offsetY: Int) {
        let left = frame.midX < visibleFrame.midX
        let bottom = frame.midY < visibleFrame.midY
        let corner: OverlayCorner = switch (left, bottom) {
        case (true, true): .bottomLeft
        case (true, false): .topLeft
        case (false, true): .bottomRight
        case (false, false): .topRight
        }
        let dx = left ? frame.minX - visibleFrame.minX : visibleFrame.maxX - frame.maxX
        let dy = bottom ? frame.minY - visibleFrame.minY : visibleFrame.maxY - frame.maxY
        return (corner, max(0, Int(dx.rounded())), max(0, Int(dy.rounded())))
    }
}
